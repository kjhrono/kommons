#!/usr/bin/env bash
# test_gotify_report_digest.sh
#
# Hermetic test for gotify-report-digest.sh, the wrapper that emails the
# Gotify alert-history report periodically.
#
# The audit helper (gotify-messages.sh) and the mail/curl delivery binaries
# are all stubbed, so the test controls the report text, the alert count and
# every byte that would have left the machine.  Two guarantees matter most:
#
#   * the digest goes out by EMAIL and never through Gotify, because pushing
#     it would insert the digest into the very history it summarises;
#   * exactly one channel is used — a recipient must not get two copies.
#
# Usage:
#   tool/test_gotify_report_digest.sh
#   DIGEST=~/bin/gotify-report-digest.sh tool/test_gotify_report_digest.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Prefer a copy sitting beside this test — the deployed ~/bin layout — and
# fall back to the in-repo tool/ directory.
if [ -f "${SCRIPT_DIR}/gotify-report-digest.sh" ]; then
  DEFAULT_DIR="$SCRIPT_DIR"
else
  DEFAULT_DIR="$REPO_ROOT/tool"
fi

DIGEST="${DIGEST:-$DEFAULT_DIR/gotify-report-digest.sh}"

if [ ! -f "$DIGEST" ]; then
  echo "FATAL: digest not found at $DIGEST" >&2
  exit 2
fi
if [ ! -f "$(dirname "$DIGEST")/alert.sh" ]; then
  echo "FATAL: alert.sh not found beside $DIGEST" >&2
  exit 2
fi

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/home/logs" "$SANDBOX/bin"

AUDIT_STUB="$SANDBOX/bin/gotify-messages.sh"
DIGEST_LOG="$SANDBOX/home/logs/gotify-report.log"
STUB_REPORT="$SANDBOX/report.txt"

cat > "$AUDIT_STUB" <<'STUB'
#!/usr/bin/env bash
# Stand-in for gotify-messages.sh: records the call, then answers --count
# with a scripted number and everything else with a scripted report.
printf '%s\n' "$*" >> "$AUDIT_LOG"
if [ "${STUB_RC:-0}" -ne 0 ]; then
  echo "gotify-messages: cannot read ${GOTIFY_DB}: stub failure" >&2
  exit "${STUB_RC}"
fi
for arg in "$@"; do
  if [ "$arg" = "--count" ]; then
    printf '%s\n' "${STUB_COUNT:-0}"
    exit 0
  fi
done
cat "$STUB_REPORT"
STUB
chmod +x "$AUDIT_STUB"

# curl is invoked with nothing on stdin, so it must NOT read stdin; mail
# receives the body on a pipe and drains it into the log.
cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf -- '--- curl call ---\n' >> "$CURL_LOG"
for arg in "$@"; do printf '%s\n' "$arg" >> "$CURL_LOG"; done
exit 0
STUB
cat > "$SANDBOX/bin/mail" <<'STUB'
#!/usr/bin/env bash
printf -- '--- mail call ---\n' >> "$MAIL_LOG"
printf 'ARGS: %s\n' "$*" >> "$MAIL_LOG"
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
AUDIT_LOG=""
GOTIFY_DB="$SANDBOX/home/gotify/data/gotify.db"
REPORT_HOURS=168
ALERT_EMAIL="ops@example.invalid"
BREVO_API_KEY="brevo-key"
GOTIFY_URL_TEST=""
GOTIFY_TOKEN_TEST=""
STUB_RC=0
STUB_COUNT=42

