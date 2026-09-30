# Phase 1 — central identity on the VM (rollout plan)

Status: **Steps 1–3 done and verified on the VM (2026-09-30).** §2
identity stack live at `https://auth.mediasart.com` (certbot lineage
expanded — auth in the SAN, chain verifies; nginx routes /auth/v1,
/rest/v1, /functions/v1; HTTP→HTTPS redirect; 11-check smoke through
the public URL: ALL PASS). §4 shared-secret cutover done on all six
project stacks — acceptance harness 6/6 VM VERIFICATION: ALL PASS.
Remaining: Steps 4–5 (facade flips + wipes, staging first), Step 6
cleanup. Execute staging-first, one section at a time, verifying
between steps.

**Ban kill-switch deployed (2026-09-30).** Identity: bans migration +
custom access token hook (override env `GOTRUE_HOOK_CUSTOM_ACCESS_
TOKEN_*`, values in the stack `.env`). Projects: ban-aware `auth.uid()`
applied on all six (`teststack/ban_aware_auth_uid.sql`, owner
preserved). Verified over the public URL — 14/14 ALL PASS: ban via
`auth_kit_set_ban`, claim on the fresh token, staging `kit_probe`
refuses the banned token (read/insert/whoami), unban restores.
`ban-management` deployed on identity and proven over the public URL
(16/16: one service-role call drives both planes; sign-in refused while
banned; unban restores). Note: katalogus-staging's stack dir moved to
`~/Apps/stages/katalogus-staging/docker` (VM reorg) — harness runners
referencing the old `~/Apps/database/` path need updating.
Companion to [CENTRAL_IDENTITY.md](CENTRAL_IDENTITY.md) (the design;
Phase 0 proven in `teststack/identity/` and automated in CI).

## 0. The simplification that reshapes this phase

**No user migration.** Every project is still in development and closed
to the public, so all `auth.users` data can simply be **wiped**. That
deletes the hardest parts of the original plan (UUID-preserving import,
dedupe, remap tables, dual-stack verification windows) and changes the
acceptance bar:

- a user is "migrated" by **registering again** through the kit;
- any leftover rows keyed to old user UUIDs in project data tables are
  dev junk — wiped per project at cutover, not remapped;
- **order of operations stops mattering for data**: projects can wipe
  before or after their facade flip.

What still must be true: every app's non-auth data model (workspaces,
catalogs, games, saves) keeps working after a wipe — i.e. project
deletions must run **with FK respect** (`TRUNCATE ... CASCADE` or
delete in dependency order), and any dev accounts that matter for
seeding (a curated demo workspace, test players) are re-created by
their normal seed flows afterwards.

## 1. Decisions this plan fixes

- **Identity stack name**: `supabase-identity` at
  `~/Apps/database/supabase-identity/`, published as
  `https://auth.mediasart.com` (cert via the same ACME flow the
  katalogus cutover used).
- **The one secret**: generate one JWT secret
  (`openssl rand -base64 48`), store it in the VM's secrets file; every
  stack's `.env` sets it as `GOTRUE_JWT_SECRET` (auth) and feeds
  Kong/PostgREST verification the same value. Rotation = coordinated
  restart, identity first (see §8).
- **Signup doors**: only the identity stack accepts signup
  (`GOTRUE_DISABLE_SIGNUP=false` there); every project stack sets
  `GOTRUE_DISABLE_SIGNUP=true` and loses all SMTP config.
- **Kit deployment**: exactly once, on the identity stack.
- **Old accounts**: wiped, not imported. Users re-register through the
  kit on first use.

## 2. Step 1 — stand up the identity stack on the VM

1. Provision `~/Apps/database/supabase-identity/` the same way the
   katalogus stacks were stood up (compose bundle from the existing
   stacks, new project name, new ports in the host range already
   published — kong on an unused host port, e.g. the 81xx range).
2. `.env` for the identity stack: fresh DB password; the **shared JWT
   secret**; `GOTRUE_MAILER_AUTOCONFIRM=false` (the kit owns
   confirmation); `GOTRUE_DISABLE_SIGNUP=false`;
   `GOTRUE_SITE_URL=https://auth.mediasart.com`;
   `API_EXTERNAL_URL=https://auth.mediasart.com/auth/v1`;
   **no SMTP** (the kit sends; GoTrue mail stays idle — if invites or
   email-change are ever needed from identity later, add Brevo SMTP
   then).
