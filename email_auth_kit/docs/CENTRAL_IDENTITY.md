# Central identity for the mediasart projects

Status: **Phase 0 PROVEN** — the two-stack prototype ran green (12/12
checks, 2026-09-29). See `teststack/identity/` for the working harness,
its README for the discovered gotchas (reserved roles, non-superuser
`postgres`, GoTrue's legacy `auth.uid()` migration, RLS stamp defaults),
and `teststack/identity/proof.py` for the exact checks.

## 1. Goal

One identity provider (IdP) for every mediasart project. Today each
stack owns its own `auth.users`: registering on katalogus means nothing
on kalcio. Under central identity, **one account (one e-mail, one
password) works everywhere**, while each project keeps its own database
for everything that is not identity.

Mental model:

```
                    ┌────────────────────────────┐
                    │  identity stack (VM)       │
                    │  auth.users · kit functions│
                    │  auth_events audit trail   │
                    │  Brevo sending (once)      │
                    └──────────┬─────────────────┘
                               │  sign in / confirm / reset
              ┌────────────────┼────────────────┐
              ▼                ▼                ▼
       katalogus stack   kalcio stack    (herald, …)
       data + RLS        data + RLS
       JWTs accepted,    JWTs accepted,
       never issued      never issued
```

The projects **verify** tokens but never **issue** them. Identity is a
service the projects consume.

## 2. Why now, and why it's cheap here

- Self-hosted Supabase = we control the JWT signing secret (§3). The
  hosted-cloud federation dance isn't needed; this is the single-VM
  shortcut.
- The email-auth-kit exists precisely to be deployed **once**: codes,
  temp passwords, Brevo mail, audit trail all live on the identity
  stack. Per-project auth ops shrink to "accept foreign JWTs".
- The katalogus integration is fresh: its repository layer is already
  the single choke point for auth calls, so the facade (§4) is a
  contained edit, not a sweep.

## 3. Design

### 3.1 The identity stack

One stack on the VM (e.g. `~/Apps/database/supabase-identity/`), owning:

- `auth.users` — the only copy. No project data tables here.
- The kit: migration + `email-verification` + `password-reset`
  functions, `BREVO_API_KEY` — deployed once, updated once.
- GoTrue configured exactly per the katalogus runbook, minus
  per-project templates: `GOTRUE_MAILER_AUTOCONFIRM=false` (the kit
  owns confirmation), Brevo SMTP optional (only for flows the kit
  doesn't cover — invites, e-mail change), site URL
  `https://auth.mediasart.com`.

Projects **disable local signup** (`GOTRUE_DISABLE_SIGNUP=true` —
identity is the only creator) and remove their SMTP config: with no
local signup and no local password reset, GoTrue in a project never
mails anyone.

### 3.2 Shared JWT secret

All stacks (identity + every project) set the **same**
`GOTRUE_JWT_SECRET` (and matching `JWT_SECRET` for Kong's
`verification` plugin) in their `docker/.env`. A token minted by the
identity stack's GoTrue then validates in every project's Kong →
PostgREST as a normal `authenticated` request. No federation protocol,
no extra network hop: the app just presents the token to its project
API as it does today.

Details that matter:

- **Audience**: keep the default `aud = authenticated` on every stack —
  don't invent per-project audiences; the JWT has no project claims,
  and it shouldn't. Project-level authorization stays in each project's
  RLS against `auth.uid()`.
- **`auth.uid()` still works** in project Postgres: PostgREST trusts
  Kong's verification; the claim comes from the verified token, not
  from a local user row. Project tables keep referencing the user's
  UUID — from the project DB's perspective it's a string. **No foreign
  keys into a remote DB**; nothing else changes in the data model.
- **Key rotation**: rotating the shared secret is a coordinated restart
  of all stacks (identity first mints, then projects verify). Schedule
  it like the cert renewals; sessions expire naturally (JWT_EXP = 1h),
  refresh tokens live in the identity DB only.

### 3.3 App-side facade

Each Flutter app gets a thin identity seam inside its repository (the
choke point that already exists in katalogus):

- `MediasartAuth` (the kit client) points at the **identity** URL:
  `MediasartAuth(supabaseUrl: 'https://auth.mediasart.com', anonKey:
  kIdentityAnonKey)`. Sign-in, signup+confirmation, reset all go
  there; the session it returns is the session the app already
  persists.
- Data calls keep pointing at the **project** URL with the project's
  anon key + the session's access token — which is what
  `supabase_flutter` already does; only the *auth endpoint* moves.
- Riverpod/session plumbing is unchanged: `onAuthStateChange` keeps
  working because the app-side client holds the session objects
  locally.

In katalogus this means: `emailAuth` in `KatalogusRepository` switches
its URL/key constants from `kSupabaseUrl` to `kIdentityUrl`, and the
native `signIn`/`signOut`/stream follow it. The kit's functions are
then **removed from katalogus' supabase/ dir** (they were mirrored for
the standalone phase; under central identity there is exactly one
deployment).

### 3.4 What must be proven on the teststack first

1. Two stacks (A = identity, B = project) sharing `GOTRUE_JWT_SECRET`;
   a token from A accepted by B's REST endpoint (200 with
   `authenticated` role, correct `auth.uid()`).
