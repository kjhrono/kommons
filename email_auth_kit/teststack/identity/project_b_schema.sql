-- project_b provisioning (run as postgres INSIDE the project_b database).
-- Complete recipe for a "project stack" under central identity: its own
-- database, its own auth schema owned by the project's auth admin, B-owned
-- connection roles, and owner-scoped RLS on the proof table.
--
-- Gotchas this encodes (each cost a debug round in the first run):
--   * Supabase's `authenticator`/`supabase_auth_admin` are RESERVED roles —
--     a second stack carries its own twins (`authenticator_b`, `auth_admin_b`).
--   * `postgres` here is not superuser: to create/grant objects owned by
--     `auth_admin_b`, membership in it is granted TRANSIENTLY (see bottom).
--   * GoTrue's bundled migration writes the LEGACY auth.uid() (reading
--     `request.jwt.claim.sub`, which modern PostgREST never sets). The
--     modern implementation (reading the `request.jwt.claims` JSON) must be
--     restored AFTER GoTrue-B has migrated its schema.
--   * An RLS table whose rows are stamped with the caller's uid needs the
--     column defaulted to auth.uid() — an insert that omits the column
--     otherwise sends NULL and trips WITH CHECK.

-- ---- roles are created cluster-wide, before this script: ------------------
--   create role authenticator_b login password '…' noinherit;
--   grant anon, authenticated to authenticator_b;
--   create role auth_admin_b login password '…' noinherit;

grant auth_admin_b to postgres;                    -- transient membership

create schema if not exists auth authorization auth_admin_b;
grant usage, create on schema public to auth_admin_b;
grant create on schema public to authenticator_b;

revoke auth_admin_b from postgres;                 -- membership revoked below

-- ---- the proof table: owner-scoped RLS ------------------------------------
create table if not exists public.identity_proof (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null default auth.uid(),          -- the RLS-stamp default
  label text not null,
  created_at timestamptz not null default now()
);
alter table public.identity_proof enable row level security;
drop policy if exists proof_owner_all on public.identity_proof;
create policy proof_owner_all on public.identity_proof
  for all using (owner = auth.uid()) with check (owner = auth.uid());
grant all on public.identity_proof to authenticated;
grant select on public.identity_proof to anon;
revoke insert, update, delete on public.identity_proof from anon;

-- ---- helpers ---------------------------------------------------------------
create or replace function public.whoami() returns uuid
language sql stable as $$ select auth.uid() $$;
create or replace function public.jwt_debug() returns text
language sql stable as
$$ select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '<missing>') $$;

-- ---- AFTER GoTrue-B has migrated (run once the auth schema is populated) ---
-- Restore the modern claim readers over the bundled legacy ones and give
-- the calling roles USAGE on the auth schema (owned by auth_admin_b):
--   grant auth_admin_b to postgres;
--   set role auth_admin_b;
--     grant usage on schema auth to anon, authenticated, authenticator_b;
--   reset role;
--   revoke auth_admin_b from postgres;
--   create or replace function auth.uid() returns uuid as $$
--     select nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'sub', '')::uuid;
--   $$ language sql stable;
--   create or replace function auth.role() returns text as $$
--     select nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '');
--   $$ language sql stable;
-- (kept as a comment: it must run after GoTrue's migrations, not before)