3. `docker compose up -d`, verify: `/auth/v1/health` 200, Studio (if
   kept) reachable only via SSH tunnel, DB reachable locally.
4. **Deploy the kit here (the only deployment)**: apply
   `email_auth_kit/supabase/migrations/20260929000000_email_auth_kit.sql`
   to the identity DB; deploy `email-verification` + `password-reset`
   to the stack's edge runtime with `--no-verify-jwt` semantics; set the
   function env: `SUPABASE_URL=http://kong:8000`,
   `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_ANON_KEY`,
   `BREVO_API_KEY`, `BREVO_SENDER=noreply@mediasart.com`
   (generic sender on the apex-adjacent subdomain; DKIM/SPF for
   `mediasart.com` is already validated in Brevo — if the sender must
   be subdomain-specific, prefer `noreply@mediasart.com` and validate
   it in Brevo before go-live).
5. Smoke through the public URL once DNS/cert exist (§3): kit signup →
   code mail → verify → sign-in; reset link → temp password → sign-in.

## 3. Step 2 — `auth.mediasart.com` on nginx

1. DNS A record `auth.mediasart.com` → the VM IP (80.225.89.206).
2. Cert: the cutover runbook's ACME step (`tool/vm/cutover_step1b_acme_http.sh`
   pattern) for `auth.mediasart.com`.
3. Vhost: copy the katalogus vhost pattern
   (`tool/nginx_katalogus_mediasart.conf`) →
   `nginx_auth_mediasart.conf`: proxy `https://auth.mediasart.com/` →
   the identity stack's kong host port; keep the kong route table
   default (rest/auth/functions/realtime). Reload nginx; verify TLS
   grade and that `https://auth.mediasart.com/auth/v1/health` is 200
   from outside.

## 4. Step 3 — teach every project stack the shared secret

For **each** project stack (katalogus, katalogus-staging, kalcio —
whatever compose dirs exist on the VM), in its `docker/.env`:

1. Set `GOTRUE_JWT_SECRET=<the shared secret>` (replacing the
   stack-local one) **and** the same value wherever PostgREST/Kong
   verification gets its key (the compose wires one to the other —
   keep them equal).
2. `GOTRUE_DISABLE_SIGNUP=true`; remove `GOTRUE_SMTP_*` lines; keep
   `GOTRUE_MAILER_AUTOCONFIRM=false`.
3. `docker compose up -d` (restart auth + kong + rest).

**Acceptance = the Phase 0 proof, run against the VM.** For each
project stack, repeat the prototype's checks with real hosts:

- mint a user + JWT on `auth.mediasart.com` (kit signup → verify →
  sign-in);
- `GET <project>/rest/v1/<any table>` with that JWT + the project's
  anon key → 200 with the right role;
- an RLS-scoped insert keyed on `auth.uid()` stamps the foreign uid;
- signup against the project's own `/auth/v1/signup` → refused
  (signup_disabled).

This is `run_phase0.sh`'s logic with real URLs; port `proof.py`'s
checks into a `verify_vm_project.sh` (or parameterize the script's
URLs/keys) before touching the VM, and keep it in the kit for reuse.
**Done** — `teststack/verify_vm_project.sh` (+ `.py`) implements exactly
this acceptance bar: identity mint (kit signup → Brevo-mailed code with
auto-fetch → verify → sign-in), foreign-JWT read + RLS-stamped insert +
owner-scoped delete on a project probe table, and the signup-refused
check. All URLs/keys ride KIT_* env; validated against the prototype
stacks mapped onto the VM's URL shapes (kong defaults, bare-GoTrue
overrides, per-run plus-addressing to sidestep the kit's rate limiter).

