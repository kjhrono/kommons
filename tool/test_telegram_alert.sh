#!/usr/bin/env bash
# test_telegram_alert.sh
#
# Hermetic test for alert.sh's Telegram helper and its wiring into the
# critical monitors.
#
# Telegram is the alert pipeline's *external* leg: Gotify and mail go blind
# when the monitored host itself is unreachable, so the critical alerts fan a
# copy out to Telegram as well.  Two guarantees matter and are both asserted
# here — the sender must be a no-op when unconfigured (so the same script runs
# configured and unconfigured), and it must produce a request Telegram will
# actually accept (well-formed JSON, plain text, within the length limit).
#
# It sources alert.sh directly and stubs `curl`, so nothing leaves the
# machine and no bot or chat is needed.
#
# Usage:
#   tool/test_telegram_alert.sh
#   ALERT_SH=~/bin/alert.sh tool/test_telegram_alert.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALERT_SH="${ALERT_SH:-$SCRIPT_DIR/alert.sh}"
MONITOR_DIR="$SCRIPT_DIR"

if [ ! -f "$ALERT_SH" ]; then
  echo "FATAL: alert.sh not found at $ALERT_SH" >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "FATAL: python3 is required to validate the JSON payload" >&2
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
assert_true() { # <label> <actual> <want>
  assert_eq "$1" "$2" "$3"
}

# Stub curl: records every invocation and its arguments, and lifts the JSON
# body passed to -d into a payload file so it can be parsed for real.
cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf -- '--- curl call ---\n' >> "$CURL_LOG"
for arg in "$@"; do printf '%s\n' "$arg" >> "$CURL_LOG"; done
prev=""
for arg in "$@"; do
  if [ "$prev" = "-d" ]; then printf '%s\n' "$arg" >> "$PAYLOAD_LOG"; fi
  prev="$arg"
done
exit 0
STUB
chmod +x "$SANDBOX/bin/curl"
BASE_PATH="$SANDBOX/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

CURL_LOG=""; PAYLOAD_LOG=""

# run_telegram <tag> <token> <chat> <subject> <body> — calls send_telegram_alert
# in a clean environment with a fresh pair of capture files.
run_telegram() {
  local tag="$1" token="$2" chat="$3" subject="$4" body="$5"
  CURL_LOG="$SANDBOX/$tag.curl.log"
  PAYLOAD_LOG="$SANDBOX/$tag.payload.log"
  local rc=0
  env -i PATH="$BASE_PATH" HOME="$SANDBOX/home" \
    CURL_LOG="$CURL_LOG" PAYLOAD_LOG="$PAYLOAD_LOG" \
    TELEGRAM_BOT_TOKEN="$token" TELEGRAM_CHAT_ID="$chat" \
    ALERT_SH="$ALERT_SH" \
    bash -c '. "$ALERT_SH"; send_telegram_alert "$1" "$2"' _ "$subject" "$body" || rc=$?
  return "$rc"
}

curl_calls() { [ -f "$CURL_LOG" ] && grep -c -- '--- curl call ---' "$CURL_LOG" || echo 0; }
payload_value() { # <key>
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' \
    "$PAYLOAD_LOG" "$1" 2>/dev/null
}
payload_ok() { # prints "ok" when the captured -d argument is valid JSON
  python3 -c 'import json,sys; json.load(open(sys.argv[1])); print("ok")' \
    "$PAYLOAD_LOG" 2>/dev/null || true
}

echo "alert.sh: $ALERT_SH"
echo "Sandbox:  $SANDBOX"
echo

# --------------------------------------------------------------------------- #
# Phase 1: unconfigured -> silent no-op (and still succeeds)
# --------------------------------------------------------------------------- #

echo "Phase 1: unset credentials are a silent no-op"

rc=0; run_telegram unset "" "" "Subject" "Body" || rc=$?
assert_eq "no-op exits 0 with both credentials unset" "$rc" "0"
assert_eq "no-op sends nothing" "$(curl_calls)" "0"

rc=0; run_telegram tokenonly "TESTTOKEN" "" "Subject" "Body" || rc=$?
assert_eq "a token without a chat id is a no-op" "$(curl_calls)" "0"

rc=0; run_telegram chatonly "" "12345" "Subject" "Body" || rc=$?
assert_eq "a chat id without a token is a no-op" "$(curl_calls)" "0"

# --------------------------------------------------------------------------- #
# Phase 2: configured -> one well-formed request
# --------------------------------------------------------------------------- #

echo
echo "Phase 2: a configured send produces one valid request"

rc=0
run_telegram send "TESTTOKEN" "12345" \
  "[Drift Alert] JWT Secret Mismatch — testhost" \
  "🚨 drift detected
