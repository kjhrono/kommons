# identity/ — central-identity prototype (Phase 0)

A working two-stack proof of [docs/CENTRAL_IDENTITY.md](../../docs/CENTRAL_IDENTITY.md):
one identity stack (the kit's teststack) and one project stack sharing a
JWT secret. **The proof ran green — all 12 checks** (see `proof.py`).

## Topology

```
identity stack A (supabase teststack, CLI-managed, port 54321)
  auth.users · kit functions (host-run deno) · Mailpit
        │ JWT secret (GOTRUE_JWT_SECRET == PGRST_JWT_SECRET of B)
        ▼
project stack B (this dir, docker compose, ports 31000/31001)
  postgrest-b  → project_b database (own auth schema, own data)
  auth-b       → signup-DISABLED GoTrue (own project_b.auth)
```

Both B containers join `supabase_network_email-auth-kit-test` and reach
the shared Postgres server; B's services point at the **project_b**
database — the exact production shape (own DB per project, same server).

## What was proven (proof.py, 12/12)

1. Kit-native signup on A creates a user (no session), e-mail code
   confirms it; sign-in yields a real JWT (`role=authenticated`).
2. **A's JWT verifies on B**: insert into B's RLS table stamps
   `auth.uid()` from the foreign token; the owner sees exactly their row.
3. Isolation: a second A-user sees zero rows; anon sees zero rows;
   `whoami()` echoes the foreign uid; anon's is null.
4. B's own GoTrue **refuses signups** — identity A is the only door.

## Gotchas (each cost a debug round — do not skip)

1. **Reserved roles**: Supabase's `authenticator` / `supabase_auth_admin`
   are reserved; a second stack carries its own twins
   (`authenticator_b` with membership in `anon`+`authenticated`,
   `auth_admin_b` owning the auth schema).
2. **`postgres` is not superuser** on Supabase Postgres. To create or
   grant schema-auth-owned objects: `grant auth_admin_b to postgres;`
   transiently, do the work `set role auth_admin_b;`, then revoke.
3. **GoTrue's bundled migration writes the LEGACY `auth.uid()`** (reads
   `request.jwt.claim.sub`, which modern PostgREST never sets). After
   GoTrue-B migrates, restore the modern readers of
   `request.jwt.claims` — otherwise every RLS check silently sees NULL.
4. **RLS stamp columns need `default auth.uid()`** — an insert omitting
   the column sends NULL and trips WITH CHECK.
5. PostgREST-B caches schema; `docker compose restart postgrest-b` after
   DDL, and the auth schema's USAGE grant must come from its OWNER.

## Run it

```bash
# one-time (identity stack A must be up: teststack/ `supabase start`)
docker exec supabase_db_email-auth-kit-test psql -U postgres \
  -c "create role authenticator_b login password 'b-prototype-authenticator-pw' noinherit;
      grant anon, authenticated to authenticator_b;
      create role auth_admin_b login password 'b-prototype-auth-pw' noinherit;
      create database project_b;"
docker exec -i supabase_db_email-auth-kit-test psql -U postgres -d project_b \
  < teststack/identity/project_b_schema.sql
# …start B (docker compose up -d in this dir), let GoTrue migrate, then
# run the post-migration block at the bottom of project_b_schema.sql and
# restart postgrest-b.
python3 teststack/identity/proof.py       # 12 checks
```

The compose file carries the two extracted secrets (A's JWT secret and
A's PostgREST JWKS env) — regenerated from stack A's containers if you
rebuild A (`supabase stop/start` changes them).
