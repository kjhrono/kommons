-- email_auth_kit — the kill-switch's PROJECT half: ban-aware auth.uid().
--
-- NOT a migration and NOT for the identity stack. Identity ships the
-- claim (supabase/migrations/20260930000000_email_auth_kit_bans.sql +
-- the custom access token hook env); each PROJECT stack applies this
-- ONCE so its claim reader honors the claim. Same reader the stack
-- already runs, plus one check: a live kit_banned_until claim makes
-- auth.uid() NULL — every auth.uid()-keyed RLS policy then denies, with
-- the project knowing nothing about the identity stack. Statelesss:
-- the claim rides the token the project already verifies.
--
-- Honest gap: tokens minted BEFORE the ban carry no claim and stay
-- valid until exp; refresh re-mints with the claim within one cycle.
--
-- Owner note: create-or-replace keeps the existing owner (on Supabase
-- stacks that is supabase_auth_admin — apply as a superuser, e.g.
-- `docker exec <stack>-db-1 psql -U supabase_admin -d postgres`).
-- Idempotent; safe to rerun.

create or replace function auth.uid() returns uuid
language plpgsql stable
set search_path = public, auth, extensions as $$
declare
  v_claims jsonb := current_setting('request.jwt.claims', true)::jsonb;
  v_banned timestamptz;
begin
  if v_claims is null then
    return null;
  end if;
  v_banned := nullif(v_claims ->> 'kit_banned_until', '')::timestamptz;
  if v_banned is not null and v_banned > now() then
    return null;
  end if;
  return nullif(v_claims ->> 'sub', '')::uuid;
end;
$$;

-- uid echo for verification runs; mirrors the ban semantics because it
-- just calls auth.uid().
create or replace function public.kit_whoami() returns uuid
language sql stable
set search_path = public, auth, extensions as
$$ select auth.uid() $$;
grant execute on function public.kit_whoami() to anon, authenticated;
