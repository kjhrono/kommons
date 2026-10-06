#!/usr/bin/env bash
# test_daily_summary.sh
#
# Hermetic test for jwt-secret-daily-summary.sh.
#
# The summary digests two logs over the same window — the shared drift/revert
# log (secret health) and the delivery watchdog's log (alert pipeline health) —
# and samples the Gotify delivery history live, at send time.  The point of
# the pipeline section is that ONE message reports both healths, so the tests
# pay as much attention to how the pipeline is classified as to what the
# message says:
#
#   healthy    — the watchdog ran in the window and saw no stall
#   stalled    — it saw one or more stalls
#   unverified — it logged nothing in the window (a dead watchdog is a
#                pipeline problem, not a quiet success)
#
# The live reading is taken through a stubbed gotify-messages.sh, so the age it
# reports is the test's to choose; the tests then cover what the digest does
# when the live reading and the watchdog's log agree, disagree, or when the
# history cannot be read at all.
#
# A stubbed `curl` captures every delivery, so the tests can prove a run
# sends exactly one message and inspect its whole body.  Nothing outside
# the sandbox HOME is read or written.
#
# Usage:
#   tool/test_daily_summary.sh
#   SUMMARY=~/bin/jwt-secret-daily-summary.sh tool/test_daily_summary.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Prefer a copy sitting beside this test — the deployed ~/bin layout — and
# fall back to the in-repo tool/ directory.
if [ -f "${SCRIPT_DIR}/jwt-secret-daily-summary.sh" ]; then
  DEFAULT_DIR="$SCRIPT_DIR"
else
  DEFAULT_DIR="$REPO_ROOT/tool"
fi

SUMMARY="${SUMMARY:-$DEFAULT_DIR/jwt-secret-daily-summary.sh}"

if [ ! -f "$SUMMARY" ]; then
  echo "FATAL: summary not found at $SUMMARY" >&2
  exit 2
fi
if [ ! -f "$(dirname "$SUMMARY")/alert.sh" ]; then
  echo "FATAL: alert.sh not found beside $SUMMARY" >&2
  exit 2
fi

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/home/logs" "$SANDBOX/bin"

DRIFT_LOG="$SANDBOX/home/logs/jwt-secret-drift.log"
DELIVERY_LOG="$SANDBOX/home/logs/jwt-secret-delivery.log"

# The delivery watchdog is the source of truth for the heartbeat title; the
# summary must keep pushing under that exact phrase (see Phase 7).
HEARTBEAT_TITLE="JWT Daily Summary"

cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Test stub: records the call and its arguments, never touches the network.
printf -- '--- curl call ---\n' >> "$CURL_LOG"
for arg in "$@"; do printf '%s\n' "$arg" >> "$CURL_LOG"; done
exit 0
STUB
chmod +x "$SANDBOX/bin/curl"

# mail receives the body on a pipe, so this stub drains stdin into the log.
# (Without it the test would reach the host's real mail(1) wherever one is
# installed, which is exactly the duplicate delivery under test here.)
cat > "$SANDBOX/bin/mail" <<'STUB'
#!/usr/bin/env bash
printf -- '--- mail call ---\n' >> "$MAIL_LOG"
printf 'ARGS: %s\n' "$*" >> "$MAIL_LOG"
cat >> "$MAIL_LOG"
exit 0
STUB
chmod +x "$SANDBOX/bin/mail"

# The digest also samples the Gotify history live at send time, through the
# same gotify-messages.sh audit helper the delivery watchdog uses.  The stub
# answers with the age the test configured (STUB_AGE seconds), or fails the way
# an unreadable history does (STUB_ERR), so every reading is deterministic.
STUB_AUDIT="$SANDBOX/bin/gotify-messages.sh"
cat > "$STUB_AUDIT" <<'STUB'
#!/usr/bin/env bash
# Test stub for gotify-messages.sh: --age-seconds answered from the test.
if [ -n "${STUB_ERR:-}" ]; then
  printf '%s\n' "$STUB_ERR" >&2
  exit 1
fi
printf '%s\n' "${STUB_AGE:-3600}"
STUB
chmod +x "$STUB_AUDIT"

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
# assert_no_stray_arg <label> <curl-log> — the recorded curl argv holds no
# whitespace-only argument.  The stubs log one argument per line, so such an
# argument shows up as a line holding nothing but a space.  curl treats a
# non-option argument as a URL, so a stray one silently adds a bogus target.
assert_no_stray_arg() {
  if grep -qx ' ' "$2" 2>/dev/null; then
    bad "$1 (a whitespace-only argument reached curl, which reads it as a URL)"
  else
    ok "$1"
  fi
}

# ts_ago <date -d offset> — an ISO-8601 timestamp like the monitors write.
ts_ago() { date -d "-$1" '+%Y-%m-%dT%H:%M:%S%z'; }

# --- harness --------------------------------------------------------------- #

CURL_LOG=""
MAIL_LOG=""
WINDOW_HOURS=24
WEBHOOK=""
GOTIFY_URL_TEST=""
GOTIFY_TOKEN_TEST=""
BREVO_KEY=""
ALERT_EMAIL_TEST=""

# Live pipeline reading the stub audit helper will report: 3600s (1h) is a
# current heartbeat, so the default is agreement with a healthy log.
LIVE_AGE=3600
LIVE_ERR=""

reset_channels() {
  WEBHOOK=""; GOTIFY_URL_TEST=""; GOTIFY_TOKEN_TEST=""
  BREVO_KEY=""; ALERT_EMAIL_TEST=""
}

