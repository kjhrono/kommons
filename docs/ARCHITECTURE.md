# Multiplayer core architecture

How the commons' multiplayer services relate to each game's session. The
one rule that shapes everything: **the session stays the single source of
truth on every device**; the sync layer only carries serialized state
between them. There is no authoritative server-side game state.

## The picture

```
                      ┌──────────────────────────── each device ───────────────────────────┐
                      │                                                                    │
   UI (game screen)   │   ┌───────────────────────────┐        ┌────────────────────────┐  │
 ─────────────────────┼──▶│ GameSession (kapax or     │◀──────▶│ GameSyncService (Iface)│  │
   session.advance…() │   │ any game's session model) │ encode │  ┌──────────────────┐  │  │
                      │   │ · roster, clock, log      │ decode │  │ InMemorySync     │  │  │
                      │   │ · actions, economy        │ (JSON) │  │ (hot-seat)       │  │  │
                      │   └───────────────────────────┘        │  ├──────────────────┤  │  │
                      │            │ publish/apply             │  │ PostgrestSync    │──┼──┼──▶ PostgREST
                      │            ▼                           │  │ (online rooms)   │  │  │    (game server)
                      │   sync.publishSession(json)            │  └──────────────────┘  │  │    rooms · roster ·
                      │   sync.pushActions([...])              └────────────────────────┘  │    snapshots · clock ·
                      │   sync.poll() → SyncEvent[]                                        │    action outbox
                      └────────────────────────────────────────────────────────────────────┘
```

- **`GameSession`** (app-side) owns gameplay: it mutates state, encodes
  itself to JSON, and applies remote snapshots/actions it pulls. It knows
  nothing about HTTP.
- **`GameSyncService`** (interface, `game_sync.dart`) is the only seam the
  session talks through: session publish/fetch, `announcePlayer`,
  `setReady`/`roster`, `poll() → SyncEvent[]`, `publishClock`/`fetchClock`,
  `deleteRoom`, and the joiner outbox `pushActions`/`takeActions`.
- **`InMemorySyncService`** implements the contract in RAM for hot-seat
  (multiple seats, one device).
- **`PostgrestSyncService`** implements it over PostgREST: rooms carry the
  host's latest snapshot + clock; the roster carries seats; joiners write
  actions to an outbox the host drains on its poll tick.

## The services around the transport

```
   saved-games screen · lobby (UI, app-side)
        │                    │
        ▼                    ▼
   ┌───────────────────────────────┐        ┌──────────────────────────────┐
   │ CloudRoomService (read model) │        │ claim protocol (cloud_room_  │
   │ · listRooms(playerName)       │        │ card.dart):                  │
   │ · hostSecretFor / seatNameFor │─────▶  │ claimHostPowers(service,     │
   │ · designateHost / cancel…     │  uses  │   room, seat) → (status,     │
   │ · hostResumeService(room)     │ claim  │   sync, snapshot)            │
   │ · forTestFactory              │        └──────────────────────────────┘
   └───────────────┬───────────────┘
                    │ reads rooms+roster tables (anon, like joining)
                    ▼
              PostgREST game server ◀── written by PostgrestSyncService
```

- **`CloudRoomService`** is the *read/listing* model over the same tables
  the sync service writes: which rooms exist, who sits where, which host
  secret this device stores (per-room in SharedPreferences — the secret
  never travels). `hostResumeService()` mints a `GameSyncService` with host
  rights from that stored secret; joiners get `joinerResumeService()`.
- **Handover** — a departing host `designateHost(seat)`; the promoted seat
  calls **`claimHostPowers`**, the one place the crown rotates: claim RPC →
  fresh secret stored locally → re-announce with host rights. Returns the
  live sync service *and* the world snapshot, so the caller decodes and
  enters the game in one round-trip. Both saved-games cards and the lobby's
  handover list run this same protocol (`claimHostAndEnter` in kapax adds
  only session decode + navigation).
- **`CloudRoomCard`** renders a room row (chips, flash, menu, Claim host);
  every behavior is an `on*` callback the host app wires.

## Supporting pieces

| Piece | Role |
| --- | --- |
| `LobbySeat` | The wire format for a seat: name, `colorHex`, pacing, ready, AI flag. JSON roundtrip with defaults so old saves load. |
| `SyncEvent` | Poll result item — `SyncEventType { sessionUpdate, playerJoined, playerReady }` plus `playerName` and a payload map. |
| `GameServerConnection` + dialog | The stored game-server URL/key everything above needs; `CloudRoomService.fromStoredConnection()` reads it. |
| Server-side auth & OAuth | The game server's GoTrue/Supabase auth service: email + provider sign-in ride the same `/auth/v1/*` surface the client stores as its server URL. Provider enabling and redirect allow-listing are the operator's checklist in [OAUTH_SERVER_SETUP.md](OAUTH_SERVER_SETUP.md); the multiplayer schema in each game's `server/schema.sql` is untouched by sign-in. |
| `bannerColor` codecs | The single hex↔Color path for every banner tint. |

## Invariants worth preserving

1. **No server authority** — the host's snapshot *is* the world; the server
   only stores blobs. Schema changes in `server/schema.sql` must stay
   compatible with in-flight rooms (or force a migration, which the deploy
   tool already gates by hash).
2. **The host secret never leaves the device that created it** — claims
   rotate it server-side and the claimer stores the fresh value locally.
3. **Joiner actions travel through the outbox** (`pushActions`/`takeActions`),
   never by direct table writes; the host applies them on its tick.
4. **All transport goes through `GameSyncService`** — nothing app-side may
   import `package:http` to touch game tables directly, or hot-seat and
   online modes drift apart.

## Where the tests live

Package: `test/lobby_wizard_test.dart` (seat roundtrip), `test/cloud_room_card_test.dart`
(card + dialogs + credential detection). App-side: kapax's
`test/postgrest_sync_service_test.dart` (transport), `test/cloud_room_service_test.dart`
(rooms, handover, claims, saved-games journeys), `test/lobby_handover_test.dart`,
`test/multiplayer_roster_test.dart`. Run them all with
`bash tool/verify_consumers.sh`.
