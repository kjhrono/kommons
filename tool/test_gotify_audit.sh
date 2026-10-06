#!/usr/bin/env bash
# test_gotify_audit.sh
#
# Hermetic test for gotify-messages.sh, the Docker-free Gotify delivery
# audit.  Builds a synthetic gotify.db fixture in a throwaway sandbox and
# exercises every filter and output mode against it.  Nothing on the real
# host is read or written, and a failing `docker` stub on PATH proves the
# audit never shells out to Docker.
#
# Usage:
#   tool/test_gotify_audit.sh
#   GOTIFY_AUDIT=~/bin/gotify-messages.sh tool/test_gotify_audit.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# Prefer a copy of the audit script beside this test (the deployed layout in
# ~/bin); fall back to the in-repo tool/ directory.
if [ -f "${SCRIPT_DIR}/gotify-messages.sh" ]; then
  AUDIT="${GOTIFY_AUDIT:-${SCRIPT_DIR}/gotify-messages.sh}"
else
  AUDIT="${GOTIFY_AUDIT:-$REPO_ROOT/tool/gotify-messages.sh}"
fi

if [ ! -f "$AUDIT" ]; then
  echo "FATAL: audit script not found at $AUDIT" >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "FATAL: python3 is required to build the fixture" >&2
  exit 2
fi

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# The database lives in its own directory so the read-only assertion can
# prove nothing (not even a -wal/-shm sidecar) is written beside it.
DBDIR="$SANDBOX/db"
mkdir -p "$DBDIR"
DB="$DBDIR/gotify.db"

pass=0
fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi
}
assert_present() { # <label> <file> <needle>
  if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1 (missing '$3' in $2)"; fi
}
assert_absent() { # <label> <file> <needle>
  if grep -qF -- "$3" "$2" 2>/dev/null; then bad "$1 (found '$3' in $2)"; else ok "$1"; fi
}
assert_line_count() { # <label> <file> <expected-lines>
  local got
  got="$(wc -l < "$2" | tr -d ' ')"
  assert_eq "$1" "$got" "$3"
}
assert_between() { # <label> <value> <min> <max>
  if [ "$2" -ge "$3" ] 2>/dev/null && [ "$2" -le "$4" ] 2>/dev/null; then
    ok "$1"
  else
    bad "$1 (got '$2', want $3..$4)"
  fi
}
assert_matches() { # <label> <file> <extended-regex>
  if grep -qE -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1 (no line matching /$3/)"; fi
}

# A `docker` stub that hard-fails if anything calls it: the audit must be
# usable with no Docker access at all.
STUB_BIN="$SANDBOX/stubbin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/docker" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$SANDBOX/docker.log"
echo "docker: access denied (audit must not touch docker)" >&2
exit 1
STUB
chmod +x "$STUB_BIN/docker"
export PATH="$STUB_BIN:$PATH"
export DOCKER_LOG="$SANDBOX/docker.log"

# --------------------------------------------------------------------------- #
# Fixture: a miniature Gotify database
# --------------------------------------------------------------------------- #

python3 - "$DB" <<'PY'
import sqlite3
import sys
from datetime import datetime, timedelta, timezone

db = sys.argv[1]
con = sqlite3.connect(db)
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
    "insert into applications (id, token, name, default_priority) values (1, 'app-one-token', 'jwt-alerts', 5)"
)
con.execute(
    "insert into applications (id, token, name, default_priority) values (2, 'app-two-token', 'other-app', 5)"
)

now = datetime.now(timezone.utc)


def stamp(minutes_ago, digits=6):
    dt = now - timedelta(minutes=minutes_ago)
    base = dt.strftime("%Y-%m-%d %H:%M:%S.%f")
    if digits > 6:
        base += "0" * (digits - 6)
    return base + "+00:00"


rows = [
    (1, 1, "drift body", "JWT Secret Drift Detected \u2014 testvm", 8, stamp(180, digits=9)),
    (2, 1, "summary body", "JWT Daily Summary \u2014 testvm", 5, stamp(120)),
    (3, 2, "other body", "Other App Alert", 8, stamp(90)),
    (4, 1, "summary body", "JWT Daily Summary \u2014 testvm", 5, stamp(10)),
    (5, 1, "REVERT\nre-cut kalcio", "JWT Revert + Auto Re-cut \u2014 testvm", 8, stamp(5, digits=9)),
]
con.executemany(
    "insert into messages (id, application_id, message, title, priority, extras, date) "
    "values (?, ?, ?, ?, ?, '{}', ?)",
    rows,
)
con.commit()
con.close()
print(f"fixture built: {len(rows)} messages")
PY

