#!/usr/bin/env bash
# test_cleanup_notify.sh
#
# Hermetic test for the notification behaviour of cleanup-env-backups.sh:
# it must push a Gotify summary when (and only when) a non-dry run actually
# deletes snapshots, and stay silent otherwise.
#
# Runs the real script against sandbox fixtures with a stubbed `curl` on
# PATH, so nothing on the machine is touched and no real alert is sent.
#
# Usage:
#   tool/test_cleanup_notify.sh
#   CLEANUP=~/bin/cleanup-env-backups.sh tool/test_cleanup_notify.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The script sources alert.sh from its own directory, so the default keeps it
# beside this test (true both in-repo and in the deployed ~/bin layout).
CLEANUP="${CLEANUP:-$SCRIPT_DIR/cleanup-env-backups.sh}"

if [ ! -f "$CLEANUP" ]; then
  echo "FATAL: cleanup script not found at $CLEANUP" >&2
  exit 2
fi
if [ ! -f "$(dirname "$CLEANUP")/alert.sh" ]; then
  echo "FATAL: alert.sh not found beside $CLEANUP" >&2
  exit 2
fi

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/home"

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

# Stub curl: records every invocation and its arguments, sends nothing.
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf -- '--- curl call ---\n' >> "$CURL_LOG"
for arg in "$@"; do printf '%s\n' "$arg" >> "$CURL_LOG"; done
exit 0
STUB
chmod +x "$SANDBOX/bin/curl"
BASE_PATH="$SANDBOX/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# run_cleanup <curl-log> <backup-root> <log-file> <gotify: on|off> <args...>
run_cleanup() {
  local curl_log="$1" root="$2" log="$3" gotify="$4"
  shift 4
  local -a gotify_env
  # Empty values are equivalent to unset for the alert helpers, and avoid a
  # version-dependent empty-array expansion.
  if [ "$gotify" = "on" ]; then
    gotify_env=(GOTIFY_URL="https://gotify.invalid" GOTIFY_APP_TOKEN="test-token")
  else
    gotify_env=(GOTIFY_URL= GOTIFY_APP_TOKEN=)
  fi
  env -i PATH="$BASE_PATH" HOME="$SANDBOX/home" HOST="testhost" \
    BACKUP_ROOT="$root" LOG="$log" CURL_LOG="$curl_log" "${gotify_env[@]}" \
    "$CLEANUP" "$@"
}

# snapshot <path> <size-bytes> <age-days>
snapshot() {
  mkdir -p "$(dirname "$1")"
  head -c "$2" /dev/zero > "$1"
  touch -d "${3} days ago" "$1"
}

# Fixture: dirA has 4 stale snapshots (newest kept as the rollback floor,
# 3 pruned), dirB has 1 stale snapshot (kept).  Each is 100 bytes, so a
# 3-deletion sweep frees exactly 300 B.
build_stale_tree() { # <root>
  local root="$1"
  local i
  for i in 1 2 3 4; do
    snapshot "$root/Projects/dirA/.env.bak.$i" 100 40
  done
  snapshot "$root/Projects/dirB/.env.bak.1" 100 40
}

count_snapshots() { find "$1" -type f -name '.env.bak.*' 2>/dev/null | wc -l | tr -d ' '; }
curl_calls() { [ -f "$1" ] && grep -c -- '--- curl call ---' "$1" || echo 0; }

echo "Cleanup script: $CLEANUP"
echo "Sandbox:        $SANDBOX"
echo

# --------------------------------------------------------------------------- #
# Phase 1: deletions happen -> exactly one Gotify summary
# --------------------------------------------------------------------------- #

echo "Phase 1: prunes snapshots and notifies"

ROOT1="$SANDBOX/case1"; LOG1="$SANDBOX/logs/case1.log"; CURL1="$SANDBOX/curl-case1.log"
build_stale_tree "$ROOT1"
rc=0
run_cleanup "$CURL1" "$ROOT1" "$LOG1" on > "$SANDBOX/case1.out" 2>&1 || rc=$?

assert_eq "run exits 0" "$rc" "0"
assert_eq "three of the five snapshots are deleted" "$(count_snapshots "$ROOT1")" "2"
assert_eq "exactly one Gotify alert is sent" "$(curl_calls "$CURL1")" "1"
assert_present "alert posts to the Gotify message endpoint" "$CURL1" "/message?token=test-token"
assert_present "alert title names the host" "$CURL1" "Cleanup — testhost"
assert_present "alert reports the deleted count and freed space" "$CURL1" "Deleted 3 .env.bak.* snapshot(s), freeing 300 B."
assert_present "alert reports scanned/kept/retention" "$CURL1" "Scanned 5, kept 2 as the newest-in-dir rollback floor, retention 30d."
assert_present "alert lists the removed paths under a Removed: heading" "$CURL1" "Removed:"
assert_present "alert lists an actual removed path" "$CURL1" "$ROOT1/Projects/dirA/.env.bak."
assert_present "alert uses the informational priority 5" "$CURL1" "priority=5"
assert_present "the sweep is logged" "$LOG1" "OK cleanup complete: scanned=5 deleted=3 freed=300B keep-floor=2"
assert_present "the notification itself is logged" "$LOG1" "ALERT cleanup summary sent: deleted=3 freed=300B"