# run_summary <tag> — run the real script in the sandbox with the channels
# configured by the current globals.
run_summary() {
  local tag="$1"
  CURL_LOG="$SANDBOX/$tag.curl.log"
  : > "$CURL_LOG"
  MAIL_LOG="$SANDBOX/$tag.mail.log"
  : > "$MAIL_LOG"
  env -i \
    PATH="$BASE_PATH" HOME="$SANDBOX/home" \
    LOG="$DRIFT_LOG" DELIVERY_LOG="$DELIVERY_LOG" \
    WINDOW_HOURS="$WINDOW_HOURS" \
    ALERT_WEBHOOK_URL="$WEBHOOK" \
    GOTIFY_URL="$GOTIFY_URL_TEST" GOTIFY_APP_TOKEN="$GOTIFY_TOKEN_TEST" \
    BREVO_API_KEY="$BREVO_KEY" ALERT_EMAIL="$ALERT_EMAIL_TEST" \
    GOTIFY_DB="$SANDBOX/gotify.db" AUDIT="$STUB_AUDIT" \
    STUB_AGE="$LIVE_AGE" STUB_ERR="$LIVE_ERR" \
    CURL_LOG="$CURL_LOG" MAIL_LOG="$MAIL_LOG" \
    bash "$SUMMARY"
}

curl_calls() { awk '/^--- curl call ---$/{n++} END{print n+0}' "$CURL_LOG" 2>/dev/null || echo 0; }
mail_calls() { awk '/^--- mail call ---$/{n++} END{print n+0}' "$MAIL_LOG" 2>/dev/null || echo 0; }

# fresh_logs — a clean secret log and a healthy watchdog log, so the summary
# line each run appends is the only one present to assert against.
fresh_logs() {
  {
    printf '%s OK all stacks match identity JWT_SECRET\n' "$T1"
  } > "$DRIFT_LOG"
  {
    printf '%s OK delivery heartbeat: "%s" last delivered 1h 00m ago (threshold 26h)\n' "$T1" "$HEARTBEAT_TITLE"
  } > "$DELIVERY_LOG"
}

echo "Summary: $SUMMARY"
echo "Sandbox: $SANDBOX"
echo

# --------------------------------------------------------------------------- #
# Phase 1: one calm message covers secret health AND pipeline health
# --------------------------------------------------------------------------- #

echo "Phase 1: a calm run reports both healths in a single message"

T1="$(ts_ago '1 hour')"; T2="$(ts_ago '2 hours')"; T3="$(ts_ago '3 hours')"

{
  printf '%s OK all stacks match identity JWT_SECRET\n' "$T1"
  printf '%s HEARTBEAT drift-check ok\n' "$T1"
  printf '%s HEARTBEAT revert-watchdog ok\n' "$T1"
  printf '%s OK all stacks match identity JWT_SECRET\n' "$T2"
  printf '%s OK all stacks match identity JWT_SECRET\n' "$T3"
} > "$DRIFT_LOG"
# Appended in chronological order, as the watchdog really writes them: the
# digest reports the last line as the newest.
{
  printf '%s OK delivery heartbeat: %s last delivered 2h 00m ago (threshold 26h)\n' "$T2" "$HEARTBEAT_TITLE"
  printf '%s OK delivery heartbeat: %s last delivered 1h 00m ago (threshold 26h)\n' "$T1" "$HEARTBEAT_TITLE"
} > "$DELIVERY_LOG"

reset_channels
WEBHOOK="https://webhook.invalid/hook"
rc=0
run_summary phase1 || rc=$?

assert_eq "a calm digest exits 0" "$rc" "0"
assert_eq "exactly one message is delivered" "$(curl_calls)" "1"
assert_present "the message carries the secret-health digest" "$CURL_LOG" "Clean runs (3):"
# Liveness heartbeats are plumbing: they must not inflate counts or appear.
assert_absent "heartbeat lines stay out of the digest" "$CURL_LOG" "HEARTBEAT"
assert_present "the clean secret window is reported" "$CURL_LOG" "(none — all stacks were green)"
assert_present "the same message carries a pipeline-health section" \
  "$CURL_LOG" "Pipeline health:"
assert_present "the pipeline is reported healthy" \
  "$CURL_LOG" "Healthy — 2 heartbeat check(s) in the window"
assert_present "the newest watchdog check is quoted verbatim" \
  "$CURL_LOG" "Newest: $T1 OK delivery heartbeat: $HEARTBEAT_TITLE last delivered 1h 00m ago"
assert_present "the watchdog log path is named" "$CURL_LOG" "Log: $DELIVERY_LOG"
assert_absent "a healthy pipeline is not alarmed" "$CURL_LOG" "STALLED"
assert_absent "a healthy pipeline is not called unverified" "$CURL_LOG" "UNVERIFIED"

# --------------------------------------------------------------------------- #
# Phase 2: a stalled pipeline is reported with its stall detail
# --------------------------------------------------------------------------- #

echo
echo "Phase 2: a stalled pipeline is reported instead of a green section"

{
  printf '%s OK all stacks match identity JWT_SECRET\n' "$T1"
} > "$DRIFT_LOG"
{
  printf '%s OK delivery heartbeat: %s last delivered 1h 00m ago (threshold 26h)\n' "$T1" "$HEARTBEAT_TITLE"
  printf '%s STALL heartbeat-stale: The newest "%s" delivery is 1d 06h old, past the 26h threshold. (newest delivery of any kind: 1d 06h ago)\n' "$T2" "$HEARTBEAT_TITLE"
  printf '%s ALERT delivery watchdog alert sent (heartbeat-stale)\n' "$T2"
  printf '%s STALL heartbeat-missing: No delivery matching "%s" exists.\n' "$T3" "$HEARTBEAT_TITLE"
} > "$DELIVERY_LOG"

reset_channels
WEBHOOK="https://webhook.invalid/hook"
rc=0
run_summary phase2 || rc=$?

assert_eq "a stalled pipeline still exits 0 (the digest is a report)" "$rc" "0"
assert_eq "the stall report is still one message" "$(curl_calls)" "1"
assert_present "the pipeline is reported stalled" \
  "$CURL_LOG" "STALLED — 2 stall(s) in the window"