if [ ! -s "$DB" ]; then
  echo "FATAL: fixture database was not created" >&2
  exit 2
fi
BEFORE_HASH="$(sha256sum "$DB" | cut -d' ' -f1)"
BEFORE_FILES="$(ls -1 "$DBDIR" | sort)"

run() { # run with GOTIFY_DB pointing at the fixture; stdout -> $OUT
  GOTIFY_DB="$DB" "$AUDIT" "$@"
}

echo "Audit script: $AUDIT"
echo "Fixture:      $DB"
echo

# --------------------------------------------------------------------------- #
# Phase 1: default table
# --------------------------------------------------------------------------- #

echo "Phase 1: default listing"

OUT="$SANDBOX/table.out"
ERR="$SANDBOX/table.err"
rc=0
run > "$OUT" 2> "$ERR" || rc=$?
assert_eq "default run exits 0" "$rc" "0"
assert_present "table has an ID/PRI header" "$OUT" "PRI"
assert_present "table shows the newest (revert) title first" "$OUT" "JWT Revert + Auto Re-cut"
assert_present "table shows the daily-summary title" "$OUT" "JWT Daily Summary"
assert_present "table shows the application name" "$OUT" "jwt-alerts"
assert_present "table shows a priority value" "$OUT" "8"
assert_present "table renders an age column" "$OUT" "AGE"
assert_present "footer reports row count and read mode" "$ERR" "message(s) in"
assert_present "footer confirms read-only access" "$ERR" "read"
# Newest-first ordering: the revert row (id 5) must appear before the drift row (id 1).
revert_line="$(grep -n "JWT Revert" "$OUT" | cut -d: -f1)"
drift_line="$(grep -n "JWT Secret Drift" "$OUT" | cut -d: -f1)"
if [ -n "$revert_line" ] && [ -n "$drift_line" ] && [ "$revert_line" -lt "$drift_line" ]; then
  ok "messages are listed newest-first"
else
  bad "messages are listed newest-first (revert=$revert_line drift=$drift_line)"
fi

# --------------------------------------------------------------------------- #
# Phase 2: filters and limits
# --------------------------------------------------------------------------- #

echo
echo "Phase 2: filters and limits"

rc=0
run -n 2 > "$OUT" 2> "$ERR" || rc=$?
assert_eq "--limit 2 exits 0" "$rc" "0"
assert_line_count "--limit 2 shows header + 2 rows" "$OUT" "4"
assert_absent "--limit 2 drops the oldest row" "$OUT" "JWT Secret Drift Detected"
assert_present "--limit 2 keeps the newest row" "$OUT" "JWT Revert"

rc=0
run --priority 8 > "$OUT" 2> "$ERR" || rc=$?
assert_eq "--priority 8 exits 0" "$rc" "0"
assert_present "--priority 8 keeps drift" "$OUT" "JWT Secret Drift Detected"
assert_present "--priority 8 keeps revert" "$OUT" "JWT Revert"
assert_present "--priority 8 keeps the other app row" "$OUT" "Other App Alert"
assert_absent "--priority 8 drops priority-5 rows" "$OUT" "Daily Summary"

rc=0
run --min-priority 6 > "$OUT" 2> "$ERR" || rc=$?
assert_eq "--min-priority 6 exits 0" "$rc" "0"
assert_line_count "--min-priority 6 shows only the 3 high-priority rows" "$OUT" "5"

rc=0
run --app other-app > "$OUT" 2> "$ERR" || rc=$?
assert_eq "--app filter exits 0" "$rc" "0"
assert_line_count "--app other-app shows exactly one row" "$OUT" "3"
assert_present "--app other-app keeps its row" "$OUT" "Other App Alert"
assert_absent "--app other-app drops jwt-alerts rows" "$OUT" "Daily Summary"

