#!/usr/bin/env bash
# gotify-retention-sweep.sh — bound the Gotify alert history.
#
# Every alert the JWT-secret monitors deliver is stored in Gotify's messages
# table and nothing ever removes it, so the database grows without bound.
# This sweep deletes messages older than RETENTION_DAYS, always keeping the
# newest KEEP_NEWEST rows as a floor.
#
# Why a container: the database belongs to the Gotify container and is
# root-owned on the host, so an unprivileged host user cannot write it — a
# direct DELETE fails with "attempt to write a readonly database". Rather
# than change the ownership of a running service's data (or require root),
# the sweep performs the delete inside a one-shot container that mounts the
# data directory and runs as root for the duration. Nothing about the
# service's files or ownership changes and Gotify keeps running untouched;
# SQLite's cross-process locking makes the concurrent access safe.
#
# Interactions worth knowing:
#   * jwt-secret-delivery-watchdog.sh reads the newest "JWT Daily Summary"
#     delivery, so keep RETENTION_DAYS well above its MAX_AGE_HOURS (26h) —
#     otherwise the heartbeat itself could be swept away and the watchdog
#     would report the pipeline as stalled.
#   * gotify-messages.sh (--report, --counts, …) only ever sees what survives
#     this sweep; pruning shortens the history they can summarise.
#   * Deleting rows bounds the row count and lets SQLite reuse the freed
#     pages, so the file stops growing; it only shrinks if you opt into
#     VACUUM, which briefly takes an exclusive lock on the database.
#   * The floor also means the effective retention is the longer of
#     RETENTION_DAYS and the time it takes to accumulate KEEP_NEWEST rows —
#     a short history is never emptied just because it is all old.
#
# Configuration (set in crontab environment or export):
#   GOTIFY_DB       path to gotify.db (default: $HOME/gotify/data/gotify.db)
#   RETENTION_DAYS  delete messages older than this many days (default: 30)
#   KEEP_NEWEST     always keep the newest N messages (default: 100)
#   LOG             audit log (default: $HOME/logs/gotify-retention.log)
#   DRY_RUN         non-empty → report only, delete nothing
#   VACUUM          non-empty → VACUUM after deleting, reclaiming file space
#   SWEEP_IMAGE     image used for the delete (default: python:3-alpine)
#   HOST            host name used in alert titles (default: hostname)
#
# Alert configuration (from alert.sh; unset → silent no-op):
#   GOTIFY_URL, GOTIFY_APP_TOKEN, GOTIFY_PRIORITY (default: 5)
#
# Usage:
#   gotify-retention-sweep.sh            # prune per configuration
#   gotify-retention-sweep.sh --dry-run  # preview without deleting
#
# Exit status: 0 success (also when nothing was old enough), 1 runtime
# failure (logged and alerted), 2 usage error.
set -euo pipefail

# Source shared helpers (timestamp) from tool/alert.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=alert.sh
. "${SCRIPT_DIR}/alert.sh"

GOTIFY_DB="${GOTIFY_DB:-$HOME/gotify/data/gotify.db}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
KEEP_NEWEST="${KEEP_NEWEST:-100}"
LOG="${LOG:-$HOME/logs/gotify-retention.log}"
DRY_RUN="${DRY_RUN:-}"
VACUUM="${VACUUM:-}"
SWEEP_IMAGE="${SWEEP_IMAGE:-python:3-alpine}"
HOST="${HOST:-$(hostname)}"

# Alert only on this channel, matching cleanup-env-backups.sh.
send_sweep_alerts() { # <title> <body> [priority]
  send_gotify_alert "$1" "$2" "${3:-${GOTIFY_PRIORITY:-5}}"
}

usage_error() { echo "gotify-retention-sweep: $1" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d'; exit 0 ;;
    *) usage_error "unknown option: $1" ;;
  esac
  shift
done

for num in "$RETENTION_DAYS" "$KEEP_NEWEST"; do
  case "$num" in ''|*[!0-9]*) usage_error "expected a non-negative integer, got '$num'" ;; esac
done

mkdir -p "$(dirname "$LOG")"

fatal() { # <message>
  echo "$(timestamp) FATAL $1" >> "$LOG"
  send_sweep_alerts "Gotify retention sweep FAILED — ${HOST}" \
    "The Gotify alert-history retention sweep could not run, so the alert
database will keep growing.

${1}

Database: ${GOTIFY_DB}
Log:      ${LOG}" 8
  echo "gotify-retention-sweep: $1" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 || fatal "docker is required to write the container-owned database"
[ -f "$GOTIFY_DB" ] || fatal "database not found: $GOTIFY_DB"

DB_DIR="$(cd "$(dirname "$GOTIFY_DB")" && pwd)" || fatal "cannot resolve directory of $GOTIFY_DB"
DB_NAME="$(basename "$GOTIFY_DB")"

docker image inspect "$SWEEP_IMAGE" >/dev/null 2>&1 \
  || fatal "sweep image not available: ${SWEEP_IMAGE} (pull it with: docker pull ${SWEEP_IMAGE})"

# --------------------------------------------------------------------------- #
# Sweep (inside a one-shot container, so the root-owned database is writable)
# --------------------------------------------------------------------------- #

result=""
rc=0
result="$(docker run --rm -i --network none \
  -v "${DB_DIR}:/data" \
  -e "SWEEP_DB=/data/${DB_NAME}" \
  -e "SWEEP_DAYS=${RETENTION_DAYS}" \
  -e "SWEEP_KEEP=${KEEP_NEWEST}" \
  -e "SWEEP_DRY=${DRY_RUN:+1}" \
  -e "SWEEP_VACUUM=${VACUUM:+1}" \
  "$SWEEP_IMAGE" python3 - <<'PY'
import os
import sqlite3
import sys
from datetime import datetime, timedelta, timezone

db_path = os.environ["SWEEP_DB"]
days = int(os.environ["SWEEP_DAYS"])
keep = int(os.environ["SWEEP_KEEP"])
dry = os.environ.get("SWEEP_DRY") == "1"
vacuum = os.environ.get("SWEEP_VACUUM") == "1"

if not os.path.isfile(db_path):
    print("ERROR=no such database: %s" % db_path)
    sys.exit(1)

# Cutoff in the same wall-clock format Gotify stores, so the comparison is
# a plain string compare and can use the index on date.
cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).strftime(
    "%Y-%m-%d %H:%M:%S+00:00"
)
# Eligible = older than the cutoff AND not part of the newest `keep` rows.
# The floor keeps the newest heartbeat the delivery watchdog looks for.
predicate = (
    "date < ? and id not in "
    "(select id from messages order by date desc, id desc limit ?)"
)

