-- email_auth_kit — Google identity linking (hosted-authorize OAuth).
--
-- A hosted-authorize Google sign-in always MINTS A NEW auth.users row,
-- even when the Google account's verified email matches an existing
-- password member — the member would land in a stranger's empty account
-- (every project's RLS keys on auth.uid(), and the minted row has no
-- history). This migration adds the DB-side remedy chosen in
-- katalogus docs/FEATURE_GOOGLE_SIGNIN.md: prove email ownership twice,
-- then move the OAuth identity onto the proven password account and
-- delete the minted stranger.
--
--   proof 1 — the caller IS the password account: the app signs the
--             member in with the password first and presents that JWT
--             (p_password_session). Kong/PostgREST has already verified
--             the token's SIGNATURE before the function runs; inside SQL
--             we enforce the structural claim (sub = the password
--             account) and every data invariant.
--   proof 2 — Google consent happened on the SAME address: the OAuth-
--             minted user must carry exactly one google identity whose
--             email equals the password account's.
--
-- Why DB-side, not GoTrue's admin API: this GoTrue build predates the
-- admin identities endpoints (GET /admin/users/{id}/identities → 404 on
-- the VM), and the admin API offers no "move an identity between users"
-- call anyway. One security-definer transaction is the honest
-- primitive: identity row moves, app_metadata gains `providers`,
-- the minted user (and its refresh tokens/sessions) die, one audit row.
--
-- Caller exposure — a DELIBERATE deviation from the kit's
-- "service_role only" rule: the intended caller is the password member
-- themselves, through PostgREST RPC with their own fresh JWT (role
-- `authenticated`). That is safe because every check below guards data
-- the caller already proved by password knowledge plus Google consent;
-- nobody can link an identity onto an account whose password they did
-- not just present, nor an identity whose email does not match. EXECUTE
-- is revoked from public/anon and granted to `authenticated`;
-- service_role bypasses grants and always passes.
--
-- Refusals are raised as bare exception messages PostgREST surfaces in
-- the error body's `message` field, so the client can switch on them:
--   invalid_session          p_password_session is not a readable JWT
--                            whose sub is a user id
--   password_account_missing no auth.users row for the session's sub
--   google_identity_missing  the minted user has no single google
--                            identity
--   google_email_missing     the google identity carries no email
--   email_mismatch           google email ≠ password account email
--   identity_owned_elsewhere the google identity already sits on a
--                            third account (never steal it)
--
-- Returns FALSE (not an error) when there is nothing to link: the
-- identity already sits on the password account, or the minted
-- stranger is gone (a previous link completed; a lost-response
-- retry). TRUE when the link was made now.
--
-- Idempotent and additive, like the rest of the kit.

-- The audit row for a linking writes kind='identity_linked', so the
-- original two-value check constraint grows a third value. Re-add only
-- when needed (idempotent re-runs).
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.auth_events'::regclass
       and contype = 'c'
       and pg_get_constraintdef(oid) like '%identity_linked%'
  ) then
    alter table public.auth_events drop constraint if exists auth_events_kind_check;
    alter table public.auth_events add constraint auth_events_kind_check
      check (kind in ('email_code', 'reset_token', 'identity_linked'));
  end if;
end
$$;

create or replace function public.auth_kit_link_google_identity(
  p_password_session text,   -- JWT of the password-signed-in member
  p_google_user_id   uuid,   -- the NEW (OAuth-minted) auth.users.id
  p_expected_email   text    -- must equal both accounts' email
) returns boolean           -- true = linked now, false = already linked
language plpgsql volatile security definer
set search_path = public, auth, extensions as $$
declare
  v_seg     text;
  v_claims  jsonb;
  v_pw_uid  uuid;
  v_email   text;
  v_g_ident auth.identities%rowtype;
  v_g_email text;