# A report shaped exactly like gotify-messages.sh --report.
write_report() {
  cat > "$STUB_REPORT" <<'R'
Gotify alert report
Range:   2026-09-29 08:00 → 2026-10-06 08:00 UTC  (7d0h)
Matched: 42 of 42 message(s) in the database

By monitor (fires most first)
     30  JWT Daily Summary
      9  Drift Check
      3  Revert Watchdog
  busiest: JWT Daily Summary (30)

By monitor vs previous window
  Previous: 2026-09-22 08:00 → 2026-09-29 08:00 UTC  (7d0h)
  JWT Daily Summary                       36 →   30   -6  ▼
  Drift Check                              6 →    9   +3  ▲
  Revert Watchdog                          3 →    3   +0  =
  trend: down 45 → 42 (-7%) — 1 rose, 1 fell, 1 flat

Volume over time (daily buckets, UTC)
  2026-09-29  ###  3
  2026-10-06  #    1
  peak: 2026-09-29 (3)

By priority
      5  x42

By app
  jwt-alerts  x42
R
}

reset_case() {
  ALERT_EMAIL="ops@example.invalid"
  BREVO_API_KEY="brevo-key"
  GOTIFY_URL_TEST=""
  GOTIFY_TOKEN_TEST=""
  REPORT_HOURS=168
  STUB_RC=0
  STUB_COUNT=42
  write_report
}

# run_digest <tag> [args...]
run_digest() {
  local tag="$1"; shift
  CURL_LOG="$SANDBOX/$tag.curl.log"; : > "$CURL_LOG"
  MAIL_LOG="$SANDBOX/$tag.mail.log"; : > "$MAIL_LOG"
  AUDIT_LOG="$SANDBOX/$tag.audit.log"; : > "$AUDIT_LOG"
  # Each run is judged on its own log line, not on the accumulated file.
  : > "$DIGEST_LOG"
  env -i \
    PATH="$BASE_PATH" HOME="$SANDBOX/home" HOST="testhost" \
    AUDIT="$AUDIT_STUB" AUDIT_LOG="$AUDIT_LOG" \
    STUB_RC="$STUB_RC" STUB_COUNT="$STUB_COUNT" STUB_REPORT="$STUB_REPORT" \
    GOTIFY_DB="$GOTIFY_DB" REPORT_HOURS="$REPORT_HOURS" \
    ALERT_EMAIL="$ALERT_EMAIL" BREVO_API_KEY="$BREVO_API_KEY" \
    GOTIFY_URL="$GOTIFY_URL_TEST" GOTIFY_APP_TOKEN="$GOTIFY_TOKEN_TEST" \
    LOG="$DIGEST_LOG" CURL_LOG="$CURL_LOG" MAIL_LOG="$MAIL_LOG" \
    bash "$DIGEST" "$@"
}

curl_calls() { awk '/^--- curl call ---$/{n++} END{print n+0}' "$CURL_LOG" 2>/dev/null || echo 0; }
mail_calls() { awk '/^--- mail call ---$/{n++} END{print n+0}' "$MAIL_LOG" 2>/dev/null || echo 0; }

echo "Digest:  $DIGEST"
echo "Sandbox: $SANDBOX"
echo

# --------------------------------------------------------------------------- #
# Phase 1: dry run previews without sending
# --------------------------------------------------------------------------- #

echo "Phase 1: --dry-run prints the digest and sends nothing"

reset_case
rc=0
run_digest dry --dry-run > "$SANDBOX/dry.out" 2>&1 || rc=$?

assert_eq "a dry run exits 0" "$rc" "0"
assert_present "the dry run prints a subject" "$SANDBOX/dry.out" "Gotify alert digest — testhost — 42 alert(s) in 7d"
assert_present "the dry run prints the header" "$SANDBOX/dry.out" "Window:   past 7d (168h)"
assert_present "the dry run prints the report" "$SANDBOX/dry.out" "By monitor (fires most first)"
assert_present "the dry run states the direction of the trend" "$SANDBOX/dry.out" \
  "Trend:    down 45 → 42 (-7%) — 1 rose, 1 fell, 1 flat"