rc=0
run --title SUMMARY > "$OUT" 2> "$ERR" || rc=$?
assert_eq "--title is case-insensitive" "$rc" "0"
assert_line_count "--title SUMMARY matches both summaries" "$OUT" "4"
assert_absent "--title SUMMARY drops non-matching rows" "$OUT" "Other App Alert"

rc=0
run --since 60 > "$OUT" 2> "$ERR" || rc=$?
assert_eq "--since 60 exits 0" "$rc" "0"
assert_line_count "--since 60 keeps only the last hour of rows" "$OUT" "4"
assert_absent "--since 60 drops the 90-minute-old row" "$OUT" "Other App Alert"
assert_present "--since 60 keeps the 5-minute-old row" "$OUT" "JWT Revert"

rc=0
run --priority 5,8 --min-priority 8 > "$OUT" 2> "$ERR" || rc=$?
assert_eq "combined filters exit 0" "$rc" "0"
assert_line_count "combined filters intersect (priority>=8)" "$OUT" "5"

rc=0
run --title "no such title" > "$OUT" 2> "$ERR" || rc=$?
assert_eq "no-match exits 0" "$rc" "0"
assert_absent "no-match prints no rows" "$OUT" "JWT"
assert_present "no-match explains itself on stderr" "$ERR" "no messages matched"

# --------------------------------------------------------------------------- #
# Phase 3: output modes
# --------------------------------------------------------------------------- #

echo
echo "Phase 3: machine-readable output"

rc=0
run --json > "$OUT" 2> "$ERR" || rc=$?
assert_eq "--json exits 0" "$rc" "0"
python3 - "$OUT" > "$SANDBOX/json.check" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
assert isinstance(data, list), "top level must be a list"
assert len(data) == 5, f"want 5 records, got {len(data)}"
assert {"id", "date", "priority", "app", "title", "message"} <= set(data[0]), "missing keys"
assert data[0]["title"].startswith("JWT Revert"), "not newest-first"
assert data[0]["priority"] == 8, "priority not preserved"
print("json ok")
PY
if grep -q "json ok" "$SANDBOX/json.check"; then
  ok "--json is a valid 5-record array with the documented keys"
else
  bad "--json output failed validation: $(cat "$SANDBOX/json.check")"
fi

rc=0
run --count > "$OUT" 2> "$ERR" || rc=$?
assert_eq "--count exits 0" "$rc" "0"
assert_eq "--count prints the integer only" "$(cat "$OUT")" "5"

rc=0
run --count --min-priority 8 > "$OUT" 2> "$ERR" || rc=$?
assert_eq "--count honours filters" "$(cat "$OUT")" "3"

rc=0
run --counts > "$OUT" 2> "$ERR" || rc=$?
assert_eq "--counts exits 0" "$rc" "0"
assert_present "--counts reports the total" "$OUT" "total: 5 message(s) matched"
assert_present "--counts breaks down by priority" "$OUT" "by priority:"
assert_present "--counts breaks down by app" "$OUT" "by app:"
assert_present "--counts reports the newest delivery" "$OUT" "newest:"
assert_present "--counts reports the oldest delivery" "$OUT" "oldest:"
assert_present "--counts counts the other app" "$OUT" "other-app  x1"

rc=0
run -n 1 --message > "$OUT" 2> "$ERR" || rc=$?
assert_eq "--message exits 0" "$rc" "0"
assert_present "--message prints the multi-line body" "$OUT" "re-cut kalcio"

rc=0
run --title "JWT Revert" --age-seconds > "$OUT" 2> "$ERR" || rc=$?
assert_eq "--age-seconds exits 0" "$rc" "0"
assert_between "--age-seconds reports the ~5-minute age of the newest match" "$(cat "$OUT")" 290 420

rc=0
run --app other-app --limit 1 --age-seconds > "$OUT" 2> "$ERR" || rc=$?
assert_between "--age-seconds ignores --limit and filters by the given app" "$(cat "$OUT")" 5300 5500

rc=0
run --title "no such title" --age-seconds > "$OUT" 2> "$ERR" || rc=$?
assert_eq "--age-seconds exits 0 with no match" "$rc" "0"
assert_eq "--age-seconds prints -1 when nothing matches" "$(cat "$OUT")" "-1"

