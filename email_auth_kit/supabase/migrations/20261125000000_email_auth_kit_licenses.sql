-- email_auth_kit — per-app premium: purchases, the one offline device,
-- the online audit and per-app suspensions.
--
--   kit_entitlements      what each account bought, per app. Written only
--                         by the license function's service-role `grant` /
--                         `revoke` (the purchase backend calls them after
--                         verifying the store receipt).
--   kit_offline_licenses  the ONE device per (account, app) allowed to use
--                         premium offline, by its hardware public key.
--   kit_license_moves     every hand-over to a new device (rate limit).
--   kit_license_reports   what apps reported using when they came online.
--   kit_app_bans          per-app strikes and suspensions (never the
--                         account-wide ban: that one stays auth_kit_bans).
--
-- The token hook gains two claims, so every project stack can enforce
-- premium in RLS with no cross-stack read (same idea as kit_banned_until):
--
--   kit_entitlements  { "<app>": { "plan": "premium", "features": [...] } }
--   kit_app_bans      { "<app>": { "level": "suspended", "until": ... } }
--
-- All tables are RLS-locked with zero policies: only the service role
-- (the license function) reads or writes them. Idempotent and additive.

create table if not exists public.kit_entitlements (
  user_id      uuid not null references auth.users (id) on delete cascade,
  app_id       text not null check (app_id ~ '^[a-z0-9_-]{1,40}$'),
  plan         text not null default 'free' check (plan in ('free', 'premium')),
  features     text[] not null default '{}',
  since        timestamptz not null default now(),
  revoked_at   timestamptz,
  source       text,          -- play | appstore | stripe | manual
  purchase_ref text,          -- the store's order / transaction id
  updated_at   timestamptz not null default now(),
  primary key (user_id, app_id)
);

create table if not exists public.kit_offline_licenses (
  user_id      uuid not null references auth.users (id) on delete cascade,
  app_id       text not null,
  license_id   uuid not null default gen_random_uuid(),
  device_key   text not null, -- base64 SPKI of the device's hardware key
  device_label text,
  platform     text,
  issued_at    timestamptz not null default now(),
  expires_at   timestamptz not null,
  primary key (user_id, app_id)
);

create table if not exists public.kit_license_moves (
  id         bigserial primary key,
  user_id    uuid not null references auth.users (id) on delete cascade,
  app_id     text not null,
  from_key   text,
  to_key     text not null,
  moved_at   timestamptz not null default now()
);
create index if not exists kit_license_moves_recent
  on public.kit_license_moves (user_id, app_id, moved_at desc);

create table if not exists public.kit_license_reports (
  id          bigserial primary key,
  user_id     uuid not null references auth.users (id) on delete cascade,
  app_id      text not null,
  used        jsonb not null,
  entitled    jsonb,
  tamper      text[] not null default '{}', -- what the app found wrong locally
  mismatch    boolean not null,
  outcome     text not null,  -- ok | grace | warned | suspended
  reported_at timestamptz not null default now()
);
alter table public.kit_license_reports
  add column if not exists tamper text[] not null default '{}';

create table if not exists public.kit_app_bans (
  user_id    uuid not null references auth.users (id) on delete cascade,
  app_id     text not null,
  level      text not null check (level in ('warned', 'suspended')),
  strikes    int not null default 0,
  until      timestamptz,     -- null with 'suspended' = until reviewed
  reason     text,
  updated_at timestamptz not null default now(),
  primary key (user_id, app_id)
);

alter table public.kit_entitlements enable row level security;
alter table public.kit_offline_licenses enable row level security;
alter table public.kit_license_moves enable row level security;
alter table public.kit_license_reports enable row level security;
alter table public.kit_app_bans enable row level security;
revoke all on public.kit_entitlements, public.kit_offline_licenses,
  public.kit_license_moves, public.kit_license_reports, public.kit_app_bans
  from anon, authenticated;

-- The hook, re-declared: the ban claim exactly as before, plus the two
-- premium claims. SECURITY DEFINER for the same reason as before (the
-- tables have no policies; GoTrue's role must still read them).
create or replace function public.auth_kit_custom_access_token(event jsonb)
returns jsonb language plpgsql stable security definer
set search_path = public, auth, extensions as $$
declare
  v_uid    uuid;
  v_banned timestamptz;
  v_now    timestamptz := now();
  v_ents   jsonb;
  v_bans   jsonb;
begin
  v_uid := nullif(event ->> 'user_id', '')::uuid;
  if v_uid is null then
    v_uid := nullif(event #>> '{user,id}', '')::uuid;
  end if;
  if v_uid is null then
    return event;
  end if;

  select coalesce(b.banned_until, u.banned_until)
    into v_banned
    from auth.users u
    left join public.auth_kit_bans b on b.user_id = u.id
   where u.id = v_uid;

  if v_banned is not null and v_banned > v_now then
    event := jsonb_set(event, '{claims,kit_banned_until}', to_jsonb(v_banned));
  end if;

  -- Live purchases, per app.
  select jsonb_object_agg(e.app_id, jsonb_build_object(
           'plan', e.plan,
           'features', to_jsonb(e.features),
           'since', extract(epoch from e.since)::bigint))
    into v_ents
    from public.kit_entitlements e
   where e.user_id = v_uid
     and e.revoked_at is null;
  if v_ents is not null then
    event := jsonb_set(event, '{claims,kit_entitlements}', v_ents);
  end if;

  -- Live per-app suspensions (a warning is not a suspension).
  select jsonb_object_agg(b.app_id, jsonb_build_object(
           'level', b.level, 'until', b.until))
    into v_bans
    from public.kit_app_bans b
   where b.user_id = v_uid
     and b.level = 'suspended'
     and (b.until is null or b.until > v_now);
  if v_bans is not null then
    event := jsonb_set(event, '{claims,kit_app_bans}', v_bans);
  end if;

  return event;
end;
$$;

revoke all on function
  public.auth_kit_custom_access_token(jsonb)
  from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    grant execute on function public.auth_kit_custom_access_token(jsonb)
      to supabase_auth_admin;
  end if;
end
$$;

-- For RLS on ANY project stack (they share the JWT secret): does the
-- caller's token carry premium (or one feature) for this app, with no
-- live suspension? Reads only the token, never these tables, so the same
-- function works on stacks that do not hold them. Example:
--
--   create policy "premium rows" on public.exports for insert
--     with check (auth.uid() = owner and kit_jwt_has_premium('katalogus', 'export'));
create or replace function public.kit_jwt_has_premium(
  p_app text, p_feature text default null)
returns boolean language sql stable as $$
  select coalesce(
    (auth.jwt() -> 'kit_app_bans' -> p_app) is null
    and (
      (p_feature is null and auth.jwt() -> 'kit_entitlements' -> p_app ->> 'plan' = 'premium')
      or (p_feature is not null and (
            (auth.jwt() -> 'kit_entitlements' -> p_app ->> 'plan' = 'premium'
               and jsonb_array_length(coalesce(auth.jwt() -> 'kit_entitlements' -> p_app -> 'features', '[]')) = 0)
            or (auth.jwt() -> 'kit_entitlements' -> p_app -> 'features') ? p_feature))
    ), false);
$$;

grant execute on function public.kit_jwt_has_premium(text, text) to authenticated;
