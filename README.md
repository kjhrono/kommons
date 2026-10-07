# kommons

![Language](https://img.shields.io/badge/language-Dart%20%2F%20Flutter-0175C2?logo=dart&logoColor=white)
![Platforms](https://img.shields.io/badge/platforms-Android%20%7C%20iOS%20%7C%20Web%20%7C%20Linux%20%7C%20macOS%20%7C%20Windows-4CAF50)
![Coding agent](https://img.shields.io/badge/coding%20agent-Freebuff-7C4DFF)
![AI model](https://img.shields.io/badge/AI%20model-GLM%205.3%20Flash-1C3C3C)

The shared shell for every kjhrono game. One Flutter package holds the
splash, the account/auth + settings, the new-game lobby wizard, and the
multiplayer transport — each game consumes it as a dependency and supplies
its identity through the seams the widgets expose. **Start here:
[COMMONS.md](COMMONS.md)** — the full module reference and the ~30-line
new-game adoption recipe.

## Quick start

A game depends on the package by path (flip to `git:` when a published ref
exists) and wraps its home in the shell:

```yaml
dependencies:
  kommons:
    path: ../kommons
```

```dart
import 'package:kommons/kommons.dart';

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ShellApp(
      title: 'My Game',
      seedColor: const Color(0xff2e6f7a),
      home: AppSplash(
        appName: 'MY GAME',
        description: 'One line of flavor.',
        onNewGame: () => _openLobby(context),
      ),
    );
  }
}
```

That is the whole shell: persisted day/night theme and language on the
`MaterialApp`, the shared settings screen with email + OAuth sign-in, and
the localized string catalog — themed, translated and ready.

## Consumers

| Game | Notes |
| --- | --- |
| [`examples/probe`](examples/probe) | **HERALD** — the reuse probe, shipped with the package: a complete minimal game on the shared shell (~200 lines), with the herald who walks the road ahead of the banners as its face and `probe` as its package name. The starting template for a new game and a canary consumer in CI. |

## What's inside

- **Shell** — `ShellApp` (the root: MaterialApp wired with the persisted
  theme + locale and the shell preloads), `AppSplash` (art + entrance
  cascade; `SplashActions.direct*` for apps that enter without a lobby),
  `AppTopBar`, the shared `SettingsScreen` with email +
  reference OAuth sign-in (Google, GitHub — the game server's hosted
  authorize flow: popups on the web, deep links through the system browser
  on Android/iOS),  persisted day/night theme (`appTheme`),
  persisted language (`appLocale`, strings in `ShellStrings`), account
  state (`account` — with terminal ban handling: a suspended account
  loses its stored session on every path and the settings card shows the
  suspension banner; and native reset parking: a forgot-password request
  parks the address itself) and cross-project preference sync.
- **Multiplayer core** — `LobbySeat`, the `GameSyncService` transport
  (in-memory and PostgREST implementations), `CloudRoomService` +
  `CloudRoomCard` + `CloudHandoverSection` (saved-games listing, host
  handover, crown claim), `LobbyWizard` (multi-step) and `SharedLobbyStep`
  (one screen: seats by game number or solo, one handoff callback), banner
  colors, the game-server
  connection dialog. How the services relate to a game's session:
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- **Tooling** — `tool/deploy.sh` (config-driven commit → push → sync →
  migrate → build → publish, per-user via a git-ignored `deploy.config`,
  template in `deploy.config.example`) and `tool/verify_consumers.sh`
  (the one-command gate over package + probe, also the CI step).
- **The central identity stack's allow list** —
  `tool/identity-redirect-allowlist.txt`
  is the declarative source of truth for the central identity stack's GoTrue
  redirect allow list AND the site URL every unmatched redirect falls back to,
  and `tool/identity_allowlist_sync.sh` is the only thing that writes them
  (`--check` to verify, `--apply` to converge). Edit the declaration, never the
  stack's `.env`. `tool/install_identity_allowlist_check.sh` puts a
  SELF-HEALING `--heal --alert` entry on the VM's crontab: a later `.env`
  rewrite that drops a declared entry, or mis-sets the site URL, is converged on
  the spot (rewriting both keys in one pass and recreating ONLY auth — a few
  seconds of shared sign-in downtime) and the running process is then
  re-verified, so the drift cannot survive to break a sign-in. It alerts once
  per heal, and loudly only when a heal fails.
  **`tool/oauth_handoff_probe.sh`** then proves the entry is not just present
  but HONOURED: nightly (`tool/install_identity_oauth_probe.sh`) it starts a real
  `/authorize` flow per declared target and reads where GoTrue resolves it at
  `/callback` — an entry that is not honoured comes back silently rewritten to
  `GOTRUE_SITE_URL`, which the probe alerts on instead of a member discovering
  it months later as a broken sign-in. The same run asserts that rewrite
  DESTINATION: a `site_url=` directive in the declaration names the origin the
  stack must fall back to. The guard CONVERGES that half from the same
  declaration rather than leaving it to be maintained by hand, so it cannot
  drift from the list, and the probe compares it against both the fallback it
  observes in flight and the running container's own `GOTRUE_SITE_URL` — a site
  URL mis-set to somewhere that cannot finish a sign-in is invisible in exactly
  the way a dropped entry is, and it is where every dropped entry lands. The
  probe is the backstop, not the only defence. A directive the probe does not
  recognise fails it, so a typo cannot silently switch the assertion off.
  The same run asserts the two **mail links** the stack sends — the signup
  confirmation and the password recovery — because both are built as
  `<site URL> + one path`, so a wrong origin there breaks a registration or a
  password reset just as silently. Those two are not rendered by GoTrue at all:
  the `auth-email` send-email hook assembles them from the `site_url` GoTrue
  hands it, which is why the probe holds the declared paths to the running
  auth's `MAILER_URLPATHS_*`, to the hook's own rendering (a host hardcoded
  there fails it), and to a real GET of each link — which must be answered by
  GoTrue and must land on the declared origin. An action that is not armed at
  all fails too (`GOTRUE_MAILER_AUTOCONFIRM=true` means no confirmation mail is
  ever sent, `GOTRUE_EXTERNAL_EMAIL_ENABLED=false` no recovery): asserting a
  link nobody receives would be vacuous.
- **The JWT-secret watch** — `tool/jwt-secret-monitor.sh` is the single program
  behind the VM's secret cron watch. `monitor` (every 15 min) compares every
  project stack's `JWT_SECRET` against the canonical identity value — defined
  once in `tool/canonical_secret.sh`, the same definition the operator repair in
  katalogus reads — and force-re-cuts a stack that exact-reverted to a
  pre-cutover secret; `meta` (every 30 min) watches the watch (monitor liveness
  + Gotify alert-delivery staleness). The routine digest
  `tool/jwt-secret-daily-summary.sh` posts at 09:00 and its delivery is the
  pipeline heartbeat the `meta` entry reads. It reports incidents only for the
  stacks the watch still contains (asking `jwt-secret-monitor.sh --stacks`), and
  names what it ignored — so a retired project's lingering log lines cannot keep
  raising the alarm.
  **`tool/install_jwt_secret_watch.sh`** installs the WHOLE watch from a fresh
  checkout — the program, every helper it sources (`canonical_secret.sh`,
  `alert.sh`, `gotify-messages.sh`, the digest) and all three cron entries in
  one managed block — delegating the alert credentials to
  `tool/install_alert_env.sh`. `tool/test_jwt_secret_watch.sh` covers it
  hermetically.

Server operators: enabling Google/GitHub and allow-listing redirect
origins on the game server is documented in
[docs/OAUTH_SERVER_SETUP.md](docs/OAUTH_SERVER_SETUP.md). The **central
identity stack**'s list is not edited by hand — it is declared in
[`tool/identity-redirect-allowlist.txt`](tool/identity-redirect-allowlist.txt)
and converged by `tool/identity_allowlist_sync.sh`, so a rebuilt `.env` or a
fresh provision cannot silently drop an entry (the native `scheme://` one is
the one that breaks a sign-in invisibly). The same declaration carries the
`site_url`, which the guard converges and the nightly probe asserts against,
because a target that is not on the list is rewritten to it. The monitoring
stack's push-alert channel — what Gotify is, the send/read recipe, and how
to adopt it in another project — is documented in
[docs/GOTIFY.md](docs/GOTIFY.md). Alert **credentials** are never kept in the
crontab, whose `crontab -l` prints every line: they live in a mode-0600
`~/etc/alerts.env` that `tool/alert.sh` sources, installed and verified by
[`tool/install_alert_env.sh`](tool/install_alert_env.sh).

## Development

```bash
bash tool/verify_consumers.sh   # analyze + test: package, probe
```

Same script in CI (`.github/workflows/consumers.yml`) — push and local
verify identically, which is what the workflow badge above tracks.

Changes here must keep the consumers green too — the probe's suite
exercises these seams. The package's `COMMONS.md` documents the
convention that widget keys are API: renaming a key in this repo is a
breaking change for every game.

## Credits

Built by [kjhrono](https://github.com/kjhrono) with **GLM 5.3 Flash** as
co-worker — design, implementation, tests and docs are the pair's joint
work.
