-- ACL diagnostic: who may use schema auth in project_b?
select nspname,
       has_schema_privilege('anon', nspname, 'USAGE') as anon_ok,
       has_schema_privilege('authenticated', nspname, 'USAGE') as authed_ok,
       has_schema_privilege('authenticator_b', nspname, 'USAGE') as conn_ok
from pg_namespace where nspname = 'auth';

select has_function_privilege('authenticated', 'public.whoami()', 'EXECUTE') as whoami_exec;

-- live test under the exact production conditions
set request.jwt.claims = '{"sub":"a80797f8-659b-46c8-96c7-31e862f12d57","role":"authenticated"}';
set role authenticated;
select auth.uid() as direct_uid;
select public.whoami() as via_function;
reset role;
