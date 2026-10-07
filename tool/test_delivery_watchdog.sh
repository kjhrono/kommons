#!/usr/bin/env bash
# test_delivery_watchdog.sh
#
# Hermetic test for jwt-secret-delivery-watchdog.sh, the dead-man's switch
# for the alert pipeline.
#
# The watchdog is fed a stubbed gotify-messages.sh (so the delivery age is
# controlled exactly) and stubbed curl/mail binaries (so no alert leaves the
# machine).  The key guarantee under test: the stall alert is still sent
# when Gotify itself is unconfigured, because "Gotify is down" is one of the
# very failures this watchdog exists to catch.
#
# Usage:
#   tool/test_delivery_watchdog.sh
#   WATCHDOG=~/bin/jwt-secret-delivery-watchdog.sh tool/test_delivery_watchdog.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG="${WATCHDOG:-$SCRIPT_DIR/jwt-secret-delivery-watchdog.sh}"

if [ ! -f "$WATCHDOG" ]; then
  echo "FATAL: watchdog not found at $WATCHDOG" >&2
  exit 2
fi
if [ ! -f "$(dirname "$WATCHDOG")/alert.sh" ]; then
  echo "FATAL: alert.sh not found beside $WATCHDOG" >&2
  exit 2
fi

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/home" "$SANDBOX/bin"

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

# --- stubs ----------------------------------------------------------------- #

STUB_AUDIT="$SANDBOX/bin/gotify-messages.sh"
cat > "$STUB_AUDIT" <<'STUB'
#!/usr/bin/env bash
# Stand-in for gotify-messages.sh: prints a scripted delivery age.
printf '%s\n' "$*" >> "$STUB_AUDIT_LOG"
if [ "${STUB_RC:-0}" -ne 0 ]; then
  echo "gotify-messages: cannot read ${GOTIFY_DB}: stub failure" >&2
  exit "$STUB_RC"
fi
title=""; prev=""
for a in "$@"; do
  [ "$prev" = "--title" ] && title="$a"
  prev="$a"
done
if [ -n "$title" ]; then
  printf '%s\n' "${STUB_HEARTBEAT_AGE:-0}"
else
  printf '%s\n' "${STUB_ANY_AGE:-0}"
fi
STUB
chmod +x "$STUB_AUDIT"

# curl is invoked with nothing on stdin, so it must NOT read stdin (that
# would block on the terminal); mail receives the body on a pipe and drains it.
cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf -- '--- curl call ---\n' >> "$CURL_LOG"
for arg in "$@"; do printf '%s\n' "$arg" >> "$CURL_LOG"; done
exit 0
STUB
cat > "$SANDBOX/bin/mail" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null
printf -- '--- mail call ---\n' >> "$MAIL_LOG"
for arg in "$@"; do printf '%s\n' "$arg" >> "$MAIL_LOG"; done
exit 0
STUB
chmod +x "$SANDBOX/bin/curl" "$SANDBOX/bin/mail"

BASE_PATH="$SANDBOX/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- harness --------------------------------------------------------------- #

WD_LOG=""; CURL_LOG=""; MAIL_LOG=""; STUB_LOG=""
STUB_RC=0; STUB_HB=0; STUB_ANY=0
MAX_AGE_HOURS=26; EXPECT_TITLE="JWT Daily Summary"
GOTIFY_URL="https://gotify.invalid"; GOTIFY_APP_TOKEN="test-token"
ALERT_WEBHOOK_URL="https://webhook.invalid/hook"; BREVO_API_KEY="brevo-key"
ALERT_EMAIL="ops@example.invalid"
TELEGRAM_BOT_TOKEN=""; TELEGRAM_CHAT_ID=""

# run_watchdog <tag> — runs the watchdog with a fresh set of capture files.
run_watchdog() {
  local tag="$1"
  WD_LOG="$SANDBOX/$tag.wd.log"
  CURL_LOG="$SANDBOX/$tag.curl.log"
  MAIL_LOG="$SANDBOX/$tag.mail.log"
  STUB_LOG="$SANDBOX/$tag.stub.log"
  env -i \
    PATH="$BASE_PATH" HOME="$SANDBOX/home" HOST="testhost" \
    AUDIT="$STUB_AUDIT" GOTIFY_DB="/stub/gotify.db" LOG="$WD_LOG" \
    STUB_AUDIT_LOG="$STUB_LOG" STUB_RC="$STUB_RC" \
    STUB_HEARTBEAT_AGE="$STUB_HB" STUB_ANY_AGE="$STUB_ANY" \
    MAX_AGE_HOURS="$MAX_AGE_HOURS" EXPECT_TITLE="$EXPECT_TITLE" \
    GOTIFY_URL="$GOTIFY_URL" GOTIFY_APP_TOKEN="$GOTIFY_APP_TOKEN" \
    ALERT_WEBHOOK_URL="$ALERT_WEBHOOK_URL" BREVO_API_KEY="$BREVO_API_KEY" \
    ALERT_EMAIL="$ALERT_EMAIL" \
    TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN" TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID" \
    CURL_LOG="$CURL_LOG" MAIL_LOG="$MAIL_LOG" \
    "$WATCHDOG" < /dev/null
}

