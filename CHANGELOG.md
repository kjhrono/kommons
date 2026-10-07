# Changelog

All notable changes to the kommons shell are documented here. The format
loosely follows [Keep a Changelog](https://keepachangelog.com/) and the
versioning intent is [semver](https://semver.org/) — while the package is
pre-1.0, minor versions carry the features.

## Unreleased

## 0.9.0 — 2026-10-07

### The nightly probe asserts the mail links too, not only the OAuth hand-off

The probe proved every declared redirect target was honoured, and that the site
URL they fall back to is the declared one — but the two mails that hand a member
a link were never followed.  A signup confirmation and a password recovery are
built as `<GOTRUE_SITE_URL> + one path`, so a wrong origin or path there breaks a
registration or a password reset at the last step, in exactly the shape this
probe exists for.

That half needs its own assertion because the link is not built where the rest of
the configuration is: GoTrue delegates every mail to the `auth-email` send-email
hook, which renders the link from the `site_url` GoTrue hands it plus a path
compiled into its own source.  A wrong origin or path can therefore hide in
CODE, where no configuration check would ever see it.

- **`tool/identity-redirect-allowlist.txt`** gains two directives,
  `mail_confirmation_path` and `mail_recovery_path`.  The ORIGIN is deliberately
  not declared a second time: it IS `site_url`, and naming it again would create
  a second place to edit for one fact.  Only the per-action path is named, and
  each is asserted — by the probe, not converged by the guard, because writing
  the stack's own mail settings would not change what a member receives.
- **`tool/oauth_handoff_probe.sh`** holds each action's declared path to four
  independent readings: the running auth's own `GOTRUE_MAILER_URLPATHS_<ACTION>`,
  a real GET of `<site URL><path>` (which must be answered by GoTrue, not by the
  web app, and must land on the declared origin), the hook's rendering as
  deployed on disk (the path it appends, and that its base comes from `site_url`
  rather than a hardcoded host), and the fact that the action is armed at all —
  `GOTRUE_MAILER_AUTOCONFIRM=true` means no confirmation mail is ever sent and
  `GOTRUE_EXTERNAL_EMAIL_ENABLED=false` no recovery, so an assertion about those
  links would be vacuous there.  A rate-limited or unobservable link fails rather
  than passing, and a mail directive with no `site_url` to root it at is refused
  outright.  The mail half costs two plain GETs and no `auth.flow_state` row.
- **`tool/test_oauth_handoff_probe.sh`** grew from 64 to 113 checks: the healthy
  mail half per action, each drift class (a disagreeing urlpath, a landing on
  another origin, a path the origin does not serve to GoTrue, auto-confirm, a
  disabled provider, a renderer rendering another path, a renderer with an
  origin of its own, an unreadable renderer, a hook with no URI, an unreadable
  auth, a rate-limited link), the footprint (no extra `/authorize` flow), and the
  back-compat case — a declaration with no mail directives leaves the half
  entirely out of the way.  Eight mutations of the new behaviour, all caught.
- **`tool/install_identity_oauth_probe.sh`** states the mail half and its cost in
  its header and in the crontab block it manages on the VM.

### The allow-list guard heals a dropped entry instead of only reporting it

The scheduled guard ran `--check --alert`: it made a dropped identity redirect
entry visible, but the entry stayed missing until a human converged it — and the
finding is precisely that a real sign-in is broken until then, so the damage sat
there between runs. The scheduled entry now converges and then re-verifies.

- **`tool/identity_allowlist_sync.sh`** gains **`--heal`**: when a declared entry
  is missing (from the `.env`, or from the running auth), it converges the stack
  exactly as `--apply` does, then **re-verifies the running auth from scratch** —
  a second, independent reading of both the `.env` and the live process, taken
  after the recreate has settled, because "the write succeeded" is not the same
  claim as "the running auth now honours it". It never returns 1: drift it can
  fix is fixed (0); drift it cannot fix is a failure (2), with the previous
  `.env` restored. `--apply`/`--check`/`--heal` are mutually exclusive.
- **Alerting follows the outcome, not the finding.** A heal that worked sends
  one informational notice per distinct drop — suppressed while the same drop
  recurs, and cleared as soon as the stack is back in sync so a later recurrence
  still notifies. The loud, transition-guarded drift alarm is reserved for a heal
  that FAILED, and it keeps its recovery notice. Heal state lives in its own
  file (`IDENTITY_ALLOWLIST_HEAL_STATE`), so a self-heal never makes the next
  clean run announce a recovery for an outage nobody was told about.
- **`tool/install_identity_allowlist_check.sh`** now schedules
  `--local --heal --alert`, and its `--check` asserts the scheduled entry
  actually self-heals — a detect-only entry left by an older installer no longer
  passes as installed. The managed block's comment is rewritten to describe the
  self-heal and its cost.
- **Cost, stated plainly:** a heal recreates ONLY the auth container, which is
  shared, so it interrupts sign-in for every project for a few seconds (existing
  JWT sessions stay valid). It never fires on a stack that is in sync, and it
  never removes an undeclared entry (the scheduled entry does not pass
  `--prune`).
- **`tool/test_identity_allowlist_sync.sh`** grew from 85 to 124 checks: the
  converge + re-verify round trip, `--heal` never exiting 1, an in-sync heal
  writing and recreating nothing, one notice per heal with repeat suppression
  that clears after a clean run, a failed heal restoring the `.env` and raising
  the loud alarm, the recovery notice, mode exclusivity, remote forwarding, and
  the installer scheduling `--heal`. All three behaviours mutation-tested.

### The nightly probe asserts the site URL, not only the entries

An entry that is not honoured is silently rewritten to `GOTRUE_SITE_URL` — so
that origin is where EVERY dropped entry lands, and GoTrue allows it implicitly
without ever validating it. A site URL pointing somewhere that cannot finish a
sign-in therefore fails in exactly the shape this probe was built for, and until
now nothing looked at it: the probe proved the declared targets were honoured
while the destination of their failure went unexamined.

- **`tool/identity-redirect-allowlist.txt`** now carries the site URL as a
  DIRECTIVE — `site_url=https://katalogus.mediasart.com` — not as an entry. It
  is converged from there (see the next section), so it is changed here and
  nowhere else, and only to an origin that can complete or relay a sign-in.
- **`tool/oauth_handoff_probe.sh`** compares it against two independent readings
  of the RUNNING auth: the fallback it observes in flight (where an unlisted
  target actually landed — a second target, kept distinct from the control, so
  one cannot mask the other) and the container's own `GOTRUE_SITE_URL` read with
  `printenv` when docker is reachable. Each disagreement fails the probe with
  its own text, so a process running a value the stack no longer holds is
  distinguishable from a mis-set one. When the directive is present but neither
  reading can be taken the probe FAILS, rather than reporting the site URL as
  checked: an assertion that could not be made is not a pass. `site_url` is the
  only directive recognised — any other `key=value` line fails too, so a typo
  cannot silently switch the assertion off.
- **`tool/identity_allowlist_sync.sh`** reads directives as configuration and
  never as entries, so the value cannot be written into
  `ADDITIONAL_REDIRECT_URLS` — see the next section for how it IS converged.
  **`tool/test_identity_allowlist_sync.sh`** grew from 124 to 130 checks for it:
  the directive is present in the declaration, is never counted as an entry, and
  never reaches the key the stack reads.
- **`tool/test_oauth_handoff_probe.sh`** grew from 35 to 64 checks (a site URL
  that passes, a mis-set fallback, a stale container reading, an unobservable
  site URL, an unrecognised directive, and the cost of the extra `/authorize`).
  All four behaviours mutation-tested.

### The allow-list guard converges the site URL too

Naming the site URL in the declaration made it ASSERTED; leaving it maintained
by hand made it a second, silent authority for the same contract.  `SITE_URL` in
the stack `.env` — which `docker-compose.yml` hands to GoTrue as
`GOTRUE_SITE_URL` — is now converged from the same declaration, for the same
reason the allow list is: nothing warns when it disagrees, it is where every
dropped entry lands, GoTrue allows that origin implicitly for ANY path, and it
roots every confirmation and recovery link the stack mails.

- **`tool/identity_allowlist_sync.sh`** reads the `site_url` directive and
  compares it against BOTH sides — `SITE_URL` in the `.env` and the running
  container's `GOTRUE_SITE_URL` — so an edit that has not been recreated yet and
  a process running a value the stack no longer holds are reported separately.
  `--apply`/`--heal` rewrite both keys in ONE pass (one backup, one recreate,
  one verification), so a failure halfway cannot leave a converged allow list
  beside a stale site URL, and the running value is verified after the recreate
  exactly as the list is.
- **Refusals, because a site URL is not just another entry.** One that is not
  `<scheme>://<host>`, or that carries `,`/`#`, is a DECLARATION error (exit 3)
  and nothing is written: converging a broken value would rewrite the root of
  every mail link.  A duplicated `SITE_URL=` key is refused the same way a
  duplicated allow-list key is.  A declaration with no `site_url` directive
  behaves exactly as before — the site half stays entirely out of the way.
- **One verdict, one alert.** The `--check` verdict line, the ops log, and the
  drift / self-heal / recovery alerts all name the site URL, so an operator
  never has to read a second place to learn the stack is mis-set.
- **`tool/test_identity_allowlist_sync.sh`** grew from 130 to 168 checks: the
  `.env`-only case, the running-auth-only case, the pair converged by `--apply`
  and re-verified, the scheduled `--heal` healing a site-URL drift (and failing
  loudly with the previous `.env` restored when the result cannot be verified),
  the malformed and duplicated refusals, and the no-directive back-compat.  Six
  mutations of the new behaviour, all caught.

### The digest stops reporting retired stacks

The 09:00 digest escalated to `secret incidents` every day over a stack that no
longer exists. When a project is retired its `.env` is removed and its entry
dropped from the monitor, but the WARN lines it produced while it was still
being watched stay in the shared log until they age out of the 24h window — and
because the retired watchdog emitted the same two-line WARN on every 15-minute
run, that was 137 lines of noise attributed to a stack that is gone.

The digest now reports incidents only for the stacks the watch still contains,
and says what it skipped instead of dropping it silently:

- **`tool/jwt-secret-monitor.sh`** gains **`--stacks`**, printing the watched
  stack names one per line and exiting — the one authority on what is still
  watched, which the digest consults rather than guessing.
- **`tool/jwt-secret-daily-summary.sh`** loads that list (env override
  `MONITOR`; default beside itself) and skips incident lines naming an unwatched
  stack at parse time, so neither the incident groups nor the `secret incidents`
  subject reason fire for them. The skipped lines are counted and named under a
  new "Ignored — retired stack(s) the watch no longer contains" section. With no
  monitor to consult the filter switches itself off and the digest reports
  exactly what it always did, rather than dropping incidents it cannot prove
  are retired. OK and REGISTRY lines are never filtered.
- **`tool/test_daily_summary.sh`** — a new phase (10 checks) pins it: a retired
  stack is ignored and named with its count, a watched stack's incident is still
  reported, and a missing monitor disables filtering. `test_jwt_secret_watch.sh`
  asserts the `--stacks` output shape.

### The JWT-secret watch, reproducible from one checkout

The VM's secret watch was split across two repos and only half of it was
installable. `tool/jwt-secret-monitor.sh`, its canonical-source library and the
installer that deployed them lived in the katalogus repo, while `alert.sh`,
`gotify-messages.sh` and the digest lived here with no installer that wrote
their schedule — so a fresh checkout produced a monitor that could not source
its helpers, and no repo file wrote the daily-summary cron entry at all. The
watch now has one home and one install path.

- **`tool/jwt-secret-monitor.sh`** — moved here from katalogus
  `tool/vm/jwt_secret_monitor.sh` (installed name unchanged,
  `~/bin/jwt-secret-monitor.sh`). The single program behind the watch.
- **`tool/canonical_secret.sh`** — moved here too; the one definition of the
  canonical JWT-secret source, read by the monitor and prepended to the
  katalogus repair's remote payload.
- **`tool/install_jwt_secret_watch.sh`** — the one installer for the WHOLE
  watch. `--apply` delegates `alert.sh` + the credential file to
  `install_alert_env.sh` (that logic keeps one owner), retires any of the four
  old watchdogs still present into `~/bin/retired-jwt-watchdogs-<ts>/` with a
  self-contained rollback bundle, installs `jwt-secret-monitor.sh`,
  `canonical_secret.sh`, `gotify-messages.sh` and `jwt-secret-daily-summary.sh`
  (previous copies kept as `.bak`), then rewrites the crontab to a single
  managed block of three entries — `*/15` monitor, `0,30` meta, `0 9`
  daily-summary. It runs the monitor once to plant the heartbeat and smoke-tests
  both modes read-only. plan / `--apply` / `--check`.
- **`tool/test_jwt_secret_watch.sh`** — the moved hermetic suite (109 checks),
  now asserting the three-entry managed block: the daily-summary entry is moved
  INSIDE it, the legacy header lines are gone, all three entries sit between the
  markers, and a second pass is idempotent.
- **katalogus** now points at this repo for the watch: `README.md`, the
  `repair_jwt_secret_drift.sh` `CANON_LIB` (resolved from a sibling kommons
  checkout, override with `KAT_KOMMONS_DIR`) and its self-test all read
  `kommons/tool/canonical_secret.sh`.

### Alert credentials out of the crontab

`crontab -l` prints every line, so the Brevo API key and the Gotify app token
the monitors read were visible to anyone who could list the schedule, and one
accidental copy away from leaving the host. They now live in a mode-0600 env
file the alert helpers source; the crontab holds only schedules and tuning.

- **`tool/alert.sh`** — sources `~/etc/alerts.env` (override with
  `ALERT_ENV_FILE`) at the single point every consumer already passes through,
  so one file configures them all. The file is a plain `KEY=value` file and is
  the source of truth; a hermetic suite running under `env -i HOME=<sandbox>`
  sees no file at all.
- **`tool/install_alert_env.sh`** — migrates the `ALERT_*`/`BREVO_*`/`GOTIFY_*`
  assignments out of the crontab into a 0600 file in a 0700 dir, swaps the
  comment block that documented them for a pointer, and installs the updated
  `alert.sh`. A re-run never overwrites an existing file, so a rotated token
  survives it. plan / `--apply` / `--check`.
- **`tool/test_alert_env.sh`** — hermetic suite (33 checks) that runs the
  installer's payload against a sandbox crontab and a real `alert.sh`: plan
  masking, the 0600/0700 modes, the single-quote round-trip, the crontab
  rewrite (secrets gone, jwt header and tuning kept), and — the point — that a
  clean shell sourcing `alert.sh` sees the values. Wired into `ops-tests.yml`.
- **`docs/GOTIFY.md`** no longer tells operators to keep the token "in the
  crontab environment", and notes that rotating a leaked token means creating a
  new application and deleting the old one (which takes its messages with it).

### The central identity allow list, declared

The identity stack serves every sibling project's auth, and GoTrue does not
reject an unlisted redirect — it silently rewrites `redirect_to` to
`GOTRUE_SITE_URL`. `/authorize` still answers 302, so the loss of an entry is
invisible until the very end of a real sign-in, when the member lands on the
website instead of back in the app. That made the allow list the wrong thing
to keep only in a hand-edited `.env`, which is rewritten for other reasons
(secrets, Google wiring, host ports) and takes the list with it.

- **`tool/identity-redirect-allowlist.txt`** — the declaration and single
  source of truth for `ADDITIONAL_REDIRECT_URLS` (the key
  `docker-compose.yml` hands to GoTrue as `GOTRUE_URI_ALLOW_LIST`). Entries are
  matched verbatim — GoTrue cuts the URL at `#` before matching, so a fragment
  is dead weight, and a trailing slash is significant. Order is preserved;
  duplicates are rejected.
- **`tool/identity_allowlist_sync.sh`** — the only thing that writes the key.
  Default plan (verbose, exit 1 on drift), `--check` (one verdict line for
  cron/CI, `--alert` notifies on a transition and on recovery), `--apply`
  (back up the `.env`, rewrite the one key, recreate *only* auth, wait for
  health and assert the running process carries every entry byte for byte,
  then restore and recreate again on any failure), and `--deploy` (install the
  tool + declaration into `~/bin`). A declared entry missing from the stack,
  or a running auth that predates the `.env`, is DRIFT; an undeclared live
  entry is a WARN and is kept unless `--prune`.
- **`tool/install_identity_allowlist_check.sh`** — puts a DETECT-ONLY guard on
  the VM's crontab: one managed entry running `--check --alert`
  (`*/30 * * * *` by default), so a later `.env` rewrite cannot drop an entry
  silently. It never applies — converging recreates the shared auth container,
  so it stays a human action — and it rewrites only its own managed block, so
  re-running is a no-op and no other cron entry is touched.
- **`tool/oauth_handoff_probe.sh`** — proves the entry is not just PRESENT but
  HONOURED, which is the half the allow-list guard cannot see. GoTrue validates
  `redirect_to` deep in the flow and silently rewrites an unlisted target to
  `GOTRUE_SITE_URL`; the probe starts a real `/authorize` flow per declared
  target and reads where GoTrue resolves it at `/callback`, so a dropped entry
  shows up as a fall back to the site URL instead of a member finding a broken
  sign-in months later. No credentials are used and no code is exchanged. It
  folds in the presence check (delegating to the allow-list tool) and asserts a
  CONTROL — a deliberately undeclared target must not be honoured — so a pass
  cannot be a false negative. Detect-only; `--alert` is transition-only.
- **`tool/install_identity_oauth_probe.sh`** — deploys the probe and puts a
  nightly `--check --alert` entry on the VM's crontab (its own managed block, so
  re-running is a no-op). One `auth.flow_state` row per declared entry plus the
  control, per night — a handful, swept by GoTrue.
- **`tool/test_oauth_handoff_probe.sh`** — hermetic suite (35 checks) whose stub
  `curl` IS GoTrue's validation: `/authorize` remembers the requested target and
  `/callback` resolves it only if it is on the stub's allow list. It asserts the
  equality-not-prefix match, the silent-rewrite finding, the control firing and
  `--no-control`, the folded-in presence half, an unreachable API, and the
  once-per-outage + recovery alerting. Wired into `ops-tests.yml`.
- **`tool/test_identity_allowlist_sync.sh`** — hermetic suite (85 checks) over
  stubbed `docker`/`ssh`/`scp`/`alert`: the declaration's well-formedness,
  missing/undeclared/live-behind-`.env` findings, apply's converge + per-entry
  live verification, the backup, key-absent insertion beside `SITE_URL`, the
  empty/duplicate-key refusals, and rollback on compose or verification
  failure. Added to `ops-tests.yml`; `docs/OAUTH_SERVER_SETUP.md` and
  `README.md` now point operators at the declaration.

### Telegram, the alert pipeline's external leg

Gotify and mail run on (or beside) the monitored host, so every one of them
goes blind at once when the host itself is unreachable — precisely the moment
a dead-man's switch has to speak. The critical alerts now fan a copy out to
Telegram as well, whose API lives off-host.

- **`tool/alert.sh`** — `send_telegram_alert <subject> <body>` POSTs to the
  Telegram Bot API (`/bot<token>/sendMessage`), sending plain text so alert
  bodies full of Markdown metacharacters cannot break the request, and
  truncating below Telegram's 4096-character cap. It is a no-op when
  `TELEGRAM_BOT_TOKEN` or `TELEGRAM_CHAT_ID` is empty, the same contract as
  every other channel. (The bot must already share a chat with the target —
  a group is how several people get one alert feed.)
- **The critical monitors** — drift-check, the revert watchdog, the liveness
  check and the delivery watchdog each add the Telegram copy to their
  existing fan-out. Routine reports are deliberately untouched: they still
  pick a single channel, because only *alerts* need the redundancy.
- **`tool/test_telegram_alert.sh`** — hermetic suite (24 checks): the no-op
  contract, the exact endpoint and chat id, real JSON round-tripping of
  quotes/backslashes/newlines, the length cap, no whitespace-only curl
  argument, and a wiring guard that each critical monitor still calls the
  helper. `test_delivery_watchdog.sh` gains a phase proving the external leg
  fires when Gotify itself is unconfigured (now 52 checks).

## 0.8.0 — 2026-10-06

### Gotify, documented for reuse

- **`docs/GOTIFY.md`** — a self-contained explainer of the push-alert channel,
  written to be lifted into another project: what Gotify is (a self-hosted
  push server with send-only **applications** and receive-only **clients**),
  the one-`curl` send (`POST /message?token=…` with `title`/`message`/
  `priority`), the `GOTIFY_URL`/`GOTIFY_APP_TOKEN`/`GOTIFY_PRIORITY`
  configuration and the no-op-when-unset contract, the `"<monitor> — <host>"`
  title convention and why the delivery watchdog depends on the exact
  heartbeat substring, priorities, the v2.9.1 read-surface limitation
  (`/health` and `/message` answer; `/api/*` 404s) and the resulting
  direct-SQLite audit, the retention rules that keep a heartbeat from being
  swept, and the nginx-vhost + no-sudo container install pattern.
  `README.md` now links it beside the OAuth page under "Server operators".

### Weekly `.env.bak.*` retention sweep

- **`tool/cleanup-env-backups.sh`** (weekly, Sundays 03:00 UTC via crontab) —
  prunes `.env.bak.*` snapshots under `~/Projects` that have not been
  touched in `RETENTION_DAYS` days (default 30). Keeps the newest snapshot
  in each directory as a rollback floor (`KEEP_PER_DIR=1`; set `0` for a
  strict age-only sweep), logs every deletion to
  `~/logs/env-backup-cleanup.log`, and supports `--dry-run`. Note that
  `jwt-secret-revert-watchdog.sh` rebuilds its pre-cutover fingerprint
  registry from the surviving snapshots, so pruning older than the
  pre-cutover backups shrinks exact-revert coverage; retained snapshots are
  unaffected. When a non-dry run actually prunes something it pushes a
  Gotify summary naming the count, the space freed and the removed paths
  (at `GOTIFY_PRIORITY`, default 5), and stays entirely silent when nothing
  is pruned — including on `--dry-run`; sending is a no-op unless
  `GOTIFY_URL` and `GOTIFY_APP_TOKEN` are set.
- **`tool/test_watchdog_identity_skip.sh`** — hermetic test (52 checks)
  proving all three monitors treat the kommons (identity) stack as the source
  of truth, not as one stack among others. It runs the real scripts against a
  sandbox `HOME` with stubbed `docker`/`curl`, so nothing outside the sandbox
  is touched:
  - **`jwt-secret-revert-watchdog.sh`** must never re-cut kommons or leave a
    backup beside its `.env`, even during a run that force-re-cuts a genuine
    revert in another stack.
  - **`jwt-secret-drift-check.sh`** uses kommons as the reference and must
    never report it as drifting, must still detect drift in the other stacks,
    must stay read-only (it never invokes docker), and must treat a missing
    identity `.env` as FATAL rather than as a stack that quietly drops out.
  - **`jwt-secret-daily-summary.sh`** digests a real watchdog + drift-check
    run without attributing any incident to kommons.

  Each central claim carries a negative control so the test fails on
  regression instead of passing vacuously: removing the watchdog's identity
  guard re-cuts the probe, decoupling kommons' `ENV_PATHS` entry onto a probe
  makes drift-check report `DRIFT kommons`, and a synthetic kommons incident
  IS surfaced by the daily summary. The test also prefers scripts sitting
  beside it, so the deployed `~/bin` copy runs against the deployed
  monitors.
- **`tool/test_cleanup_notify.sh`** — hermetic test (36 checks) for the
  cleanup notification contract: a stubbed `curl` proves exactly one summary
  is sent on a pruning run and none when there is nothing to prune, on
  `--dry-run`, or when Gotify is unconfigured.

### Docker-free Gotify delivery audit

- **`tool/gotify-messages.sh`** — queries the Gotify history directly from
  `~/gotify/data/gotify.db` using the python3 stdlib `sqlite3` module, so it
  needs no Docker access, no root and no Gotify admin login. Lists recent
  deliveries newest-first with id, priority, age, UTC time, application and
  title; filters by `--limit`, `--priority`, `--min-priority`, `--app`,
  `--title`, `--since` and `--since-hours`; and emits either a table,
  `--json`, `--counts` (totals per priority/app, newest, oldest),
  `--age-seconds` or `--report`. The database is
  opened read-only, so the audit never locks or mutates the live file. This
  answers “did the alert actually land?” — on this Gotify the HTTP API only
  exposes `/message` and `/health` (every `/api/*` route returns 404), so
  the database is the only queryable delivery record.
- **`tool/test_gotify_audit.sh`** — hermetic test (101 checks) that builds
  a synthetic `gotify.db` fixture in a throwaway sandbox and covers every
  filter, output mode, error path and the read-only guarantee; a failing
  `docker` stub on `PATH` proves the audit never shells out to Docker.
- **`tool/gotify-messages.sh`** gains two machine-usable output modes.
  `--age-seconds` prints the age in seconds of the newest matching delivery
  (or `-1` when nothing matches), giving scripts a scalar to compare against
  a threshold. `--report` prints an alert-history report over the selected
  range: which monitor fires most (grouped from the title before its host
  suffix), volume over time in wall-clock buckets that widen from 15m to
  hourly to daily to weekly as the range grows, and breakdowns by priority
  and application. Buckets are anchored to the clock rather than to the
  range start, and a tie for “busiest” is reported as a tie instead of
  naming an arbitrary winner. Both modes ignore `--limit` so they always
  see the whole range.

### Alert-pipeline dead-man's switch

- **`tool/jwt-secret-delivery-watchdog.sh`** (hourly at :20 via crontab) —
  all three JWT-secret monitors deliver *through* Gotify, so a broken Gotify
  server, a revoked app token or a dead cron made every one of them fail
  silently and the monitoring went blind without saying so.
  `jwt-secret-daily-summary.sh` is the only monitor that sends
  unconditionally (drift-check and the revert watchdog stay quiet while
  healthy), which makes its delivery the pipeline's heartbeat. This watchdog
  reads the Gotify history and alerts when that heartbeat has not arrived
  within `MAX_AGE_HOURS` (default 26), when no matching delivery exists at
  all, or when the history itself cannot be read. It fans the alert out to
  every configured channel — Gotify, webhook, local mail and Brevo —
  deliberately including email, because the component that broke may be
  Gotify itself; it stays silent while healthy and exits 1 when it alerts.
- **`tool/test_delivery_watchdog.sh`** — hermetic test (45 checks) driving
  the watchdog with a stubbed `gotify-messages.sh` and stubbed `curl`/`mail`:
  healthy silence, stale/missing/unreadable histories, the exact threshold
  boundary, configuration errors, and the case that matters most — the alert
  still goes out when Gotify is unconfigured.

### Pipeline health in the daily digest

Secret health and pipeline health were reported by two separate streams, so
an operator had to read both to answer "is the monitoring working?". The
daily summary now answers it in one message.

- **`tool/jwt-secret-daily-summary.sh`** — the digest gains a
  **Pipeline health (delivery watchdog)** section, folded in from the
  delivery watchdog's own log over the same `WINDOW_HOURS` window (path
  configurable via `DELIVERY_LOG`, default `~/logs/jwt-secret-delivery.log`).
  The watchdog's window reduces to one of three verdicts: **Healthy** (it ran
  and saw no stall, quoted with the newest heartbeat check), **STALLED**
  (each stall is carried through with its detail), or **UNVERIFIED** (it
  logged nothing in the window — a watchdog that stopped running is a
  pipeline problem, not a quiet success, and the section distinguishes a
  missing log from one that exists but has gone quiet). A stalled or
  unverified pipeline also escalates the email subject, and the run records
  its verdict as `PIPELINE=` / `DELIVERY_STALLS=` in the drift log. The
  Gotify push title is deliberately left as the bare
  `JWT Daily Summary — <host>`: `jwt-secret-delivery-watchdog.sh` finds the
  heartbeat by that exact substring, so decorating it would make every push
  read as a dead monitor.
