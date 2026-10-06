#!/usr/bin/env bash
# test_liveness_check.sh
#
# Hermetic test for jwt-secret-liveness-check.sh, which catches a monitor that
# has stopped running by measuring the heartbeats in the shared log.
#
# The log fixtures and the stubbed curl/mail binaries are all controlled here,
# so every heartbeat age, every alert and every exit code is exact.  The
# behaviour that matters most is not the alert itself but WHEN it fires: a
# monitor that stays down must be reported once, not on every run, or the
# alert becomes noise and the real outage gets skimmed past.
#
# Usage:
#   tool/test_liveness_check.sh
#   CHECK=~/bin/jwt-secret-liveness-check.sh tool/test_liveness_check.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Prefer a copy sitting beside this test — the deployed ~/bin layout — and
# fall back to the in-repo tool/ directory.
if [ -f "${SCRIPT_DIR}/jwt-secret-liveness-check.sh" ]; then
  DEFAULT_DIR="$SCRIPT_DIR"
else
  DEFAULT_DIR="$REPO_ROOT/tool"
fi

CHECK="${CHECK:-$DEFAULT_DIR/jwt-secret-liveness-check.sh}"

if [ ! -f "$CHECK" ]; then
  echo "FATAL: liveness check not found at $CHECK" >&2
  exit 2
fi
if [ ! -f "$(dirname "$CHECK")/alert.sh" ]; then
  echo "FATAL: alert.sh not found beside $CHECK" >&2
  exit 2
fi

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/home/logs" "$SANDBOX/bin"

MONITOR_LOG="$SANDBOX/home/logs/jwt-secret-drift.log"

# curl is invoked with nothing on stdin, so it must NOT read stdin; mail
# receives the alert body on a pipe and drains it into the log.
cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf -- '--- curl call ---\n' >> "$CURL_LOG"
for arg in "$@"; do printf '%s\n' "$arg" >> "$CURL_LOG"; done
exit 0
STUB
cat > "$SANDBOX/bin/mail" <<'STUB'
#!/usr/bin/env bash
printf -- '--- mail call ---\n' >> "$MAIL_LOG"
cat >> "$MAIL_LOG"
exit 0
STUB
chmod +x "$SANDBOX/bin/curl" "$SANDBOX/bin/mail"

BASE_PATH="$SANDBOX/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

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

# --- harness --------------------------------------------------------------- #

CURL_LOG=""
MAIL_LOG=""
CHECK_LOG=""
STATE=""
MONITORS="drift-check revert-watchdog"
MAX_AGE_MINUTES=45
WEBHOOK="https://webhook.invalid/hook"
GOTIFY_URL_TEST=""
GOTIFY_TOKEN_TEST=""
BREVO_KEY=""
ALERT_EMAIL=""

reset_channels() {
  WEBHOOK="https://webhook.invalid/hook"
  GOTIFY_URL_TEST=""; GOTIFY_TOKEN_TEST=""
  BREVO_KEY=""; ALERT_EMAIL=""
}

ts_ago() { date -d "-$1 minutes" '+%Y-%m-%dT%H:%M:%S%z'; }

# write_log <monitor> <age-minutes> [<monitor> <age-minutes> ...] — a fresh log
# holding one heartbeat per pair, in the order given.
write_log() {
  : > "$MONITOR_LOG"
  while [ "$#" -gt 0 ]; do
    printf '%s HEARTBEAT %s ok\n' "$(ts_ago "$2")" "$1" >> "$MONITOR_LOG"
    shift 2
  done
}

# run_check <tag> [args...] — the tag also selects the state file, so calling
# it twice with the same tag models successive scheduled runs.
run_check() {
  local tag="$1"; shift
  CURL_LOG="$SANDBOX/$tag.curl.log"; : > "$CURL_LOG"
  MAIL_LOG="$SANDBOX/$tag.mail.log"; : > "$MAIL_LOG"
  CHECK_LOG="$SANDBOX/$tag.check.log"; : > "$CHECK_LOG"
  STATE="$SANDBOX/$tag.state"
  env -i \
    PATH="$BASE_PATH" HOME="$SANDBOX/home" HOST="testhost" \
    MONITOR_LOG="$MONITOR_LOG" MONITORS="$MONITORS" \
    MAX_AGE_MINUTES="$MAX_AGE_MINUTES" STATE="$STATE" LOG="$CHECK_LOG" \
    ALERT_WEBHOOK_URL="$WEBHOOK" \
    GOTIFY_URL="$GOTIFY_URL_TEST" GOTIFY_APP_TOKEN="$GOTIFY_TOKEN_TEST" \
    BREVO_API_KEY="$BREVO_KEY" ALERT_EMAIL="$ALERT_EMAIL" \
    CURL_LOG="$CURL_LOG" MAIL_LOG="$MAIL_LOG" \
    bash "$CHECK" "$@"
}

