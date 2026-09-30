# Components reference

Every file in the kit, what it does, and how to wire it.

## supabase/migrations/

### `20260929000000_email_auth_kit.sql`

One idempotent migration per project. Creates:

- `public.auth_events` — audit table
  (`id, email, event, code_hash, token_hash, attempts, expires_at,
  consumed_at, ip, user_agent, created_at`). Written only by the edge
  functions via `service_role`; readable in Studio for support.
- `public.request_auth_event(email, event, ...)` — inserts a new
  challenge row and returns `(plaintext_code_or_token, row_id)`.
- `public.consume_auth_event(id, presented, kind)` — constant-time
  SHA-256 comparison + attempt counting + expiry; returns `true` at
  most once per event.
- Helper `public.auth_event_rate_ok(email, kind, window)` for the
  rate-limit guard the functions call before issuing anything.
- `REVOKE`s so anon/authenticated can't read the audit table directly;
  only `service_role` (edge functions) touches it.

### `20260930000000_email_auth_kit_bans.sql`

The kill-switch (identity-side; additive, idempotent):

- `public.auth_kit_bans` — `(user_id PK→auth.users, banned_until,
  reason, set_at)`; RLS on, zero policies (service_role only).
- `public.auth_kit_set_ban(email, banned_until, reason)` — service-role
  RPC; null `banned_until` lifts the ban; returns false for unknown
  addresses.
- `public.auth_kit_custom_access_token(event)` — the **custom access
  token hook** (wire it in `config.toml`:
  `[auth.hook.custom_access_token]` with
  `uri = "pg-functions://postgres/public/auth_kit_custom_access_token"`).
  SECURITY DEFINER (the ban table has no RLS policies; GoTrue's caller
  role must read it); embeds `kit_banned_until` in every token minted or
  refreshed while a ban is live. EXECUTE is granted back to
  `supabase_auth_admin` — the blanket revoke would otherwise break every
  sign-in.
- Project side (no migration needed there — the exact SQL lives in
  `teststack/identity/post_migration.sql`): a ban-aware `auth.uid()`
  returns NULL on a live `kit_banned_until` claim, denying every
  `auth.uid()`-keyed policy. Pre-ban tokens stay valid until exp;
  refresh re-mints with the claim.

## supabase/functions/

### `email-verification/` (index.ts, deno.json)

Two actions in one function (`action` in the JSON body):

- `request` `{ email }` → sends a 6-digit code via Brevo. Same response
  whether the account exists or not. Rate limit: 3 / 15 min / email.
- `verify` `{ email, code }` → validates against the hashed row, and on
  success flips `auth.users.email_confirmed_at` via the admin API.

### `password-reset/` (index.ts, deno.json)

- `request` `{ email, redirect_to }` → e-mails a signed reset **link**
  (`<redirect_to>?token=...&email=...`). 30-minute single-use token.
- `confirm` `{ email, token }` → clicking the link opens YOUR page,
  which calls this action: generates a **12-char temp password**, sets
  it on the account (admin API), revokes other sessions, e-mails the
  temp password, and returns `must_change_password: true` so your UI
  forces a new password immediately after login.
- `notify` `{ user_id }` → optional "your password was changed" e-mail
  (call after a voluntary change; requires the caller's JWT).

### `ban-management/` (index.ts)

The kill-switch's support-dashboard surface — ops calls instead of psql.
Gated by the EXACT service-role key (constant-time compare of the bearer
against `SUPABASE_SERVICE_ROLE_KEY`; the kit's functions run behind
`VERIFY_JWT=false`, so an exact-secret match, not a decodable claim, is
the unforgable credential). Every action requires it.

- `ban` `{ email, until, reason?, notify? }` → drives BOTH planes in one
  call: the kit claim (`auth_kit_set_ban`) + GoTrue's native ban
  (`ban_duration` via admin API). `until` is ISO or `"forever"`;
  `notify: true` mails a suspension notice.
- `unban` `{ email, notify? }` → lifts both planes.
- `status` `{ email }` → `{ known, banned, kit_banned_until, native_ban,
  reason, set_at }`.
- `list` → all live kit bans.

Deploy exactly like the kit's other functions (router dispatches the
sibling dir; env: runtime-injected `SUPABASE_URL` +
`SUPABASE_SERVICE_ROLE_KEY`, optional `BREVO_*` for the notify mail).

## Client: `lib/mediasart_auth_client.dart`

Pure Dart, zero Flutter, zero generated code:

- `MediasartAuth` — the entry point; construct with your Supabase URL
  and anon key. Methods mirror the flows:
  `requestCode / verifyCode / requestReset / completeReset /
  notifyPasswordChanged`, plus `changePassword` which goes straight to
  Supabase Auth (no edge function needed), and the ban-aware identity
  session surface `signIn / refreshSession` (point `supabaseUrl` at
  `https://auth.mediasart.com`).
- **Ban detection** — `signIn` and `refreshSession` throw
  `AuthBannedException` when the account is banned: either the identity
  refused the sign-in/refresh (native ban), or the fresh token carries
  a live `kit_banned_until` claim (the data-plane kill-switch;
  `bannedUntil` carries the claim's timestamp). It subclasses
  `AuthCodeException` (reason `banned`), so generic catches keep
  working — but catch the ban type first for the dedicated UX (sign
  out, show a "account suspended" state; on refresh-refusal the token
  is dead, don't retry).
- `AuthCode/auth` — minimal Supabase Auth REST wrapper used by
  `changePassword` and by the login-after-reset path.
- `AuthException` — typed errors (network, rate-limited, expired,
  invalid-code, must-change-password) so your UI can branch cleanly.

## Wiring in a project (checklist)

```bash
# 1. migration
cp email-auth-kit/supabase/migrations/*_email_auth_kit.sql <project>/supabase/migrations/
supabase db push            # local; on the VM apply via psql

# 2. functions
cp -r email-auth-kit/supabase/functions/email-verification <project>/supabase/functions/
cp -r email-auth-kit/supabase/functions/password-reset      <project>/supabase/functions/
supabase functions deploy email-verification --no-verify-jwt
supabase functions deploy password-reset      --no-verify-jwt

# 3. secrets (once per project stack)
supabase secrets set BREVO_API_KEY=xkeysib-... BREVO_SENDER=no-reply@mediasart.com

# 4. client dep (path or git)
# pubspec.yaml:
#   mediasart_auth_client:
#     git: https://github.com/kjhrono/email-auth-kit
```

Auth settings to flip per project: disable Supabase's native
confirmation/reset e-mail templates for the flows the kit replaces
(Supabase Studio → Authentication → Emails), keep `enable_signup=true`.
For local dev, Inbucket (port 54324) catches everything — point
`BREVO_API_KEY` at nothing and the functions fall back to logging the
code/link to the function logs instead of failing.