Affected stacks: dirA, dirB" || rc=$?

assert_eq "configured send exits 0" "$rc" "0"
assert_eq "exactly one request is sent" "$(curl_calls)" "1"
assert_eq "the payload is valid JSON" "$(payload_ok)" "ok"
assert_eq "the chat id is carried through" "$(payload_value chat_id)" "12345"
assert_eq "the request targets the bot's sendMessage endpoint" \
  "$(grep -c 'https://api.telegram.org/botTESTTOKEN/sendMessage' "$CURL_LOG")" "1"

text="$(payload_value text)"
case "$text" in
  "[Drift Alert] JWT Secret Mismatch — testhost"*"drift detected"*)
    ok "the subject and body are joined into the text" ;;
  *) bad "subject/body join (got '$text')" ;;
esac
case "$text" in
  *"Affected stacks: dirA, dirB"*) ok "the full body is delivered" ;;
  *) bad "body content (got '$text')" ;;
esac
assert_true "no parse_mode is set (plain text survives Markdown chars)" \
  "$(payload_value disable_web_page_preview)" "True"

# No argument may be whitespace-only: curl reads that as a second URL — the
# exact defect that once hid in send_brevo_alert.
if grep -qx '[[:space:]]*' "$CURL_LOG"; then
  bad "a whitespace-only argument reached curl"
else
  ok "no whitespace-only argument reaches curl"
fi

# --------------------------------------------------------------------------- #
# Phase 3: hostile characters stay valid JSON
# --------------------------------------------------------------------------- #

echo
echo "Phase 3: quotes, backslashes and newlines survive"

hostile_subject='He said "hi"'
hostile_body='line one
line two with a backslash \ and "quotes"'
rc=0
run_telegram hostile "TESTTOKEN" "12345" "$hostile_subject" "$hostile_body" || rc=$?

assert_eq "hostile-character send exits 0" "$rc" "0"
assert_eq "hostile-character payload is still valid JSON" "$(payload_ok)" "ok"
# Compare against the subject/body the shell actually passed, so the check
# never depends on hand-escaped literals agreeing with the JSON encoder.
expected="$(printf '%s\n%s' "$hostile_subject" "$hostile_body")"
if python3 - "$PAYLOAD_LOG" "$expected" <<'PY'
import json, sys
text = json.load(open(sys.argv[1]))["text"]
raise SystemExit(0 if text == sys.argv[2] else 1)
PY
then
  ok "the text round-trips through JSON intact"
else
  bad "the text did not round-trip through JSON"
fi

# --------------------------------------------------------------------------- #
# Phase 4: over-long alerts are truncated below Telegram's limit
# --------------------------------------------------------------------------- #

echo
echo "Phase 4: over-long alerts are truncated"

long_body="$(head -c 5000 /dev/zero | tr '\0' 'x')"
rc=0
run_telegram long "TESTTOKEN" "12345" "Subject" "$long_body" || rc=$?

assert_eq "long send exits 0" "$rc" "0"
assert_eq "long payload is valid JSON" "$(payload_ok)" "ok"
assert_eq "the truncated text stays within Telegram's 4096-character cap" \
  "$(python3 -c 'import json,sys; t=json.load(open(sys.argv[1]))["text"]; print(1 if len(t)<=4096 else 0)' "$PAYLOAD_LOG")" "1"
assert_eq "the cut is announced" \
  "$(payload_value text | grep -c '… (truncated)')" "1"

# --------------------------------------------------------------------------- #
# Phase 5: the critical monitors actually call the helper
# --------------------------------------------------------------------------- #

echo
echo "Phase 5: the critical monitors fan out to Telegram"

# A call line (two-space indent, quoted subject) never matches the header
# comment that merely lists the helper name.
assert_calls() { # <label> <file> <expected-count>
  local label="$1" file="$2" want="$3"
  if [ ! -f "$file" ]; then bad "$label (missing ${file##*/})"; return; fi
  local got
  got="$(grep -cE '^  send_telegram_alert "' "$file")"
  assert_eq "$label" "$got" "$want"
}

assert_calls "drift-check alerts on Telegram"      "$MONITOR_DIR/jwt-secret-drift-check.sh" "1"
assert_calls "revert-watchdog alerts on Telegram"  "$MONITOR_DIR/jwt-secret-revert-watchdog.sh" "1"
assert_calls "liveness alerts (and recovers) on Telegram" \
  "$MONITOR_DIR/jwt-secret-liveness-check.sh" "2"
assert_calls "delivery watchdog alerts on Telegram" "$MONITOR_DIR/jwt-secret-delivery-watchdog.sh" "1"

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