try:
    con = sqlite3.connect(db_path, timeout=30)
    con.execute("pragma busy_timeout=30000")
    before = con.execute("select count(*) from messages").fetchone()[0]
    doomed = con.execute(
        "select count(*) from messages where " + predicate, (cutoff, keep)
    ).fetchone()[0]
    span = con.execute(
        "select min(date), max(date) from messages where " + predicate,
        (cutoff, keep),
    ).fetchone()
    deleted = 0
    if not dry and doomed:
        cursor = con.execute(
            "delete from messages where " + predicate, (cutoff, keep)
        )
        deleted = cursor.rowcount
        con.commit()
        if vacuum:
            con.execute("vacuum")
    after = con.execute("select count(*) from messages").fetchone()[0]
    size = os.path.getsize(db_path)
    con.close()
except Exception as exc:  # noqa: BLE001 - reported verbatim to the operator
    print("ERROR=%s: %s" % (type(exc).__name__, exc))
    sys.exit(1)

print("STATUS=ok")
print("CUTOFF=%s" % cutoff)
print("RETENTION_DAYS=%d" % days)
print("TOTAL_BEFORE=%d" % before)
print("DOOMED=%d" % doomed)
print("DELETED=%d" % deleted)
print("TOTAL_AFTER=%d" % after)
print("OLDEST_DOOMED=%s" % (span[0] or "-"))
print("NEWEST_DOOMED=%s" % (span[1] or "-"))
print("KEEP_FLOOR=%d" % min(keep, before))
print("DB_BYTES=%d" % size)
print("VACUUMED=%d" % (1 if (vacuum and deleted) else 0))
PY
)" || rc=$?

c() { printf '%s\n' "$result" | sed -n "s/^$1=//p" | head -1; }

if [ "$rc" -ne 0 ] || [ "$(c STATUS)" != "ok" ]; then
  fatal "sweep failed (exit ${rc}): $(c ERROR)${result:+(output: $(printf '%s' "$result" | tr '\n' ' '))}"
fi

cutoff="$(c CUTOFF)"
before="$(c TOTAL_BEFORE)"
doomed="$(c DOOMED)"
deleted="$(c DELETED)"
after="$(c TOTAL_AFTER)"
oldest="$(c OLDEST_DOOMED)"
newest="$(c NEWEST_DOOMED)"
floor="$(c KEEP_FLOOR)"
bytes="$(c DB_BYTES)"
vacuumed="$(c VACUUMED)"

# --------------------------------------------------------------------------- #
# Report
# --------------------------------------------------------------------------- #

if [ -n "$DRY_RUN" ]; then
  line="$(timestamp) DRY-RUN retention: total=${before} would-delete=${doomed} keep-floor=${floor} retention=${RETENTION_DAYS}d"
  echo "$line" >> "$LOG"
  echo "$line"
  exit 0
fi

line="$(timestamp) OK retention: total=${before} deleted=${deleted} remaining=${after} keep-floor=${floor} retention=${RETENTION_DAYS}d vacuumed=${vacuumed} db=${bytes}B"
echo "$line" >> "$LOG"
echo "$line"

# --------------------------------------------------------------------------- #
# Notify — only when rows were actually pruned
# --------------------------------------------------------------------------- #

if [ "$deleted" -gt 0 ]; then
  send_sweep_alerts "Gotify alert history pruned — ${HOST}" \
    "Deleted ${deleted} Gotify message(s) older than ${RETENTION_DAYS} days.

Remaining:  ${after} message(s) (kept the newest ${floor} as a floor)
Deleted:    ${oldest} → ${newest}
Database:   ${GOTIFY_DB} (${bytes} bytes)"
  # Only claim delivery when a channel was actually configured to receive it.
  if [ -n "${GOTIFY_URL:-}" ] && [ -n "${GOTIFY_APP_TOKEN:-}" ]; then
    echo "$(timestamp) ALERT retention summary sent: deleted=${deleted}" >> "$LOG"
  else
    echo "$(timestamp) NOTE retention summary not sent: no Gotify credentials configured" >> "$LOG"
  fi
fi

exit 0
