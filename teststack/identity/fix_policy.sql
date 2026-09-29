-- Recreate the RLS policy + whoami() on project_b (they were lost in
-- the GoTrue-B migration churn; the auth schema was recreated after
-- the public schema objects were made).
drop policy if exists proof_owner_all on public.identity_proof;
create policy proof_owner_all on public.identity_proof
  for all using (owner = auth.uid()) with check (owner = auth.uid());

create or replace function public.whoami() returns uuid
language sql stable as $$ select auth.uid() $$;
grant execute on function public.whoami() to anon, authenticated;

create or replace function public.jwt_debug() returns text
language sql stable as
$$ select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '<missing>') $$;
grant execute on function public.jwt_debug() to anon, authenticated;