assert_present "the first stall detail is carried" "$CURL_LOG" "STALL heartbeat-stale:"
assert_present "the stall threshold survives into the digest" "$CURL_LOG" "past the 26h threshold"
assert_present "the second stall detail is carried too" "$CURL_LOG" "STALL heartbeat-missing:"
assert_absent "a stalled pipeline is never called healthy" "$CURL_LOG" "Healthy —"
assert_absent "a stalled pipeline is never called unverified" "$CURL_LOG" "UNVERIFIED"
# The watchdog's own ALERT lines are a consequence of a stall, not a stall:
# they must not inflate the count.
assert_absent "watchdog ALERT lines are not counted as stalls" "$CURL_LOG" "3 stall(s)"

# --------------------------------------------------------------------------- #
# Phase 3: an unverified pipeline is surfaced, not silently passed
# --------------------------------------------------------------------------- #

echo
echo "Phase 3: a silent watchdog is surfaced as unverified"

{
  printf '%s OK all stacks match identity JWT_SECRET\n' "$T1"
} > "$DRIFT_LOG"

rm -f "$DELIVERY_LOG"
reset_channels
WEBHOOK="https://webhook.invalid/hook"
rc=0
run_summary phase3_missing || rc=$?

assert_eq "a missing watchdog log still exits 0" "$rc" "0"
assert_present "the pipeline section is present" \
  "$CURL_LOG" "Pipeline health:"
assert_present "a missing watchdog log is unverified" \
  "$CURL_LOG" "UNVERIFIED — the watchdog logged nothing in the window"
assert_present "the missing watchdog log path is named" "$CURL_LOG" "Log: $DELIVERY_LOG"
assert_absent "a missing watchdog log is not called healthy" "$CURL_LOG" "Healthy —"

# The log exists but holds nothing inside the window: the watchdog ran once
# and has since gone quiet — still unverified, and distinguishable.
printf '%s OK delivery heartbeat: %s last delivered 1h 00m ago (threshold 26h)\n' \
  "$(ts_ago '30 hours')" "$HEARTBEAT_TITLE" > "$DELIVERY_LOG"
rc=0
run_summary phase3_quiet || rc=$?

assert_present "a watchdog quiet for the whole window is unverified" \
  "$CURL_LOG" "UNVERIFIED — the watchdog logged nothing in the window"
assert_present "the quiet case says the log itself exists" \
  "$CURL_LOG" "(the log exists but holds no entry inside the window)"
assert_present "the quiet case still names the log" "$CURL_LOG" "Log: $DELIVERY_LOG"

# --------------------------------------------------------------------------- #
# Phase 4: the window filter applies to the delivery log too
# --------------------------------------------------------------------------- #

echo
echo "Phase 4: out-of-window watchdog entries are ignored"

{
  printf '%s OK all stacks match identity JWT_SECRET\n' "$T1"
  printf '%s OK all stacks match identity JWT_SECRET\n' "$(ts_ago '30 hours')"
} > "$DRIFT_LOG"
{
  printf '%s OK delivery heartbeat: %s last delivered 9h 00m ago (threshold 26h)\n' "$(ts_ago '9 hours')" "$HEARTBEAT_TITLE"
  printf '%s OK delivery heartbeat: %s last delivered 30h 00m ago (threshold 26h)\n' "$(ts_ago '30 hours')" "$HEARTBEAT_TITLE"
} > "$DELIVERY_LOG"

reset_channels
WEBHOOK="https://webhook.invalid/hook"
rc=0
run_summary phase4 || rc=$?

assert_present "only the in-window secret run is counted" "$CURL_LOG" "Clean runs (1):"
assert_present "only the in-window watchdog check is counted" \
  "$CURL_LOG" "Healthy — 1 heartbeat check(s) in the window"
assert_present "the in-window watchdog line is quoted" "$CURL_LOG" "last delivered 9h 00m ago"
assert_absent "the stale watchdog line is not quoted" "$CURL_LOG" "last delivered 30h 00m ago"

# --------------------------------------------------------------------------- #
# Phase 5: malformed watchdog lines cannot derail the digest
# --------------------------------------------------------------------------- #

echo
echo "Phase 5: malformed watchdog lines are ignored"

{
  printf '%s OK all stacks match identity JWT_SECRET\n' "$T1"
} > "$DRIFT_LOG"
{
  printf '%s OK delivery heartbeat: %s last delivered 1h 00m ago (threshold 26h)\n' "$T1" "$HEARTBEAT_TITLE"
  printf 'not-a-timestamp STALL heartbeat-stale: undated noise\n'
  printf '%s INFO something the watchdog never writes\n' "$T1"
  printf '\n'
} > "$DELIVERY_LOG"

reset_channels
WEBHOOK="https://webhook.invalid/hook"
rc=0
run_summary phase5 || rc=$?

assert_eq "a log with junk lines still exits 0" "$rc" "0"
assert_present "the valid watchdog check is counted" \
  "$CURL_LOG" "Healthy — 1 heartbeat check(s) in the window"
assert_absent "an undated STALL line does not stall the pipeline" "$CURL_LOG" "STALLED"
assert_absent "an undated STALL line is not printed" "$CURL_LOG" "undated noise"

# --------------------------------------------------------------------------- #
# Phase 6: the subject reflects both healths
# --------------------------------------------------------------------------- #

echo
echo "Phase 6: the subject names the pipeline problem alongside secret health"

{
  printf '%s OK all stacks match identity JWT_SECRET\n' "$T1"
} > "$DRIFT_LOG"

# Calm: a stale-but-unsent subject must not cry wolf.
{
  printf '%s OK delivery heartbeat: %s last delivered 1h 00m ago (threshold 26h)\n' "$T1" "$HEARTBEAT_TITLE"
} > "$DELIVERY_LOG"
reset_channels
BREVO_KEY="brevo-key"; ALERT_EMAIL_TEST="ops@example.invalid"
rc=0
run_summary phase6_calm || rc=$?
assert_eq "the calm subject is still delivered exactly once" "$(curl_calls)" "1"
assert_eq "Brevo delivery does not also mail a copy" "$(mail_calls)" "0"
assert_present "the calm subject reports the OK runs" "$CURL_LOG" "JWT Secret Daily Summary — "
assert_present "the calm subject counts the clean runs" "$CURL_LOG" "1 clean run(s)"
assert_absent "the calm subject carries no warning" "$CURL_LOG" "⚠️"
assert_absent "the calm subject claims no pipeline problem" "$CURL_LOG" "pipeline "

