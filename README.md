# mediasart email-auth-kit

A reusable, **project-agnostic** email-identity kit for the mediasart
projects. Every project on the VM (self-hosted Supabase) wires in the
same three flows:

| Flow | What the user gets | What proves it worked |
|---|---|---|
| **Email confirmation** | a 6-digit code at registration | the address exists and belongs to the user |
| **Change password** | a settings-screen form | the old password was known |
| **Forgot password** | a link that sends a **temp password** | access recovered without the old one |

Everything here is generic: no project names, no UI. You develop the UX,
the kit provides the backend + client plumbing.

## Architecture

Three layers, one per concern:

```
your project (Flutter / web / CLI)
   │  mediasart_auth_client  (pure Dart package, lib/)
   ▼
Edge functions (supabase/functions/)  ──HTTPS──▶  Brevo API (SMTP relay)
   │  service_role, one function per flow
   ▼
Postgres: auth.users + public.auth_events (audit trail)
```

- **SQL** (`supabase/migrations/`) — audit table, helper functions.
  Idempotent; safe to apply on any project's stack.
- **Edge functions** — `email-verification` and `password-reset`. They
  mint one-time codes/tokens, e-mail them via Brevo, and swap them for
  Supabase auth sessions. Secrets stay server-side.
- **Dart client** (`lib/`) — one class per flow over the `functions-js`
  HTTP surface. `flutter_riverpod`-free and `dart:io`-free so it runs on
  web, desktop, and mobile.

## Quick start (per project)

1. Copy `supabase/migrations/*_email_auth_kit.sql` into your project's
   `supabase/migrations/` and apply (`supabase db push`, or psql on the
   VM stack).
2. Copy `supabase/functions/email-verification` and
   `supabase/functions/password-reset` into your project's
   `supabase/functions/` and deploy them:
   `supabase functions deploy email-verification --no-verify-jwt`
   (the functions verify the caller themselves — see each function's
   doc comment for why `--no-verify-jwt` is safe here).
3. On the VM, set the Brevo secrets once per project (or per stack):
   `supabase secrets set BREVO_API_KEY=...` and
   `supabase secrets set BREVO_SENDER=no-reply@mediasart.com`.
   Brevo must already be domain-verified for mediasart.com (done).
4. In Supabase Auth settings, **disable** the built-in confirmation and
   reset e-mails for the flows you replace — the kit sends its own.
   Keep `enable_signup = true`; the kit works with Supabase's native
   `auth.users`, it does not fork identity.
5. In your app, add the `mediasart_auth_client` package (path or git
   dep) and call the three flows — see the example calls in
   `docs/COMPONENTS.md`.

## Flows in detail

### 1. Email confirmation (registration proof)

```
register(email, password)          ← native Supabase signUp, NO auto session
requestCode(email)                 ← function: 6-digit code → inbox
verifyCode(email, code)            ← function: marks the address confirmed
```

The code is 6 digits, hashed (SHA-256) in the audit table, valid
**15 minutes**, max **5 attempts**, then locked; re-requesting issues a
new code and invalidates the old one. On success the function promotes
the user to `email_confirmed` via the admin API — no magic link, no
redirect plumbing needed.

### 2. Change password (at will)

Plain and local-first: the user enters the **current** password once,
the new one twice; the client calls Supabase's native
`auth.updateUser(password: ...)` with the session it already holds.
No e-mail is needed and none is sent by default — the kit offers an
optional notify-only function (`password-reset?mode=notify`) if you
want a "your password was changed" e-mail from a new device.

### 3. Forgot password (link → temp password)

```
requestReset(email)                ← function: token → /reset link in inbox
completeReset(email, token)        ← function: temp password → inbox,
                                     old sessions revoked
```

Clicking the link is what triggers the **temp password** e-mail, so the
reset stays two-step: proof of inbox first, credential second. The temp
password is 12 chars, single-use, and forces a change on first login
(see `mustChangePassword` in the client). Tokens are 32 bytes of CSPRNG,
hashed, valid **30 minutes**, single-use.

## Security posture

- Codes/tokens are only ever stored **hashed**; the plaintext lives in
  the e-mail and nowhere else.
- Every request path is **rate-limited** per email+IP (see the SQL
  comments) and answered identically whether or not the address exists
  (no account enumeration).
- Edge functions use the **service_role key**, which never leaves the
  server; the client only ever talks to its own function endpoints.
- `public.auth_events` gives every flow a complete audit trail (who,
  what, when, from which IP, outcome) — query it from Studio.

## What this kit is NOT

- Not a mail server: Brevo sends, the kit only calls its API.
- Not a session fork: identity stays in Supabase `auth.users`.
- Not project-specific: no schema beyond the single audit table.
