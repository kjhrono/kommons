# kommons

The shared shell for every kjhrono game: the splash a player sees first, the
account/auth and settings they configure, the lobby they set up multiplayer
through, and the multiplayer transport itself. One copy of the code, consumed
by each game as a dependency — games supply their identity through the seams
each widget exposes.

**Consumers today:** [`examples/probe`](examples/probe) — **HERALD**, a complete minimal game on the
shared shell that ships *with this package* as both the new-game starting
template and a consumer its tests exercise on every change.
**Status:** this folder is its own git repo, hosted at
`github.com/kjhrono/kommons` (the CI badge in the README tracks the consumer
gate). Consumer games use a `path:` dependency from beside this checkout,
and their pubspecs document the `git:` flip for when a published ref makes
sense.

```yaml
dependencies:
  kommons:
    path: ../kommons   # development, beside a checkout
    # or, adopting a release tag (v0.2.0 verified adoptable from a
    # fresh checkout via both path: and git:):
    # git:
    #   url: https://github.com/kjhrono/kommons.git
    #   ref: v0.2.0
```

## Adopting the shell in a new game (~30 lines + your lobby steps)

The whole adoption in one paste — dependency, boot, multiplayer door:

```yaml
# pubspec.yaml — the release tag; path: ../kommons beside a checkout
dependencies:
  kommons:
    git:
      url: https://github.com/kjhrono/kommons.git
      ref: v0.2.0
```

```dart
// The shell owns MaterialApp: persisted theme + locale, delegates, preload.
void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => ShellApp(
        title: 'My Game',
        seedColor: const Color(0xff2e5d7a),
        home: AppSplash(
          appName: 'My Game',
          description: 'What your game is, in one line.',
          actions: SplashActions.directAndNewGame,
          onDirect: () {},  // PLAY → your single-player screen
          onNewGame: () {}, // NEW GAME → the lobby (or SharedLobbyEntry)
        ),
      );
}

// The multiplayer door: SharedLobbyStep inside YOUR Scaffold — it renders
// chips and text fields, so it needs a Material ancestor. One callback
// hands the table to the game's NEW-GAME section.
Navigator.push(context, MaterialPageRoute<void>(
  builder: (_) => Scaffold(
    appBar: AppBar(title: const Text('NEW GAME')),
    body: SharedLobbyStep(onHandoff: (SharedLobbyHandoff h) => startGame(h)),
  ),
));
```

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
   step descriptors + step bodies, no scaffolding code. Wrap the step in
   your own `Scaffold` — it renders chips and text fields and needs a
   Material ancestor.
5. **Multiplayer** (optional) — `PostgrestSyncService` + `CloudRoomService`
   against your game server (schema: `server/schema.sql` in each game repo),
   `CloudRoomCard` for the saved-games listing.

## Module reference

### Shell