# Pipeline stall only.
{
  printf '%s STALL heartbeat-stale: The newest "%s" delivery is 1d 06h old, past the 26h threshold.\n' "$T2" "$HEARTBEAT_TITLE"
} > "$DELIVERY_LOG"
rc=0
run_summary phase6_stall || rc=$?
assert_eq "a stall still sends one message" "$(curl_calls)" "1"
assert_present "the subject warns about the stall" "$CURL_LOG" "⚠️"
assert_present "the subject names the stalled pipeline" "$CURL_LOG" "pipeline stalled"
assert_absent "the stalled subject does not invent secret incidents" "$CURL_LOG" "secret incidents"

# Unverified pipeline only.
rm -f "$DELIVERY_LOG"
rc=0
run_summary phase6_unverified || rc=$?
assert_present "the subject warns when the pipeline is unverified" "$CURL_LOG" "⚠️"
assert_present "the subject says pipeline unverified" "$CURL_LOG" "pipeline unverified"

# Both at once: the two reasons are combined into one subject.
{
  printf '%s DRIFT kalcio (mismatch)\n' "$T1"
} > "$DRIFT_LOG"
{
  printf '%s STALL heartbeat-stale: The newest "%s" delivery is 1d 06h old.\n' "$T2" "$HEARTBEAT_TITLE"
} > "$DELIVERY_LOG"
rc=0
run_summary phase6_both || rc=$?
assert_present "the combined subject names the secret incidents" "$CURL_LOG" "secret incidents"
assert_present "the combined subject joins both reasons" "$CURL_LOG" "secret incidents + pipeline stalled"
assert_present "the combined message still carries the drift" "$CURL_LOG" "DRIFT kalcio"
assert_eq "the combined run is still a single message" "$(curl_calls)" "1"

# --------------------------------------------------------------------------- #
# Phase 7: the Gotify heartbeat title is left alone on purpose
# --------------------------------------------------------------------------- #

echo
echo "Phase 7: the push title keeps the watchdog's EXPECT_TITLE phrase"

# jwt-secret-delivery-watchdog.sh locates the heartbeat by the bare
# "JWT Daily Summary" substring, so the push title must not be decorated
# with the escalation the subject carries.
{
  printf '%s OK all stacks match identity JWT_SECRET\n' "$T1"
} > "$DRIFT_LOG"
{
  printf '%s STALL heartbeat-stale: The newest "%s" delivery is 1d 06h old.\n' "$T2" "$HEARTBEAT_TITLE"
} > "$DELIVERY_LOG"
reset_channels
GOTIFY_URL_TEST="https://gotify.invalid"; GOTIFY_TOKEN_TEST="test-token"
rc=0
run_summary phase7 || rc=$?
assert_eq "the push is a single delivery" "$(curl_calls)" "1"
assert_present "the push title keeps the heartbeat phrase" \
  "$CURL_LOG" "title=$HEARTBEAT_TITLE — "
assert_absent "the push title is not escalated" "$CURL_LOG" "title=⚠️"
assert_present "the push body still carries the stall" "$CURL_LOG" "STALLED — 1 stall(s) in the window"

# --------------------------------------------------------------------------- #
# Phase 8: the run records the pipeline verdict in its own log
# --------------------------------------------------------------------------- #

echo
echo "Phase 8: the run logs the pipeline verdict for later audits"

{
  printf '%s OK all stacks match identity JWT_SECRET\n' "$T1"
} > "$DRIFT_LOG"
{
  printf '%s OK delivery heartbeat: %s last delivered 1h 00m ago (threshold 26h)\n' "$T1" "$HEARTBEAT_TITLE"
} > "$DELIVERY_LOG"
reset_channels
WEBHOOK="https://webhook.invalid/hook"
rc=0
run_summary phase8 || rc=$?
assert_present "the summary line records the pipeline as healthy" \
  "$DRIFT_LOG" "PIPELINE=healthy"
assert_present "the summary line records the stall count" "$DRIFT_LOG" "DELIVERY_STALLS=0"

{
  printf '%s STALL heartbeat-stale: The newest "%s" delivery is 1d 06h old.\n' "$T2" "$HEARTBEAT_TITLE"
} > "$DELIVERY_LOG"
rc=0
run_summary phase8_stall || rc=$?
assert_present "a stalled pipeline is recorded as stalled" "$DRIFT_LOG" "PIPELINE=stalled"
assert_present "a stalled pipeline records the stall count" "$DRIFT_LOG" "DELIVERY_STALLS=1"

# --------------------------------------------------------------------------- #
# Phase 9: a realistic (quoted-title) watchdog line is digested
# --------------------------------------------------------------------------- #

echo
echo "Phase 9: a real watchdog line with a quoted title is digested"

{
  printf '%s OK all stacks match identity JWT_SECRET\n' "$T1"
} > "$DRIFT_LOG"
# Exactly the shape jwt-secret-delivery-watchdog.sh writes on a healthy run.
printf '%s OK delivery heartbeat: "%s" last delivered 45m ago (threshold 26h)\n' \
  "$T1" "$HEARTBEAT_TITLE" > "$DELIVERY_LOG"

reset_channels
WEBHOOK="https://webhook.invalid/hook"
rc=0
run_summary phase9 || rc=$?
assert_present "a quoted-title heartbeat still counts" \
  "$CURL_LOG" "Healthy — 1 heartbeat check(s) in the window"
assert_present "the quoted heartbeat age is carried" "$CURL_LOG" "last delivered 45m ago"

# --------------------------------------------------------------------------- #
# Phase 10: the delivered payload is valid JSON
# --------------------------------------------------------------------------- #

echo
echo "Phase 10: the delivered webhook payload is valid JSON"

