#!/usr/bin/env bash
# test_gotify_retention_sweep.sh
#
# Hermetic test for gotify-retention-sweep.sh.
#
# The sweep performs its DELETE inside a one-shot container because the Gotify
# database is root-owned on the host.  This test replaces `docker` with a stub
# that runs the piped Python locally, translating the `-v` mount and the `-e`
# variables back onto the host fixture — so the real pruning logic (predicate,
# keep-floor, VACUUM, reporting, failure handling) is exercised end to end
# without touching a container, the live database, or the network.
#
# Usage:
#   tool/test_gotify_retention_sweep.sh
#   SWEEP=~/bin/gotify-retention-sweep.sh tool/test_gotify_retention_sweep.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEP="${SWEEP:-$SCRIPT_DIR/gotify-retention-sweep.sh}"

if [ ! -f "$SWEEP" ]; then
  echo "FATAL: sweep not found at $SWEEP" >&2
  exit 2
fi
if [ ! -f "$(dirname "$SWEEP")/alert.sh" ]; then
  echo "FATAL: alert.sh not found beside $SWEEP" >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "FATAL: python3 is required to build the fixture" >&2
  exit 2
fi

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/home" "$SANDBOX/all-bin" "$SANDBOX/min-bin" "$SANDBOX/db"

pass=0
fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi
}
assert_present() { # <label> <file> <needle>
  if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1 (missing '$3' in ${2##*/})"; fi
}
assert_absent() { # <label> <file> <needle>
  if grep -qF -- "$3" "$2" 2>/dev/null; then bad "$1 (found '$3' in ${2##*/})"; else ok "$1"; fi
}

# --------------------------------------------------------------------------- #
# Stubs
# --------------------------------------------------------------------------- #

# Emulates enough of `docker` for the sweep: `image inspect` reports presence,
# and `run` executes the piped interpreter locally with the -v mount mapped
# back to its host path and the -e variables applied.
cat > "$SANDBOX/all-bin/docker" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$DOCKER_LOG"
if [ "${1:-}" = "image" ] && [ "${2:-}" = "inspect" ]; then
  [ "${STUB_IMAGE_PRESENT:-1}" = "1" ] && exit 0
  exit 1
fi
[ "${1:-}" = "run" ] || { echo "stub docker: unsupported: $*" >&2; exit 64; }
shift
mounts=(); envs=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --rm|-i|--interactive|--tty) shift ;;
    --network) shift 2 ;;
    -v|--volume) mounts+=("$2"); shift 2 ;;
    -e|--env) envs+=("$2"); shift 2 ;;
    *) break ;;
  esac
done
image="$1"; shift
[ "${1:-}" = "python3" ] && shift
[ "${1:-}" = "-" ] && shift