**Executed on the VM (2026-09-30)** — all six stacks (katalogus,
katalogus-staging, kalcio, kognitio, kollectio, kapaxinfiniti) cut over
and verified: kit mint on auth.mediasart.com, foreign-JWT read +
owner-scoped insert/delete on a per-stack `kit_probe` table
(`teststack/kit_probe_table.sql`), own signup refused. Ops notes the
run earned: GoTrue refuses to boot with an empty `GOTRUE_SMTP_PORT` —
keep the inert `2500` placeholder (empty `SMTP_HOST` is what disables
mail); this stack generation's envoy gateway checks API keys only while
JWT signatures verify in rest+auth, so each stack's own anon key still
opens its own gateway and identity's anon key becomes the shared door
at facade-flip time; `JWT_JWKS` must stay unset for the shared-secret
fallthrough; kognitio's GoTrue/rest target its own `kognitio-db`
database and kollectio's DB is the bare `kollectio` container.

## 5. Step 4 — flip each app's facade + wipe, project by project

Staging first (katalogus-staging), then prod per project. Per project:

1. Merge the facade change (the app's `MediasartAuth` URL/anon key →
   `https://auth.mediasart.com`; sign-in/sign-out through the identity
   client). For katalogus this is the constants swap in
   `KatalogusRepository`; kalcio gets the same seam when it adopts the
   kit.
2. Deploy the app build.
3. **Wipe**: truncate `auth.users` (and GoTrue's `refresh_tokens`,
   `sessions`, `audit_log_entries`) on the *project* stack, plus dev
   data rows keyed to old user UUIDs per the project's dependency
   order. The identity stack's `auth.users` starts empty and stays the
   only copy.
4. Verify from the app: register (kit mail arrives, code confirms),
   sign in, exercise one real data flow end to end (create a workspace
   / start a game), sign out, sign in again.
5. Repeat for the next project. No cross-project coordination is needed
   — each project flips and wipes independently; identity is already
   live.

Rollback per project (before users depend on it): re-point the facade
to the project stack (config-only), restore from the pre-wipe backup if
the data mattered (dev-only data usually does not — that's the point).

## 6. Step 5 — cleanup + documents

- Identity stack: remove the prototype's leftover bits if any
  (`project_b` never existed there — nothing to do); keep the
  `auth_events` audit table and its retention habit (the kit's table
  grows; a monthly `delete from auth_events where created_at < now() -
  interval '90 days'` cron on the VM is enough).
- Project stacks: confirm no SMTP vars remain, signup disabled,
  templates directories removed from the auth container mounts.
- Update the katalogus runbooks: `tool/email_brevo_setup.md`'s
  Brevo-section stays as the historical reference; add a line that
  transactional mail now lives on the identity stack; the deploy
  addendum (`tool/email_kit_deploy.md`) gets a Phase-1 note that its
  per-project function deployment is superseded by the identity
  deployment.
- COMMONS.md: note that games adopt identity via the kit's client and
  `auth.mediasart.com`.

## 7. Verification checklist (whole phase)

- [ ] `https://auth.mediasart.com/auth/v1/health` 200 from outside
- [ ] Kit signup/confirm/sign-in through the public URL (one user)
- [ ] Kit reset link → temp password → forced-change flow (one user)
- [ ] Each project stack: foreign JWT accepted, RLS stamps the foreign
      `auth.uid()`, own signup refused
- [ ] Each app: register → use → sign out → sign in, against identity
- [ ] Only the identity stack has `auth.users` with rows
- [ ] No project stack retains `GOTRUE_SMTP_*`
- [ ] The automated Phase 0 CI proof still passes (drift alarm armed)
- [ ] Brevo: sends come from the identity deployment's API key, DKIM
      aligned, no per-project keys in play

## 8. Operational notes that survive the phase

- **JWT secret rotation**: generate new → identity stacks restart with
  it first → project stacks follow within the hour (JWTs live 1h;
  refresh tokens re-mint on identity). Never let identity run a secret
  no project accepts.
- **Backups**: the identity DB now holds the one `auth.users` — it
  joins the VM's nightly dump set; project DBs keep their own dumps.
- **The CI proof** (kommons' `identity-proof` workflow) stays the drift
  alarm for the prototype mechanics; after Phase 1 lands, add a monthly
  manual §7 re-check of the *real* endpoints.
