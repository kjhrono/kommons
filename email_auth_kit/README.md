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
signUpWithConfirmation(email, password)  ← function: creates the user
                                           UNCONFIRMED + 6-digit code → inbox
verifyCode(email, code)                  ← function: marks the address
                                           confirmed, sends the welcome
```

The code is 6 digits, hashed (SHA-256) in the audit table, valid
**15 minutes**, max **5 attempts**, then locked; re-requesting issues a
new code and invalidates the old one. On success the function promotes
the user to `email_confirmed` via the admin API — no magic link, no
redirect plumbing needed. When that is the address's **first**
confirmation the same call also mails the product's welcome message
(§ Product configuration); a later re-verify stays quiet.

`signUpWithConfirmation` **refuses an address that already has an
account**: the function answers 409 `account_exists` and the client
throws `AuthCodeException('account_exists')`. The reason is that this
flow can only set a password **on create** — for an existing user it
would mail a code, confirm the address, and leave the password the
member had just typed unapplied, so they could never sign in with it.
Only the reset flow may replace a password: send them there (or to
sign-in). Two consequences: the reply discloses whether an address has
an account (`requestCode` does not), and an interrupted signup — account
created, code never entered — is finished through the reset, which
confirms the address as well (below).

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

Completing the reset also **confirms** the address: presenting the token
is proof of inbox ownership, and without it the reset could hand out a
password that still cannot be used — GoTrue refuses a sign-in on an
unconfirmed address (`email_not_confirmed`), which is exactly the state
an interrupted signup leaves behind.

## Product configuration (the welcome mail)

The welcome mail's links are **server configuration, never client
input**. The client only declares which product it is:

```dart
MediasartAuth(supabaseUrl: 'https://auth.mediasart.com', anonKey: '…',
              product: 'katalogus')
```

and the deployment holds the links, keyed by that name:

```
KIT_WELCOME_LINKS={"default":{"product":"mediasart","web":"https://mediasart.com"},
                   "katalogus":{"product":"Katalogus",
                                "web":"https://katalogus.mediasart.com",
                                "play":"https://play.google.com/store/apps/details?id=…",
                                "ios":"https://apps.apple.com/app/…",
                                "site":"https://mediasart.com"}}
```

Supported keys: `product` (the mail's title), `web`, `play`, `ios`,
`site` — each row is emitted only when its key is set, so a stack with
no store listings yet sends a shorter mail rather than dead links. An
unknown product falls back to `default`; with no configuration at all no
welcome is sent (the function logs it), never a broken one.

## Security posture

- Codes/tokens are only ever stored **hashed**; the plaintext lives in
  the e-mail and nowhere else. (The 6-digit code is a salt-free SHA-256
  of a 10^6 space — fine against anyone who cannot read the table, which
  is the service role only; salt it if that ever changes.)
- Every request path is **rate-limited** per email+IP (see the SQL
  comments). `requestCode` / `requestReset` are answered identically
  whether or not the address exists (no account enumeration); `signup`
  is the deliberate exception — see flow 1 — because it cannot give an
  existing account a password and must not pretend otherwise.
- Edge functions use the **service_role key**, which never leaves the
  server; the client only ever talks to its own function endpoints.
- `public.auth_events` gives every flow a complete audit trail (who,
  what, when, from which IP, outcome) — query it from Studio.

## What this kit is NOT

- Not a mail server: Brevo sends, the kit only calls its API.
- Not a session fork: identity stays in Supabase `auth.users`.
- Not project-specific: no schema beyond the single audit table.