curl_calls() { [ -f "$CURL_LOG" ] && grep -c -- '--- curl call ---' "$CURL_LOG" || echo 0; }

reset_case() {
  STUB_RC=0; STUB_HB=0; STUB_ANY=0
  MAX_AGE_HOURS=26; EXPECT_TITLE="JWT Daily Summary"
  GOTIFY_URL="https://gotify.invalid"; GOTIFY_APP_TOKEN="test-token"
  ALERT_WEBHOOK_URL="https://webhook.invalid/hook"; BREVO_API_KEY="brevo-key"
  ALERT_EMAIL="ops@example.invalid"
  TELEGRAM_BOT_TOKEN=""; TELEGRAM_CHAT_ID=""
}

echo "Watchdog: $WATCHDOG"
echo "Sandbox:  $SANDBOX"
echo

# --------------------------------------------------------------------------- #
# Phase 1: recent heartbeat -> healthy and silent
# --------------------------------------------------------------------------- #

echo "Phase 1: a recent heartbeat is healthy and silent"

reset_case
STUB_HB=3600; STUB_ANY=600
rc=0
run_watchdog healthy || rc=$?

assert_eq "healthy run exits 0" "$rc" "0"
assert_eq "healthy run sends no alert" "$(curl_calls)" "0"
assert_eq "healthy run sends no mail" "$([ -f "$MAIL_LOG" ] && wc -l < "$MAIL_LOG" | tr -d ' ' || echo 0)" "0"
assert_present "healthy run is logged as OK" "$WD_LOG" "OK delivery heartbeat"
assert_present "healthy log records the heartbeat age" "$WD_LOG" "last delivered 1h 00m ago"
assert_eq "the watchdog queries the heartbeat and the overall history" "$(wc -l < "$STUB_LOG" | tr -d ' ')" "2"
assert_present "the heartbeat query filters on the expected title" "$STUB_LOG" "--title JWT Daily Summary"
assert_present "the diagnostic query is unfiltered" "$STUB_LOG" "--age-seconds"

# --------------------------------------------------------------------------- #
# Phase 2: stale heartbeat -> alert on every channel
# --------------------------------------------------------------------------- #

echo
echo "Phase 2: a stale heartbeat alerts on every channel"

reset_case
STUB_HB=108000; STUB_ANY=108000
rc=0
run_watchdog stale || rc=$?

assert_eq "stale run exits 1" "$rc" "1"
assert_eq "all three HTTP channels are used" "$(curl_calls)" "3"
assert_present "the alert posts to Gotify" "$CURL_LOG" "/message?token=test-token"
assert_present "the Gotify alert is high priority" "$CURL_LOG" "priority=8"
assert_present "the alert posts to the webhook" "$CURL_LOG" "https://webhook.invalid/hook"
assert_present "the alert sends Brevo email" "$CURL_LOG" "api.brevo.com"
assert_absent "no Telegram call is made without credentials" "$CURL_LOG" "api.telegram.org"
assert_present "local mail is also attempted" "$MAIL_LOG" "mail call"
assert_present "the alert is titled with the host" "$CURL_LOG" "JWT Alert Delivery Stalled — testhost"
assert_present "the alert explains the staleness and threshold" "$CURL_LOG" "1d 06h old, past the 26h threshold"
assert_present "the alert includes the any-delivery diagnostic" "$CURL_LOG" "newest delivery of any kind: 1d 06h ago"
assert_present "the stall is logged" "$WD_LOG" "STALL heartbeat-stale"
assert_present "the notification is logged" "$WD_LOG" "ALERT delivery watchdog alert sent"

# --------------------------------------------------------------------------- #
# Phase 3: heartbeat never delivered -> alert
# --------------------------------------------------------------------------- #

echo
echo "Phase 3: a missing heartbeat alerts"

reset_case
STUB_HB=-1; STUB_ANY=600
rc=0
run_watchdog missing || rc=$?

assert_eq "missing heartbeat exits 1" "$rc" "1"
assert_present "the alert says no matching delivery exists" "$CURL_LOG" "No delivery matching"
assert_present "the alert names the expected title" "$CURL_LOG" "JWT Daily Summary"
assert_present "the stall reason is logged" "$WD_LOG" "STALL heartbeat-missing"
assert_present "the diagnostic still reports a healthy pipeline" "$CURL_LOG" "newest delivery of any kind: 10m ago"

# --------------------------------------------------------------------------- #
# Phase 4: unreadable history -> alert
# --------------------------------------------------------------------------- #

echo
echo "Phase 4: an unreadable delivery history alerts"