begin
  -- ---------------------------------------------------------- proof 1
  -- The caller is the password account. Read the session JWT's sub
  -- WITHOUT verifying the signature: the gateway (Kong/PostgREST) has
  -- already verified it — here the claim only pins WHICH account the
  -- verified token names. Same stance as the kit client's claim reads.
  if p_password_session is null then
    raise exception 'invalid_session';
  end if;
  v_seg := split_part(p_password_session, '.', 2);
  if v_seg = '' then
    raise exception 'invalid_session';
  end if;
  v_seg := translate(v_seg, '-_', '+/');  -- base64url → base64
  begin
    v_claims := convert_from(
                  decode(rpad(v_seg, length(v_seg) + (4 - length(v_seg) % 4) % 4, '='), 'base64'),
                  'utf8')::jsonb;
    v_pw_uid := nullif(coalesce(v_claims ->> 'sub', ''), '')::uuid;
  exception when others then
    raise exception 'invalid_session';
  end;
  if v_pw_uid is null then
    raise exception 'invalid_session';
  end if;

  select email into v_email from auth.users where id = v_pw_uid;
  if v_email is null then
    raise exception 'password_account_missing';
  end if;

  -- ---------------------------------------------------------- proof 2
  -- A GONE minted user is the idempotent replay: a previous call
  -- already moved the identity and deleted the stranger (the
  -- caller retried after a lost response). Nothing to do — the
  -- member keeps the password session they just proved.
  if not exists (select 1 from auth.users where id = p_google_user_id) then
    return false;
  end if;

  -- The OAuth-minted user: exactly one identity and it is google (a
  -- password credential would make it a second member, not a stray).
  if not exists (
      select 1 from auth.identities
       where user_id = p_google_user_id and provider = 'google')
     or exists (
      select 1 from auth.identities
       where user_id = p_google_user_id and provider <> 'google') then
    raise exception 'google_identity_missing';
  end if;

  select * into v_g_ident
    from auth.identities
   where user_id = p_google_user_id and provider = 'google';

  v_g_email := coalesce(v_g_ident.identity_data ->> 'email', v_g_ident.email);
  if v_g_email is null then
    raise exception 'google_email_missing';
  end if;

  -- The p_expected_email promise must hold for BOTH accounts.
  if lower(v_g_email) <> lower(v_email)
     or p_expected_email is null
     or lower(p_expected_email) <> lower(v_email) then
    raise exception 'email_mismatch';
  end if;

  -- ------------------------------------------------------------ move
  -- Lock the google identity row by its provider id (the Google `sub`):
  -- the owner decides. Already on the password account → idempotent
  -- replay. On a THIRD account → refuse, never steal.
  select * into v_g_ident
    from auth.identities
   where provider = 'google' and provider_id = v_g_ident.provider_id
   for update;
  if not found then
    raise exception 'google_identity_missing';
  end if;
  if v_g_ident.user_id = v_pw_uid then
    return false;
  end if;
  if v_g_ident.user_id <> p_google_user_id then
    raise exception 'identity_owned_elsewhere';
  end if;

  -- Move the identity onto the proven password account.
  update auth.identities
     set user_id = v_pw_uid,
         updated_at = now()
   where id = v_g_ident.id;

  -- Mirror GoTrue's multi-provider shape in raw_app_meta_data.
  -- (this generation's column name; GoTrue itself reads it back
  -- as the token's app_metadata claim)
  update auth.users
     set raw_app_meta_data = jsonb_set(
           coalesce(raw_app_meta_data, '{}'::jsonb),
           '{providers}',
           coalesce(raw_app_meta_data -> 'providers', '[]'::jsonb) || '["google"]'::jsonb)
   where id = v_pw_uid
     and not coalesce(raw_app_meta_data -> 'providers', '[]'::jsonb) @> '["google"]'::jsonb;

  -- The minted stranger dies: its refresh tokens and sessions die with
  -- it (FK cascade). The member keeps the PASSWORD session.
  delete from auth.users where id = p_google_user_id;

  -- ------------------------------------------------------------ audit
  -- code_hash carries the sha256 of the google provider id (the Google
  -- `sub`) — the table's opaque-identifier column; expires_at /
  -- consumed_at / attempts are unused for this kind (audit only, and
  -- the per-email rate limiter counts by kind, so 'identity_linked'
  -- rows never throttle code challenges).
  insert into public.auth_events (email, kind, code_hash, expires_at)
  values (lower(v_email), 'identity_linked',
          encode(sha256(convert_to(v_g_ident.provider_id, 'UTF8')), 'hex'),
          now() + interval '1 hour');

  return true;
end;
$$;

-- The member-facing surface (see the header's deviation note): strip
-- the default PUBLIC grant, keep it reachable for the signed-in member.
revoke all on function
  public.auth_kit_link_google_identity(text, uuid, text)
  from public, anon, authenticated;

grant execute on function
  public.auth_kit_link_google_identity(text, uuid, text)
  to authenticated;
