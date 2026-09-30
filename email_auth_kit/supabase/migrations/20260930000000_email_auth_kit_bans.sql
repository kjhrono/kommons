-- email_auth_kit — the kill-switch: identity-level ban propagated to
-- every project stack through the JWT itself.
--
-- Two halves, one per plane:
--
--   AUTH PLANE (identity): the kit's edge functions call GoTrue's admin
--     API to set auth.users.banned_until — signed-in callers never touch
--     this schema. GoTrue refuses sign-ins/refreshes natively.
--
--   DATA PLANE (every project): the custom access token hook embeds a
--     kit_banned_until claim in every token MINTED OR REFRESHED while a
--     ban is live. A project only needs a ban-aware auth.uid() (the kit
--     provides the exact SQL in docs/) — a live claim ⇒ NULL uid ⇒ every
--     auth.uid()-keyed RLS policy denies. No cross-stack reads, no mirror
--     tables: the claim rides the token the project already verifies.
--
-- Honesty (docs/CENTRAL_IDENTITY.md §"revocation"): tokens minted BEFORE
-- the ban keep the claim they were born with and stay valid on stateless
-- verifiers until exp (the project can shorten JWT_EXP; refresh re-mints
-- with the claim within seconds of the ban). This primitive kills the
-- account's future, not its past second.
--
-- Idempotent and additive, like the rest of the kit.

create table if not exists public.auth_kit_bans (
  user_id      uuid primary key references auth.users (id) on delete cascade,
  banned_until timestamptz,
  reason       text,
  set_at       timestamptz not null default now()
);

alter table public.auth_kit_bans enable row level security;
revoke all on public.auth_kit_bans from anon, authenticated;

-- Service-role set/unset. Mirror of auth_kit_find_user_id's exposure:
-- SECURITY DEFINER, EXECUTE revoked from everyone but service_role
-- (service_role bypasses grants; proven live by the kit's other RPCs).
create or replace function public.auth_kit_set_ban(
  p_email text,
  p_banned_until timestamptz,   -- null lifts the ban
  p_reason text default null
) returns boolean
language plpgsql volatile security definer
set search_path = public, auth, extensions as $$
declare
  v_uid uuid;
begin
  select id into v_uid from auth.users where email = lower(p_email) limit 1;
  if v_uid is null then
    return false;
  end if;

  if p_banned_until is null then
    delete from public.auth_kit_bans where user_id = v_uid;
    return true;
  end if;

  insert into public.auth_kit_bans (user_id, banned_until, reason)
  values (v_uid, p_banned_until, p_reason)
  on conflict (user_id) do update
    set banned_until = excluded.banned_until,
        reason       = excluded.reason,
        set_at       = now();
  return true;
end;
$$;

revoke all on function
  public.auth_kit_set_ban(text, timestamptz, text)
  from public, anon, authenticated;

-- The claim: one function, wired in config.toml as
-- [auth.hook.custom_access_token] — GoTrue calls it on every sign-in and
-- refresh, so live bans land in the token within one refresh.
--
-- SECURITY DEFINER on purpose: the caller is GoTrue's own role, and the
-- kit's ban table is RLS-locked with zero policies — an invoker-rights
-- read would silently see no rows and no claim. As definer (the migration
-- owner, postgres) both auth.users and auth_kit_bans are readable.
create or replace function public.auth_kit_custom_access_token(event jsonb)
returns jsonb language plpgsql stable security definer
set search_path = public, auth, extensions as $$
declare
  v_uid    uuid;
  v_banned timestamptz;
  v_now    timestamptz := now();
begin
  -- Hook payloads carry the user id at the top level (user_id); older
  -- shapes nest it under user.id. Accept either.
  v_uid := nullif(event ->> 'user_id', '')::uuid;
  if v_uid is null then
    v_uid := nullif(event #>> '{user,id}', '')::uuid;
  end if;
  if v_uid is null then
    return event;
  end if;

  -- Kit table first (the kit's own switch), then GoTrue's native column —
  -- whichever is live wins. Rows with a passed banned_until are litter:
  -- left in place deliberately, pruning is a maintenance job, not a
  -- token-time cost.
  select coalesce(b.banned_until, u.banned_until)
    into v_banned
    from auth.users u
    left join public.auth_kit_bans b on b.user_id = u.id
   where u.id = v_uid;

  if v_banned is not null and v_banned > v_now then
    return jsonb_set(event, '{claims,kit_banned_until}', to_jsonb(v_banned));
  end if;
  return event;
end;
$$;

-- The blanket revoke below strips the default PUBLIC grant — GoTrue's
-- role must keep (or get back) EXECUTE or every sign-in breaks. Grant
-- only when the role exists (CLI, self-hosted and hosted all carry it).
revoke all on function
  public.auth_kit_custom_access_token(jsonb)
  from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    grant execute on function public.auth_kit_custom_access_token(jsonb)
      to supabase_auth_admin;
  end if;
end
$$;