reset_case
STUB_RC=1
rc=0
run_watchdog unreadable || rc=$?

assert_eq "unreadable history exits 1" "$rc" "1"
assert_present "the alert reports the read failure" "$CURL_LOG" "Could not read the Gotify delivery history"
assert_present "the alert carries the underlying error" "$CURL_LOG" "stub failure"
assert_present "the diagnostic reports the history as unreadable" "$CURL_LOG" "unavailable (history unreadable)"
assert_present "the stall reason is logged" "$WD_LOG" "STALL history-unreadable"

# --------------------------------------------------------------------------- #
# Phase 5: the alert survives Gotify itself being down
# --------------------------------------------------------------------------- #

echo
echo "Phase 5: the alert still fires when Gotify is unconfigured"

reset_case
STUB_HB=108000; STUB_ANY=108000
GOTIFY_URL=""; GOTIFY_APP_TOKEN=""
rc=0
run_watchdog nogotify || rc=$?

assert_eq "run exits 1 without Gotify credentials" "$rc" "1"
assert_eq "the remaining channels still fire" "$(curl_calls)" "2"
assert_absent "no Gotify push is attempted" "$CURL_LOG" "/message?token="
assert_present "Brevo email still goes out" "$CURL_LOG" "api.brevo.com"
assert_present "the webhook still goes out" "$CURL_LOG" "https://webhook.invalid/hook"
assert_present "the alert body is unchanged" "$CURL_LOG" "JWT Alert Delivery Stalled"

# --------------------------------------------------------------------------- #
# Phase 6: threshold boundary and title configuration
# --------------------------------------------------------------------------- #

echo
echo "Phase 6: threshold boundary and configurable heartbeat"

reset_case
MAX_AGE_HOURS=1; STUB_HB=3600; STUB_ANY=3600
rc=0
run_watchdog boundary_ok || rc=$?
assert_eq "an age exactly at the threshold is healthy" "$rc" "0"

reset_case
MAX_AGE_HOURS=1; STUB_HB=3601; STUB_ANY=3601
rc=0
run_watchdog boundary_bad || rc=$?
assert_eq "one second past the threshold alerts" "$rc" "1"
assert_present "the alert quotes the configured threshold" "$CURL_LOG" "past the 1h threshold"

reset_case
EXPECT_TITLE="JWT Daily Summary — customvm"; STUB_HB=60; STUB_ANY=60
rc=0
run_watchdog custom_title || rc=$?
assert_eq "custom title run is healthy" "$rc" "0"
assert_present "the custom title is passed to the history query" "$STUB_LOG" "--title JWT Daily Summary — customvm"

# --------------------------------------------------------------------------- #
# Phase 7: configuration errors
# --------------------------------------------------------------------------- #

echo
echo "Phase 7: configuration errors"

reset_case
rc=0
env -i PATH="$BASE_PATH" HOME="$SANDBOX/home" AUDIT="$SANDBOX/nope.sh" \
  LOG="$SANDBOX/cfg.log" "$WATCHDOG" > "$SANDBOX/cfg.out" 2>&1 < /dev/null || rc=$?
assert_eq "a missing audit helper exits 2" "$rc" "2"
assert_present "the missing helper is named" "$SANDBOX/cfg.out" "audit helper not found"

reset_case
rc=0
env -i PATH="$BASE_PATH" HOME="$SANDBOX/home" AUDIT="$STUB_AUDIT" \
  LOG="$SANDBOX/cfg2.log" MAX_AGE_HOURS="soon" "$WATCHDOG" > "$SANDBOX/cfg2.out" 2>&1 < /dev/null || rc=$?
assert_eq "a non-numeric threshold exits 2" "$rc" "2"
assert_present "the bad threshold is explained" "$SANDBOX/cfg2.out" "MAX_AGE_HOURS must be a non-negative integer"

# --------------------------------------------------------------------------- #
# Phase 8: the external Telegram leg survives Gotify being down
# --------------------------------------------------------------------------- #

echo
echo "Phase 8: the external Telegram leg fires when Gotify is down"

reset_case
STUB_HB=108000; STUB_ANY=108000
GOTIFY_URL=""; GOTIFY_APP_TOKEN=""
TELEGRAM_BOT_TOKEN="tg-token"; TELEGRAM_CHAT_ID="424242"
rc=0
run_watchdog telegram || rc=$?

assert_eq "run exits 1 with Telegram configured" "$rc" "1"
assert_eq "the external channels all fire (webhook, Brevo, Telegram)" "$(curl_calls)" "3"
assert_absent "no Gotify push is attempted" "$CURL_LOG" "/message?token="
assert_present "the alert posts to the Telegram Bot API" "$CURL_LOG" "api.telegram.org/bottg-token/sendMessage"
assert_present "the Telegram payload names the chat" "$CURL_LOG" "424242"
assert_present "the Telegram leg carries the stall verdict" "$CURL_LOG" "JWT Alert Delivery Stalled"

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