- **`tool/test_daily_summary.sh`** — hermetic test (60 checks) running the
  real summary against a sandbox `HOME` with a stubbed `curl`: that one
  message carries both healths, the three pipeline verdicts and their
  escalation, window filtering and malformed lines in either log, and that
  the push title keeps the phrase the watchdog matches on.

### Live delivery-age cross-check in the daily digest

The digest reported pipeline health from the delivery watchdog's log alone, and
that log is stale by construction: the watchdog only runs hourly, so its newest
line describes the pipeline as of its last check. A pipeline that died just
after that check read healthy for up to an hour, and one that had recovered read
stalled for the rest of the day.

- **`tool/jwt-secret-daily-summary.sh`** — the **Pipeline health** section is
  now built from two readings, compared against each other:
  - a **live reading**, taken at send time from the Gotify delivery history
    through the same `gotify-messages.sh --age-seconds` query the watchdog uses
    (`GOTIFY_DB`, `AUDIT`, `EXPECT_TITLE` and `MAX_AGE_HOURS` all default to the
    watchdog's values so the two describe the same heartbeat), reduced to
    `ok` / `stale` / `missing` / `unparsable` / `unreadable`; and
  - the **watchdog log's verdict** over the window, as before.

  When the two disagree the digest says so in one `⚠ DISAGREEMENT` line, in
  either direction: a log reading healthy while the live heartbeat is past
  `MAX_AGE_HOURS` (the pipeline went quiet after the last check), or a log
  reading stalled while delivery is current (it has since resumed). A silent
  watchdog beside a healthy live reading is called out as the watchdog looking
  down, not the pipeline. An unreadable history renders as
  `Live: unavailable — <reason>` and is deliberately *not* a disagreement, since
  there is nothing to compare it against. A definitively bad live reading
  escalates the subject (`pipeline stale` / `pipeline missing`) even when the log
  is healthy, and the run records `PIPELINE_LIVE=` and `DISAGREE=` beside the
  existing `PIPELINE=`. The section heading loses its
  `(delivery watchdog)` qualifier, which no longer described its only source.
- **`tool/jwt-secret-daily-summary.sh`** (subject) — a disagreement is now its
  own escalation, `pipeline disagreement`, rather than a footnote to whichever
  verdict won. Escalating only on the verdicts was not enough: every conflict
  already set one off, but the *conflict* stayed invisible, so a log reading
  `stalled` beside a live history showing delivery is current went out as a
  plain `pipeline stalled` — blaming the pipeline for a stale log — and a silent
  watchdog beside a healthy live reading went out as `pipeline unverified`, when
  the body's own reading is that the *watchdog*, not the pipeline, is down. The
  subject now carries both facts (`pipeline stalled + pipeline disagreement`),
  in the one line the recipient actually reads. Two readings that agree the
  pipeline is unhealthy are a pipeline problem, not a conflict, and do not get
  the token.
- **`tool/test_daily_summary.sh`** (155 checks total) — a phase drives the live
  reading from a stubbed audit helper: agreement, both disagreement directions,
  a silent watchdog, a missing heartbeat and an unreadable history, asserting
  the rendered line, the subject escalation and the recorded verdicts. It also
  pins the disagreement escalation itself, including the negative control: an
  agreement claims no conflict in its subject, and two readings that agree the
  pipeline is unhealthy get no disagreement token.

### Readable daily digest

The digest had grown into a reprint of the shared watchdog log: dozens of
`OK` and `REGISTRY` lines every day, all saying the same thing, burying the
handful of lines worth reading. It is now a summary in the literal sense.

- **`tool/jwt-secret-daily-summary.sh`** — routine lines collapse to counts
  and incidents group by stack, so the same window reads in a screenful
  instead of a scroll:
  - **Clean runs (N):** counts the window per distinct outcome
    (`<n> x <outcome>  (last <time>)`), most frequent first — a mixed window
    still shows each outcome once, and the heading total still matches the
    old `OK` count.
  - **REGISTRY rebuilds (N), last <time>** replaces the per-rebuild lines.
    Registry churn is routine and near-identical, with one exception: when
    the window holds more than one distinct rebuild it flags the change with
    `! N distinct outcomes — the fingerprint set changed`, which is the only
    registry event worth reading.
  - **Incidents by stack:** DRIFT, WARN, REVERT, FATAL and DONE lines are
    grouped under the stack they belong to, with the most-affected stack first
    and its events sorted. `Kognitio — 21 event(s):` says at a glance what
    twenty-one flat lines did not. A two-word `REVERT DETECTED` is attributed
    to its stack, and a `DONE:` summary inherits the stack of the reverts it
    concluded (see below); only a genuinely stack-less event falls under
    `(host-level)` rather than being dropped. Timestamps drop to the minute,
    since seconds carry no signal at daily resolution.
  - The liveness `HEARTBEAT` plumbing stays out of the digest, and the email
    subject now says `— N clean run(s)` to match the new heading.
- **`tool/test_daily_summary.sh`** — the condensed contract is pinned by a
  phase that proves each routine line becomes a count rather than being
  reprinted, that grouping attributes events to their stack (including
  `REVERT DETECTED` and stack-less host events), that a bare event keyword is
  never mistaken for a stack, that liveness plumbing stays out, and that a
  changed fingerprint set is flagged while an unchanged one is only counted.

### `DONE:` summaries attributed to the stack they conclude

The revert watchdog writes one `DONE:` line per run and names no stack in it —
"at least one exact revert was auto-re-cut" or "re-cut FAILED" — so the digest
was filing the outcome of an incident under a vague `(host-level)` heading,
right next to nothing. The outcome is the most important line of the incident,
and it was the one line that lost its stack.

- **`tool/jwt-secret-daily-summary.sh`** — incident lines are now collected in
  log order along with the stack each belongs to, so grouping can see which run
  a summary closes. A `DONE:` line is attributed to the stacks named by the
  `REVERT` lines of the same run, a run being delimited by the `REGISTRY` line
  the watchdog writes at its start. That delimiter is what keeps one run's
  summary off another run's stack. This is exact rather than a guess: a `DONE:`
  line is only ever written when a re-cut was attempted, so its run always
  contains the `REVERT` lines it concluded. A run that re-cut several stacks
  concludes all of them, and the summary is listed under each rather than under
  an arbitrary one. When the window opens mid-incident and the reverts fall
  outside it there is genuinely nothing to attribute the summary to, and it
  keeps the `(host-level)` fallback.
- **`tool/test_daily_summary.sh`** (147 checks total) — a phase driven by a
  parser that reads the delivered message asserts, from the rendered groups
  themselves, that a summary sits with the reverts it concluded, that two runs
  in one window do not bleed onto each other's stacks, that a run re-cutting two
  stacks shows its summary under both, that nothing lands in `(host-level)` when
  every incident named a stack, and that a window opening mid-incident still
  falls back honestly.

### Liveness check for the 15-minute monitors

The dead-man's switch watches the *pipeline*: it proves the daily summary was
actually delivered. It cannot see `jwt-secret-drift-check.sh` or
`jwt-secret-revert-watchdog.sh`, which deliver through that pipeline and say
nothing while the secrets are healthy — so a deleted cron entry or a lost
executable bit would have left the secrets unguarded and completely silent.

- **`jwt-secret-drift-check.sh` and `jwt-secret-revert-watchdog.sh`** — both
  now write one `HEARTBEAT <monitor> <verdict>` line per run, from an `EXIT`
  trap so every path leaves exactly one, including a `set -e` abort. The
  drift-check previously logged its clean result **only when no alert channel
  was configured**, which on the VM meant a healthy run recorded nothing at
  all; it also now creates its log directory, which the always-on heartbeat
  made load-bearing. `jwt-secret-liveness-check.sh` measures these lines, and
  the daily digest ignores them.
- **`tool/jwt-secret-liveness-check.sh`** (every 30 minutes via crontab) —
  alerts when a monitor's newest heartbeat is older than `MAX_AGE_MINUTES`
  (default 45, three missed cycles), is absent altogether, or carries an
  unparsable timestamp. Alerts fire on **transitions only**: the state file
  (`STATE`) remembers what has already been reported so a monitor that stays
  down is not re-alerted every half hour, and coming back up sends a short
  recovery notice so the episode has a visible end. It fans out to every
  configured channel and reports honestly when none is set. `--dry-run`
  reports without alerting or touching the state.
- **`tool/test_liveness_check.sh`** — hermetic test (70 checks) driving the
  check with fixture logs and stubbed `curl`/`mail`: the report-once and
  recovery-once behaviour, the exact threshold boundary, never-seen monitors,
  a missing log, out-of-order and unparsable heartbeats, selecting which
  monitors to watch, dry run, configuration errors and `--help`.
- **`tool/test_watchdog_identity_skip.sh`** (52 → 56 checks) and
  **`tool/test_daily_summary.sh`** (63 → 64 checks) — assert that both
  monitors emit a heartbeat on every path, including a FATAL one, and that
  heartbeat lines never leak into the daily digest.

### Periodic Gotify alert-history digest

The alert-history report is only useful if someone remembers to ask for it.

- **`tool/gotify-report-digest.sh`** (weekly, Mondays 08:00 UTC via crontab)
  — runs `gotify-messages.sh --report` over `REPORT_HOURS` (default 168, a
  week) and emails the result, so the trend arrives unprompted. The subject
  carries the alert count and window, and a header promotes the report's own
  "busiest monitor" and window-over-window trend verdicts plus the database
  path, so the digest can be triaged without reading the histogram. It is delivered
  **by email only** — Brevo when `BREVO_API_KEY` and `ALERT_EMAIL` are set,
  otherwise local `mail(1)` — deliberately never through Gotify: the report
  is built from Gotify's `messages` table, so pushing the digest would write
  it into the history it summarises and every later run would count the
  previous digest as a delivery. Exactly one channel is used, so a recipient
  never gets two copies. A quiet window is still delivered (a weekly "0
  alerts" is a confirmation, and a missing digest should mean the job did
  not run), an unbuildable report fails loudly with a FATAL log line and a
  failure email, `--dry-run` previews without sending, and the log states
  plainly when no email channel was configured instead of claiming a send.
- **`tool/test_gotify_report_digest.sh`** — hermetic test (77 checks) with a
  stubbed audit helper and stubbed `curl`/`mail`: both delivery channels and
  the once-only rule, the never-pushed guarantee, window configuration and
  labelling, quiet and tie windows, the trend verdict, the failure and
  configuration-error paths, and that `--help` sends nothing.

### Which way the alert trend is going

The report showed the *shape* of the alert stream — a bar per bucket under
"Volume over time" — but never its direction: a week with twice the alerts of
the week before looked exactly like a quiet one until every bar had been read.

- **`tool/gotify-messages.sh`** — `--report` now compares its window with the
  preceding window of the same length and prints **`By monitor vs previous
  window`**: the previous range, then one line per monitor that fired in either
  window — `<before> → <now>  <delta>  ▲/▼/=` — biggest mover first, so the
  direction is the first thing read. A monitor that appeared reads `0 → 3  +3`,
  one that stopped reads `5 → 0  -5`, one that held steady is marked `=`. The
  section ends with a liftable `trend:` line summarising the window total
  (`down 45 → 42 (-7%) — 1 rose, 1 fell, 1 flat`), the way `busiest:` already
  was. When the history itself begins inside the preceding window the section
  says so (`partly covered: this history begins …`) rather than reporting the
  unrecorded part as silence, and a window that went quiet against a busy one
  still prints the comparison, because a fall to zero is the trend most worth
  knowing. The comparison honours the report's own filters and reuses
  `monitor_of()`, so the two windows are compared like for like.
- **`tool/gotify-report-digest.sh`** — lifts the `trend:` verdict into the
  digest header as `Trend:    …`, directly above `Busiest:`, so the direction
  of the trend is readable before the report body. A report that lacks the line
  (one built before the comparison existed) leaves no empty header entry.
- **`tool/test_gotify_audit.sh`** (122 checks) — a purpose-built two-window
  fixture proves a monitor rising, one falling, one holding flat, one new and
  one gone, the biggest-mover ordering, the window-total direction, the
  partial-coverage caveat, that an alert outside both windows enters neither
  count, and that a silent window against a busy one still states its fall.
- **`tool/test_gotify_report_digest.sh`** — the stubbed report carries a trend
  verdict, and the tests assert the header promotes it above the busiest
  monitor, that the direction reaches both email channels, and that a quiet
  window or an older report invents no trend line.

### Fixed

- **`tool/alert.sh`, `tool/jwt-secret-daily-summary.sh`** — the daily summary
  emailed the same digest twice on any host that had both a working `mail(1)`
  and a `BREVO_API_KEY`, which is exactly the VM's situation: once through the
  local MTA and once through Brevo. Routine reports now pick a **single**
  channel via the new `send_email_report()` helper — Brevo when configured,
  local `mail(1)` otherwise — and the run records which one carried it
  (`EMAIL=brevo` / `EMAIL=mail` / `EMAIL=none`) so a summary that reached
  nobody is visible in the log instead of looking like any other send. The
  urgent alerts keep their deliberate fan-out across every channel, because
  the channel that broke may be the very one being reported on. The
  `gotify-report-digest.sh` wrapper now calls the same shared helper rather
  than keeping its own copy of the policy.
- **`tool/test_daily_summary.sh`** — 63 → 84 checks. The suite had no `mail`
  stub, so on a host with `mail(1)` installed it reached the real binary; it
  now stubs both channels and asserts the single-channel rule, the fallback,
  the no-channel case, and a Brevo key without a recipient.
- **`tool/alert.sh`** — `send_brevo_alert()` built its `curl` command line with
  `-H 'Content-Type: application/json' \      -d "…"` on a single line, so the
  backslash escaped a space instead of continuing the line and curl received a
  whitespace-only argument. curl reads any non-option argument as a URL, so
  every Brevo request carried a bogus second target beside the real endpoint:
  a failed request and a non-zero exit, both swallowed by the trailing
  `|| true`. The body still reached `api.brevo.com`, which is exactly why the
  channel kept working and the defect stayed invisible. The `-d` argument now
  sits on its own line, and the delivered command line is asserted to hold no
  whitespace-only argument.
- **`tool/test_daily_summary.sh`** — the Brevo path now asserts that no
  whitespace-only argument reaches curl, with a negative control: restoring the
  escaped space fails exactly that assertion.
- **`tool/alert.sh`** — `send_webhook_alert()` built its request body with a
  transposed brace and quote (`-d "{\"text\":\"${safe}}\""`), so the value
  string was closed before the object was: every webhook payload ended in
  `}"` instead of `"}` and was **not valid JSON**, making the webhook channel
  unusable for any real target. Found while verifying the new digest against
  the VM's real logs; a round-trip guard now asserts the delivered body is
  parseable JSON and still carries both health sections.

### Gotify alert-history retention

Every alert the monitors deliver is stored in Gotify's `messages` table and
nothing ever removed it, so the database grew without bound.

- **`tool/gotify-retention-sweep.sh`** (weekly, Sundays 03:30 UTC via
  crontab) — deletes messages older than `RETENTION_DAYS` (default 30) while
  always keeping the newest `KEEP_NEWEST` rows (default 100) as a floor, so
  a short history is never emptied just because it is all old. It logs an
  auditable summary and notifies only when it actually pruned something
  (and says so honestly when no alert channel is configured); `--dry-run`
  previews without deleting and `VACUUM=1` optionally reclaims file space.
  The delete runs inside a one-shot container (default `python:3-alpine`)
  because the database is root-owned — an unprivileged host user gets
  "attempt to write a readonly database" — which leaves the service's files
  and ownership untouched and relies on SQLite's cross-process locking for
  safety against the running Gotify. Keep `RETENTION_DAYS` well above the
  delivery watchdog's 26h threshold so the heartbeat is not swept away.
- **`tool/test_gotify_retention_sweep.sh`** — hermetic test (58 checks) with
  a `docker` stub that executes the sweep's piped Python locally, mapping
  the `-v` mount and `-e` variables onto a fixture database: pruning, the
  keep-floor, dry run, VACUUM opt-in, silence when nothing is old enough,
  the no-channel case, and the failure paths (missing docker, missing image,
  missing database).

### CI: hermetic ops suites on every push and pull request

The monitors are shell scripts deployed to `~/bin` and driven by cron, so a
regression in them stays invisible until the moment an alert fails to arrive.

- **`.github/workflows/ops-tests.yml`** — runs the hermetic `tool/` suites
  (`test_watchdog_identity_skip.sh`, `test_liveness_check.sh`,
  `test_daily_summary.sh`, `test_gotify_audit.sh`,
  `test_gotify_report_digest.sh`, `test_gotify_retention_sweep.sh`,
  `test_delivery_watchdog.sh`, `test_cleanup_notify.sh`) on every push and
  pull request, and on demand. A first step also asserts that each deployed
  script is present and executable, since cron runs them directly and a lost
  mode bit breaks
  the VM's monitoring. Every suite runs even after one fails, so a single run
  reports the whole picture; the job needs only bash and python3 — no Docker
  daemon, no network, no Flutter toolchain. The suite list is an explicit
  allowlist rather than a glob because `tool/test_watchdog.sh` (inspects  the real `~/Projects` tree) and `tool/test_watchdog_revert.sh` (rewrites a real
  stack's `.env`) are deliberately non-hermetic and stay manual, on the VM.

### Shell API changes

No Dart API changes — this release is operational tooling only.

### Adoption

```yaml
kommons:
  git:
    url: https://github.com/kjhrono/kommons.git
    ref: v0.8.0
```

The monitoring scripts are sourced from `~/bin` on the VM and driven by
crontab; `tool/gotify-messages.sh` reads the Gotify history without Docker or
root. See [`docs/GOTIFY.md`](docs/GOTIFY.md) for the push-alert channel, and
each script's inline header for its required environment variables.

## 0.7.0 — 2026-10-05

### JWT secret monitoring toolkit

The central-identity cutover shares one `GOTRUE_JWT_SECRET` across all project
stacks. A silent rollback to a pre-cutover local secret breaks auth for every
consumer, so three operational scripts guard against it:

- **`tool/jwt-secret-drift-check.sh`** (run every 15 min via crontab) —
  compares every stack's `JWT_SECRET` against the identity stack's; logs
  `DRIFT`/`WARN`/`OK` to `~/logs/jwt-secret-drift.log` and alerts on drift.
- **`tool/jwt-secret-revert-watchdog.sh`** (run every 15 min via crontab) —
  builds a fingerprint registry from every `.env.bak.*` history file and,
  when a stack's secret exactly matches a known pre-cutover fingerprint,
  force-re-cuts automatically: backs up `.env`, restores the identity secret,
  runs `docker compose up -d --force-recreate`, polls the auth container
  health, and verifies the secret landed in the running container.
- **`tool/jwt-secret-daily-summary.sh`** (run daily at 09:00 UTC via crontab)
  — parses the shared drift log for the past 24 h, reports all OK runs plus
  any DRIFT/WARN/REVERT incidents, and sends the digest via webhook + Brevo
  email.

Key operational decisions:

- **No `--wait` on `docker compose up`** — Supabase's realtime container
  has a flaky WebSocket healthcheck that intermittently fails and blocks
  `--wait` until timeout; the watchdog instead polls the auth container only.
- **`GOTRHE_JWT_SECRET` → `GOTRUE_JWT_SECRET`** typo in the auth container
  verification step is fixed.
- All scripts use `ALERT_WEBHOOK_URL` (generic incoming-webhook) instead of
  a provider-specific webhook URL; alerts also fall back to Brevo email via
  `BREVO_API_KEY` + `ALERT_EMAIL`.

### Shell API changes

No Dart API changes — this release is operational tooling only.

### Adoption

```yaml
kommons:
  git:
    url: https://github.com/kjhrono/kommons.git
    ref: v0.7.0
```

The three scripts are sourced from `~/bin/` on the VM; see inline docs for
required env vars (`ALERT_EMAIL`, `BREVO_API_KEY`, `ALERT_WEBHOOK_URL`).

## 0.6.0 — 2026-10-01

The shell takes over two account behaviors every consumer had to
reinvent: the ban kill-switch becomes controller-enforced end to end,
and the forgot-password flow parks its own state.

### The shell enforces the ban; the shell parks the reset

Two behaviors that early consumers had to reimplement per game become
native `AccountController` behavior — other games get them for free, and
adapters that predate them can shed their workarounds.

- **Ban gate** — a `banned` refusal from the auth service is terminal at
  the controller level on every path that can surface it: the password
  sign-in (including the sign-up-or-in fallback), signup, code/link
  verification, recovery, and the silent paths (startup session restore
  and expired-token refresh). The controller stamps the suspension
  (`account.banned`, `account.bannedUntil` parsed from the refusal
  message when the server sends a window), drops the stored session,
  and notifies listeners. Silent paths still degrade to the device-local
  record — the settings card carries the news instead: an `ACCOUNT
  SUSPENDED` banner with the window. Sign-out and `resetForTest` clear
  the state. Callers treat a ban as terminal: no retry — the token is
  dead server-side no matter what the local copy claims. The contract
  for auth services: surface the suspension as `AuthException` code
  `banned` (the plain GoTrue REST client already passes GoTrue's
  `error_code` through; the kit-backed adapters map
  `AuthBannedException` to it).
- **Native reset parking** — `requestPasswordReset` parks the address
  itself (`account.pendingResetEmail`), idempotently, exactly like the
  parked signup. Screens no longer have to remember to
  `parkPasswordReset` after the request; doing so stays harmless.

New in `test/account_ban_gate_test.dart` (8 tests: the gate on sign-in,
window capture, the dead-session drop on the silent restore, sign-out
clearing, parking, resend, and the settings banner).

### Adoption

```yaml
kommons:
  git:
    url: https://github.com/kjhrono/kommons.git
    ref: v0.6.0
```

Additions, no breaking changes: `account.banned` / `account.bannedUntil`
and the settings-card suspension banner are new surfaces — any game whose
`AuthService` surfaces GoTrue's `banned` error_code (the plain REST client
already does) gets the gate for free. Games that parked the reset address
in their own screens can drop the call; leaving it is harmless (the
parking is idempotent).

## 0.5.0 — 2026-09-30

The identity phase lands: the email_auth_kit becomes the VM's central
identity service with a proven revocation primitive, and the harnesses
that keep it honest become permanent CI machinery.

### Phase 0 harness hardening

Phase 0 of the central-identity plan became a permanent, CI-guarded
harness instead of a one-off demo: the two-stack proof now survives
fresh checkouts and restarts, the kit's smoke suite runs anywhere via
environment, and a new harness proves the same acceptance bar against
real VM hosts.

### Phase 0 harness hardening

- **The proof survives a virgin database** — stack B's schema
  provisioning no longer depends on GoTrue's first-boot ordering: a
  stub `auth.uid()` owned by `auth_admin_b` (the role GoTrue-B
  migrates as) is replaced by the modern claim reader once the
  fingerprint of GoTrue's bundled legacy function changes, with
  `ON_ERROR_STOP` and a post-flight assert so a silently-stubbed proof
  can't pass.
- **Restart-proof runs** — readiness waits for auth-b, postgrest-b and
  the host-run kit functions, and stale function processes are killed
  before relaunch, so a `supabase stop/start` no longer races deno's
  boot or serves dead env from an earlier run.
- **Failure visibility** — a stack-A startup failure prints its log
  tail instead of a bare non-zero exit, and the teststack
  `config.toml` is tracked so CI starts the real stack, not a
  config-less default one.
- **Honest revocation checks** — the proof pins what stateless
  verification actually guarantees: sign-out revokes the refresh path
  and identity refuses the bearer server-side, while an unexpired
  access token stays valid on the data plane until `exp`.
- The identity-proof workflow reruns the proof on a schedule and on
  kit changes — a standing drift alarm.

### Smoke suite parameterization

- The 23-check smoke suite reads its stack coordinates (`KIT_API_URL`,
  `KIT_EV_URL`, `KIT_PR_URL`, `KIT_MAILPIT_URL`, `KIT_ANON_KEY`,
  `KIT_DB_CONTAINER`) from the environment, with `--smoke` and
  `RUN_SMOKE=1` modes — `identity/run_phase0.sh --smoke` re-validates a
  restarted teststack against its CURRENT keys instead of baking any
  in, because every restart regenerates the API keys and Mailpit's
  address.

### VM acceptance harness

- **`teststack/verify_vm_project.sh` (+ `.py`)** — Phase 1's acceptance
  bar parameterized for real VM hosts over the `KIT_*` env contract:
  identity mint through the kit (signup → Brevo-mailed code with
  auto-fetch → verify → sign-in), foreign-JWT read on the project,
  RLS-stamped insert keyed on `auth.uid()`, owner-scoped delete, and
  the project's own signup refused. Plus-addressing per run sidesteps
  the kit's rate limiter; `KIT_BREVO_API_KEY`/`KIT_MAILPIT_URL`
  auto-fetch the mailed code, `KIT_ADMIN_KEY` auto-deletes the minted
  user.
- The Brevo auto-fetch was fixed against the live API: the list
  endpoint is `GET /smtp/emails?email=<addr>` (the filter is mandatory
  and `@` must not be %-encoded), message content lives at
  `GET /smtp/emails/{uuid}` in `body`, the list index lags sends by up
  to ~2 minutes (deadline polling), and hard-bounced test addresses
  are send-suppressed until `DELETE /smtp/blockedContacts/{email}`
  clears them.

### Phase 1 — central identity live on the VM

Steps 1–3 of `docs/PHASE1_VM_ROLLOUT.md` are done and verified: the
identity stack serves `https://auth.mediasart.com`, and every project
stack now verifies tokens signed with identity's JWT secret.

- **auth.mediasart.com live** — the shared `mediasart.com` certbot
  lineage expanded (auth in the SAN, chain verifies); nginx routes
  /auth/v1, /rest/v1, /functions/v1 to the identity gateway with
  HTTP→HTTPS redirect. Verified from outside (TLS + endpoint probes)
  and with the full 11-check smoke through the public URL.
- **Shared secret on all six stacks** — katalogus, katalogus-staging,
  kalcio, kognitio, kollectio, kapaxinfiniti rolled with their
  `COMPOSE_PROJECT_NAME`-pinned `.env`s (backups kept), signups
  disabled, SMTP emptied. Ops notes the run earned: GoTrue refuses to
  boot on an empty `GOTRUE_SMTP_PORT` (keep the inert `2500`
  placeholder); this stack generation's envoy gateway checks API keys
  only while signatures verify in rest+auth, so each stack keeps its
  own anon key until the facade flip.
- **Acceptance 6/6 ALL PASS** — `verify_vm_project.sh` per stack: kit
  mint on identity, foreign-JWT read plus RLS-stamped insert/delete on
  a per-stack `kit_probe` table (`teststack/kit_probe_table.sql`), own
  signup refused. Harness fix from the run: Brevo's list filter
  percent-decodes `+` as a space, so derived plus-addresses encode with
  `quote(email, safe='@')`.
- Topology absorbed: kognitio targets its own `kognitio-db` database,
  kollectio's DB is a bare postgres container, and katalogus-staging
  moved to `~/Apps/stages/` in a VM reorg (verified intact after the
  move).

### The ban kill-switch

The revocation primitive CENTRAL_IDENTITY.md anticipated: identity
writes a ban flag that every project's RLS can check — no cross-stack
plumbing, the flag rides the JWT.

- **Identity side** (`20260930000000_email_auth_kit_bans.sql`) —
  `auth_kit_bans`, the service-role `auth_kit_set_ban` RPC, and
  `auth_kit_custom_access_token`: the GoTrue custom access token hook
  embedding a `kit_banned_until` claim into every token minted or
  refreshed while a ban is live. SECURITY DEFINER (the ban table has
  zero policies) with EXECUTE granted back to `supabase_auth_admin` —
  the blanket revoke would otherwise break every sign-in.
- **Project side** (`teststack/ban_aware_auth_uid.sql`) — a ban-aware
  `auth.uid()` returns NULL on a live claim, denying every
  `auth.uid()`-keyed policy; applied on all six VM stacks with
  `supabase_auth_admin` ownership preserved.
- **Proven twice**: in the prototype (proof section 6, 15 checks,
  CI-green on a virgin database) and on the VM over the public URL
  (14/14: ban → claim on the fresh token → staging refuses
  read/insert/whoami → pre-ban tokens honestly honored until exp →
  unban restores everything).
- **`ban-management/` edge function** — the dashboard surface: one
  service-role call drives BOTH planes (kit claim + GoTrue's native
  ban), plus `status`/`list` and optional notify mails. The gate is an
  exact constant-time bearer match against the service-role key — the
  kit's functions run behind `VERIFY_JWT=false`, so a decodable-claim
  check would be forgeable. 16/16 public-URL verification; the smoke
  suite gains section 8 and a 10s timeout on every request.
- **Client** — `AuthBannedException` (subclass of `AuthCodeException`)
  thrown by the new ban-aware `signIn` / `refreshSession` on either
  plane (`bannedUntil` from the claim when known); catch it first for
  the suspended-account UX.

### Adoption

```yaml
kommons:
  git:
    url: https://github.com/kjhrono/kommons.git
    ref: v0.5.0
```

No shell API changes in 0.5.0 — the lobby/auth surfaces are unchanged
from 0.4.0; everything new is the kit's VM rollout, the ban
kill-switch, and the harness/CI machinery around them.

## 0.4.0 — 2026-09-29

The release that folds the mediasart email-identity kit into the repo
as a subpackage, registers kalcio in the consumer gate, and hardens the
release machinery itself.

### The email_auth_kit subpackage

`email_auth_kit/` carries the generic, project-agnostic email-identity
flows for every mediasart app: a Supabase SQL migration (`auth_events`
audit/challenge table with hashed codes, rate-limit guard, SECURITY
DEFINER helpers), two Deno edge functions (`email-verification` with
kit-native signup — the user is created unconfirmed and one 6-digit
code mail goes out; `password-reset` with link → temp-password
flows and a self-verified `notify` action), and a pure-Dart client
(`mediasart_auth_client`) that games add as a path dep on the
subpackage. Verified end to end against a local stack (23-check smoke
suite with real mail) and 11 client unit tests; both gate with this
repo's consumer script. Design docs in `email_auth_kit/docs/`,
including the central-identity plan whose two-stack Phase 0 proof
(`teststack/identity/`) ran 12/12 green.

### Consumer gate and change alerts

- kalcio registered in the gate (analyze-only — its test battery is
  kalcio CI's job); consumers missing from the checkout skip loudly
  instead of failing CI.
- Tag mode gates the kit from the **tagged snapshot**; tags predating
  the subpackage skip loudly.
- `tool/verify_alert_chain.sh` closes the kommons→kalcio alert loop in
  one guarded command.

### Release machinery

- Release workflow pub-gets the probe before the root analyze (fresh
  checkouts have no probe `.dart_tool` — caught on the first v0.3.0
  attempt).
- Actions bumped to Node 24 majors (checkout@v5, setup-java@v5);
  Dependabot now groups future action bumps into one weekly PR.

### Adoption

```yaml
kommons:
  git:
    url: https://github.com/kjhrono/kommons.git
    ref: v0.4.0
```

No shell API changes in 0.4.0 — the lobby/auth surfaces are unchanged
from 0.3.0; everything new is the subpackage and the CI machinery
around it.

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