# --------------------------------------------------------------------------- #
# Phase 2: nothing prunable -> silence
# --------------------------------------------------------------------------- #

echo
echo "Phase 2: stays silent when nothing is pruned"

ROOT2="$SANDBOX/case2"; LOG2="$SANDBOX/logs/case2.log"; CURL2="$SANDBOX/curl-case2.log"
snapshot "$ROOT2/Projects/dirA/.env.bak.fresh" 100 1
rc=0
run_cleanup "$CURL2" "$ROOT2" "$LOG2" on > "$SANDBOX/case2.out" 2>&1 || rc=$?

assert_eq "clean run exits 0" "$rc" "0"
assert_eq "no snapshot is deleted" "$(count_snapshots "$ROOT2")" "1"
assert_eq "no alert is sent" "$(curl_calls "$CURL2")" "0"
assert_absent "no ALERT line is logged" "$LOG2" "ALERT cleanup summary sent"
assert_present "the silent sweep is still audited" "$LOG2" "OK cleanup complete: scanned=1 deleted=0"

# --------------------------------------------------------------------------- #
# Phase 3: dry run never notifies
# --------------------------------------------------------------------------- #

echo
echo "Phase 3: dry run never notifies"

ROOT3="$SANDBOX/case3"; LOG3="$SANDBOX/logs/case3.log"; CURL3="$SANDBOX/curl-case3.log"
build_stale_tree "$ROOT3"
rc=0
run_cleanup "$CURL3" "$ROOT3" "$LOG3" on --dry-run > "$SANDBOX/case3.out" 2>&1 || rc=$?

assert_eq "dry run exits 0" "$rc" "0"
assert_eq "dry run deletes nothing" "$(count_snapshots "$ROOT3")" "5"
assert_eq "dry run sends no alert" "$(curl_calls "$CURL3")" "0"
assert_absent "dry run logs no ALERT line" "$LOG3" "ALERT cleanup summary sent"
assert_present "dry run reports what it would delete" "$LOG3" "WOULD-DELETE"
assert_present "dry run reports would-delete=3" "$LOG3" "would-delete=3"

# --------------------------------------------------------------------------- #
# Phase 4: pruning still works with Gotify unconfigured
# --------------------------------------------------------------------------- #

echo
echo "Phase 4: pruning is unaffected when Gotify is not configured"

ROOT4="$SANDBOX/case4"; LOG4="$SANDBOX/logs/case4.log"; CURL4="$SANDBOX/curl-case4.log"
build_stale_tree "$ROOT4"
rc=0
run_cleanup "$CURL4" "$ROOT4" "$LOG4" off > "$SANDBOX/case4.out" 2>&1 || rc=$?

assert_eq "run exits 0 without Gotify credentials" "$rc" "0"
assert_eq "snapshots are still pruned" "$(count_snapshots "$ROOT4")" "2"
assert_eq "no alert is attempted without credentials" "$(curl_calls "$CURL4")" "0"
assert_present "the sweep is still logged" "$LOG4" "OK cleanup complete: scanned=5 deleted=3 freed=300B"

# --------------------------------------------------------------------------- #
# Phase 5: help text reflects the new behaviour
# --------------------------------------------------------------------------- #

echo
echo "Phase 5: help text"

rc=0
"$CLEANUP" --help > "$SANDBOX/help.out" 2>&1 || rc=$?
assert_eq "--help exits 0" "$rc" "0"
assert_present "--help documents the Gotify alert configuration" "$SANDBOX/help.out" "GOTIFY_APP_TOKEN"
assert_present "--help documents the alert priority" "$SANDBOX/help.out" "GOTIFY_PRIORITY"
assert_present "--help documents silence when nothing is pruned" "$SANDBOX/help.out" "when nothing is pruned"

# --------------------------------------------------------------------------- #
# Phase 6: long removals are truncated in the alert body
# --------------------------------------------------------------------------- #

echo
echo "Phase 6: long removal lists are truncated"

ROOT6="$SANDBOX/case6"; LOG6="$SANDBOX/logs/case6.log"; CURL6="$SANDBOX/curl-case6.log"
for i in $(seq 1 12); do
  snapshot "$ROOT6/Projects/dirA/.env.bak.$i" 100 40
done
rc=0
run_cleanup "$CURL6" "$ROOT6" "$LOG6" on > "$SANDBOX/case6.out" 2>&1 || rc=$?

assert_eq "large sweep exits 0" "$rc" "0"
assert_eq "11 of 12 snapshots are deleted" "$(count_snapshots "$ROOT6")" "1"
assert_present "alert reports the 11-deletion count in KB" "$CURL6" "Deleted 11 .env.bak.* snapshot(s), freeing 1.0 KB."
assert_eq "alert lists at most 10 removed paths" "$(grep -c '^  .*\.env\.bak\.' "$CURL6" | tr -d ' ')" "10"
assert_present "alert notes the truncated remainder" "$CURL6" "and 1 more"

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
