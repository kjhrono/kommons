-- postgres is not superuser here (supabase_admin is), so the schema's
-- OWNER grants its own usage.
set role auth_admin_b;
grant usage on schema auth to anon, authenticated, authenticator_b;
reset role;
select has_schema_privilege('anon', 'auth', 'USAGE') as anon_ok,
       has_schema_privilege('authenticated', 'auth', 'USAGE') as authed_ok;
select nspacl from pg_namespace where nspname = 'auth';
set request.jwt.claims = '{"sub":"a80797f8-659b-46c8-96c7-31e862f12d57","role":"authenticated"}';
set role authenticated;
select auth.uid() as direct_uid;
select public.whoami() as via_function;
reset role;