# Direction is the headline: the trend must be readable before the busiest row.
trend_line="$(grep -n "^Trend:" "$SANDBOX/dry.out" | cut -d: -f1)"
busiest_line="$(grep -n "^Busiest:" "$SANDBOX/dry.out" | cut -d: -f1)"
if [ -n "$trend_line" ] && [ -n "$busiest_line" ] && [ "$trend_line" -lt "$busiest_line" ]; then
  ok "the header states direction above the busiest monitor"
else
  bad "the header states direction above the busiest monitor (trend=$trend_line busiest=$busiest_line)"
fi
assert_eq "The dry run sends no email" "$(curl_calls)" "0"
assert_eq "the dry run sends no mail" "$(mail_calls)" "0"
assert_present "the dry run is logged as a dry run" "$DIGEST_LOG" "DRY-RUN digest: alerts=42 window=168h"

# --------------------------------------------------------------------------- #
# Phase 2: Brevo delivery — one email, no push
# --------------------------------------------------------------------------- #

echo
echo "Phase 2: the digest is delivered by email, once, and never pushed"

reset_case
# Gotify credentials are present on the VM, so prove they are ignored here.
GOTIFY_URL_TEST="https://gotify.invalid"; GOTIFY_TOKEN_TEST="test-token"
rc=0
run_digest brevo > /dev/null 2>&1 || rc=$?

assert_eq "an emailed digest exits 0" "$rc" "0"
assert_eq "exactly one email channel is used" "$(curl_calls)" "1"
assert_eq "no local mail is sent alongside it" "$(mail_calls)" "0"
assert_present "the email goes through Brevo" "$CURL_LOG" "api.brevo.com"
assert_present "the subject counts the alerts and names the window" \
  "$CURL_LOG" "Gotify alert digest — testhost — 42 alert(s) in 7d"
assert_present "the recipient is the configured address" "$CURL_LOG" "ops@example.invalid"
assert_present "the body carries the report" "$CURL_LOG" "By monitor (fires most first)"
assert_present "the body carries the header" "$CURL_LOG" "Alerts:   42 delivered in the window"
assert_present "the body promotes the busiest monitor" "$CURL_LOG" "Busiest:  JWT Daily Summary (30)"
assert_present "the body promotes the direction of the trend" "$CURL_LOG" \
  "Trend:    down 45 → 42 (-7%) — 1 rose, 1 fell, 1 flat"
assert_present "the body names the database" "$CURL_LOG" "Database: $GOTIFY_DB"
# The whole point: the digest must not enter the history it reports on.
assert_absent "the digest is never pushed to Gotify" "$CURL_LOG" "/message?token="
assert_present "the delivery is logged with its channel" "$DIGEST_LOG" "OK digest sent via brevo: alerts=42 window=168h"

# --------------------------------------------------------------------------- #
# Phase 3: local mail is the fallback when Brevo is not configured
# --------------------------------------------------------------------------- #

echo
echo "Phase 3: mail(1) is used when Brevo is not configured"

reset_case
BREVO_API_KEY=""
rc=0
run_digest mail > /dev/null 2>&1 || rc=$?

assert_eq "a mail-fallback digest exits 0" "$rc" "0"
assert_eq "no Brevo call is made" "$(curl_calls)" "0"
assert_eq "one local mail is sent" "$(mail_calls)" "1"
assert_present "the mail subject counts the alerts" "$MAIL_LOG" "Gotify alert digest — testhost — 42 alert(s) in 7d"
assert_present "the recipient is passed to mail" "$MAIL_LOG" "ops@example.invalid"
assert_present "the mail body carries the report" "$MAIL_LOG" "By monitor (fires most first)"
assert_present "the mail body carries the trend direction" "$MAIL_LOG" \
  "Trend:    down 45 → 42 (-7%)"
assert_present "the delivery is logged with its channel" "$DIGEST_LOG" "OK digest sent via mail: alerts=42 window=168h"

# --------------------------------------------------------------------------- #
# Phase 4: no channel configured is reported honestly
# --------------------------------------------------------------------------- #

echo
echo "Phase 4: without an email channel the digest says so instead of pretending"