curl_calls() { awk '/^--- curl call ---$/{n++} END{print n+0}' "$CURL_LOG" 2>/dev/null || echo 0; }

echo "Check:   $CHECK"
echo "Sandbox: $SANDBOX"
echo

# --------------------------------------------------------------------------- #
# Phase 1: every monitor running -> silent
# --------------------------------------------------------------------------- #

echo "Phase 1: heartbeats inside the threshold are quiet"

reset_channels
write_log drift-check 5 revert-watchdog 8
rc=0
run_check quiet > /dev/null 2>&1 || rc=$?

assert_eq "a healthy check exits 0" "$rc" "0"
assert_eq "a healthy check alerts nobody" "$(curl_calls)" "0"
assert_present "the healthy run is logged" "$CHECK_LOG" "OK all monitors running: drift-check=ok(5m ago) revert-watchdog=ok(8m ago)"
assert_absent "a healthy run records no alert" "$CHECK_LOG" "ALERT liveness"
# State is only written once something is wrong.
if [ -e "$STATE" ]; then bad "a healthy run leaves no state"; else ok "a healthy run leaves no state"; fi

# --------------------------------------------------------------------------- #
# Phase 2: one stale monitor -> reported, exactly once
# --------------------------------------------------------------------------- #

echo
echo "Phase 2: a monitor that stops running is reported once, not repeatedly"

reset_channels
write_log drift-check 90 revert-watchdog 8
rc=0
run_check seq > /dev/null 2>&1 || rc=$?

assert_eq "a stale monitor exits 1" "$rc" "1"
assert_eq "the stall is alerted" "$(curl_calls)" "1"
assert_present "the alert names the stopped monitor" "$CURL_LOG" "JWT Monitor Not Running — testhost"
assert_present "the alert says which monitor" "$CURL_LOG" "The drift-check monitor"
assert_present "the alert carries the age" "$CURL_LOG" "1h 30m ago"
assert_present "the alert carries the threshold" "$CURL_LOG" "past the 45m threshold"
assert_present "the alert points at the cron entry" "$CURL_LOG" "crontab -l"
assert_present "the stall is logged" "$CHECK_LOG" "STALE drift-check: 1h 30m ago (threshold 45m)"
assert_present "the send is logged" "$CHECK_LOG" "ALERT liveness alert sent for drift-check"
assert_eq "the monitor is remembered as reported" "$(cat "$STATE")" "drift-check"

# A second run in the same outage must not re-alert.
rc=0
run_check seq > /dev/null 2>&1 || rc=$?
assert_eq "the second run still exits 1" "$rc" "1"
assert_eq "the second run does not re-alert" "$(curl_calls)" "0"
assert_present "the suppressed repeat says so" "$CHECK_LOG" "alert already sent, not repeating"
assert_eq "the state is unchanged" "$(cat "$STATE")" "drift-check"

# A third run, still down: still quiet.
rc=0
run_check seq > /dev/null 2>&1 || rc=$?
assert_eq "a third run still does not re-alert" "$(curl_calls)" "0"

# --------------------------------------------------------------------------- #
# Phase 3: recovery is announced and clears the state
# --------------------------------------------------------------------------- #

echo
echo "Phase 3: recovery is announced once and clears the state"

reset_channels
write_log drift-check 2 revert-watchdog 8
rc=0
run_check seq > /dev/null 2>&1 || rc=$?

