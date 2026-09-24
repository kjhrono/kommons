# Changelog

All notable changes to the kommons shell are documented here. The format
loosely follows [Keep a Changelog](https://keepachangelog.com/) and the
versioning intent is [semver](https://semver.org/) — while the package is
pre-1.0, minor versions carry the features.

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