# send_webhook_alert hand-builds its request body, so a transposed brace or
# quote would ship a malformed body that no webhook target can parse — the
# digest would arrive broken exactly when it matters.  Guard the whole chain.
{
  printf '%s OK all stacks match identity JWT_SECRET\n' "$T1"
} > "$DRIFT_LOG"
printf '%s OK delivery heartbeat: "%s" last delivered 1h 00m ago (threshold 26h)\n' \
  "$T1" "$HEARTBEAT_TITLE" > "$DELIVERY_LOG"

reset_channels
WEBHOOK="https://webhook.invalid/hook"
rc=0
run_summary phase10 || rc=$?

PAYLOAD="$SANDBOX/phase10.payload.json"
awk '/^-d$/{getline; print; exit}' "$CURL_LOG" > "$PAYLOAD"

if [ -s "$PAYLOAD" ]; then
  ok "the webhook request carries a JSON body"
  if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$PAYLOAD" 2>/dev/null; then
    ok "the webhook body is valid JSON"
  else
    bad "the webhook body is valid JSON (it is malformed)"
  fi
  if python3 - "$PAYLOAD" <<'PY' 2>/dev/null
import json, sys
text = json.load(open(sys.argv[1]))["text"]
assert "Clean runs (1):" in text
assert "Pipeline health:" in text
assert "Healthy \u2014 1 heartbeat check(s) in the window" in text
PY
  then
    ok "the JSON round-trips to the digest with both health sections"
  else
    bad "the JSON round-trips to the digest with both health sections"
  fi
else
  bad "the webhook request carries a JSON body (no -d payload captured)"
  bad "the webhook body is valid JSON (no payload captured)"
  bad "the JSON round-trips to the digest with both health sections (no payload)"
fi

# --------------------------------------------------------------------------- #
# Phase 11: exactly one email channel
# --------------------------------------------------------------------------- #

echo
echo "Phase 11: the digest goes out by one email channel, never two"

# The VM has both a working mail(1) and a Brevo key, so a summary that sent
# through both channels would deliver the same digest to the recipient twice:
# noise mistaken for redundancy.  Only the urgent alerts keep that fan-out,
# because the channel that broke may be the one being reported on.
reset_channels
WEBHOOK=""
fresh_logs
BREVO_KEY="brevo-key"; ALERT_EMAIL_TEST="ops@example.invalid"
rc=0
run_summary phase11_brevo > /dev/null 2>&1 || rc=$?

assert_eq "with both channels available the summary exits 0" "$rc" "0"
assert_eq "one email leaves the host" "$(curl_calls)" "1"
assert_eq "local mail is not used alongside Brevo" "$(mail_calls)" "0"
assert_present "the channel actually used is recorded" "$DRIFT_LOG" "EMAIL=brevo"
assert_present "the Brevo email carries the digest" "$CURL_LOG" "api.brevo.com"
assert_present "the Brevo email carries both healths" "$CURL_LOG" "Pipeline health:"
# send_brevo_alert hand-builds its curl command line, so a broken continuation
# ships curl an extra argument; `|| true` then hides the failure it causes.  The
# endpoint and the JSON body can both look right while this is wrong.
assert_no_stray_arg "the Brevo request passes no stray argument to curl" "$CURL_LOG"

# Drop Brevo: the one email falls back to local mail rather than vanishing.
fresh_logs
BREVO_KEY=""
rc=0
run_summary phase11_mail > /dev/null 2>&1 || rc=$?

assert_eq "without Brevo the summary exits 0" "$rc" "0"
assert_eq "without Brevo the email goes by mail(1)" "$(mail_calls)" "1"
assert_eq "the fallback sends no Brevo request" "$(curl_calls)" "0"
assert_present "the fallback channel is recorded" "$DRIFT_LOG" "EMAIL=mail"
assert_absent "the fallback is not also logged as Brevo" "$DRIFT_LOG" "EMAIL=brevo"
assert_present "the mailed copy carries both healths" "$MAIL_LOG" "Pipeline health:"

# No channel at all: the run still happens and says plainly that it mailed
# nothing, rather than leaving a silent hole in the daily heartbeat.
fresh_logs
ALERT_EMAIL_TEST=""
rc=0
run_summary phase11_none > /dev/null 2>&1 || rc=$?

assert_eq "with no channel the summary still exits 0" "$rc" "0"
assert_eq "with no channel nothing is mailed" "$(mail_calls)" "0"
assert_eq "with no channel no Brevo request is made" "$(curl_calls)" "0"
assert_present "with no channel the absence is recorded" "$DRIFT_LOG" "EMAIL=none"

# Brevo configured but no recipient: still nothing to send to.
fresh_logs
BREVO_KEY="brevo-key"
rc=0
run_summary phase11_norecipient > /dev/null 2>&1 || rc=$?
assert_eq "a key without a recipient sends nothing" "$(curl_calls)" "0"
assert_eq "a key without a recipient mails nothing" "$(mail_calls)" "0"
assert_present "the recipient-less run is recorded honestly" "$DRIFT_LOG" "EMAIL=none"

# --------------------------------------------------------------------------- #
# Phase 12: the digest is condensed, not a log dump
# --------------------------------------------------------------------------- #

echo
echo "Phase 12: routine lines become counts and incidents group under their stack"

# A day of healthy monitoring is dozens of clean runs and registry rebuilds,
# none of which carry information; incidents do, and they are worth grouping.
T_OLD="$(ts_ago '20 hours')"; T_MID="$(ts_ago '10 hours')"; T_NEW="$(ts_ago '1 hour')"
{
  printf '%s OK all stacks match identity JWT_SECRET\n' "$T_OLD"
  printf '%s OK all stacks match identity JWT_SECRET\n' "$T_MID"
  printf '%s OK no exact reverts detected across project stacks\n' "$T_MID"
  printf '%s REGISTRY built: 5 pre-cutover fingerprints (identity=aaaa…)\n' "$T_MID"
  printf '%s REGISTRY built: 5 pre-cutover fingerprints (identity=aaaa…)\n' "$T_NEW"
  printf '%s DRIFT kalcio: JWT_SECRET differs from identity (/kalcio/.env)\n' "$T_MID"
  printf '%s WARN katalogus: .env missing at /katalogus/.env\n' "$T_MID"
  printf '%s REVERT DETECTED kognitio: deadbeef = pre-cutover secret — triggering auto re-cut\n' "$T_NEW"
  printf '%s REVERT kognitio: backed up /kognitio/.env → /kognitio/.env.bak.1\n' "$T_NEW"
  printf '%s DONE: at least one exact revert was auto-re-cut\n' "$T_NEW"
  printf '%s FATAL: could not read identity JWT_SECRET from /id/.env\n' "$T_NEW"
  printf '%s HEARTBEAT drift-check ok\n' "$T_NEW"
} > "$DRIFT_LOG"
{
  printf '%s OK delivery heartbeat: "%s" last delivered 1h 00m ago (threshold 26h)\n' "$T_NEW" "$HEARTBEAT_TITLE"
} > "$DELIVERY_LOG"