rc=0
run --age-seconds --json > "$OUT" 2> "$ERR" || rc=$?
assert_eq "--age-seconds conflicts with --json" "$rc" "2"

# --------------------------------------------------------------------------- #
# Phase 4: alert-history report
# --------------------------------------------------------------------------- #

echo
echo "Phase 4: alert-history report"

rc=0
run --report > "$OUT" 2> "$ERR" || rc=$?
assert_eq "--report exits 0" "$rc" "0"
assert_present "report has a title" "$OUT" "Gotify alert report"
assert_present "report states the range" "$OUT" "Range:"
assert_present "report counts every fixture message" "$OUT" "Matched: 5 of 5 message(s)"
assert_present "report ranks monitors" "$OUT" "By monitor (fires most first)"
assert_present "report names the busiest monitor" "$OUT" "busiest: JWT Daily Summary (2)"
assert_present "report lists every monitor that fired" "$OUT" "JWT Secret Drift Detected"
assert_present "report lists the non-JWT monitor" "$OUT" "Other App Alert"
assert_present "report buckets volume over time" "$OUT" "Volume over time (15m buckets, UTC)"
assert_matches "volume buckets land on wall-clock boundaries" "$OUT" \
  '^  [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:(00|15|30|45)  '
assert_present "report marks the peak bucket" "$OUT" "peak:"
assert_present "report breaks down by priority" "$OUT" "By priority"
assert_present "report breaks down by app" "$OUT" "By app"
assert_present "report counts jwt-alerts deliveries" "$OUT" "jwt-alerts  x4"
assert_present "report counts other-app deliveries" "$OUT" "other-app  x1"
# The bars show the shape of the alert stream; the comparison says which way it
# is going.  Every fixture message is recent, so the preceding window is only
# partly covered and the report must admit that rather than read it as silence.
assert_present "report compares against the preceding window" "$OUT" \
  "By monitor vs previous window"
assert_present "the comparison states the preceding window's range" "$OUT" "Previous:"
assert_present "the comparison caveats a window older than the history" "$OUT" \
  "partly covered"
assert_present "the comparison ends with a liftable trend line" "$OUT" \
  "trend: up 0 → 5 (from none) — 4 rose, 0 fell"

rc=0
run --report --limit 1 > "$OUT" 2> "$ERR" || rc=$?
assert_present "--report ignores --limit" "$OUT" "Matched: 5 of 5 message(s)"

rc=0
run --report --min-priority 8 > "$OUT" 2> "$ERR" || rc=$?
assert_present "--report honours the priority filter" "$OUT" "Matched: 3 of 5 message(s)"
assert_present "a tie is reported honestly rather than arbitrarily" "$OUT" \
  "busiest: no clear leader — 3 monitors tied at 1"

rc=0
run --report --since-hours 1 > "$OUT" 2> "$ERR" || rc=$?
assert_eq "--since-hours exits 0" "$rc" "0"
assert_present "--since-hours 1 narrows the report to the last hour" "$OUT" "Matched: 2 of 5 message(s)"

rc=0
run --report --since 60 > "$OUT" 2> "$ERR" || rc=$?
assert_present "--since 60 agrees with --since-hours 1" "$OUT" "Matched: 2 of 5 message(s)"

rc=0
run --report --since-hours abc > "$OUT" 2> "$ERR" || rc=$?
assert_eq "a non-numeric --since-hours exits 2" "$rc" "2"

rc=0
run --report --title "no such title" > "$OUT" 2> "$ERR" || rc=$?
assert_eq "an empty report exits 0" "$rc" "0"
assert_present "an empty report says so" "$OUT" "No messages matched"
assert_present "an empty report still states the range" "$OUT" "Range:"

rc=0
run --report --count > "$OUT" 2> "$ERR" || rc=$?
assert_eq "--report conflicts with --count" "$rc" "2"

# --------------------------------------------------------------------------- #
# Phase 5: database path, errors and safety
# --------------------------------------------------------------------------- #

echo
echo "Phase 5: paths, errors and safety"

rc=0
run --db "$DB" -n 1 > "$OUT" 2> "$ERR" || rc=$?
assert_eq "--db flag exits 0" "$rc" "0"
assert_present "--db flag uses the given database" "$OUT" "JWT Revert"

