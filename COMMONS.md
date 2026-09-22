# kommons

The shared shell for every kjhrono game: the splash a player sees first, the
account/auth and settings they configure, the lobby they set up multiplayer
through, and the multiplayer transport itself. One copy of the code, consumed
by each game as a dependency — games supply their identity through the seams
each widget exposes.

**Consumers today:** `kapaxinfiniti` (the flagship) and
[`examples/probe`](examples/probe) — **HERALD**, a complete minimal game on the
shared shell that ships *with this package* as both the new-game starting
template and a second consumer its tests exercise on every change.
**Status:** this folder is its own git repo (first commit in place) with no
remote yet — kapax uses a `path:` dependency from this machine, and its
pubspec documents the `git:` flip for when a remote exists.

```yaml
dependencies:
  kommons:
    path: ../kommons   # or git:, once published
```

## Adopting the shell in a new game (~30 lines + your lobby steps)

1. **Dependencies** — pubspec line above. (`shared_preferences` arrives
   transitively; declare it yourself only if your code imports it directly —
   tests usually do.)
2. **Root widget** — `ShellApp` owns the MaterialApp wiring: the persisted
   theme and locale, Material's localization delegates, and the shell's
   startup preload (theme, locale, account) before the first frame:

   ```dart
   void main() => runApp(ShellApp(
         title: 'My Game',
         seedColor: const Color(0xff2e5d7a),
         home: const MySplash(),
       ));
   ```

   Custom palettes go through `themeBuilder`; `locale`, `themeMode` and
   `supportedLocales` are passthrough overrides. Hand-rolling the root
   (an `AnimatedBuilder` over `appTheme`/`appLocale` feeding MaterialApp)
   still works — ShellApp is the shortcut, not a requirement.

3. **Home** — configure `AppSplash` (below): name, description, flavor deck,
   `settingsBuilder` → `SettingsScreen(gameId: ...)`, and the actions shape
   that fits the app: `directAndNewGame` (PLAY for solo + NEW GAME for the
   shared lobby), `both` (NEW GAME + Continue), or `direct` (single-player
   apps, personal tools).
4. **Lobby** — either the one-screen `SharedLobbyStep` (seats by game number,
   solo, one `onHandoff` callback) or a multi-step wizard on `LobbyWizard`:
   step descriptors + step bodies, no scaffolding code.
5. **Multiplayer** (optional) — `PostgrestSyncService` + `CloudRoomService`
   against your game server (schema: `server/schema.sql` in each game repo),
   `CloudRoomCard` for the saved-games listing.

## Module reference

### Shell