resolve() { # container path -> host path
  local p="$1" m host cont
  for m in ${mounts[@]+"${mounts[@]}"}; do
    host="${m%%:*}"; cont="${m#*:}"; cont="${cont%%:*}"
    case "$p" in
      "$cont"/*) printf '%s/%s' "$host" "${p#"$cont"/}"; return 0 ;;
    esac
  done
  printf '%s' "$p"
}

resolved=()
for e in ${envs[@]+"${envs[@]}"}; do
  key="${e%%=*}"; val="${e#*=}"
  case "$val" in /*) val="$(resolve "$val")" ;; esac
  resolved+=("${key}=${val}")
done

exec env ${resolved[@]+"${resolved[@]}"} python3 -
STUB
chmod +x "$SANDBOX/all-bin/docker"

cat > "$SANDBOX/all-bin/curl" <<'STUB'
#!/usr/bin/env bash
printf -- '--- curl call ---\n' >> "$CURL_LOG"
for arg in "$@"; do printf '%s\n' "$arg" >> "$CURL_LOG"; done
exit 0
STUB
chmod +x "$SANDBOX/all-bin/curl"

PATH_ALL="$SANDBOX/all-bin:/usr/local/bin:/usr/bin:/bin"

# The no-docker phase must not find a real docker *anywhere* — including one
# installed on the host, which a plain "/usr/bin:/bin" would still expose.
# It gets a minimal PATH of symlinks to just the utilities the sweep needs,
# plus the curl stub for capturing the alert.
for tool in bash sh env python3 sed head tail tr cat cut mkdir basename \
            dirname date grep wc printf stat awk rm sort; do
  target="$(command -v "$tool" 2>/dev/null)" && ln -sf "$target" "$SANDBOX/min-bin/$tool"
done
cp "$SANDBOX/all-bin/curl" "$SANDBOX/min-bin/curl"
PATH_NO_DOCKER="$SANDBOX/min-bin"

# --------------------------------------------------------------------------- #
# Fixture: five messages — three older than 30 days, two recent
# --------------------------------------------------------------------------- #

DB="$SANDBOX/db/gotify.db"

build_fixture() {
  rm -f "$DB" "$SANDBOX/db/gotify.db-journal"
  python3 - "$DB" <<'PY'
import sqlite3
import sys
from datetime import datetime, timedelta, timezone

con = sqlite3.connect(sys.argv[1])
con.executescript(
    """
    create table applications (
        id integer primary key autoincrement, token text, user_id integer,
        name text, description text, internal integer, image text,
        default_priority integer, last_used text, sort_key text);
    create table messages (
        id integer primary key autoincrement, application_id integer,
        message text, title text, priority integer, extras text, date text);
    """
)
con.execute(
    "insert into applications (id, token, name) values (1, 'tok', 'jwt-alerts')"
)
now = datetime.now(timezone.utc)


def stamp(days_ago=0, minutes_ago=0):
    when = now - timedelta(days=days_ago, minutes=minutes_ago)
    return when.strftime("%Y-%m-%d %H:%M:%S.%f") + "+00:00"


rows = [
    (1, "JWT Secret Drift Detected \u2014 testvm", 8, stamp(days_ago=60)),
    (2, "JWT Daily Summary \u2014 testvm", 5, stamp(days_ago=40)),
    (3, "JWT Revert + Auto Re-cut \u2014 testvm", 8, stamp(days_ago=35)),
    (4, "JWT Daily Summary \u2014 testvm", 5, stamp(days_ago=1)),
    (5, "JWT Daily Summary \u2014 testvm", 5, stamp(minutes_ago=60)),
]
con.executemany(
    "insert into messages (id, application_id, message, title, priority, extras, date) "
    "values (?, 1, 'body', ?, ?, '{}', ?)",
    rows,
)
con.commit()
con.close()
PY
}

row_count() {
  python3 -c "
import sqlite3, sys
print(sqlite3.connect(sys.argv[1]).execute('select count(*) from messages').fetchone()[0])
" "$DB"
}
row_ids() {
  python3 -c "
import sqlite3, sys
print(sorted(r[0] for r in sqlite3.connect(sys.argv[1]).execute('select id from messages')))
" "$DB"
}

# --------------------------------------------------------------------------- #
# Harness
# --------------------------------------------------------------------------- #

EXTRA_ENV=()

# run_sweep <tag> <path> <image-present> [sweep args...]
#   EXTRA_ENV (applied last, so it can override the defaults) carries any
#   per-phase configuration such as KEEP_NEWEST, VACUUM or a bad GOTIFY_DB.
run_sweep() {
  local tag="$1" path="$2" image="$3"
  shift 3
  TAG_LOG="$SANDBOX/$tag.sweep.log"
  CURL_LOG="$SANDBOX/$tag.curl.log"
  DOCKER_LOG="$SANDBOX/$tag.docker.log"
  env -i PATH="$path" HOME="$SANDBOX/home" HOST="testhost" \
    GOTIFY_DB="$DB" LOG="$TAG_LOG" \
    GOTIFY_URL="https://gotify.invalid" GOTIFY_APP_TOKEN="test-token" \
    CURL_LOG="$CURL_LOG" DOCKER_LOG="$DOCKER_LOG" STUB_IMAGE_PRESENT="$image" \
    ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
    "$SWEEP" "$@" < /dev/null
}

curl_calls() { [ -f "$CURL_LOG" ] && grep -c -- '--- curl call ---' "$CURL_LOG" || echo 0; }

echo "Sweep:   $SWEEP"
echo "Sandbox: $SANDBOX"
echo

# --------------------------------------------------------------------------- #
# Phase 1: prunes old messages and notifies
# --------------------------------------------------------------------------- #

echo "Phase 1: prunes messages older than the retention window"

build_fixture
EXTRA_ENV=(KEEP_NEWEST=1)
rc=0
run_sweep prune "$PATH_ALL" 1 > "$SANDBOX/prune.out" 2>&1 || rc=$?

assert_eq "sweep exits 0" "$rc" "0"
assert_eq "the three stale messages are deleted" "$(row_count)" "2"
assert_eq "the two recent messages survive" "$(row_ids)" "[4, 5]"
assert_eq "exactly one alert is sent" "$(curl_calls "$CURL_LOG")" "1"
assert_present "alert reports the deleted count" "$CURL_LOG" "Deleted 3 Gotify message(s) older than 30 days."
assert_present "alert reports the remaining count" "$CURL_LOG" "Remaining:  2 message(s)"
assert_present "alert states the retention window" "$CURL_LOG" "older than 30 days"
assert_present "the sweep is logged" "$TAG_LOG" "OK retention: total=5 deleted=3 remaining=2"
assert_present "the log records the active floor" "$TAG_LOG" "keep-floor=1"
assert_present "the notification is logged" "$TAG_LOG" "ALERT retention summary sent: deleted=3"
assert_present "the container is asked for the image first" "$DOCKER_LOG" "image inspect python:3-alpine"
assert_present "the container runs without network access" "$DOCKER_LOG" "--network none"

# --------------------------------------------------------------------------- #
# Phase 2: nothing old enough -> silence
# --------------------------------------------------------------------------- #

echo
echo "Phase 2: stays silent when nothing is old enough"

build_fixture
EXTRA_ENV=(KEEP_NEWEST=1 RETENTION_DAYS=365)
rc=0
run_sweep stale "$PATH_ALL" 1 > /dev/null 2>&1 || rc=$?

assert_eq "run exits 0" "$rc" "0"
assert_eq "nothing is deleted" "$(row_count)" "5"
assert_eq "no alert is sent" "$(curl_calls "$CURL_LOG")" "0"
assert_absent "no ALERT line is logged" "$TAG_LOG" "ALERT retention summary sent"
assert_present "the silent sweep is still audited" "$TAG_LOG" "OK retention: total=5 deleted=0 remaining=5"

# --------------------------------------------------------------------------- #
# Phase 3: dry run deletes nothing and never notifies
# --------------------------------------------------------------------------- #

echo
echo "Phase 3: dry run reports without deleting"

build_fixture
EXTRA_ENV=(KEEP_NEWEST=1)
rc=0
run_sweep dry "$PATH_ALL" 1 --dry-run > "$SANDBOX/dry.out" 2>&1 || rc=$?

assert_eq "dry run exits 0" "$rc" "0"
assert_eq "dry run deletes nothing" "$(row_count)" "5"
assert_eq "dry run sends no alert" "$(curl_calls "$CURL_LOG")" "0"
assert_present "dry run reports what it would delete" "$TAG_LOG" "DRY-RUN retention: total=5 would-delete=3"
assert_absent "dry run logs no ALERT line" "$TAG_LOG" "ALERT retention summary sent"

# --------------------------------------------------------------------------- #
# Phase 4: the keep-floor protects the newest rows
# --------------------------------------------------------------------------- #

echo
echo "Phase 4: the keep-floor protects the newest rows"

build_fixture
EXTRA_ENV=(KEEP_NEWEST=3)
rc=0
run_sweep floor "$PATH_ALL" 1 > /dev/null 2>&1 || rc=$?

assert_eq "floor run exits 0" "$rc" "0"
assert_eq "the floor spares the 35-day-old row" "$(row_ids)" "[3, 4, 5]"
assert_present "the log records the active floor" "$TAG_LOG" "keep-floor=3"
assert_present "only the unprotected stale rows are pruned" "$TAG_LOG" "deleted=2"

build_fixture
EXTRA_ENV=(KEEP_NEWEST=99)
rc=0
run_sweep floorbig "$PATH_ALL" 1 > /dev/null 2>&1 || rc=$?

assert_eq "an oversized floor deletes nothing" "$(row_count)" "5"
assert_eq "an oversized floor sends no alert" "$(curl_calls "$CURL_LOG")" "0"
assert_present "an oversized floor reports a zero sweep" "$TAG_LOG" "deleted=0"

# --------------------------------------------------------------------------- #
# Phase 5: VACUUM is opt-in
# --------------------------------------------------------------------------- #

echo
echo "Phase 5: VACUUM is opt-in"

build_fixture
EXTRA_ENV=(KEEP_NEWEST=1)
rc=0
run_sweep novacuum "$PATH_ALL" 1 > /dev/null 2>&1 || rc=$?
assert_present "no VACUUM by default" "$TAG_LOG" "vacuumed=0"

build_fixture
EXTRA_ENV=(KEEP_NEWEST=1 VACUUM=1)
rc=0
run_sweep vacuum "$PATH_ALL" 1 > /dev/null 2>&1 || rc=$?
assert_eq "vacuum run exits 0" "$rc" "0"
assert_eq "vacuum still prunes correctly" "$(row_count)" "2"
assert_present "VACUUM is recorded when requested" "$TAG_LOG" "vacuumed=1"

build_fixture
EXTRA_ENV=(KEEP_NEWEST=1 GOTIFY_URL= GOTIFY_APP_TOKEN=)
rc=0
run_sweep nochannel "$PATH_ALL" 1 > /dev/null 2>&1 || rc=$?
assert_eq "pruning works without an alert channel" "$rc" "0"
assert_eq "rows are pruned without an alert channel" "$(row_count)" "2"
assert_eq "no alert is attempted without credentials" "$(curl_calls "$CURL_LOG")" "0"
assert_present "the log admits nothing was sent" "$TAG_LOG" \
  "NOTE retention summary not sent: no Gotify credentials configured"
assert_absent "the log does not claim a send" "$TAG_LOG" "ALERT retention summary sent"

# --------------------------------------------------------------------------- #
# Phase 6: failures are loud and alerted
# --------------------------------------------------------------------------- #

echo
echo "Phase 6: failures are logged and alerted"

build_fixture
EXTRA_ENV=(KEEP_NEWEST=1)
rc=0
run_sweep nodocker "$PATH_NO_DOCKER" 1 > "$SANDBOX/nodocker.out" 2>&1 || rc=$?
assert_eq "a missing docker exits 1" "$rc" "1"
assert_eq "a missing docker deletes nothing" "$(row_count)" "5"
assert_present "the failure is logged as FATAL" "$TAG_LOG" "FATAL docker is required"
assert_eq "the failure is alerted" "$(curl_calls "$CURL_LOG")" "1"
assert_present "the alert names the sweep failure" "$CURL_LOG" "Gotify retention sweep FAILED"
assert_present "the failure alert is high priority" "$CURL_LOG" "priority=8"

build_fixture
EXTRA_ENV=(KEEP_NEWEST=1)
rc=0
run_sweep noimage "$PATH_ALL" 0 > "$SANDBOX/noimage.out" 2>&1 || rc=$?
assert_eq "a missing image exits 1" "$rc" "1"
assert_present "the missing image is named" "$TAG_LOG" "sweep image not available: python:3-alpine"
assert_present "the remedy is suggested" "$TAG_LOG" "docker pull python:3-alpine"
assert_eq "a missing image deletes nothing" "$(row_count)" "5"

EXTRA_ENV=(GOTIFY_DB="$SANDBOX/does-not-exist.db")
rc=0
run_sweep nodb "$PATH_ALL" 1 > /dev/null 2>&1 || rc=$?
assert_eq "a missing database exits 1" "$rc" "1"
assert_present "the missing database is named" "$TAG_LOG" "database not found"

# --------------------------------------------------------------------------- #
# Phase 7: usage and configuration errors
# --------------------------------------------------------------------------- #

echo
echo "Phase 7: usage and configuration errors"

rc=0
"$SWEEP" --bogus > "$SANDBOX/usage.out" 2>&1 || rc=$?
assert_eq "an unknown option exits 2" "$rc" "2"
assert_present "the unknown option is echoed" "$SANDBOX/usage.out" "unknown option: --bogus"

rc=0
env -i PATH="$PATH_ALL" HOME="$SANDBOX/home" RETENTION_DAYS="soon" \
  LOG="$SANDBOX/cfg.log" "$SWEEP" < /dev/null > "$SANDBOX/cfg.out" 2>&1 || rc=$?
assert_eq "a non-numeric retention exits 2" "$rc" "2"
assert_present "the bad retention is explained" "$SANDBOX/cfg.out" "non-negative integer"

rc=0
env -i PATH="$PATH_ALL" HOME="$SANDBOX/home" KEEP_NEWEST="-1" \
  LOG="$SANDBOX/cfg2.log" "$SWEEP" < /dev/null > "$SANDBOX/cfg2.out" 2>&1 || rc=$?
assert_eq "a negative keep-floor exits 2" "$rc" "2"

rc=0
"$SWEEP" --help > "$SANDBOX/help.out" 2>&1 || rc=$?
assert_eq "--help exits 0" "$rc" "0"
assert_present "--help documents the retention window" "$SANDBOX/help.out" "RETENTION_DAYS"
assert_present "--help documents the container requirement" "$SANDBOX/help.out" "SWEEP_IMAGE"

# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #

echo
echo "-------------------------------------------------------------"
if [ "$fail" -eq 0 ]; then
  echo "=== TEST PASSED ($pass checks) ==="
  exit 0
fi
echo "=== TEST FAILED ($fail failed, $pass passed) ==="
exit 1
