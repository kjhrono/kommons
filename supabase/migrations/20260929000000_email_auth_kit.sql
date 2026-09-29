-- email_auth_kit — generic, project-agnostic email identity flows.
--
-- One table (public.auth_events) plus three helpers. Everything is
-- idempotent and additive; safe to apply on any mediasart project's
-- Supabase stack (hosted or self-hosted on the VM).
--
-- Design rules (shared with the edge functions):
--   * codes/tokens are stored HASHED (sha256); plaintext only in email
--   * single-use consumption with attempt counting and expiry
--   * constant-time comparison, per-email+kind rate limits
--   * anon/authenticated get NOTHING here; service_role only
--
-- Requires: pgcrypto for gen_random_bytes (preinstalled on every
-- Supabase stack, in the `extensions` schema — hence the search_path
-- below; on vanilla Postgres it installs into `public`). Hashing uses
-- Postgres core sha256() (PG11+), so no digest() dependency.
-- Idempotent: create-or-replace + if-not-exists throughout.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Audit / challenge table
-- ---------------------------------------------------------------------------
create table if not exists public.auth_events (
  id          uuid primary key default gen_random_uuid(),
  email       text not null,
  kind        text not null check (kind in ('email_code','reset_token')),
  code_hash   text not null,                       -- sha256 hex of the code/token
  attempts    int  not null default 0,
  max_attempts int not null default 5,
  expires_at  timestamptz not null,
  consumed_at timestamptz,
  ip          text,
  user_agent  text,
  created_at  timestamptz not null default now()
);

create index if not exists auth_events_email_kind_idx
  on public.auth_events (email, kind, created_at desc);

alter table public.auth_events enable row level security;

-- No policies: RLS with zero policies means only service_role (the
-- edge functions, via the service key) can read/write. Studio admins
-- read it through the postgres role, not the API.

revoke all on public.auth_events from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Rate limit guard — called by the functions before issuing anything.
-- Returns true when < limit rows were created in the window.
-- ---------------------------------------------------------------------------
create or replace function public.auth_event_rate_ok(
  p_email text,
  p_kind  text,
  p_window interval,
  p_limit  int
) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select count(*) < p_limit
  from public.auth_events
  where email = lower(p_email)
    and kind = p_kind
    and created_at > now() - p_window;
$$;

-- ---------------------------------------------------------------------------
-- Issue a challenge: inserts a fresh row, returns (plaintext, row_id).
-- The caller e-mails the plaintext; the DB keeps only the hash.
-- p_code_space: 'digits' → 6-digit numeric code, else 32-byte token.
-- ---------------------------------------------------------------------------
create or replace function public.request_auth_event(
  p_email text,
  p_kind  text,
  p_ttl   interval,
  p_code_space text default 'digits',
  p_ip    text default null,
  p_user_agent text default null
) returns table (plaintext text, event_id uuid)
language plpgsql volatile security definer
set search_path = public, extensions as $$
declare
  v_plain text;
  v_id uuid;
begin
  -- invalidate any outstanding challenge of the same kind for the email
  update public.auth_events
     set consumed_at = now()
   where email = lower(p_email)
     and kind = p_kind
     and consumed_at is null;

  v_plain := case
    when p_code_space = 'digits'
      then lpad((floor(random() * 1000000))::int::text, 6, '0')
    else encode(gen_random_bytes(32), 'hex')
  end;

  insert into public.auth_events (email, kind, code_hash, expires_at, ip, user_agent)
  values (lower(p_email), p_kind, encode(sha256(convert_to(v_plain, 'UTF8')), 'hex'),
          now() + p_ttl, p_ip, p_user_agent)
  returning id into v_id;

  return query select v_plain, v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Consume a challenge: constant-time-ish compare, attempt counting,
-- expiry, single-use. Returns true at most once per event.
-- ---------------------------------------------------------------------------
create or replace function public.consume_auth_event(
  p_event_id uuid,
  p_presented text,
  p_kind text
) returns boolean
language plpgsql volatile security definer
set search_path = public, extensions as $$
declare
  v_row public.auth_events%rowtype;
  v_ok boolean := false;
begin
  select * into v_row
    from public.auth_events
   where id = p_event_id and kind = p_kind
   for update;

  if not found then
    return false;
  end if;

  if v_row.consumed_at is not null or v_row.expires_at < now() then
    return false;
  end if;

  -- p_presented arrives already lowercased/trimmed by the caller.
  v_ok := v_row.code_hash = encode(sha256(convert_to(p_presented, 'UTF8')), 'hex');

  if v_ok then
    update public.auth_events set consumed_at = now() where id = v_row.id;
  else
    update public.auth_events
       set attempts = attempts + 1
     where id = v_row.id;
    -- lock the challenge after max failed attempts
    if v_row.attempts + 1 >= v_row.max_attempts then
      update public.auth_events set consumed_at = now() where id = v_row.id;
    end if;
  end if;

  return v_ok;
end;
$$;

-- Find a user id by email. The edge functions can't read auth.users
-- through PostgREST (the auth schema is never exposed to the API), and
-- paginating GoTrue's listUsers is a trap — so the lookup happens
-- INSIDE the database, SECURITY DEFINER, exposed only to service_role.
create or replace function public.auth_kit_find_user_id(p_email text)
returns uuid
language sql stable security definer
set search_path = public, auth, extensions as $$
  select id from auth.users where email = lower(p_email) limit 1;
$$;

-- Lock everything down: PUBLIC gets EXECUTE by default on functions,
-- so revoke from everyone except service_role (which bypasses grants).
revoke all on function
  public.auth_event_rate_ok(text, text, interval, integer),
  public.request_auth_event(text, text, interval, text, text, text),
  public.consume_auth_event(uuid, text, text),
  public.auth_kit_find_user_id(text)
  from public, anon, authenticated;
