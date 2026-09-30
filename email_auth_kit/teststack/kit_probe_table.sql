-- kit_probe — the acceptance harness's owner-scoped RLS table
-- (docs/PHASE1_VM_ROLLOUT.md §4). Apply once per project stack when
-- running verify_vm_project.sh against it (idempotent; safe to leave
-- in place afterwards — only the harness's own rows ever land here).
create table if not exists public.kit_probe (
  id         uuid primary key default gen_random_uuid(),
  owner      uuid not null default auth.uid(),
  label      text not null,
  created_at timestamptz not null default now()
);
alter table public.kit_probe enable row level security;
drop policy if exists kit_probe_owner_all on public.kit_probe;
create policy kit_probe_owner_all on public.kit_probe
  for all using (owner = auth.uid()) with check (owner = auth.uid());
grant all on public.kit_probe to authenticated;
revoke all on public.kit_probe from anon;