reset_channels
WEBHOOK="https://webhook.invalid/hook"
rc=0
run_summary phase12 > /dev/null 2>&1 || rc=$?

assert_eq "the condensed digest exits 0" "$rc" "0"
# Clean runs and registry rebuilds become counts, with no line reprinted.
assert_present "clean runs are counted per outcome" "$CURL_LOG" "2 x all stacks match identity JWT_SECRET"
assert_present "a second outcome is counted separately" \
  "$CURL_LOG" "1 x no exact reverts detected across project stacks"
assert_present "the clean-run heading totals both outcomes" "$CURL_LOG" "Clean runs (3):"
assert_absent "no individual OK line is reprinted" "$CURL_LOG" "$T_OLD OK all stacks"
assert_present "registry rebuilds collapse to a single line" \
  "$CURL_LOG" "REGISTRY rebuilds (2), last ${T_NEW%:*}"
assert_absent "no individual REGISTRY line is reprinted" "$CURL_LOG" "$T_MID REGISTRY built"
assert_absent "an unchanged registry is not called a change" "$CURL_LOG" "distinct outcomes"

# Incidents are grouped under the stack that names them.
assert_present "incidents are announced by stack" "$CURL_LOG" "Incidents by stack:"
assert_present "a single-event stack gets a heading" "$CURL_LOG" "kalcio — 1 event(s):"
assert_present "a multi-event stack is grouped" "$CURL_LOG" "kognitio — 3 event(s):"
assert_present "grouping preserves the drift line" \
  "$CURL_LOG" "DRIFT kalcio: JWT_SECRET differs from identity"
assert_present "grouping preserves the revert lines" \
  "$CURL_LOG" "REVERT kognitio: backed up /kognitio/.env"
assert_present "a two-word event is still attributed to its stack" \
  "$CURL_LOG" "REVERT DETECTED kognitio: deadbeef"
assert_present "remarks retain the stack that carries them" "$CURL_LOG" "katalogus — 1 event(s):"
# The DONE: summary belongs to the reverts it concludes (kognitio, above), so
# only the genuinely stack-less FATAL is left host-level.
assert_present "the one stack-less event is grouped separately" "$CURL_LOG" "(host-level) — 1 event(s):"
assert_present "the DONE summary is kept" "$CURL_LOG" "DONE: at least one exact revert was auto-re-cut"
assert_present "the FATAL line is kept" "$CURL_LOG" "FATAL: could not read identity JWT_SECRET"
assert_absent "a bare event keyword is not mistaken for a stack" "$CURL_LOG" "FATAL — "
assert_absent "liveness plumbing stays out of the digest" "$CURL_LOG" "HEARTBEAT"
assert_absent "the all-green wording is gone once incidents exist" \
  "$CURL_LOG" "(none — all stacks were green)"

# A changed fingerprint set is the one registry event worth flagging.
printf '%s REGISTRY built: 4 pre-cutover fingerprints (identity=bbbb…)\n' "$T_NEW" >> "$DRIFT_LOG"
rc=0
run_summary phase12_registry > /dev/null 2>&1 || rc=$?
assert_present "a changed fingerprint set is flagged" "$CURL_LOG" "2 distinct outcomes"
assert_present "the unchanged outcome is still only counted" "$CURL_LOG" "REGISTRY rebuilds (3)"

# --------------------------------------------------------------------------- #
# Phase 13: the delivery age is read live, and disagreement is called out
# --------------------------------------------------------------------------- #

echo
echo "Phase 13: the digest reads the delivery age live and flags disagreement"

# The delivery watchdog only runs hourly, so its log describes the pipeline as
# of its last check.  The digest samples the Gotify history itself at send time
# and prints the current age next to the log's verdict.  Brevo is the channel
# here because it carries the subject as well as the body, and these cases are
# as much about the subject as the body.
reset_channels
WEBHOOK=""
BREVO_KEY="brevo-key"; ALERT_EMAIL_TEST="ops@example.invalid"

# Agreement: a healthy log and a current live heartbeat say the same thing.
{
  printf '%s OK all stacks match identity JWT_SECRET\n' "$T1"
} > "$DRIFT_LOG"
printf '%s OK delivery heartbeat: "%s" last delivered 1h 00m ago (threshold 26h)\n' \
  "$T1" "$HEARTBEAT_TITLE" > "$DELIVERY_LOG"
LIVE_AGE=3600; LIVE_ERR=""
rc=0
run_summary phase13_agree || rc=$?

assert_eq "a live-checked digest exits 0" "$rc" "0"
assert_present "the live delivery age is computed at send time" "$CURL_LOG" \
  "last delivered 1h 00m ago (threshold 26h) — OK"
assert_present "the watchdog log's view sits beside it" "$CURL_LOG" \
  "Watchdog log: Healthy — 1 heartbeat check(s)"
assert_absent "agreement is not dressed up as a disagreement" "$CURL_LOG" "DISAGREEMENT"
assert_absent "an agreement never claims a conflict in the subject" \
  "$CURL_LOG" "pipeline disagreement"
assert_present "the live verdict is recorded for later audits" "$DRIFT_LOG" "PIPELINE_LIVE=ok"
assert_present "agreement is recorded too" "$DRIFT_LOG" "DISAGREE=0"

