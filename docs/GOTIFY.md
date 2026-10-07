# Gotify: push alerts from a script to a phone

[Gotify](https://gotify.net) is a small **self-hosted push-notification
server**. You POST a message to it from anywhere (a cron job, a monitor, a
build) and every device subscribed to that Gotify server gets a push — the
same shape as an incoming webhook or a Pushover/ntfy, except the server is
yours, the history is a file you own, and there is no vendor account.

This page is the mental model plus the copy-paste recipe. It is written so it
can be lifted whole into another project: the first two sections are
Gotify-general, the later ones describe how kommons uses it (and what is
worth copying vs. leaving behind).

## The mental model

Gotify has exactly two moving parts: **applications** (things that *send*)
and **clients** (devices that *receive*). A send is one HTTP POST with an
application's token in the query string; Gotify stores the message and pushes
it to every client. Nothing else is required.

```
   your script / cron / monitor
            │  POST /message?token=<APP_TOKEN>
            │  title=…  message=…  priority=…
            ▼
   ┌──────────────────────────┐        push
   │  Gotify server (yours)   │ ─────────────────▶  phone / web UI
   │  stores every message    │                   (all subscribed clients)
   │  in gotify.db (SQLite)   │
   └──────────────────────────┘
```

Three consequences worth internalising:

- **The sender is dumb on purpose.** No SDK, no session, no retry protocol —
  one `curl` (or `httpx`, or `fetch`). If the POST succeeds, the message is
  in Gotify's database, whether or not a phone was awake to show it.
- **Delivery is store-and-forward, not acknowledged.** Gotify records that a
  message *arrived*; it does **not** record that a device *displayed* it.
  A row in the history means "reached Gotify", full stop. Design monitoring
  around that (see *Reading the history*).
- **The token is the whole auth.** An application token can only *send*; it
  cannot read other messages, create apps, or administer the server. So the
  token is a secret worth protecting, but a leak is not a server compromise.

### Applications vs. clients

| Thing | Created where | Token used for | Used by |
| --- | --- | --- | --- |
| **Application** | web UI → Apps → Create Application | `?token=<app-token>` on `POST /message` | your scripts — one app per source, so the web UI shows *what* alerted |
| **Client** | web UI → Clients → Create Client | logging the mobile/web app into the server | humans/devices — one client per device |

You only need an **application token** to send. You need a **client token**
only to receive pushes on a phone; it never appears in sender code.

## Sending a message

The send endpoint is `POST <server>/message`, token in the query string,
fields as `multipart/form-data`:

```bash
GOTIFY_URL="https://notify.example.com"     # base URL, no trailing slash
GOTIFY_APP_TOKEN="Axxxxxxxxxxxxx"           # application token

curl -s -o /dev/null --max-time 10 \
  -X POST "${GOTIFY_URL}/message?token=${GOTIFY_APP_TOKEN}" \
  -F "title=Backup finished" \
  -F "message=3 snapshots pruned, 1.2 GiB freed" \
  -F "priority=5"
```

- **`title`** — the bold line on the notification (keep it short; a phone
  truncates it).
- **`message`** — the body; Markdown is rendered in the web UI.
- **`priority`** — integer `0`–`10` (see below). Omitted → the application's
  default priority.

That is the entire sender API. kommons wraps it in a helper, `alert.sh`'s
`send_gotify_alert <title> <message> [priority]`, whose one important
property is the **no-op contract**: it sends nothing (and fails nothing)
when `GOTIFY_URL` or `GOTIFY_APP_TOKEN` is empty. That is what lets the same
monitor run on a laptop with no Gotify configured and on the VM with it
configured, with no branching.

### Priorities

Gotify maps priority to notification behaviour, not to a queue:

| Priority | Meaning in the client |
| --- | --- |
| `0` | no notification shown (still stored in history) |
| `1`–`3` | low — quiet/minimised |
| `4`–`7` | normal — the default, `5` is a good "routine report" level |
| `8`–`10` | high — sound/vibration, surfaces above other notifications |

Convention in kommons: `GOTIFY_PRIORITY` (default `5`) for routine reports,
explicitly `8` for alerts that mean *something is broken right now* (drift
detected, a revert, the delivery watchdog itself firing).

### Title convention: `<thing> — <host>`

Every alert from kommons is titled `"<monitor> — <host>"`, e.g.
`JWT secret drift detected — default-vnic`, using an **em dash**. The host
half is what tells two identical monitors on two machines apart in the same
notification list. If you copy the pattern, copy the em dash too — it is a
separator humans scan by, and greps should not need to guess.

## Configuration (environment variables)

| Variable | Meaning | Default |
| --- | --- | --- |
| `GOTIFY_URL` | server base URL, e.g. `https://notify.example.com` | *(unset → sending is a no-op)* |
| `GOTIFY_APP_TOKEN` | application token (send-only secret) | *(unset → sending is a no-op)* |
| `GOTIFY_PRIORITY` | default priority for sends that do not pass one | `5` |
| `GOTIFY_DB` | path to the history database, for the *reader* tools | `$HOME/gotify/data/gotify.db` |

Keep `GOTIFY_APP_TOKEN` out of the repo AND out of the crontab: `crontab -l`
prints every line, so a crontab is a poor home for a secret. Put it in a
mode-0600 env file that the senders source — on the monitoring VM that is
`~/etc/alerts.env`, sourced by `tool/alert.sh` (installed/verified by
`tool/install_alert_env.sh`). The token is per-application, so a project
usually has one for "reports" and one for "alerts".

Rotating a leaked token means creating a new application and deleting the old
one — the API cannot re-issue a token in place. Gotify deletes an application's
messages along with it (in code, not via a foreign key), so re-point the
history first if it matters.

## Reading the history (why not the HTTP API)

The HTTP API you should *send* through is `/message`. What you can *read*
back is a separate question, and the honest answer is: **probe your own
server before relying on it.** On the deployment this doc grew out of
(`gotify/server:2`, server **v2.9.1**, reached through its nginx vhost):

| Request | Result |
| --- | --- |
| `GET /health` | `200 {"health":"green","database":"green"}` |
| `GET /version` | `200 {"version":"2.9.1", …}` |
| `GET /` | `200` — the web UI |
| `POST /message?token=…` | the send path; works with an application token |
| `GET /api/messages`, `/api/applications`, `/api/apps` | **`404`** |

So on that server the only machine-usable surfaces are *send* and *health*;
the admin REST API does not answer, and there is no read endpoint at all.
Rather than fight it, kommons reads the **SQLite database directly** — which
also happens to be the only place that records history, since the HTTP layer
would not have shown per-device delivery anyway.

### The database

Gotify stores everything in one SQLite file (default `data/gotify.db` inside
the container; on kommons' VM, `~/gotify/data/gotify.db`). The tables that
matter:

```sql
messages(id, application_id, message, title, priority, extras, date)
applications(id, token, name, default_priority, …)
```

`date` is an ISO-like UTC string (`YYYY-MM-DD HH:MM:SS+00:00`), so age math
is a plain comparison. To read it with nothing installed but Python, open it
**read-only** — `sqlite3.connect("file:…?mode=ro", uri=True)` — and fall back
to snapshotting the file plus its `-wal`/`-shm` sidecars if read-only open
fails. `python3 -c "import sqlite3"` is all you need; the `sqlite3` CLI is
often absent on servers.

kommons' reader is `tool/gotify-messages.sh`: `--limit`/`-n` (`0` = all),
`--priority`, `--min-priority`, `--app`, `--title`, `--since`,
`--since-hours`, `--message`, `--json`, `--counts`, `--count`,
`--age-seconds` and `--report` (which also compares each monitor's count
against the preceding window of equal length, so you can see a trend, not
just a total). It needs no Docker, no root and no admin login — only read
permission on the file.

**Remember:** a row means the alert reached Gotify. It is *not* proof a
phone received it. If you need "did the pipeline stay alive", watch that
rows are still *arriving* on time — do not wait for an acknowledgement that
will never come.

## Turning the history into a heartbeat (dead-man's switch)

Because drift/revert-style monitors are silent while healthy, the only
positive signal that the pipeline works is that *something* arrives on
schedule. The pattern:

1. Have one **routine report** (kommons: the daily summary) send
   unconditionally every day. Its title is the heartbeat.
2. Have a watchdog read the newest matching history row's age and alert when
   it exceeds a threshold.

```
routine report ──daily──▶ Gotify ──▶ can your phone still hear Gotify?
                                 │
        watchdog reads gotify.db │ newest "Daily Summary" title
                                 ▼
        age > MAX_AGE_HOURS  →  ALERT (fan out to every channel)
```

Two details that bite:

- **Match the heartbeat by title substring, exactly.** kommons' watchdog
  looks for `EXPECT_TITLE` (default `JWT Daily Summary`) in the newest
  message title. If you change a report's title, you have silently broken the
  watchdog — keep the heartbeat phrase stable, and put extra context after
  it, not before.
- **The watchdog's alert must not travel only through Gotify.** The thing
  that broke may be Gotify (or the network path to it). Fan the alert out to
  a second transport — email, a webhook, SMS — so a silent Gotify still
  produces a visible alarm everywhere else. This is the one place
  *redundancy* beats *pick-one-channel*.

## The external leg: a channel that isn't on the host

The heartbeat only helps if its alert can get out when the host is the thing
that broke. Every channel above — Gotify, local `mail` — runs on or beside
the monitored machine, so they fail together. Keep at least one **off-host**
channel for the critical alerts. kommons' is a Telegram bot
(`send_telegram_alert` in `tool/alert.sh`):

| Variable | Meaning |
| --- | --- |
| `TELEGRAM_BOT_TOKEN` | bot token from @BotFather |
| `TELEGRAM_CHAT_ID` | the chat to post to — a user id, a group id, or `@channel` |

```bash
curl -s -o /dev/null --max-time 10 \
  -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -H 'Content-Type: application/json' \
  -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"Backup finished\"}"
```

Two rules this pattern keeps:

- **Off-host is for alerts, not reports.** Critical alerts fan a copy out to
  *every* configured channel — including this one — because the broken
  channel may be the one reporting. Routine reports still pick exactly one
  channel, so the external leg never becomes a second copy of a digest.
- **A bot cannot start a conversation.** Whoever owns the chat must message
  the bot (or add it to the group) first, or every send fails. Send plain
  text (no `parse_mode`): alert bodies are full of Markdown metacharacters
  that would otherwise turn into a 400.

Telegram is one implementation, not the only one — ntfy, Slack or plain SMS
play the same role. What matters is that the leg the watchdog uses does not
share the host it is watching.

## Retention

Nothing in Gotify deletes old messages, so `messages` grows forever. Bound it
with a periodic sweep. kommons' `tool/gotify-retention-sweep.sh` deletes
messages older than `RETENTION_DAYS` (default `30`) while always keeping the
newest `KEEP_NEWEST` rows (default `100`) as a floor, so a short history is
never emptied just for being old.

Two rules that apply to any project:

- **Keep the retention window comfortably longer than the heartbeat
  threshold.** If the sweep could delete the newest heartbeat before the
  watchdog looks for it, the watchdog reports a healthy pipeline as stalled.
  (kommons: `RETENTION_DAYS=30` ≫ `MAX_AGE_HOURS=26`.)
- **The database is owned by the Gotify container (root), so a host user
  cannot write it.** kommons performs the delete inside a one-shot container
  that mounts the data directory and runs as root for that command only —
  no change to file ownership, no `sudo` on the host, and Gotify keeps
  running. SQLite's cross-process locking makes the concurrent access safe.

## Exposing it: the reverse proxy

Gotify listens on `127.0.0.1:8050` on the VM (container port 80), so a
reverse proxy is what makes it reachable by remote senders and by phone
clients. kommons' vhost (`tool/notify-mediasart.conf`) is a small, complete
example:

- `:80` serves the ACME challenge and `301`s everything else to HTTPS.
- `:443` terminates TLS from **the shared `mediasart.com` certbot lineage**,
  expanded to include `notify.mediasart.com` as a SAN.
- `location /` is a plain `proxy_pass http://127.0.0.1:8050;` plus the shared
  proxy snippet (websocket headers, timeouts).

The install is scripted in `tool/setup-notify-vhost.sh`, which runs **on the
VM as an ordinary user in the `docker` group** and does every root-level file
operation through short-lived containers with volume mounts — install the
vhost, symlink + `sed` the server_name, `kill -HUP` nginx, then run
`certbot/certbot` in `--webroot` mode with `--expand` to add the new SAN. The
takeaway for another project is the *shape*: no `sudo` on the host, no
editing files as root, one idempotent script (or a few lines in a provisioning
tool) that you can rerun for a new subdomain.

## Adopting it in another project — checklist

- [ ] **Run the server.** e.g. `docker run -d --name gotify
      --restart unless-stopped -p 127.0.0.1:8050:80 -v
      /srv/gotify/data:/app/data gotify/server:2`. Change the first-run
      default admin password immediately.
- [ ] **Expose it** behind TLS (reverse proxy or a tunnel). Senders use the
      public URL; the container port stays bound to loopback.
- [ ] **Create an application** in the web UI (Apps → Create Application) and
      copy its token. Make one per source if you want the history to be
      readable by origin.
- [ ] **Create a client** and log a phone into it (Clients → Create Client;
      in the mobile app, enter the server URL + client token). This is the
      only step that is about receiving.
- [ ] **Put `GOTIFY_URL` and `GOTIFY_APP_TOKEN` in a mode-0600 env file** that
      the senders source — never in the repo, and not in the crontab, whose
      `crontab -l` prints every line. Add `GOTIFY_PRIORITY` if the default `5`
      is not what you want.
- [ ] **Send a test:** the `curl -X POST … /message?token=…` above. Confirm
      it appears in the web UI *and* on the phone.
- [ ] **Adopt a title convention** (`<thing> — <host>`) and a priority
      policy (routine = `5`, broken = `8`).
- [ ] **Make sending optional.** Wrap the POST so an unset URL/token is a
      silent no-op; the same script then runs everywhere.
- [ ] **Add a heartbeat + watchdog** if silence would be indistinguishable
      from health: one unconditional routine report, one watchdog aged on the
      newest matching title, and a second transport for the watchdog's own
      alert.
- [ ] **Sweep the history** so `gotify.db` does not grow without bound, and
      keep the retention window longer than the watchdog threshold.
- [ ] **Probe `/health` (and the read surface you plan to use)** before
      depending on it — the same features vary by server and version.

## Worked example in this repo

| Piece | File |
| --- | --- |
| The send helper (and its no-op contract) | `tool/alert.sh` — `send_gotify_alert` |
| The heartbeating routine report | `tool/jwt-secret-daily-summary.sh` |
| The dead-man's switch reading history | `tool/jwt-secret-delivery-watchdog.sh` |
| The Docker-free history reader | `tool/gotify-messages.sh` |
| The retention sweep | `tool/gotify-retention-sweep.sh` |
| The nginx vhost + no-sudo install | `tool/notify-mediasart.conf`, `tool/setup-notify-vhost.sh` |

Every script there reads its configuration from the environment, so the same
code runs against any Gotify server — which is the whole point of a
self-hosted push service.
