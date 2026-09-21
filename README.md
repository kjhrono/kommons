# kjhrono_commons

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
| `../kj_probe` | Minimal reuse probe: boots the shared splash/settings/lobby in ~200 lines total. |

## What's inside

- **Shell** — `AppSplash` (art + entrance cascade), `AppTopBar`, the
  shared `SettingsScreen` with email + OAuth-seam sign-in, persisted
  day/night theme (`appTheme`), account state (`account`).
- **Multiplayer core** — `LobbySeat`, the `GameSyncService` transport
  (in-memory and PostgREST implementations), `CloudRoomService` +
  `CloudRoomCard` (saved-games listing, host handover, crown claim),
  `LobbyWizard`, banner colors, the game-server connection dialog.
- **Tooling** — `tool/deploy.sh`: config-driven commit → push → sync →
  migrate → build → publish, per-user via a git-ignored `deploy.config`
  (`deploy.config.example` is the template).

## Development

```bash
flutter analyze && flutter test   # 4 suites, 27 tests
```

Changes here must keep the consumers green too — kapax runs 777 tests
against these seams, kj_probe 3. The package's `COMMONS.md` documents the
convention that widget keys are API: renaming a key in this repo is a
breaking change for every game.