# The log reads healthy but the live heartbeat has since gone stale — exactly
# what an hourly watchdog log cannot see.
LIVE_AGE=$((30 * 3600))
rc=0
run_summary phase13_stale || rc=$?

assert_present "a stale live age is reported as stale" "$CURL_LOG" \
  "last delivered 1d 06h ago (threshold 26h) — STALE"
assert_present "a stale live age is called a disagreement" "$CURL_LOG" "⚠ DISAGREEMENT"
assert_present "the disagreement names the log's healthy reading" "$CURL_LOG" \
  "the watchdog log reads"
assert_present "the disagreement carries the live age" "$CURL_LOG" "heartbeat 1d 06h old"
assert_present "the quiet-pipeline cause is spelled out" "$CURL_LOG" \
  "the pipeline went quiet after the watchdog's last check"
assert_present "the subject escalates on the live reading alone" "$CURL_LOG" "pipeline stale"
# Escalating on the verdict is not enough: the conflict itself must be named,
# because it means one of the two readings is wrong.
assert_present "the subject names the disagreement, not just the verdict" \
  "$CURL_LOG" "pipeline stale + pipeline disagreement"
assert_present "the stale live verdict is recorded" "$DRIFT_LOG" "PIPELINE_LIVE=stale"
assert_present "the disagreement is recorded" "$DRIFT_LOG" "DISAGREE=1"

# The mirror image: the log still quotes a stall, but delivery is current again.
printf '%s STALL heartbeat-stale: The newest "%s" delivery is 1d 06h old.\n' \
  "$T2" "$HEARTBEAT_TITLE" > "$DELIVERY_LOG"
LIVE_AGE=300
rc=0
run_summary phase13_resumed || rc=$?

assert_present "a resumed pipeline is reported current" "$CURL_LOG" \
  "last delivered 5m ago (threshold 26h) — OK"
assert_present "the disagreement names the log's stall" "$CURL_LOG" "the watchdog log reads"
assert_present "the disagreement notes delivery is current" "$CURL_LOG" "delivery is current"
assert_present "the log's stall detail is still carried" "$CURL_LOG" "STALL heartbeat-stale:"
assert_present "a recovered pipeline still reads stalled in the log" "$CURL_LOG" "pipeline stalled"
# Without the disagreement the subject would assert a stalled pipeline while
# delivery is current — blaming the pipeline for a stale log.
assert_present "the subject flags the conflict behind that verdict" \
  "$CURL_LOG" "pipeline stalled + pipeline disagreement"

# Both readings agree the pipeline is unhealthy: that is a pipeline problem,
# not a conflict, and the subject must not cry disagreement on top of it.
printf '%s STALL heartbeat-stale: The newest "%s" delivery is 1d 06h old.\n' \
  "$T2" "$HEARTBEAT_TITLE" > "$DELIVERY_LOG"
LIVE_AGE=$((30 * 3600))
rc=0
run_summary phase13_both_bad || rc=$?

assert_present "a stale live reading beside a stalled log still escalates" \
  "$CURL_LOG" "pipeline stale"
assert_absent "two readings that agree on failure are not a conflict" \
  "$CURL_LOG" "pipeline disagreement"
assert_present "agreement on failure is recorded" "$DRIFT_LOG" "DISAGREE=0"

# The watchdog itself silent while the live history is fine: the log is not
# evidence the pipeline is down, so the digest says which side looks broken.
# LIVE_AGE is set here rather than inherited, so this case states its own input.
rm -f "$DELIVERY_LOG"
LIVE_AGE=300
rc=0
run_summary phase13_watchdog_down || rc=$?

assert_present "a silent watchdog is still called unverified" "$CURL_LOG" \
  "Watchdog log: UNVERIFIED"
assert_present "the live reading is contrasted with the silent watchdog" "$CURL_LOG" \
  "the watchdog, not the pipeline, looks down"
assert_present "the subject flags the watchdog/log conflict" "$CURL_LOG" \
  "pipeline unverified + pipeline disagreement"

# No heartbeat in the history at all, while the log claims healthy.
printf '%s OK delivery heartbeat: "%s" last delivered 1h 00m ago (threshold 26h)\n' \
  "$T1" "$HEARTBEAT_TITLE" > "$DELIVERY_LOG"
LIVE_AGE=-1
rc=0
run_summary phase13_missing || rc=$?

assert_present "a missing live heartbeat is reported" "$CURL_LOG" \
  "in the history — MISSING"
assert_present "a missing live heartbeat is a disagreement" "$CURL_LOG" "⚠ DISAGREEMENT"
assert_present "the subject escalates on the missing heartbeat" "$CURL_LOG" "pipeline missing"
assert_present "the subject flags the conflict on the missing heartbeat" "$CURL_LOG" \
  "pipeline missing + pipeline disagreement"
assert_present "the missing live verdict is recorded" "$DRIFT_LOG" "PIPELINE_LIVE=missing"

# The history cannot be read at all: say so honestly, and do not manufacture a
# disagreement out of a reading that was never taken.
LIVE_ERR="gotify-messages: database not found: /nowhere/gotify.db"
rc=0
run_summary phase13_unreadable || rc=$?

assert_eq "an unreadable history still sends the digest" "$rc" "0"
assert_present "an unreadable history is reported honestly" "$CURL_LOG" \
  "Live: unavailable — gotify-messages: database not found"
assert_absent "an unreadable history is not a disagreement" "$CURL_LOG" "DISAGREEMENT"
assert_present "the unreadable reading is recorded" "$DRIFT_LOG" "PIPELINE_LIVE=unreadable"

# The helper answered, but not with an age: never read that as zero seconds and
# call the pipeline healthy.
LIVE_AGE="not-a-number"; LIVE_ERR=""
rc=0
run_summary phase13_unparsable || rc=$?

assert_eq "an unparsable reading still sends the digest" "$rc" "0"
assert_present "an unparsable reading is reported as such" "$CURL_LOG" \
  "Live: unexpected age reading from the history"