export GOTIFY_DB="$DB"
rc=0
"$AUDIT" -n 1 > "$OUT" 2> "$ERR" || rc=$?
assert_eq "GOTIFY_DB env var is honoured" "$rc" "0"
assert_present "GOTIFY_DB run reads the fixture" "$OUT" "JWT Revert"
unset GOTIFY_DB

rc=0
GOTIFY_DB="$SANDBOX/does-not-exist.db" "$AUDIT" > "$OUT" 2> "$ERR" || rc=$?
assert_eq "missing database exits 1" "$rc" "1"
assert_present "missing database reports the path" "$ERR" "database not found"

rc=0
run --bogus > "$OUT" 2> "$ERR" || rc=$?
assert_eq "unknown option exits 2" "$rc" "2"
assert_present "unknown option is echoed" "$ERR" "unknown option: --bogus"

rc=0
run --limit -3 > "$OUT" 2> "$ERR" || rc=$?
assert_eq "non-numeric limit exits 2" "$rc" "2"
assert_present "non-numeric limit is explained" "$ERR" "non-negative integer"

rc=0
run --json --counts > "$OUT" 2> "$ERR" || rc=$?
assert_eq "conflicting output modes exit 2" "$rc" "2"
assert_present "conflicting modes are explained" "$ERR" "mutually exclusive"

rc=0
run --help > "$OUT" 2> "$ERR" || rc=$?
assert_eq "--help exits 0" "$rc" "0"
assert_present "--help documents the options" "$OUT" "--min-priority"
assert_present "--help documents the database default" "$OUT" "GOTIFY_DB"

AFTER_HASH="$(sha256sum "$DB" | cut -d' ' -f1)"
AFTER_FILES="$(ls -1 "$DBDIR" | sort)"
assert_eq "the database is never modified" "$AFTER_HASH" "$BEFORE_HASH"
assert_eq "no -wal/-shm sidecar is created beside the database" "$AFTER_FILES" "$BEFORE_FILES"

if [ -f "$SANDBOX/docker.log" ]; then
  bad "the audit invoked docker: $(cat "$SANDBOX/docker.log")"
else
  ok "the audit never invoked docker"
fi

# --------------------------------------------------------------------------- #
# Phase 6: the report states the direction of the trend
# --------------------------------------------------------------------------- #

echo
echo "Phase 6: the report compares the window with the preceding one"

# The bars under "Volume over time" show the shape of the alert stream, not its
# direction.  This fixture is built so the preceding window genuinely has data:
# five monitors that between them rise, fall, hold flat, appear and disappear.
DB2DIR="$SANDBOX/db2"
mkdir -p "$DB2DIR"
DB2="$DB2DIR/gotify.db"

python3 - "$DB2" <<'PY'
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
    "insert into applications (id, token, name, default_priority) values (1, 't', 'jwt-alerts', 5)"
)

now = datetime.now(timezone.utc)


def stamp(hours_ago):
    return (now - timedelta(hours=hours_ago)).strftime("%Y-%m-%d %H:%M:%S+00:00")


def add(title, hours):
    return [(1, "body", f"{title} \u2014 testvm", 8, stamp(h)) for h in hours]


rows = []
rows += add("JWT Secret Drift Detected", range(2, 14))   # 12 now, 3 before: rose
rows += add("JWT Secret Drift Detected", range(25, 28))
rows += add("JWT Daily Summary", range(1, 5))            # 4 now, 9 before: fell
rows += add("JWT Daily Summary", range(25, 34))
rows += add("JWT Alert Delivery Stalled", (5, 6))        # 2 now, 2 before: flat
rows += add("JWT Alert Delivery Stalled", (28, 29))
rows += add("Brand New Monitor", (7, 8, 9))              # 3 now, none before: new
rows += add("JWT Revert + Auto Re-cut", range(30, 35))   # none now, 5 before: gone
# Older than both windows: it must not enter either count, only prove the
# history reaches back far enough for the comparison to be fully covered.
rows += add("Ancient Monitor", (60,))
con.executemany(
    "insert into messages (application_id, message, title, priority, extras, date) "
    "values (?, ?, ?, ?, '{}', ?)",
    rows,
)
con.commit()
con.close()
print(f"trend fixture built: {len(rows)} messages")
PY