| Export | What it gives you |
| --- | --- |
| `shell_app.dart` | `ShellApp` — the root widget that owns the MaterialApp wiring: persisted theme + locale on MaterialApp, Material localization delegates (the host's own merge in after), and the shell's startup preload (theme, locale, account). `seedColor`/`themeBuilder` shape the themes; `locale`/`themeMode`/`supportedLocales` are overrides. |
| `app_settings.dart` | Globals `appTheme` (`AppThemeNotifier`, persisted day/night) and `account` (`AccountController` — player name, session, cloud sign-in state), plus `appLocale` (`AppLocaleNotifier`, persisted language). `ServerConnection` records a game-server URL+key. Tests: `SharedPreferences.setMockInitialValues({})`, `account.resetForTest()`, `appLocale.resetForTest()`. |
| `app_top_bar.dart` | `AppTopBar` — release version (left), theme toggle + settings gear (right); `settingsBuilder` seam decides which settings screen opens. `AppTopBarActions` drops the same two buttons into any host `AppBar.actions`. |
| `auth_service.dart` | `AuthService` — plain GoTrue/Supabase REST client (no SDK): email sign-in/sign-up with confirmation, password recovery (`resetPassword` → `/auth/v1/recover`, `verifyRecovery` → `/auth/v1/verify` type=recovery) and password change (`updatePassword` → `PUT /auth/v1/user`), OAuth authorize URLs + implicit-fragment decoding (`authorizeUrl`, `sessionFromImplicitFragment`, `fetchUser`), `AuthSession`, `AuthException`. Per-app configuration: point it at your auth server. |
| `settings_screen.dart` | `SettingsScreen` — the shared ACCOUNT card (email flow + OAuth buttons, forgot-password sub-form, forced change-password form after recovery, change-password section on the signed-in card), PLAYER NAME, Language (a real picker over `appLocale`). Seams: `gameId` tags the route, `extraSections` appends game cards below the shared ones, `oauthProviders: {'google': handler}` turns a provider button live (no handler = disabled — pass `oauthPopupHandlers()` for the reference flow), `serverSetup` is your onboarding dialog while no game server is configured. |
| `app_splash.dart` | `AppSplash` — background art, big title, welcome (reads `account`: anonymous vs signed-in form), flavor scene, action buttons, description footer. Config: `appName`, `description`, `welcomeName`, `background`, `scenes` (defaults to `kDefaultSplashScenes`), `continueEnabled`/`continueLabel` (null = localized default), `actions` (`SplashActions.both` = NEW GAME + Continue, `startOnly` = NEW GAME alone, `direct` = PLAY alone — straight into the app, no lobby, or `directAndNewGame` = PLAY leading with NEW GAME behind), `onDirect`/`directLabel` for the direct variants, `settingsBuilder`, `debugSceneIndex` (test seam), `animateEntrance`. |

**Localization** — the shell carries its own strings in
`shell_strings.dart` (`ShellStrings`, English default + Italian today).
`appLocale` persists the pick; apps on `ShellApp` get the wiring for free
(`locale` plus Material's delegates on the MaterialApp). Hand-rolled roots
put it on themselves:

```dart
MaterialApp(
  locale: appLocale.value?.locale,
  // theme/darkTheme, delegates, …
)
```

Unset stays English. `ShellLanguage.nativeName` renders each language in
itself inside the picker. Host-supplied text (app name, flavor lines, step
titles) is the host's to localize; the splash's `continueLabel` overrides
its localized default.

**OAuth (Google / GitHub)** — the reference flow is the game server's
hosted GoTrue authorize page: the server holds the provider secrets (its
Supabase/GoTrue dashboard — no client secrets in app code), the app opens
`<server>/auth/v1/authorize?provider={provider}&redirect_to={target}` (GoTrue's
own route, already published by the stack's gateway as an open route — nothing
to add server-side), and the redirect back carries an implicit fragment that
decodes into a real session (`AccountController.signInWithProvider`). The
delivery follows the platform:

* **Web** — a popup back onto the app's origin; nothing to configure.
* **Android / iOS** — the system browser (external session — Google blocks
  WebView-based in-app browsers), then the redirect re-opens the app through
  its app links and the collector decodes the same fragment. Set
  `account.oauthRedirectUri` (e.g. `Uri.parse('mygame://auth')`) so the
  authorize URL carries the app's target, and wire it to receive links
  (Android App Links / iOS Universal Links, or a custom scheme with the
  intent-filter / `CFBundleURLTypes` entries; `url_launcher` + `app_links`
  do the opening and listening — the collector covers warm returns, cold
  starts, refused launches as a `StateError`, and a 10-minute abandon as a
  quiet cancel).

The server must allow-list both the web origin and the mobile redirect.
Wire it with one line — `SettingsScreen(oauthProviders: oauthPopupHandlers())`
— as `examples/probe` does. Hosts may swap `account.collectOAuthFragment`
for a callback page or a fully custom delivery; the deep-link flow core
(`collectOAuthFragmentDeepLink`) takes injected callbacks for tests. The
operator side — enabling the providers in the game server's GoTrue/Supabase
dashboard and allow-listing every redirect target — is documented in
[docs/OAUTH_SERVER_SETUP.md](docs/OAUTH_SERVER_SETUP.md), alongside the
schema notes.

**Lost & changed passwords** — the account card covers the whole lifecycle
in-app (email templates stay server-side):

* **Forgot password** — a link under the email sign-in form opens a sub-form
  (`forgot-password` → `reset-code-field`): the shell emails a recovery code
  (GoTrue `/auth/v1/recover`), the player types it back and lands signed-in
  with `account.passwordResetPending` true — the forced change-password form
  is the only step on the card (sign-out is refused until a new password is
  chosen, code `reset_in_progress`). If the server's template instead mails a
  link, its token works in the same field.
* **Change password** — the signed-in card carries a section
  (`change-password-section`, fields `current/current-password-field`,
  `new/new-password-field`, `confirm/confirm-password-field`) that verifies
  the current password and PUTs the new one (`PUT /auth/v1/user`). It doubles
  as the "first connect with the mailed temporary password, then set your
  own" path: sign in with the temp password, change it here.
* `cancel-reset` (`resend-reset` beside it) leaves the sub-form without
  side effects; validation errors (`invalid_email`, `shortPassword`,
  `passwordMismatch`) surface inline before any call.

**Splash art ships with the package** — `assets/splash_bg.svg` plus three
vignettes (`splash_caravan`, `splash_dungeon`, `splash_tame`), referenced as
`packages/kommons/assets/...`. A game may pass its own `background`
and `scenes`.

**The entrance cascade** (on unless `animateEntrance: false` or the platform
asks for reduced motion): title/welcome fade+rise (0–455 ms) → buttons
stagger in, New Game leading and Continue 100 ms behind (280–660 ms) →
flavor line (660–860 ms) → foreground vignette rises into place last
(760–960 ms). All beats are named constants at the top of `_AppSplashState`.

### Multiplayer core

| Export | What it gives you |
| --- | --- |
| `lobby_seat.dart` | `LobbySeat` — the game-agnostic seat: name, `colorHex`, pacing (`interactEveryDays`), `ready`, AI flag; JSON roundtrip with defaults for old saves. |
| `game_sync.dart` | `GameSyncService` — the transport contract: session publish/fetch, `announcePlayer`, `setReady`, `roster`, `poll`, clock publish/fetch, `deleteRoom`, and the joiner action outbox (`pushActions`/`takeActions`). `SyncEvent` — polled lobby/game events. |
| `game_sync_service.dart` | The two implementations: `InMemorySyncService` (hot-seat) and `PostgrestSyncService` (online rooms via PostgREST). |
| `cloud_room_service.dart` | `CloudRoomService` — read model over the server's rooms+roster: `listRooms(playerName)`, `fromStoredConnection()` (reads the saved game-server connection), per-room host secret/seat-name storage, `hostResumeService` (re-mints host rights), the handover API (`designateHost`, `cancelHostDesignation`, `claimHostPromotion`, `forgetHostedRoom`). `CloudRoom`/`CloudSeat` — the listing models. `forTestFactory` for tests. |
| `cloud_room_card.dart` | The shared saved-games surfaces: `CloudRoomCard` (banner seat chips local-first, host crown, flash wash + change note, room menu — everything behind `onOpen/onDelete/onLeave/onHandover/onCancelHandover` seams), `cloudSeatChip`, `seatsLocalFirst`, `showHandoverSeatPicker`, `confirmDeleteRoomDialog`, `confirmLeaveRoomDialog`, `hostCredentialsRevoked`, and `claimHostPowers` — the crown-claim protocol returning `(status, sync, snapshot)`. |
| `cloud_handover_section.dart` | `CloudHandoverSection` — the whole pending-host-handover block (header, error line, claim-only cards) from `rooms`/`error`/`onClaim`/`claimBusy`; renders nothing when quiet. |
| `game_server_dialog.dart` | `showGameServerConnectionDialog` + `saveGameServerConnection`/`storedGameServerUrl` — the shared connect-to-game-server onboarding. |
| `banner_color_picker.dart` | `bannerPalette`, `showBannerColorPicker`, and the `bannerColor`/`bannerColorHex` codecs every banner tint flows through. |
| `lobby_wizard.dart` | `LobbyWizard` — the new-game wizard frame: progress rail (tappable nodes, done-checks), "Step X of Y — Title" header, Back/Continue nav (hidden on first/last step). Host supplies `steps: List<LobbyStepDescriptor>` (title, icon, optional `subtitle`), `current`, `onGoto`, `body`, optional `title`, `appBarActions`, and `canContinue(stepIndex)` — the per-step gate that disables Continue until the host says the step is complete (the rail stays free navigation). |
| `lobby_step.dart` | `SharedLobbyStep` — the shared one-screen lobby for games that don't need a wizard: the local seat (persisted `account` name + next free banner color), extra seats joined by entering the game number (field locks while seats are attached, unlocks when all are removed), and START SOLO. Exactly one callback — `onHandoff(SharedLobbyHandoff)` — carries `self`, the guest `seats`, the `roomCode` (null offline) and the `online` flag into the game's NEW-GAME section, where the shell's work ends. Fully localized, keys prefixed `shared-lobby-*`. |

The multiplayer UI speaks the shell's languages: every player-facing string in the room card, handover section and server dialog comes from `ShellStrings`, following the same `appLocale` pick as the rest of the shell.

### Tooling (not a Dart export)

- **`tool/deploy.sh`** — commit → push to GitHub → rsync server files to the
  VM → apply `schema.sql` when its hash changed → rebuild web → publish to
  the nginx webroot. Flags: `--dry-run`, `--no-commit`, `--no-build`,
  `--force-migrate`, `--message`. Games keep a ~15-line `scripts/deploy.sh`
  delegate plus their own **git-ignored** `deploy.config` (template:
  `deploy.config.example` — host, ssh user/key, target dirs, web root,
  db container, git paths). This is the per-user distribution story: every
  player/collaborator points the config at their own machine.

## Conventions

- **Globals, not DI** — `appTheme` and `account` are process-wide
  singletons; tests reset them (`account.resetForTest()` + mocked prefs).
- **Seams, not subclasses** — app identity enters through constructor
  callbacks/builders (`settingsBuilder`, `extraSections`, `oauthProviders`,
  the card's `on*` callbacks), never through editing package code.
- **Widget keys are API** — tests in consumers pin `ValueKey`s the widgets
  document (e.g. the room card's `cloud-<code>`, `cloud-seat-<code>-<name>`,
  `confirm-delete-room`); renaming one is a breaking change.
- **Reduced motion is honored** — every animation in the shell rests at its
  final layout when the platform asks, not at its first frame.
- **Server schema** — the multiplayer core expects the PostgREST surface
  defined in each game repo's `server/schema.sql` (rooms, roster, snapshots,
  action outbox); keep copies in sync across games.

## Development

```bash
bash tool/verify_consumers.sh   # ONE command: analyze + test for the
                                # package, examples/probe, and kapax
```

`--quick` runs analyze only. The same script is the CI gate
(`.github/workflows/consumers.yml` calls it on every push/PR), so local and
remote verification can never drift apart. Consumer failures are collected,
not short-circuited — one broken game never hides another's result. Add a
new game by appending a line to `CONSUMERS` in `tool/verify_consumers.sh`.

When you change the package, the consumers' gates are the proof the seams
hold — kapax alone carries 778 tests against them.