assert_absent "an unparsable reading never reads as healthy" "$CURL_LOG" "— OK"
assert_present "the unparsable reading is recorded" "$DRIFT_LOG" "PIPELINE_LIVE=unparsable"

# --------------------------------------------------------------------------- #
# Phase 14: a DONE summary is attributed to the stack its run re-cut
# --------------------------------------------------------------------------- #

echo
echo "Phase 14: stack-less DONE lines inherit the stack of the reverts they conclude"

# jwt-secret-revert-watchdog.sh writes one DONE: line per run and names no stack
# in it, so the digest must infer the stack from the run's REVERT lines.  A run
# begins at its REGISTRY line, which is what keeps one run's summary from being
# pinned on another run's stack.

cat > "$SANDBOX/check_done.py" <<'PY'
import json
import sys

text = json.load(open(sys.argv[1]))["text"]
check = sys.argv[2]

SUCCESS = "DONE: at least one exact revert was auto-re-cut"
FAILED = "DONE: revert detected but re-cut FAILED"


def group(name):
    """The event lines listed under a stack's heading."""
    out, on = [], False
    for ln in text.splitlines():
        if ln.startswith("  " + name + " — "):
            on = True
            continue
        if on and ln.startswith("  ") and not ln.startswith("    "):
            on = False
        if on and ln.startswith("    "):
            out.append(ln.strip())
    return out


if check == "first-run":
    g = group("kognitio")
    sys.exit(0 if len(g) == 3 and sum(SUCCESS in l for l in g) == 1 else 1)
if check == "second-run":
    g = group("kalcio")
    sys.exit(0 if len(g) == 2 and sum(SUCCESS in l for l in g) == 1 else 1)
if check == "no-bleed":
    sys.exit(
        0
        if not any("kalcio" in l for l in group("kognitio"))
        and not any("kognitio" in l for l in group("kalcio"))
        else 1
    )
if check == "no-host-level":
    sys.exit(0 if group("(host-level)") == [] else 1)
if check == "multi-stack":
    kog, kal = group("kognitio"), group("kalcio")
    sys.exit(
        0
        if sum(SUCCESS in l for l in kog) == 1 and sum(SUCCESS in l for l in kal) == 1
        else 1
    )
if check == "fallback":
    g = group("(host-level)")
    sys.exit(0 if len(g) == 1 and FAILED in g[0] else 1)
sys.exit(2)
PY

# assert_py <label> <json> <check-name>
assert_py() {
  if python3 "$SANDBOX/check_done.py" "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1"; fi
}

# Two runs in one window, each with its own revert.
{
  printf '%s REGISTRY built: 5 pre-cutover fingerprints (identity=aaaa…)\n' "$T_OLD"
  printf '%s REVERT DETECTED kognitio: deadbeef = pre-cutover secret — triggering auto re-cut\n' "$T_OLD"
  printf '%s REVERT kognitio: re-cut complete\n' "$T_OLD"
  printf '%s DONE: at least one exact revert was auto-re-cut\n' "$T_OLD"
  printf '%s REGISTRY built: 5 pre-cutover fingerprints (identity=aaaa…)\n' "$T_NEW"
  printf '%s REVERT DETECTED kalcio: feedface = pre-cutover secret — triggering auto re-cut\n' "$T_NEW"
  printf '%s DONE: at least one exact revert was auto-re-cut\n' "$T_NEW"
} > "$DRIFT_LOG"
printf '%s OK delivery heartbeat: "%s" last delivered 1h 00m ago (threshold 26h)\n' \
  "$T_NEW" "$HEARTBEAT_TITLE" > "$DELIVERY_LOG"

reset_channels
WEBHOOK="https://webhook.invalid/hook"
rc=0
run_summary phase14_runs > /dev/null 2>&1 || rc=$?

assert_eq "the DONE-attribution digest exits 0" "$rc" "0"
awk '/^-d$/{getline; print; exit}' "$CURL_LOG" > "$SANDBOX/phase14.json"
assert_py "a DONE is grouped with the reverts its own run concluded" \
  "$SANDBOX/phase14.json" first-run
assert_py "the second run's DONE sits under its own stack" \
  "$SANDBOX/phase14.json" second-run
assert_py "a DONE never bleeds onto another run's stack" \
  "$SANDBOX/phase14.json" no-bleed
assert_py "no DONE is left in the host-level bucket" \
  "$SANDBOX/phase14.json" no-host-level

# One run that re-cut two stacks: its single DONE concludes both.
{
  printf '%s REGISTRY built: 5 pre-cutover fingerprints (identity=aaaa…)\n' "$T_NEW"
  printf '%s REVERT DETECTED kognitio: deadbeef = pre-cutover secret\n' "$T_NEW"
  printf '%s REVERT DETECTED kalcio: feedface = pre-cutover secret\n' "$T_NEW"
  printf '%s REVERT kognitio: re-cut complete\n' "$T_NEW"
  printf '%s REVERT kalcio: re-cut complete\n' "$T_NEW"
  printf '%s DONE: at least one exact revert was auto-re-cut\n' "$T_NEW"
} > "$DRIFT_LOG"
rc=0
run_summary phase14_multi > /dev/null 2>&1 || rc=$?
awk '/^-d$/{getline; print; exit}' "$CURL_LOG" > "$SANDBOX/phase14m.json"
assert_py "a run that re-cut two stacks concludes both" \
  "$SANDBOX/phase14m.json" multi-stack

# The window can open in the middle of an incident: the reverts are outside it,
# so there is genuinely nothing to attribute the summary to.
{
  printf '%s DONE: revert detected but re-cut FAILED — manual intervention required\n' "$T_NEW"
} > "$DRIFT_LOG"
rc=0
run_summary phase14_fallback > /dev/null 2>&1 || rc=$?
awk '/^-d$/{getline; print; exit}' "$CURL_LOG" > "$SANDBOX/phase14f.json"
assert_py "a DONE whose reverts fell outside the window stays host-level" \
  "$SANDBOX/phase14f.json" fallback

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