assert_eq "a recovered check exits 0" "$rc" "0"
assert_eq "the recovery is announced" "$(curl_calls)" "1"
assert_present "the recovery notice says so" "$CURL_LOG" "JWT Monitor Running Again — testhost"
assert_present "the recovery names the monitor" "$CURL_LOG" "The drift-check monitor"
assert_present "the recovery is logged" "$CHECK_LOG" "RECOVERED drift-check: heartbeats resumed (2m ago)"
if [ -s "$STATE" ]; then bad "the state is cleared on recovery (still holds $(cat "$STATE"))"; else ok "the state is cleared on recovery"; fi

# Once recovered, it stays quiet.
rc=0
run_check seq > /dev/null 2>&1 || rc=$?
assert_eq "a steady run after recovery is silent" "$(curl_calls)" "0"
assert_eq "a steady run after recovery exits 0" "$rc" "0"

# --------------------------------------------------------------------------- #
# Phase 4: a monitor that has never logged a heartbeat
# --------------------------------------------------------------------------- #

echo
echo "Phase 4: a monitor with no heartbeat at all is reported as never seen"

reset_channels
write_log revert-watchdog 8
rc=0
run_check never > /dev/null 2>&1 || rc=$?

assert_eq "a never-seen monitor exits 1" "$rc" "1"
assert_eq "a never-seen monitor alerts" "$(curl_calls)" "1"
assert_present "the alert says the monitor never logged" "$CURL_LOG" "has never recorded a heartbeat"
assert_present "the never-seen case is logged as stale" "$CHECK_LOG" "STALE drift-check: never (threshold 45m)"
assert_absent "the running monitor is not blamed" "$CURL_LOG" "The revert-watchdog monitor"

# A log that does not exist yet is the same situation, not a crash.
rm -f "$MONITOR_LOG"
rc=0
run_check nolog > /dev/null 2>&1 || rc=$?
assert_eq "a missing log exits 1 rather than crashing" "$rc" "1"
assert_present "a missing log blames both monitors" "$CURL_LOG" "The revert-watchdog monitor"

# An unparsable timestamp is treated as no heartbeat, not as fresh.
reset_channels
write_log drift-check 5 revert-watchdog 8
printf 'not-a-timestamp HEARTBEAT drift-check ok\n' >> "$MONITOR_LOG"
printf '%s HEARTBEAT drift-check ok\n' "$(ts_ago 70)" >> "$MONITOR_LOG"
printf '%s HEARTBEAT drift-check ok\n' "$(ts_ago 1)" >> "$MONITOR_LOG"
rc=0
run_check badts > /dev/null 2>&1 || rc=$?
assert_eq "an out-of-order fresh heartbeat wins over the stale ones" "$rc" "0"
assert_eq "a fresh heartbeat silences the check" "$(curl_calls)" "0"

# --------------------------------------------------------------------------- #
# Phase 5: threshold boundary and configuration
# --------------------------------------------------------------------------- #

echo
echo "Phase 5: the threshold is exact and configurable"

reset_channels
MAX_AGE_MINUTES=45
write_log drift-check 45 revert-watchdog 45
rc=0
run_check boundary > /dev/null 2>&1 || rc=$?
assert_eq "an age exactly at the threshold is healthy" "$rc" "0"
assert_eq "an age exactly at the threshold alerts nobody" "$(curl_calls)" "0"

reset_channels
write_log drift-check 46 revert-watchdog 5
rc=0
run_check boundary_bad > /dev/null 2>&1 || rc=$?
assert_eq "one minute past the threshold alerts" "$rc" "1"
assert_present "the alert quotes the configured threshold" "$CURL_LOG" "past the 45m threshold"

reset_channels
MAX_AGE_MINUTES=120
write_log drift-check 90 revert-watchdog 5
rc=0
run_check relaxed > /dev/null 2>&1 || rc=$?
assert_eq "a relaxed threshold accepts a 90m-old heartbeat" "$rc" "0"
assert_present "the relaxed threshold is logged" "$CHECK_LOG" "(threshold 120m)"

# Only the monitors named in MONITORS are watched.
reset_channels
MAX_AGE_MINUTES=45
MONITORS="drift-check"
write_log drift-check 5 revert-watchdog 600
rc=0
run_check selected > /dev/null 2>&1 || rc=$?
assert_eq "an unwatched monitor is ignored" "$rc" "0"
assert_eq "an unwatched monitor alerts nobody" "$(curl_calls)" "0"
assert_absent "the unwatched monitor is absent from the summary" "$CHECK_LOG" "revert-watchdog"

