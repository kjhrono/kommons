# Changelog

All notable changes to the kommons shell are documented here. The format
loosely follows [Keep a Changelog](https://keepachangelog.com/) and the
versioning intent is [semver](https://semver.org/) — while the package is
pre-1.0, minor versions carry the features.

## Unreleased

Phase 0 of the central-identity plan became a permanent, CI-guarded
harness instead of a one-off demo: the two-stack proof now survives
fresh checkouts and restarts, the kit's smoke suite runs anywhere via
environment, and a new harness proves the same acceptance bar against
real VM hosts.

### Phase 0 harness hardening

- **The proof survives a virgin database** — stack B's schema
  provisioning no longer depends on GoTrue's first-boot ordering: a
  stub `auth.uid()` owned by `auth_admin_b` (the role GoTrue-B
  migrates as) is replaced by the modern claim reader once the
  fingerprint of GoTrue's bundled legacy function changes, with
  `ON_ERROR_STOP` and a post-flight assert so a silently-stubbed proof
  can't pass.
- **Restart-proof runs** — readiness waits for auth-b, postgrest-b and
  the host-run kit functions, and stale function processes are killed
  before relaunch, so a `supabase stop/start` no longer races deno's
  boot or serves dead env from an earlier run.
- **Failure visibility** — a stack-A startup failure prints its log
  tail instead of a bare non-zero exit, and the teststack
  `config.toml` is tracked so CI starts the real stack, not a
  config-less default one.
- **Honest revocation checks** — the proof pins what stateless
  verification actually guarantees: sign-out revokes the refresh path
  and identity refuses the bearer server-side, while an unexpired
  access token stays valid on the data plane until `exp`.
- The identity-proof workflow reruns the proof on a schedule and on
  kit changes — a standing drift alarm.

### Smoke suite parameterization

- The 23-check smoke suite reads its stack coordinates (`KIT_API_URL`,
  `KIT_EV_URL`, `KIT_PR_URL`, `KIT_MAILPIT_URL`, `KIT_ANON_KEY`,
  `KIT_DB_CONTAINER`) from the environment, with `--smoke` and
  `RUN_SMOKE=1` modes — `identity/run_phase0.sh --smoke` re-validates a
  restarted teststack against its CURRENT keys instead of baking any
  in, because every restart regenerates the API keys and Mailpit's
  address.

### VM acceptance harness

- **`teststack/verify_vm_project.sh` (+ `.py`)** — Phase 1's acceptance
  bar parameterized for real VM hosts over the `KIT_*` env contract:
  identity mint through the kit (signup → Brevo-mailed code with
  auto-fetch → verify → sign-in), foreign-JWT read on the project,
  RLS-stamped insert keyed on `auth.uid()`, owner-scoped delete, and
  the project's own signup refused. Plus-addressing per run sidesteps
  the kit's rate limiter; `KIT_BREVO_API_KEY`/`KIT_MAILPIT_URL`
  auto-fetch the mailed code, `KIT_ADMIN_KEY` auto-deletes the minted
  user.
- The Brevo auto-fetch was fixed against the live API: the list
  endpoint is `GET /smtp/emails?email=<addr>` (the filter is mandatory
  and `@` must not be %-encoded), message content lives at
  `GET /smtp/emails/{uuid}` in `body`, the list index lags sends by up
  to ~2 minutes (deadline polling), and hard-bounced test addresses
  are send-suppressed until `DELETE /smtp/blockedContacts/{email}`
  clears them.

### Phase 1 — central identity live on the VM

Steps 1–3 of `docs/PHASE1_VM_ROLLOUT.md` are done and verified: the
identity stack serves `https://auth.mediasart.com`, and every project
stack now verifies tokens signed with identity's JWT secret.

- **auth.mediasart.com live** — the shared `mediasart.com` certbot
  lineage expanded (auth in the SAN, chain verifies); nginx routes
  /auth/v1, /rest/v1, /functions/v1 to the identity gateway with
  HTTP→HTTPS redirect. Verified from outside (TLS + endpoint probes)
  and with the full 11-check smoke through the public URL.
- **Shared secret on all six stacks** — katalogus, katalogus-staging,
  kalcio, kognitio, kollectio, kapaxinfiniti rolled with their
  `COMPOSE_PROJECT_NAME`-pinned `.env`s (backups kept), signups
  disabled, SMTP emptied. Ops notes the run earned: GoTrue refuses to
  boot on an empty `GOTRUE_SMTP_PORT` (keep the inert `2500`
  placeholder); this stack generation's envoy gateway checks API keys
  only while signatures verify in rest+auth, so each stack keeps its
  own anon key until the facade flip.
- **Acceptance 6/6 ALL PASS** — `verify_vm_project.sh` per stack: kit
  mint on identity, foreign-JWT read plus RLS-stamped insert/delete on
  a per-stack `kit_probe` table (`teststack/kit_probe_table.sql`), own
  signup refused. Harness fix from the run: Brevo's list filter
  percent-decodes `+` as a space, so derived plus-addresses encode with
  `quote(email, safe='@')`.
- Topology absorbed: kognitio targets its own `kognitio-db` database,
  kollectio's DB is a bare postgres container, and katalogus-staging
  moved to `~/Apps/stages/` in a VM reorg (verified intact after the
  move).

### The ban kill-switch

The revocation primitive CENTRAL_IDENTITY.md anticipated: identity
writes a ban flag that every project's RLS can check — no cross-stack
plumbing, the flag rides the JWT.

- **Identity side** (`20260930000000_email_auth_kit_bans.sql`) —
  `auth_kit_bans`, the service-role `auth_kit_set_ban` RPC, and
  `auth_kit_custom_access_token`: the GoTrue custom access token hook
  embedding a `kit_banned_until` claim into every token minted or
  refreshed while a ban is live. SECURITY DEFINER (the ban table has
  zero policies) with EXECUTE granted back to `supabase_auth_admin` —
  the blanket revoke would otherwise break every sign-in.
- **Project side** (`teststack/ban_aware_auth_uid.sql`) — a ban-aware
  `auth.uid()` returns NULL on a live claim, denying every
  `auth.uid()`-keyed policy; applied on all six VM stacks with
  `supabase_auth_admin` ownership preserved.
- **Proven twice**: in the prototype (proof section 6, 15 checks,
  CI-green on a virgin database) and on the VM over the public URL
  (14/14: ban → claim on the fresh token → staging refuses
  read/insert/whoami → pre-ban tokens honestly honored until exp →
  unban restores everything).
- **`ban-management/` edge function** — the dashboard surface: one
  service-role call drives BOTH planes (kit claim + GoTrue's native
  ban), plus `status`/`list` and optional notify mails. The gate is an
  exact constant-time bearer match against the service-role key — the
  kit's functions run behind `VERIFY_JWT=false`, so a decodable-claim
  check would be forgeable. 16/16 public-URL verification; the smoke
  suite gains section 8 and a 10s timeout on every request.
- **Client** — `AuthBannedException` (subclass of `AuthCodeException`)
  thrown by the new ban-aware `signIn` / `refreshSession` on either
  plane (`bannedUntil` from the claim when known); catch it first for
  the suspended-account UX.

## 0.4.0 — 2026-09-29

The release that folds the mediasart email-identity kit into the repo
as a subpackage, registers kalcio in the consumer gate, and hardens the
release machinery itself.

### The email_auth_kit subpackage

`email_auth_kit/` carries the generic, project-agnostic email-identity
flows for every mediasart app: a Supabase SQL migration (`auth_events`
audit/challenge table with hashed codes, rate-limit guard, SECURITY
DEFINER helpers), two Deno edge functions (`email-verification` with
kit-native signup — the user is created unconfirmed and one 6-digit
code mail goes out; `password-reset` with link → temp-password
flows and a self-verified `notify` action), and a pure-Dart client
(`mediasart_auth_client`) that games add as a path dep on the
subpackage. Verified end to end against a local stack (23-check smoke
suite with real mail) and 11 client unit tests; both gate with this
repo's consumer script. Design docs in `email_auth_kit/docs/`,
including the central-identity plan whose two-stack Phase 0 proof
(`teststack/identity/`) ran 12/12 green.

### Consumer gate and change alerts

- kalcio registered in the gate (analyze-only — its test battery is
  kalcio CI's job); consumers missing from the checkout skip loudly
  instead of failing CI.
- Tag mode gates the kit from the **tagged snapshot**; tags predating
  the subpackage skip loudly.
- `tool/verify_alert_chain.sh` closes the kommons→kalcio alert loop in
  one guarded command.

### Release machinery

- Release workflow pub-gets the probe before the root analyze (fresh
  checkouts have no probe `.dart_tool` — caught on the first v0.3.0
  attempt).
- Actions bumped to Node 24 majors (checkout@v5, setup-java@v5);
  Dependabot now groups future action bumps into one weekly PR.

### Adoption

```yaml
kommons:
  git:
    url: https://github.com/kjhrono/kommons.git
    ref: v0.4.0
```

No shell API changes in 0.4.0 — the lobby/auth surfaces are unchanged
from 0.3.0; everything new is the subpackage and the CI machinery
around it.

## 0.3.0 — 2026-09-24

The lobby remembers its roster, the invited guest can start the table,
and a release tag now proves itself before it publishes. Everything
below is backwards-compatible for hosts: existing `SharedLobbyStep`
call sites keep working unchanged — new capabilities are optional
parameters (`gameId:`, `onScanInvite:`).

### Added

- **Roster persistence** (`lobby_roster.dart`) — pass `gameId:` to
  `SharedLobbyStep` and the table persists across restarts: the
  committed number, open slots and claimed seats come back exactly as
  left, so a host can prepare the table in advance. The draft clears on
  handoff or solo start; an arriving invite wins over the stored number;
  a corrupt draft is discarded, never fatal.
- **Splash scan door** (`AppSplash.onScanInvite`) — a "scan a friend's
  QR" button on the splash itself, hidden when the callback is absent:
  a read jumps straight into the pre-seated lobby through the same
  `joinScanExecutor` seam the lobby uses.
- **Banner preview in the entry chooser** — a circular swatch carrying
  the player's initial beside the two doors, resolved through the same
  call seat 1 uses, so the color seen is the color carried into the
  lobby.
- **Seat editing** — a claimed seat's pencil action (or a long-press on
  the chip) opens a pre-filled dialog to rename it (typo fixes) or
  re-open it ("SEAT X — open" again, ready for another player; the
  JOIN GAME gate re-arms).
- **Join confirmations** — the arrival snackbar now names the table
  ("Joining table {code} as {name}."), the committed code is *visible*
  in the locked field, and the exit rides the handoff ("Starting table
  {code}…" onto the game screen). Both wordings are `ShellStrings`
  overrides; keep the `{code}`/`{name}` placeholders when rewording.
- **Invited-guest exit** — a locked invite code with no extra seats arms
  JOIN GAME: the guest joins the host's table without adding seats first
  or falling back to solo. The host path is unchanged — the number still
  commits with the first seat.
- **Release automation** (`.github/workflows/release.yml`) — pushing a
  `v*` tag verifies tag↔pubspec coherence, runs the package gate, adopts
  the tag as a stranger would (a throwaway git-dependency consumer:
  resolve over HTTPS, pin-check, compile, boot), and only then opens the
  GitHub Release with the matching changelog section as notes.
- **`verify_consumers.sh --tag <ref>`** — the consumer gate against any
  tag, via a git-archive snapshot + `dependency_overrides`; the working
  tree is never touched.
- **Journey coverage at both levels** — the probe
  (`journey_scan_to_handoff_test.dart`) and a bare-`ShellApp` package
  test (`journey_scan_to_lobby_test.dart`) pin splash-scan → locked
  lobby → handoff with only the documented wiring.
- **Probe platform scaffolding** — Android/iOS folders for HERALD with
  the camera declarations scan-to-join needs (`CAMERA` + `uses-feature`
  on Android, `NSCameraUsageDescription` on iOS).

### Changed

- An invite-committed code displays in the locked game-number field
  (previously committed internally but rendered empty).
- The probe's NEW GAME and its invite/splash-scan arrivals share one
  branch: an arriving code always skips the entry chooser.

### Fixed

- The probe's boot test still drove the pre-reshape lobby flow under
  analyze-only gates; it now walks chooser → open seat → claim →
  handoff.

## 0.2.0 — 2026-09-23

The lobby grows a proper front door, invites go visual, and email
registration proves the address. Everything below is backwards-compatible
for hosts: existing `SharedLobbyStep` call sites keep working unchanged.

### Added

- **Lobby entry chooser** (`SharedLobbyEntry`) — the shared NEW-GAME
  landing: proposes the persisted player's name (editable, persisted) and
  offers SINGLE-PLAYER (the game's own screen) and MULTI-PLAYER (the seat
  lobby) doors.
- **Open seats** — ADD SEAT opens a roster slot advertised as
  "SEAT X — open" instead of asking a name; tapping it claims the seat
  through a name dialog. JOIN GAME stays disabled until every promised
  seat is claimed. Up to 8 seats; removing a slot renumbers the rest.
- **Scan-to-join** (`scanInviteWithCamera`) — a camera QR scanner in the
  lobby beside the paste button, over `mobile_scanner`, feeding the same
  invite codec; swappable `scanInviteExecutor` seam for tests and hosts.
- **Signup-confirmation links** — the emailed `{{ .ConfirmationURL }}`
  (`type=signup`) link is recognized by the shell's link watcher and
  completes a parked registration automatically (both `token_hash` and
  fragment-token generations); `confirmation_link.dart` parser,
  `AuthService.verifySignupTokenHash`, `completeSignupConfirmationLink`.
- **Provider grant story in settings** — the sign-in line names the
  provider, and GitHub sessions carry the note that grants must be
  revoked at github.com.
- `verify_consumers.sh --list` — prints the registered consumer gates.

### Changed

- The language picker always shows the effective language pre-selected
  (unset resolves to English), and re-tapping the selected entry persists
  it — previously a first visit showed nothing selected and tapping the
  apparent selection did nothing.
- The probe (HERALD) routes NEW GAME through the entry chooser and reads
  as a proper example game.

### Fixed

- OAuth session restore no longer drops the "popup closed" early-return;
  a stale flush guard no longer blocks per-game preference pushes.

### Operators

- `docs/OAUTH_SERVER_SETUP.md` explains why registrations may "sign in
  asap" (`GOTRUE_MAILER_AUTOCONFIRM=true`) and documents the
  confirm-signup template options alongside the recovery template notes.
