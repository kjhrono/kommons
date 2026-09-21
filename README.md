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
| [kapaxinfiniti](https://github.com/kjhrono/kapaxinfiniti) | The flagship — settlement building, taming, spell cards, challenges. |
| [`examples/kj_probe`](examples/kj_probe) | The reuse probe, shipped with the package: a complete minimal game on the shared shell (~200 lines) — the starting template for a new game and a canary consumer in CI. |

## What's inside

- **Shell** — `AppSplash` (art + entrance cascade), `AppTopBar`, the
  shared `SettingsScreen` with email + OAuth-seam sign-in, persisted
  day/night theme (`appTheme`), account state (`account`).
- **Multiplayer core** — `LobbySeat`, the `GameSyncService` transport
  (in-memory and PostgREST implementations), `CloudRoomService` +
  `CloudRoomCard` + `CloudHandoverSection` (saved-games listing, host
  handover, crown claim), `LobbyWizard`, banner colors, the game-server
  connection dialog. How the services relate to a game's session:
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- **Tooling** — `tool/deploy.sh` (config-driven commit → push → sync →
  migrate → build → publish, per-user via a git-ignored `deploy.config`,
  template in `deploy.config.example`) and `tool/verify_consumers.sh`
  (the one-command gate over package + probe + kapax, also the CI step).

## Development

```bash
bash tool/verify_consumers.sh   # analyze + test: package, probe, kapax
```

Same script in CI (`.github/workflows/consumers.yml`) — push and local
verify identically.

Changes here must keep the consumers green too — kapax runs 781 tests
against these seams, the probe 3. The package's `COMMONS.md` documents the
convention that widget keys are API: renaming a key in this repo is a
breaking change for every game.