# --------------------------------------------------------------------------- #
# Phase 6: no channel configured is stated plainly
# --------------------------------------------------------------------------- #

echo
echo "Phase 6: without an alert channel the check says so"

reset_channels
WEBHOOK=""
write_log drift-check 90 revert-watchdog 90
rc=0
run_check nochannel > /dev/null 2>&1 || rc=$?

assert_eq "a channel-less run still exits 1" "$rc" "1"
assert_eq "a channel-less run sends nothing" "$(curl_calls)" "0"
assert_present "the log admits the alert went nowhere" "$CHECK_LOG" "NOTE liveness alert not sent for drift-check: no alert channel configured"
assert_absent "the log does not claim a send" "$CHECK_LOG" "ALERT liveness alert sent"

# --------------------------------------------------------------------------- #
# Phase 7: dry run observes without acting
# --------------------------------------------------------------------------- #

echo
echo "Phase 7: --dry-run reports without alerting or changing state"

reset_channels
write_log drift-check 90 revert-watchdog 5
rc=0
run_check dry --dry-run > "$SANDBOX/dry.out" 2>&1 || rc=$?

assert_eq "a dry run still reports the problem in its exit status" "$rc" "1"
assert_eq "a dry run sends nothing" "$(curl_calls)" "0"
assert_present "a dry run prints the verdict" "$SANDBOX/dry.out" "drift-check=stale(1h 30m ago)"
assert_present "a dry run is logged as a dry run" "$CHECK_LOG" "DRY-RUN liveness"
if [ -e "$STATE" ]; then bad "a dry run changes no state"; else ok "a dry run changes no state"; fi

# Because no state was recorded, the next real run still alerts.
rc=0
run_check dry > /dev/null 2>&1 || rc=$?
assert_eq "a real run after a dry run still alerts" "$(curl_calls)" "1"

# --------------------------------------------------------------------------- #
# Phase 8: configuration errors
# --------------------------------------------------------------------------- #

echo
echo "Phase 8: configuration errors are rejected"

reset_channels
write_log drift-check 5 revert-watchdog 5

MAX_AGE_MINUTES=0
rc=0
run_check zero > "$SANDBOX/zero.out" 2>&1 || rc=$?
assert_eq "a zero threshold exits 2" "$rc" "2"
assert_present "the zero threshold is explained" "$SANDBOX/zero.out" "MAX_AGE_MINUTES must be at least 1"

MAX_AGE_MINUTES="soon"
rc=0
run_check badmin > "$SANDBOX/badmin.out" 2>&1 || rc=$?
assert_eq "a non-numeric threshold exits 2" "$rc" "2"
assert_present "the bad threshold is explained" "$SANDBOX/badmin.out" "MAX_AGE_MINUTES must be a non-negative integer"

MAX_AGE_MINUTES=45
MONITORS="  "
rc=0
run_check nomonitors > "$SANDBOX/nomon.out" 2>&1 || rc=$?
assert_eq "an empty monitor list exits 2" "$rc" "2"
assert_present "the empty monitor list is explained" "$SANDBOX/nomon.out" "MONITORS must name at least one monitor"

MONITORS="drift-check"
rc=0
run_check badopt --nonsense > "$SANDBOX/opt.out" 2>&1 || rc=$?
assert_eq "an unknown option exits 2" "$rc" "2"
assert_present "the unknown option is named" "$SANDBOX/opt.out" "unknown option: --nonsense"

# --------------------------------------------------------------------------- #
# Phase 9: --help documents the interface without running it
# --------------------------------------------------------------------------- #

echo
echo "Phase 9: --help prints the header documentation"

reset_channels
write_log drift-check 900 revert-watchdog 900
rc=0
run_check help --help > "$SANDBOX/help.out" 2>&1 || rc=$?

assert_eq "--help exits 0" "$rc" "0"
assert_present "--help documents the threshold" "$SANDBOX/help.out" "MAX_AGE_MINUTES"
assert_present "--help documents the watched monitors" "$SANDBOX/help.out" "MONITORS"
assert_present "--help documents the exit codes" "$SANDBOX/help.out" "Exit status"
assert_eq "--help alerts nobody" "$(curl_calls)" "0"
assert_eq "--help exits 0 even with everything stale" "$rc" "0"

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