| Export | What it gives you |
| --- | --- |
| `shell_app.dart` | `ShellApp` — the root widget that owns the MaterialApp wiring: persisted theme + locale on MaterialApp, Material localization delegates (the host's own merge in after), and the shell's startup preload (theme, locale, account). `seedColor`/`themeBuilder` shape the themes; `locale`/`themeMode`/`supportedLocales` are overrides. `onJoinInvite` receives a parsed invite when the app is opened through a join link (see **Invites** below); `onRecoveryLink` receives a reset-email link the same way. A signup-confirmation link (`…type=signup`) is handled by the shell itself — it completes a parked registration (see **Signup confirmation** below). When an authorize-redirect link (`…#access_token=…`) re-opens the app with no OAuth flow waiting, the shell restores the session it carries (`restoreSessionsFromLinks: false` opts out). |
| `app_settings.dart` | Globals `appTheme` (`AppThemeNotifier`, persisted day/night) and `account` (`AccountController` — player name, session, cloud sign-in state, **cross-project preference sync**), plus `appLocale` (`AppLocaleNotifier`, persisted language). `ServerConnection` records a game-server URL+key. Tests: `SharedPreferences.setMockInitialValues({})`, `account.resetForTest()`, `appLocale.resetForTest()`. |
| `shell_preferences.dart` | The cross-project preference sync codec: the `kommons` slice of GoTrue `user_metadata` (theme, locale, player name) with per-key `updatedAt` stamps, the patch builder and the reconcile rules the controller runs on sign-in — plus the per-game settings map (`kommons.games.<gameId>`) hosts can opt into. See **Cross-project preference sync** below. |
| `app_top_bar.dart` | `AppTopBar` — release version (left), theme toggle + settings gear (right); `settingsBuilder` seam decides which settings screen opens. `AppTopBarActions` drops the same two buttons into any host `AppBar.actions`. |
| `auth_service.dart` | `AuthService` — plain GoTrue/Supabase REST client (no SDK): email sign-in/sign-up with confirmation, password recovery (`resetPassword` → `/auth/v1/recover`, `verifyRecovery` → `/auth/v1/verify` type=recovery) and password change (`updatePassword` → `PUT /auth/v1/user`), OAuth authorize URLs + implicit-fragment decoding (`authorizeUrl`, `sessionFromImplicitFragment`, `fetchUser`), `AuthSession` (including the OAuth `provider_token` grant), `AuthException`. Per-app configuration: point it at your auth server. |
| `settings_screen.dart` | `SettingsScreen` — the shared ACCOUNT card (email flow + OAuth buttons, forgot-password sub-form, forced change-password form after recovery, change-password section on the signed-in card; the sign-in line names the provider — *Signed in with github · …* — and GitHub sessions carry the grant note, since sign-out cannot revoke that grant client-side), PLAYER NAME, Language (a real picker over `appLocale`; the current choice is always pre-selected — an unset language shows English, the effective one, and re-tapping it persists the pick). Seams: `gameId` tags the route, `extraSections` appends game cards below the shared ones, `oauthProviders: {'google': handler}` turns a provider button live (no handler = disabled — pass `oauthPopupHandlers()` for the reference flow), `serverSetup` is your onboarding dialog while no game server is configured. |
| `app_splash.dart` | `AppSplash` — background art, big title, welcome (reads `account`: anonymous vs signed-in form), flavor scene, action buttons, description footer. Config: `appName`, `description`, `welcomeName`, `background`, `scenes` (defaults to `kDefaultSplashScenes`), `continueEnabled`/`continueLabel` (null = localized default), `actions` (`SplashActions.both` = NEW GAME + Continue, `startOnly` = NEW GAME alone, `direct` = PLAY alone — straight into the app, no lobby, or `directAndNewGame` = PLAY leading with NEW GAME behind), `onDirect`/`directLabel` for the direct variants, `onScanInvite` (adds a scan button that opens the camera QR scanner — same seam as the lobby's — and hands the parsed game number to the host; jump straight into the lobby with `SharedLobbyStep(initialCode: …)`, null hides the button), `settingsBuilder`, `debugSceneIndex` (test seam), `animateEntrance`. |

**Localization** — the shell carries its own strings in
`shell_strings.dart` (`ShellStrings`, English default + Italian today).
`appLocale` persists the pick; apps on `ShellApp` get the wiring for free
(`locale` plus Material's delegates on the MaterialApp). Hosts can reword
any string per language — most usefully a partial override, since every
field defaults:

```dart
ShellStrings.installOverrides({
  ShellLanguage.english: const ShellStrings(
      preferencesSynced: 'Your look, language and name just synced.'),
  ShellLanguage.italiano: const ShellStrings.italian(
      preferencesSynced: 'Aspetto, lingua e nome sono arrivati dal cloud.'),
});
```

(`ShellStrings.resetOverrides()` restores the built-ins; install before
`runApp`.) The lobby's join wordings are overrides too:
`inviteJoinedWith` ("Joining table {code} as {name}.", the arrival
confirmation when an invite or splash scan seats a player) and
`startingTable` ("Starting table {code}…", the exit confirmation that
rides the handoff onto the game screen). Keep the `{code}`/`{name}`
placeholders when rewording — they are what the helpers substitute.
Hand-rolled roots put the rest on themselves:

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

**Provider grants at sign-out** — a provider sign-in's redirect fragment
carries the provider's own `provider_token` (the grant, distinct from
GoTrue's session pair); the shell captures it onto the session, keeps it
across metadata writes and refreshes, and `signOut` uses it to revoke the
grant through the same launch plumbing the authorize link uses
(`oauth_revoke.dart`). The honest per-provider split: **Google** exposes a
client-side revoke endpoint, so its grant is revoked for real (next sign-in
shows the consent screen again); **GitHub's** grant can only be removed
with the server-held client secret, so the shell does not pretend —
`canRevokeProviderGrant` reports false and sign-out stops the GoTrue
session only (operators who want GitHub grants gone use the dashboard or
an admin job — see OAUTH_SERVER_SETUP.md). The settings card tells the
player their side of the story too: the sign-in line names the provider
(`signedInWithProvider`), and GitHub sessions show `githubGrantNote` —
revoke it at github.com → Settings → Applications. Restores carry the
provider across restarts, so the story stays right after an app reboot. A
failed launch is a quiet skip, never a sign-out failure.

**The lobby flow** — NEW GAME lands in `SharedLobbyEntry`, which proposes
the persisted player's name in an editable field (the last natural moment
to adjust it before sitting at a table; the edit persists through
`account.setPlayerName`) and offers the two front doors. **SINGLE-PLAYER**
hands the name to the game's own screen — no seats, no numbers, no lobby
(the splash's `direct` action is its zero-lobby sibling). **MULTI-PLAYER**
opens `SharedLobbyStep`, where the local seat shows that name and ADD
SEAT offers an **open seat** — "SEAT X — open" — instead of asking for a
name up front: the slot waits for the friend who will sit there. Tapping
an open seat claims it (a small dialog asks the name the table will see,
welcome snackbar included); removing it renumbers the seats below.The game number commits with the first seat, and JOIN GAME stays disabled
until every promised seat has been claimed — an open slot is a player who
has not sat down yet. Up to 8 seats; START SOLO remains the one-tap way
out.

* **Preparing the table in advance** — pass `gameId:` to
  `SharedLobbyStep` and the roster persists (prefs key
  `prefs.lobby.<gameId>.roster`, via `lobby_roster.dart`): a host adds
  open slots and claims seats today, and after an app restart the same
  table waits — committed number, open and claimed seats alike. The draft
  clears when it has served its purpose: starting the game (the handoff
  owns the table from there) or START SOLO (a solo table has nothing to
  re-offer). An invite link or scan landing on a prepared table wins for
  that visit — the link's number replaces the stored one. Without a
  `gameId` the lobby stays purely in-memory, as before.

**Invites** — a host seats distant friends without dictating a number to
them. Once a game number is committed (a join, or the host's own table),
the lobby renders an invite section: the shareable link
(`https://<page>#join=K7QX2` on web — the page itself, so the copied link
opens the same app; a portable `#join=…` fragment elsewhere), **Copy
link**, **Send by email** (a pre-filled `mailto:` the player
addresses — the shell sees no contacts; where no mail handler exists the
link lands on the clipboard instead), and a **QR code** for phone players:
scan-to-join, nothing to copy or type. The QR encodes the same full invite
URL the link field shows and appears only where that URL is meaningful —
on web (the page's own origin) or wherever the host passes
`SharedLobbyStep(inviteBaseUrl: …)` (e.g. the game's landing page on
mobile builds); with no base URL it stays hidden, because a bare
`#join=…` fragment is nothing a phone's camera can open. **Share the QR**
renders that QR as a PNG (white mat, testable via `qrShareExecutor`) and
hands it to the platform share sheet (`share_plus`) with the invite link
riding along as text — straight into a chat app. Where no share handler
exists it falls back to copying the link, exactly like the email button.
The full join journey — splash scan → locked lobby with the code seated —
is pinned twice: by the probe (`examples/probe/test/journey_scan_to_handoff_test.dart`)
and package-level through a bare `ShellApp` host mirroring the adoption
snippet (`test/journey_scan_to_lobby_test.dart`), so the documented wiring
itself cannot regress.

On the other end the link carries the table to the friend — or the friend
scans the code straight off the screen: the lobby's camera **scan button**
(`scanInviteWithCamera`) reads a QR from the seat-side camera and commits
the number exactly like a typed join. Where the camera is unavailable
(desktop, web without camera permission) it explains itself with a
localized message instead of dying silently. Mobile hosts must declare
the camera: Android needs `<uses-permission android:name="android.permission.CAMERA"/>`
(plus a `uses-feature` with `required="false"` so camera-less devices can
still install) and iOS needs an `NSCameraUsageDescription` that says *why*
— the probe's manifests are the reference wording.

* **ShellApp.onJoinInvite** — the shell watches for opened links (the
  browser URL on web; app links on mobile, cold start *and* warm returns,
  sharing the one `app_links` backend with the OAuth collector) and hands
  the parsed `JoinInvite` to the host's handler, which navigates to its
  lobby with `SharedLobbyStep(initialCode: invite.code)`: the number is
  committed and locked before the first frame, an "Invited as …" snackbar
  confirms the persona, and ADD SEAT keeps working for adding more
  friends to the same table.
* **Paste** — the uncommitted lobby offers *Paste a link you were sent*
  (a QR code or a link copied from chat/email): after a confirm dialog it
  commits and locks the number exactly like a typed join.

```dart
ShellApp(
  // …
  onJoinInvite: (invite) => Navigator.push(context, MaterialPageRoute(
    builder: (_) => MyLobby(initialCode: invite.code),
  )),
)
```

What the shell deliberately does **not** do: validate the number against
a server (the game's transport owns that at start), persist invites
across restarts, or send email itself — there is no mail server in the
package, just the player's own mail client. Mobile hosts should register
their app-link target the same way as the OAuth redirect (see
[docs/OAUTH_SERVER_SETUP.md](docs/OAUTH_SERVER_SETUP.md)).

* **From the splash** — pass `AppSplash.onScanInvite` and the splash
carries a scan button of its own: a friend shows their QR at the door,
the phone reads it, and the host callback receives the parsed game
number — HERALD's own splash jumps straight into the seat lobby with the
number pre-seated, skipping the chooser. The button reuses the lobby's
scanner seam (`joinScanExecutor`), so tests stub it identically, and the
splash hides it entirely when no callback is supplied.
**Signup confirmation** — an email registration proves the address before
signing the player in. With the server's confirmation mail enabled
(`GOTRUE_MAILER_AUTOCONFIRM=false` — see
[docs/OAUTH_SERVER_SETUP.md](docs/OAUTH_SERVER_SETUP.md) for why `true`
signs players in "asap" with no email at all), a fresh signup answers
`email_not_confirmed`: the shell parks it (persisted — a restart returns
to the same state) and shows the check-your-inbox card with the code
field, a resend (`POST /auth/v1/resend`) and the typed address. The
proof completes either way:

* **Code** — the emailed `{{ .Token }}` digits, via `confirmSignupCode`.
* **Link** — the `{{ .ConfirmationURL }}` link (`type=signup`), handled
  automatically: the shell detects `…?token_hash=…&type=signup`
  (self-addressing — confirms on any device) and `…#token=…&type=signup`
  (verified against this device's parked email) exactly like recovery
  links, and completes the confirmation itself — no host code, landing
  the player signed in with preferences synced. A link with nothing
  parked declines quietly; a plain-token link on a foreign device throws
  `confirmation_email_unknown` (use the code, or have the server mail
  token-hash links).

Detection is disjoint from recovery, joins and OAuth by construction
(`type=signup` vs the others' payloads) — 16 tests in
`test/confirmation_link_test.dart`.

**Lost & changed passwords** — the account card covers the whole lifecycle
in-app (email templates stay server-side):

* **Forgot password** — a link under the email sign-in form opens a sub-form
  (`forgot-password` → `reset-code-field`): the shell emails a recovery code
  (GoTrue `/auth/v1/recover`), the player types it back and lands signed-in
  with `account.passwordResetPending` true — the forced change-password form
  is the only step on the card (sign-out is refused until a new password is
  chosen, code `reset_in_progress`).
* **Recovery links** (`recovery_link.dart`) — a `{{ .ConfirmationURL }}`
  template's whole link is a supported sign-back-in path, two ways:

  * *Opened as a link* — register `ShellApp.onRecoveryLink`; the shell
    detects `…?token_hash=…&type=recovery` (newer generation,
    self-addressing) and `…#token=…&type=recovery` (fragment, verified
    against this device's parked reset email) on the browser URL (web) or
    app links (mobile, cold start and warm returns) and hands the parsed
    link to the handler — HERALD completes it with
    `account.completeRecoveryLink(link)` and pushes the settings screen.
  * *Pasted* — the reset sub-form's code field accepts the whole pasted
    link (`recoveryLinkFromClipboardText`); a plain-token paste rides the
    email this device parked, so it always verifies.

  A plain-token link opened on a device that never requested the reset
  throws `recovery_email_unknown` (honest message: use the code, or have
  the server mail token-hash links). Delivery is disjoint from joins by
  construction (`type=recovery` vs `join=`) — 18 tests in
  `test/recovery_link_test.dart`.
* **Change password** — the signed-in card carries a section
  (`open-change-password` reveals it on the signed-in card; the fields are
  `current-password-field`, `new-password-field`,
  `confirm-password-field`, with `save-new-password` and, in the
  temp-password flow, `not-now-password`) that verifies
  the current password and PUTs the new one (`PUT /auth/v1/user`). It doubles
  as the "first connect with the mailed temporary password, then set your
  own" path: sign in with the temp password, change it here.
* **Temporary-password flag** — an operator issuing a temporary password
  (admin API or dashboard) sets `must_change_password: true` in the user's
  `user_metadata`; the shell reads the flag out of every session response,
  exposes `account.mustChangePassword`, and **auto-opens the change-password
  section** on the next settings visit — no link tap. The flagged form skips
  the current-password field (that session just proved the password) and
  offers **Not now** (`not-now-password`): the flag nags on every settings
  visit but never imprisons — sign-out stays available, unlike the recovery
  flow. A successful change clears the key server-side (GoTrue metadata
  merge: `"must_change_password": null` removes it) and locally in the same
  PUT.
* `cancel-reset` (`resend-reset` beside it) leaves the sub-form without
  side effects; validation errors (`invalid_email`, `shortPassword`,
  `passwordMismatch`) surface inline before any call.

**Cross-project preference sync** — one player, many games, one experience:
the shell keeps **theme, language and player name** in a namespaced slice of
the GoTrue user's `user_metadata` (`{"kommons": {"theme": ..., "locale":...,
"playerName": ..., "updatedAt": {per-key epoch stamps}}}`), so every game
pointed at the same auth server inherits them on sign-in — email, Google or
GitHub alike, no schema change, private to the account by construction. The
namespace keeps provider-written metadata and server flags
(`must_change_password`) untouched.

* **Pull on sign-in** — every sign-in path runs
  `account.syncPreferencesOnSignIn()` — including a session restored from
  an app link (`account.restoreFromSessionFragment`, an authorize redirect
  that re-opened the app with no collector waiting): fetch the user,
  reconcile cloud vs
  local per key (a cloud value applies when it is at least as new as the
  local edit — `updatedAt` stamps, `shell_preferences.dart`), then push the
  union back. Two devices that edited *different* keys both win; a newer
  local edit is never shadowed by older cloud state. Offline or unreachable
  servers fail quietly — the local experience is already correct and the
  next sign-in retries the merge. The sync never throws into the sign-in
  flow.
* **Push on change** — the theme toggle, the language picker and the player
  name field stamp the edit locally (`prefs.account.prefStamps`) and flush a
  debounced (3 s) `PUT /auth/v1/user` via `AuthService.updateUserMetadata`;
  rapid edits coalesce into one call, failed flushes re-queue and ride the
  next sign-in. Not signed in → the edit stays local and is remembered as
  this device's choice (stamped + origin-marked, so a cloud value can never
  silently clobber it at the next sign-in — the offline edit wins and
  propagates up).
* **Where each value came from** — every shared preference carries a
  provenance (`ShellPrefOrigin`: `cloud` / `local` / `device`), persisted in
  `prefs.account.prefOrigins` and updated by every sync path (pulled values
  → cloud; a device's kept or edited values → local). The settings screen
  narrates it under the game sections — one line like *"Theme from your
  account, Language app default, Player name from this device"* — rebuilt
  live on edits, pulls and sign-ins. Read it in code with
  `account.preferenceOrigin(key)`.
* **The sync is visible** — when a sign-in pulls values that *actually
  changed* locally (`account.preferencesPulled`, a change-counting signal;
  same-value re-confirms stay silent), `ShellApp` shows a small floating
  "Preferences loaded from your account" snackbar on MaterialApp's root
  messenger — once per pull, localized (in the *new* language when the
  locale itself was pulled), and quiet under
  `ShellApp(showPreferencesSyncedNotice: false)`. Hosts can drive their own
  UI from `preferencesPulled`, acknowledging events with
  `shouldShowSyncNotice` / `markSyncNoticeShown`.
* **Per-game settings opt in too** — a host can ride the same machinery
  with its own namespaced map under `kommons.games.<gameId>` (stamped per
  game in `kommons.games.updatedAt`): `await
  account.setGameSettings(gameId, {…})` saves locally and pushes through
  the same debounced flush; `await account.gameSettings(gameId)` reads the
  merged map. The reconcile is the shell rules one level down — a newer
  cloud map pulls on sign-in (and fires the same pull signal), a strictly
  newer local map (e.g. an offline edit) pushes, equal stamps are no-ops.
  Values are JSON-shaped (maps, lists, strings, numbers, bools); the
  reserved `updatedAt` key inside a game map is stripped on save. Games
  that never call the API are never synced and never stored.
* **What never pushes** — unset choices (no language picked, the default
  'Player' name) and everything else host-side by design: `extraSections`
  widget state, server connections, `gameId`-scoped keys. (The per-game
  *sync* above only carries what the host explicitly saves through it.)
* **Test seams** — `account.debugFlushPendingPreferencePushes()` (await the
  sign-in sync, run the flush now), `appTheme.applySynced(mode)` /
  `appLocale.applySynced(language)` (apply a synced value without re-firing
  the push loop), 33 tests in `test/preference_sync_test.dart`.

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
| `lobby_entry.dart` | `SharedLobbyEntry` — the shared NEW-GAME entry: a name field proposing the persisted player's name (editable; the edit persists through `account.setPlayerName`), a **banner preview** showing the exact color (and initial) the lobby's seat 1 will carry — assigned by the same `nextFreeBannerColorHex` rule, so the player sees their color before entering — then the two front doors — SINGLE-PLAYER (`onSinglePlayer(name)`, the project wires its solo screen) and MULTI-PLAYER (`onMultiPlayer(name)`, land in `SharedLobbyStep`). A game without one of the modes passes a handler that pops instead. Keys `shared-lobby-entry-*`. |
| `lobby_step.dart` | `SharedLobbyStep` — the shared one-screen lobby for games that don't need a wizard: the local seat (persisted `account` name + next free banner color, seat 1), **open seats** — ADD SEAT opens a roster slot advertised as "SEAT X — open" (no name asked); tapping it claims the seat through a name dialog; a claimed seat carries an **edit** action (pencil, or a long-press on the chip) whose dialog renames it (typo fixes) or re-opens it for another player — JOIN GAME stays disabled while any promised seat is unclaimed (up to 8 seats) — except for the invited guest: a locked invite code with no extra seats arms JOIN GAME, so they join the host's table without hosting one. The game number commits with the first seat (field locks, invite section appears: link, copy, email, QR — see below) and releases when all seats are removed. Exactly one callback — `onHandoff(SharedLobbyHandoff)` — carries `self`, the claimed `seats`, the `roomCode` (null offline) and the `online` flag into the game's NEW-GAME section, where the shell's work ends. Pass `gameId:` to persist the roster across restarts (`lobby_roster.dart`: the host prepares the table in advance; the draft clears on handoff or solo), `initialCode:` to seat a player who arrived through an invite link (the code shows in the locked field, and the arrival snackbar names the table), `inviteBaseUrl:` to make the QR scannable on non-web builds. Fully localized, keys prefixed `shared-lobby-*`. |
| `join_link.dart` | `JoinInvite` + `joinInviteFromUri` / `joinInviteFromClipboardText` — the invite codec: `…#join=K7QX2` (fragment, or `?join=` for hosted shorteners, optional `&server=`) parses in, `link(base:)` builds the shareable string; `copyJoinLink` / `readJoinLinkClipboard` wrap the system clipboard (null-safe where none exists). |
| `join_scan.dart` | `scanInviteWithCamera(context, …)` — the scan-to-join entry point: a `mobile_scanner` camera sheet over the lobby's executor seam (`scanInviteExecutor`, swappable for tests and embedding), parsing what it sees through the same codec — a scanned image of the invite QR works exactly like a scanned text. |

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

- **Releases** — pushing a `v*` tag (e.g. `v0.3.0`) triggers the
  `release` workflow: it checks the tag matches `pubspec.yaml`'s version,
  runs the package gate (analyze + test), and opens the GitHub Release
  with the matching CHANGELOG section as notes. The tag is the artifact —
  games adopt a release with `kommons: { git: { url: …, ref: v0.3.0 } }`.

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

### Change alerts to connected games

When kommons changes on `master` — **after** the consumer gate is green —
its CI pings every registered game repo with a `repository_dispatch`
event (`kommons_changed`), carrying the new commit. Setup, once:

1. **Kommons side** — tell it who to alert and let it:

   - Repository **variable** `KOMMONS_NOTIFY_REPOS` (Settings → Secrets
     and variables → Actions → Variables), space-separated:
     `kjhrono/kalcio kjhrono/herald`
   - Repository **secret** `KOMMONS_NOTIFY_TOKEN`: a fine-grained PAT
     with **repository_dispatch: write** on those repos.

   Either one missing (or a push to a non-master ref) makes the alert
   step skip silently — CI stays green.

2. **Game side** — each game opts in with this listener
   (`.github/workflows/kommons-alert.yml`) — checkout order matters:
   `kommons/` must land beside the game *before* the gate step runs:

   ```yaml
   name: kommons-changed
   on:
     repository_dispatch:
       types: [kommons_changed]
   jobs:
     check:
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v4
           with:
             ref: master
         - name: Checkout kommons (the changed dependency)
           uses: actions/checkout@v4
           with:
             repository: kjhrono/kommons
             ref: ${{ github.event.client_payload.sha }}
             path: kommons
         - uses: subosito/flutter-action@v2
           with:
             channel: stable
         - name: Re-verify against the new kommons
           run: bash kommons/tool/verify_consumers.sh --quick
   ```

   With the layout contract (game beside `kommons/`), the gate script
   resolves the game's consumers exactly as in kommons' own CI — the
   alert reruns the game's analyze (add `t` gates for tests) against
   the exact commit that triggered the ping.

## Development

```bash
bash tool/verify_consumers.sh          # ONE command: analyze + test for
                                       # the package and examples/probe
bash tool/verify_consumers.sh --list   # who is registered in the gate
bash tool/verify_consumers.sh --tag v0.2.0 [--quick]
                                       # gate a release tag instead of the
                                       # working tree — "does that tag adopt
                                       # cleanly?" — via a git-archive
                                       # snapshot + dependency_overrides
```

`--quick` runs analyze only. The same script is the CI gate
(`.github/workflows/consumers.yml` calls it on every push/PR), so local and
remote verification can never drift apart. Consumer failures are collected,
not short-circuited — one broken game never hides another's result.

When you change the package, the consumers' gates are the proof the seams
hold — the probe's suite exercises them on every run.

### Bringing a game into the consumer gate

A game joins CI verification with two edits in *this* repo — the game
itself needs no workflow of its own, because kommons runs the gates:

1. **Check it out beside kommons in CI** — add a step to
   `.github/workflows/consumers.yml`, next to the commons checkout:

   ```yaml
   - name: Checkout <game> (consumer)
     uses: actions/checkout@v4
     with:
       repository: <org>/<game>
       ref: master
       path: <game>
   ```

2. **Append it to `CONSUMERS`** in `tool/verify_consumers.sh`:

   ```bash
   CONSUMERS=(
     "commons|${COMMONS_DIR}|at"
     "probe|${COMMONS_DIR}/examples/probe|at"
     "<game>|${COMMONS_DIR}/../<game>|at"
   )
   ```

   Each entry is `name|directory|gates`; gates is `a` (analyze), `t`
   (test) or `at` (both). `bash tool/verify_consumers.sh --list` prints
   the registered consumers with their gates — the same list every run
   executes.

The layout contract behind both edits: the game lives in a `<game>/`
folder *beside* `kommons/` — in CI (the checkout paths above) and
locally (your projects folder) alike — and its pubspec consumes the
package with a `path:` dependency (`../kommons`; flip to `git:` when a
published ref exists). One layout serves development and the gate
identically, so `bash tool/verify_consumers.sh` locally is exactly what
CI runs. The gate runs the game's whole `flutter test` suite (analyze
runs even under `--quick`), tolerates a locally missing game directory
only by failing it, and exits non-zero on any failure — a shell change
that breaks a joined game can never land.
