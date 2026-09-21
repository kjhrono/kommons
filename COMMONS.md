# kommons

The shared shell for every kjhrono game: the splash a player sees first, the
account/auth and settings they configure, the lobby they set up multiplayer
through, and the multiplayer transport itself. One copy of the code, consumed
by each game as a dependency — games supply their identity through the seams
each widget exposes.

**Consumers today:** `kapaxinfiniti` (the flagship) and
[`examples/kj_probe`](examples/kj_probe) — a complete minimal game on the
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
2. **Root widget** — listen to the persisted theme:

   ```dart
   return AnimatedBuilder(
     animation: appTheme,
     builder: (context, _) => MaterialApp(
       theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: mySeed, brightness: Brightness.light)),
       darkTheme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: mySeed, brightness: Brightness.dark)),
       themeMode: appTheme.value,
       home: const MyHome(),
     ),
   );
   ```

3. **Home** — configure `AppSplash` (below): name, description, flavor deck,
   `onNewGame` → your lobby, `settingsBuilder` → `SettingsScreen(gameId: ...)`.
4. **Lobby** — build your new-game wizard on `LobbyWizard`: step descriptors
   + step bodies, no scaffolding code.
5. **Multiplayer** (optional) — `PostgrestSyncService` + `CloudRoomService`
   against your game server (schema: `server/schema.sql` in each game repo),
   `CloudRoomCard` for the saved-games listing.

## Module reference

### Shell

| Export | What it gives you |
| --- | --- |
| `app_settings.dart` | Globals `appTheme` (`AppThemeNotifier`, persisted day/night) and `account` (`AccountController` — player name, session, cloud sign-in state). `ServerConnection` records a game-server URL+key. Tests: `SharedPreferences.setMockInitialValues({})`, `account.resetForTest()`. |
| `app_top_bar.dart` | `AppTopBar` — release version (left), theme toggle + settings gear (right); `settingsBuilder` seam decides which settings screen opens. `AppTopBarActions` drops the same two buttons into any host `AppBar.actions`. |
| `auth_service.dart` | `AuthService` — plain GoTrue/Supabase REST client (no SDK): email sign-in/sign-up with confirmation, `AuthSession`, `AuthException`. Per-app configuration: point it at your auth server. |
| `settings_screen.dart` | `SettingsScreen` — the shared ACCOUNT card (email flow + OAuth buttons), PLAYER NAME, Language, theme. Seams: `gameId` tags the route, `extraSections` appends game cards below the shared ones, `oauthProviders: {'google': handler}` turns a provider button live (no handler = disabled), `serverSetup` is your onboarding dialog while no game server is configured. |
| `app_splash.dart` | `AppSplash` — background art, big title, welcome (reads `account`: anonymous vs signed-in form), flavor scene, NEW GAME / Continue buttons, description footer. Config: `appName`, `description`, `welcomeName`, `background`, `scenes` (defaults to `kDefaultSplashScenes`), `continueEnabled`/`continueLabel`, `actions` (`SplashActions.both` or `startOnly`), `settingsBuilder`, `debugSceneIndex` (test seam), `animateEntrance`. |

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
                                # package, examples/kj_probe, and kapax
```

`--quick` runs analyze only. The same script is the CI gate
(`.github/workflows/consumers.yml` calls it on every push/PR), so local and
remote verification can never drift apart. Consumer failures are collected,
not short-circuited — one broken game never hides another's result. Add a
new game by appending a line to `CONSUMERS` in `tool/verify_consumers.sh`.

When you change the package, the consumers' gates are the proof the seams
hold — kapax alone carries 778 tests against them.