2. RLS in B keyed on that foreign-minted `auth.uid()`.
3. A project with `GOTRUE_DISABLE_SIGNUP=true` refusing direct signup
   while the kit (on A) creates users fine.

### 3.5 Security posture

- **One ban, one deletion — global.** That's the point, but say it out
  loud: a misbehaving account is removed everywhere at once.
- **Shared sender + branding**: all transactional mail comes from one
  identity; templates stay generic (the kit's are).
- **Rate limits centralize for free**: the kit's `auth_events` guards
  become the single choke point for password abuse across projects.
- **The anon key of the identity stack ships in every app** — it is a
  publishable key; treat it like the project ones.
- Compartmentalization loss is real but acceptable at this scale; the
  blast radius of a JWT-secret leak is now all projects — rotate fast,
  keep the secret in the VM `.env` files with the same backup discipline.

## 4. User migration plan

Existing users live in each project's `auth.users`. Order: katalogus
first (most active), then kalcio.

1. **Snapshot** both sources: `pg_dump` of `auth.users`
   (`id, email, encrypted_password, email_confirmed_at, created_at,
   updated_at, ...`) from each project stack.
2. **Dedupe by e-mail** (lower-cased): first occurrence wins for
   canonical identity; conflicts become a manual list (same person on
   both stacks keeps the older account; the newer UUID's data rows get
   re-pointed by the per-project mapping table, see step 5).
3. **Import into the identity stack preserving UUIDs** — `insert into
   auth.users (id, email, encrypted_password, ...) values (...)`
   against the identity DB (GoTrue accepts pre-hashed bcrypt
   `encrypted_password`; users keep their passwords). Set
   `email_confirmed_at` from the source: nobody should be forced to
   re-confirm an address they already proved.
4. **Apps flip over** behind the facade (§3.3). During the window an
   app's data stack still accepts the project-minted tokens; after the
   flip only identity tokens are minted. Old sessions die within JWT_EXP.
5. **Per-project remap table** (only if dedupe merged accounts):
   `legacy_uuid → canonical_uuid` applied as a one-off
   `update ... set user_id = canonical` sweep in that project's data
   tables, inside a transaction, after a backup.
6. **Verification**: sign in with a pre-migration password on each
   project; run each app's auth-adjacent tests against staging before
   production. Rollback = re-point the app facade to the old stack
   (config-only) until the identity stack is trusted.

## 5. Rollout phases

- **Phase 0 — prototype**: teststack proof of §3.4. One session of work.
- **Phase 1 — katalogus onto central identity**: stand up the identity
  stack, deploy the kit once, migrate katalogus users, flip the facade.
  The katalogus runbook's domain work already landed on mediasart.com —
  `auth.mediasart.com` needs only cert + vhost + `.env` lines.
- **Phase 2 — kalcio**: facade + migration (its supabase stack is
  live again post-cutover; same recipe).
- **Phase 3 — cleanup**: `GOTRUE_DISABLE_SIGNUP=true` + SMTP removal on
  all project stacks; kit functions removed from katalogus; runbooks
  consolidated into this doc.

## 6. Open decisions (settled as we go)

- Identity subdomain name (`auth.mediasart.com` assumed).
- Whether herald ever gets its own stack or shares one (irrelevant to
  this design; the facade is the only thing that would change).
- E-mail-change flow: GoTrue on the identity stack (native, mails both
  addresses) vs. a kit action. Default: GoTrue-native, since the kit
  deliberately doesn't fork identity.
