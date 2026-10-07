#!/usr/bin/env bash
# test_notify.sh — hermetic test for notify.sh's send_gotify_alert helper.
#
# Sources notify.sh directly and stubs `curl`, so nothing leaves the machine
# and no Gotify server or token is needed.
#
# Usage:
#   ./test_notify.sh                    # finds notify.sh beside this test
#   GIT_NOTIFY=/path/to/notify.sh ./test_notify.sh
set -uo pipefail

# Locate notify.sh: either via $GIT_NOTIFY or beside this test file.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFY_SH="${GIT_NOTIFY:-$SCRIPT_DIR/notify.sh}"

if [ ! -f "$NOTIFY_SH" ]; then
  echo "FATAL: notify.sh not found at $NOTIFY_SH" >&2
  exit 2
fi

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/home" "$SANDBOX/bin"

pass=0
fail=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi
}

# Stub curl: records every invocation, one arg per line (so a whitespace-only
# argument can be detected), and returns success.
cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf -- '--- curl call ---' >> "$CURL_LOG"
printf '\n' >> "$CURL_LOG"
for arg in "$@"; do
  printf '%s\n' "$arg" >> "$CURL_LOG"
done
exit 0
STUB
chmod +x "$SANDBOX/bin/curl"
BASE_PATH="$SANDBOX/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

CURL_LOG=""

# run_notify <tag> <url> <token> <title> <body> [priority]
#   Calls send_gotify_alert in a clean environment with a fresh capture file.
#   Uses env -i so nothing reaches notify.sh but what we export.
run_notify() {
  local tag="$1" url="$2" token="$3" title="$4" body="$5" priority="${6:-}"
  CURL_LOG="$SANDBOX/$tag.curl.log"
  : > "$CURL_LOG"
  local rc=0
  if [ -n "$priority" ]; then
    env -i PATH="$BASE_PATH" HOME="$SANDBOX/home" \
      GOTIFY_URL="$url" GOTIFY_APP_TOKEN="$token" \
      CURL_LOG="$CURL_LOG" \
      bash -c '. "$0"; send_gotify_alert "$@"' \
      "$NOTIFY_SH" "$title" "$body" "$priority" || rc=$?
  else
    env -i PATH="$BASE_PATH" HOME="$SANDBOX/home" \
      GOTIFY_URL="$url" GOTIFY_APP_TOKEN="$token" \
      CURL_LOG="$CURL_LOG" \
      bash -c '. "$0"; send_gotify_alert "$@"' \
      "$NOTIFY_SH" "$title" "$body" || rc=$?
  fi
  return "$rc"
}

curl_calls() {
  if [ -f "$CURL_LOG" ]; then
    grep -c -- '--- curl call ---' "$CURL_LOG" || true
  else
    echo 0
  fi
}

echo "notify.sh: $NOTIFY_SH"
echo "Sandbox:  $SANDBOX"
echo

# --------------------------------------------------------------------------- #
# Phase 1: unconfigured -> silent no-op, still succeeds
# --------------------------------------------------------------------------- #

echo "Phase 1: unset credentials are a silent no-op"

rc=0; run_notify unset "" "" "Subject" "Body" || rc=$?
assert_eq "no-op exits 0 with both credentials unset" "$rc" "0"
assert_eq "no-op sends nothing" "$(curl_calls)" "0"

rc=0; run_notify urlonly "https://gotify.example" "" "Subject" "Body" || rc=$?
assert_eq "a URL without a token is a no-op" "$(curl_calls)" "0"

rc=0; run_notify tokenonly "" "APP_TOKEN" "Subject" "Body" || rc=$?
assert_eq "a token without a URL is a no-op" "$(curl_calls)" "0"

# --------------------------------------------------------------------------- #
# Phase 2: configured -> one well-formed multipart request
# --------------------------------------------------------------------------- #

echo
echo "Phase 2: a configured send produces one well-formed request"

rc=0; run_notify configured "https://notify.example.com" "ATESTTOKEN" \
  "Backup finished — myhost" "3 snapshots pruned, 1.2 GiB freed" 5 || rc=$?

assert_eq "configured send exits 0" "$rc" "0"
assert_eq "exactly one request is sent" "$(curl_calls)" "1"
assert_eq "the POST target carries the server and the app token" \
  "$(grep -c 'https://notify.example.com/message?token=ATESTTOKEN' "$CURL_LOG")" "1"
