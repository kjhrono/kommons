# kommons

The shared shell for every kjhrono game. One Flutter package holds the
splash, the account/auth + settings, the new-game lobby wizard, and the
multiplayer transport — each game consumes it as a dependency and supplies
its identity through the seams the widgets expose. **Start here:
[COMMONS.md](COMMONS.md)** — the full module reference and the ~30-line
new-game adoption recipe.

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
  on Android/iOS), persisted day/night theme (`appTheme`),
  persisted language (`appLocale`, strings in `ShellStrings`), account
  state (`account`).
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

Server operators: enabling Google/GitHub and allow-listing redirect
origins on the game server is documented in
[docs/OAUTH_SERVER_SETUP.md](docs/OAUTH_SERVER_SETUP.md).

## Development

```bash
bash tool/verify_consumers.sh   # analyze + test: package, probe
```

Same script in CI (`.github/workflows/consumers.yml`) — push and local
verify identically.

Changes here must keep the consumers green too — the probe's suite
exercises these seams. The package's `COMMONS.md` documents the
convention that widget keys are API: renaming a key in this repo is a
breaking change for every game.