if [ ! -s "$DB2" ]; then
  echo "FATAL: trend fixture database was not created" >&2
  exit 2
fi

rc=0
GOTIFY_DB="$DB2" "$AUDIT" --since-hours 24 --report > "$OUT" 2> "$ERR" || rc=$?
assert_eq "the trend report exits 0" "$rc" "0"
assert_present "the trend report covers the window" "$OUT" "Matched: 21 of 41 message(s)"

TREND="$SANDBOX/trend.out"
sed -n '/^By monitor vs previous window/,/^  trend:/p' "$OUT" > "$TREND"
if [ -s "$TREND" ]; then
  ok "the report carries a preceding-window comparison"
else
  bad "the report carries a preceding-window comparison"
fi
assert_present "the comparison states the preceding window's range" "$TREND" "Previous:"
assert_absent "a fully covered comparison is not caveated" "$TREND" "partly covered"
assert_absent "an alert outside both windows enters neither count" "$TREND" "Ancient Monitor"

# Squeeze the column padding so the exact figures can be asserted.
tr -s ' ' < "$TREND" > "$TREND.sq"
assert_present "a monitor that rose is called out" "$TREND.sq" \
  "JWT Secret Drift Detected 3 → 12 +9 ▲"
assert_present "a monitor that fell is called out" "$TREND.sq" \
  "JWT Daily Summary 9 → 4 -5 ▼"
assert_present "an unchanged monitor is marked flat" "$TREND.sq" \
  "JWT Alert Delivery Stalled 2 → 2 +0 ="
assert_present "a monitor new in this window rises from zero" "$TREND.sq" \
  "Brand New Monitor 0 → 3 +3 ▲"
assert_present "a monitor gone from this window falls to zero" "$TREND.sq" \
  "JWT Revert + Auto Re-cut 5 → 0 -5 ▼"
assert_present "the trend line states the direction of the window total" "$TREND.sq" \
  "trend: up 19 → 21 (+11%) — 2 rose, 2 fell, 1 flat"

# The biggest mover leads, so the direction is the first thing read.
drift_line="$(grep -n "JWT Secret Drift Detected" "$TREND.sq" | cut -d: -f1)"
daily_line="$(grep -n "JWT Daily Summary" "$TREND.sq" | cut -d: -f1)"
if [ -n "$drift_line" ] && [ -n "$daily_line" ] && [ "$drift_line" -lt "$daily_line" ]; then
  ok "the biggest mover is listed first"
else
  bad "the biggest mover is listed first (drift=$drift_line daily=$daily_line)"
fi

# Silence is a direction too: a window that went quiet against a noisy one has
# to say so, or the most actionable trend of all reads as an empty report.
DB3="$SANDBOX/db3/silent.db"
mkdir -p "$(dirname "$DB3")"
python3 - "$DB3" <<'PY'
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
    "insert into applications (id, token, name, default_priority) values (1, 't', 'jwt-alerts', 5)"
)
now = datetime.now(timezone.utc)
rows = [
    (
        1,
        "body",
        "JWT Revert + Auto Re-cut \u2014 testvm",
        8,
        (now - timedelta(hours=h)).strftime("%Y-%m-%d %H:%M:%S+00:00"),
    )
    for h in range(30, 35)
]
con.executemany(
    "insert into messages (application_id, message, title, priority, extras, date) "
    "values (?, ?, ?, ?, '{}', ?)",
    rows,
)
con.commit()
con.close()
PY

rc=0
GOTIFY_DB="$DB3" "$AUDIT" --since-hours 24 --report > "$OUT" 2> "$ERR" || rc=$?
assert_eq "a silent window still exits 0" "$rc" "0"
assert_present "a silent window says it matched nothing" "$OUT" "No messages matched"
sed -n '/^By monitor vs previous window/,/^  trend:/p' "$OUT" | tr -s ' ' > "$TREND.sq"
assert_present "a silent window still states the direction" "$TREND.sq" \
  "trend: down 5 → 0 (-100%) — 0 rose, 1 fell"
assert_present "the fall is attributed to its monitor" "$TREND.sq" \
  "JWT Revert + Auto Re-cut 5 → 0 -5 ▼"

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