assert_eq "the title field is set" \
  "$(grep -c '^title=Backup finished — myhost$' "$CURL_LOG")" "1"
assert_eq "the message field is set" \
  "$(grep -c '^message=3 snapshots pruned, 1.2 GiB freed$' "$CURL_LOG")" "1"
assert_eq "the routine priority 5 is set" \
  "$(grep -c '^priority=5$' "$CURL_LOG")" "1"
if grep -q -- '/api/' "$CURL_LOG"; then
  bad "the URL must not use /api/*"
else
  ok "the message endpoint is used (not /api/*)"
fi
assert_eq "the title is reproduced verbatim" \
  "$(grep -x 'title=Backup finished — myhost' "$CURL_LOG" | wc -l)" "1"
assert_eq "the body is reproduced verbatim" \
  "$(grep -x 'message=3 snapshots pruned, 1.2 GiB freed' "$CURL_LOG" | wc -l)" "1"

# No argument may be whitespace-only: curl reads that as a second URL — the
# exact defect that once hid in send_brevo_alert (an escaped newline on one
# continuation line produced a whitespace argument).
if grep -Exq '[[:space:]]+' "$CURL_LOG"; then
  bad "a whitespace-only argument reached curl"
else
  ok "no whitespace-only argument reaches curl"
fi

# --------------------------------------------------------------------------- #
# Phase 3: priority overrides work
# --------------------------------------------------------------------------- #

echo
echo "Phase 3: the priority override works"

rc=0; run_notify highpri "https://notify.example.com" "ATESTTOKEN" \
  "Drift detected — myhost" "DRIFT in dirA" 8 || rc=$?
assert_eq "high-priority send exits 0" "$rc" "0"
assert_eq "the high priority 8 is set" \
  "$(grep -c '^priority=8$' "$CURL_LOG")" "1"

# Without an explicit priority, send_gotify_alert falls back to the default.
# Verify the default path (priority arg omitted entirely) still yields 5.
rc=0; run_notify no_pri "https://notify.example.com" "ATESTTOKEN" \
  "Report — myhost" "Some text" || rc=$?
assert_eq "omitted priority yields default 5" \
  "$(grep -c '^priority=5$' "$CURL_LOG")" "1"

# An explicit priority always wins.
rc=0; run_notify override "https://notify.example.com" "ATESTTOKEN" \
  "Report — myhost" "Some text" 7 || rc=$?
assert_eq "an explicit priority overrides the default" \
  "$(grep -c '^priority=7$' "$CURL_LOG")" "1"

# --------------------------------------------------------------------------- #
# Phase 4: the title / priority conventions hold in practice
# --------------------------------------------------------------------------- #

echo
echo "Phase 4: titles carry the host, alerts use priority 8"

rc=0; run_notify alert "https://notify.example.com" "ATESTTOKEN" \
  "Drift detected — myhost" "drift in dirA" 8 || rc=$?
assert_eq "alerts use high priority (8)" "$rc" "0"
case "$(grep '^priority=' "$CURL_LOG" | tail -1)" in
  priority=8) ok "the latest alert used priority 8" ;;
  *) bad "expected priority 8, got $(grep '^priority=' "$CURL_LOG" | tail -1)" ;;
esac

title_snippet="$(grep -c '— myhost' "$CURL_LOG" | tr -d ' ')"
assert_eq "titles include the host (em-dash convention)" "$title_snippet" "1"

# --------------------------------------------------------------------------- #
# Phase 5: the no-op contract is load-bearing
# --------------------------------------------------------------------------- #

echo
echo "Phase 5: the no-op contract, proven load-bearing"

# An empty-string URL is still a no-op (the helper tests [ -n "$GOTIFY_URL" ]).
rc=0; run_notify empty_url "" "ATESTTOKEN" "Title" "Body" || rc=$?
assert_eq "an empty-string URL is still a no-op" "$(curl_calls)" "0"

echo
echo "-------------------------------------------------------------"
if [ "$fail" -eq 0 ]; then
  echo "=== TEST PASSED ($pass checks) ==="
  exit 0
fi
echo "=== TEST FAILED ($fail failed, $pass passed) ==="
exit 1
