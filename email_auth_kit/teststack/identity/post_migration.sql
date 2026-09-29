-- Post-migration fixes for project_b — run ONCE, after GoTrue-B's
-- first-boot migration has landed (the script waits for the stub's body
-- to change). Idempotent: safe to rerun.
--
-- Ownership model (postgres is NOT a superuser on this stack, so every
-- statement must be legal for its actor):
--   * the auth schema and its claim readers are owned by auth_admin_b
--     (GoTrue-B connects as that role; the script's step-5 stub is also
--     created in-role). The readers are therefore rewritten in-role.
--   * public-schema objects are owned by postgres (step 5 ran as it) and
--     are re-asserted as postgres after the role is dropped again.

-- Act as GoTrue-B's role for everything auth-schema-owned.
grant auth_admin_b to postgres;
set role auth_admin_b;

-- (Claim readers and schema grants below run as auth_admin_b.)

-- The modern claim readers (replace GoTrue's bundled legacy readers,
-- which modern PostgREST cannot satisfy).
create or replace function auth.uid() returns uuid as $$
  select nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'sub', '')::uuid;
$$ language sql stable;

create or replace function auth.role() returns text as $$
  select nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '');
$$ language sql stable;

reset role;
revoke auth_admin_b from postgres;

-- Schema access for the API roles — granted as the auth schema's OWNER
-- (postgres created it in step 5's stub). GoTrue's own migration grants
-- are silent no-ops when the schema pre-exists, which is exactly what
-- broke whoami() ("permission denied for schema auth") on a virgin DB.
grant usage on schema auth to anon, authenticated, authenticator_b;

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