reset_case
ALERT_EMAIL=""; BREVO_API_KEY=""
rc=0
run_digest nochannel > /dev/null 2>&1 || rc=$?

assert_eq "a channel-less run still exits 0" "$rc" "0"
assert_eq "nothing is sent by Brevo" "$(curl_calls)" "0"
assert_eq "nothing is sent by mail" "$(mail_calls)" "0"
assert_present "the log admits the digest went nowhere" "$DIGEST_LOG" "NOTE digest not sent: no email channel configured"
assert_absent "the log does not claim a send" "$DIGEST_LOG" "OK digest sent"

# A BREVO_API_KEY without a recipient cannot deliver either.
reset_case
ALERT_EMAIL=""; BREVO_API_KEY="brevo-key"
rc=0
run_digest norecipient > /dev/null 2>&1 || rc=$?
assert_eq "a key without a recipient sends nothing" "$(curl_calls)" "0"
assert_present "a key without a recipient is reported" "$DIGEST_LOG" "NOTE digest not sent"

# --------------------------------------------------------------------------- #
# Phase 5: the report window is configurable and passed through
# --------------------------------------------------------------------------- #

echo
echo "Phase 5: REPORT_HOURS drives the window, the label and the query"

reset_case
REPORT_HOURS=36
rc=0
run_digest window36 > /dev/null 2>&1 || rc=$?

assert_present "the audit is asked for a 36h window" "$AUDIT_LOG" "--since-hours 36 --report"
assert_present "the count is asked for the same window" "$AUDIT_LOG" "--since-hours 36 --count -n 0"
assert_present "a non-day window is labelled in hours" "$CURL_LOG" "42 alert(s) in 36h"
assert_present "the header reports the window in hours" "$CURL_LOG" "Window:   past 36h (36h)"
assert_present "the log records the configured window" "$DIGEST_LOG" "window=36h"

reset_case
REPORT_HOURS=48
rc=0
run_digest window48 > /dev/null 2>&1 || rc=$?
assert_present "a whole number of days is labelled in days" "$CURL_LOG" "42 alert(s) in 2d"

# The count must not be clipped by the table's default row limit.
assert_present "the count disables the row limit" "$AUDIT_LOG" "--count -n 0"

# --------------------------------------------------------------------------- #
# Phase 6: a quiet window is still reported
# --------------------------------------------------------------------------- #

echo
echo "Phase 6: a window with no alerts is still delivered"

reset_case
STUB_COUNT=0
cat > "$STUB_REPORT" <<'R'
Gotify alert report
Range:   2026-09-29 08:00 → 2026-10-06 08:00 UTC  (7d0h)
Matched: 0 of 42 message(s) in the database

No messages matched the filters.
R
rc=0
run_digest quiet > /dev/null 2>&1 || rc=$?

assert_eq "a quiet digest exits 0" "$rc" "0"
assert_eq "a quiet digest is still delivered" "$(curl_calls)" "1"
assert_present "the subject says zero alerts" "$CURL_LOG" "0 alert(s) in 7d"
assert_present "the body repeats the report's empty verdict" "$CURL_LOG" "No messages matched the filters."
assert_absent "a quiet window invents no busiest monitor" "$CURL_LOG" "Busiest:"
assert_absent "a quiet window claims no busiest in the subject" "$CURL_LOG" "no clear leader"
assert_absent "a quiet window invents no trend" "$CURL_LOG" "Trend:"

# The report's tie verdict is carried through verbatim rather than guessed at.
reset_case
sed -i 's/  busiest: JWT Daily Summary (30)/  busiest: no clear leader — 3 monitors tied at 30/' "$STUB_REPORT"
rc=0
run_digest tie > /dev/null 2>&1 || rc=$?
assert_present "a tie is reported as a tie" "$CURL_LOG" "Busiest:  no clear leader — 3 monitors tied at 30"

