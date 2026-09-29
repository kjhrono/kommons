-- Post-migration fixes for project_b — run ONCE, after GoTrue-B has
-- migrated its schema (its bundled migration writes the LEGACY
-- auth.uid()/auth.role() readers, which modern PostgREST cannot satisfy).
-- Idempotent: safe to rerun.
grant auth_admin_b to postgres;
set role auth_admin_b;
grant usage on schema auth to anon, authenticated, authenticator_b;

-- The modern claim readers, installed AS THE OWNER (postgres lacks
-- USAGE at this point in a fresh boot, so this must run in-role).
create or replace function auth.uid() returns uuid as $$
  select nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'sub', '')::uuid;
$$ language sql stable;

create or replace function auth.role() returns text as $$
  select nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '');
$$ language sql stable;
reset role;
revoke auth_admin_b from postgres;

-- Public-schema objects (re-asserted; policies have no IF NOT EXISTS).
drop policy if exists proof_owner_all on public.identity_proof;
create policy proof_owner_all on public.identity_proof
  for all using (owner = auth.uid()) with check (owner = auth.uid());

create or replace function public.whoami() returns uuid
language sql stable as $$ select auth.uid() $$;
grant execute on function public.whoami() to anon, authenticated;

grant all on public.identity_proof to authenticated;
grant select on public.identity_proof to anon;
revoke insert, update, delete on public.identity_proof from anon;
alter table public.identity_proof enable row level security;