# A report built before the comparison existed must not leave an empty header
# line — the digest promotes a verdict, it never invents one.
reset_case
sed -i '/^  trend: /d' "$STUB_REPORT"
rc=0
run_digest notrend > /dev/null 2>&1 || rc=$?
assert_eq "a report without a trend still delivers" "$(curl_calls)" "1"
assert_absent "a missing trend leaves no empty header line" "$CURL_LOG" "Trend:"
assert_present "the rest of the header survives" "$CURL_LOG" "Busiest:  JWT Daily Summary (30)"

# --------------------------------------------------------------------------- #
# Phase 7: failures are loud and never look like a delivery
# --------------------------------------------------------------------------- #

echo
echo "Phase 7: a report that cannot be built fails loudly"

reset_case
STUB_RC=1
rc=0
run_digest broken > /dev/null 2>&1 || rc=$?

assert_eq "an unreadable history exits 1" "$rc" "1"
assert_present "the failure is logged" "$DIGEST_LOG" "FATAL report failed"
assert_present "the underlying error is carried" "$DIGEST_LOG" "stub failure"
assert_eq "the failure is reported by email" "$(curl_calls)" "1"
assert_present "the failure email says so" "$CURL_LOG" "Gotify alert digest FAILED"
assert_absent "the failure is not logged as a successful digest" "$DIGEST_LOG" "OK digest sent"

reset_case
STUB_COUNT="not-a-number"
rc=0
run_digest badcount > /dev/null 2>&1 || rc=$?
assert_eq "an unparsable count exits 1" "$rc" "1"
assert_present "the bad count is explained" "$DIGEST_LOG" "count produced an unexpected value"

# --------------------------------------------------------------------------- #
# Phase 8: configuration errors
# --------------------------------------------------------------------------- #

echo
echo "Phase 8: configuration errors are rejected before anything is sent"

reset_case
rc=0
env -i PATH="$BASE_PATH" HOME="$SANDBOX/home" AUDIT="$SANDBOX/nope.sh" \
  LOG="$DIGEST_LOG" bash "$DIGEST" > "$SANDBOX/cfg.out" 2>&1 || rc=$?
assert_eq "a missing audit helper exits 2" "$rc" "2"
assert_present "the missing helper is named" "$SANDBOX/cfg.out" "audit helper not found"

reset_case
REPORT_HOURS=0
rc=0
run_digest zerohours > "$SANDBOX/zero.out" 2>&1 || rc=$?
assert_eq "a zero-hour window exits 2" "$rc" "2"
assert_present "the zero window is explained" "$SANDBOX/zero.out" "REPORT_HOURS must be at least 1"

reset_case
REPORT_HOURS="week"
rc=0
run_digest badhours > "$SANDBOX/bad.out" 2>&1 || rc=$?
assert_eq "a non-numeric window exits 2" "$rc" "2"
assert_present "the bad window is explained" "$SANDBOX/bad.out" "REPORT_HOURS must be a non-negative integer"

reset_case
rc=0
run_digest badopt --nonsense > "$SANDBOX/opt.out" 2>&1 || rc=$?
assert_eq "an unknown option exits 2" "$rc" "2"
assert_present "the unknown option is named" "$SANDBOX/opt.out" "unknown option: --nonsense"

# --------------------------------------------------------------------------- #
# Phase 9: --help documents the interface without running it
# --------------------------------------------------------------------------- #

echo
echo "Phase 9: --help prints the header documentation"

reset_case
rc=0
run_digest help --help > "$SANDBOX/help.out" 2>&1 || rc=$?

assert_eq "--help exits 0" "$rc" "0"
assert_present "--help documents the window knob" "$SANDBOX/help.out" "REPORT_HOURS"
assert_present "--help documents the dry run" "$SANDBOX/help.out" "--dry-run"
assert_present "--help documents the exit codes" "$SANDBOX/help.out" "Exit status"
assert_eq "--help sends nothing" "$(curl_calls)" "0"
assert_eq "--help sends no mail" "$(mail_calls)" "0"

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
