#!/usr/bin/env bash
# gotify-report-digest.sh — periodic alert-history digest, delivered by email.
#
# `gotify-messages.sh --report` answers "how has the alert stream been
# behaving?", but only when someone remembers to ask.  This wrapper runs that
# report over a fixed window and mails it, so the trend arrives on its own.
#
# The report compares its window against the preceding one and states which
# monitors rose or fell.  The digest lifts that verdict into its own header, so
# whether the alert stream is getting noisier is visible before the report body
# — the shape of the stream was already there in the bars; the direction was
# not.
#
# Email only, deliberately.  The report is built from Gotify's `messages`
# table, so pushing the digest to Gotify would write it into the very history
# it summarises: every later run would count the previous digest as a
# delivery and the "By monitor" trend would slowly fill with the reporting
# itself.  Keeping the digest off the push channel is what keeps the trends
# honest.
#
# Local mail(1) is only a fallback.  Brevo is preferred when configured,
# because it does not depend on an MTA being installed and working, and the
# digest is then delivered by the same path the other monitors already use.
#
# The digest is always sent, even when the window holds no alerts: a weekly
# "0 alerts" is a useful confirmation, and a missing digest must mean the
# job did not run rather than that the silence was good news.  The
# alert-pipeline dead-man's switch covers the case where the pipeline
# itself is down.
#
# Configuration (set in crontab environment or export):
#   REPORT_HOURS    window summarised, in hours (default: 168 = 7 days)
#   GOTIFY_DB       path to gotify.db (default: $HOME/gotify/data/gotify.db)
#   AUDIT           path to gotify-messages.sh (default: beside this script)
#   LOG             audit log (default: $HOME/logs/gotify-report.log)
#   HOST            host name used in the subject (default: hostname)
#   DRY_RUN         non-empty → print the digest, send nothing
#
# Email configuration (from alert.sh; unset → the digest is not delivered):
#   ALERT_EMAIL       recipient (required whichever channel is used)
#   BREVO_API_KEY     with ALERT_EMAIL, sends through the Brevo REST API
#   BREVO_SENDER      Brevo sender address (default: noreply@mediasart.com)
#   BREVO_SENDER_NAME Brevo sender name (default: mediasart)
#   mail(1)           fallback channel when Brevo is not configured
#
# Usage:
#   gotify-report-digest.sh            # email the digest
#   gotify-report-digest.sh --dry-run  # print it instead
#
# Exit status: 0 sent (or deliberately not sent), 1 the report could not be
# built, 2 usage or configuration error.
set -euo pipefail

# Source shared alert helpers (send_email_alert, send_brevo_alert,
# timestamp) from tool/alert.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=alert.sh
. "${SCRIPT_DIR}/alert.sh"

REPORT_HOURS="${REPORT_HOURS:-168}"
GOTIFY_DB="${GOTIFY_DB:-$HOME/gotify/data/gotify.db}"
AUDIT="${AUDIT:-${SCRIPT_DIR}/gotify-messages.sh}"
LOG="${LOG:-$HOME/logs/gotify-report.log}"
HOST="${HOST:-$(hostname)}"
DRY_RUN="${DRY_RUN:-}"
ALERT_EMAIL="${ALERT_EMAIL:-}"
BREVO_API_KEY="${BREVO_API_KEY:-}"

usage_error() { echo "gotify-report-digest: $1" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d'; exit 0 ;;
    *) usage_error "unknown option: $1" ;;
  esac
  shift
done

case "$REPORT_HOURS" in
  ''|*[!0-9]*) usage_error "REPORT_HOURS must be a non-negative integer" ;;
esac
[ "$REPORT_HOURS" -gt 0 ] || usage_error "REPORT_HOURS must be at least 1"

if [ ! -f "$AUDIT" ]; then
  echo "gotify-report-digest: audit helper not found at $AUDIT" >&2
  exit 2
fi

mkdir -p "$(dirname "$LOG")"

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #

# human_window <hours> — compact label for subjects and log lines.
human_window() {
  local h="$1"
  if [ "$h" -ge 24 ] && [ $((h % 24)) -eq 0 ]; then
    printf '%dd' $((h / 24))
  else
    printf '%dh' "$h"
  fi
}

# The channel policy (one copy, never two) lives in alert.sh, shared with the
# daily summary — see preferred_email_channel / send_email_report there.

# fatal <message> — log, try to say so by email, and fail.
fatal() {
  echo "$(timestamp) FATAL $1" >> "$LOG"
  if [ -n "$ALERT_EMAIL" ]; then
    send_email_report "[Digest] Gotify alert digest FAILED — ${HOST}" \
      "The Gotify alert-history digest could not be produced.

${1}

Database: ${GOTIFY_DB}
Log:      ${LOG}" >/dev/null || true
  fi
  echo "gotify-report-digest: $1" >&2
  exit 1
}

# --------------------------------------------------------------------------- #
# Build the digest
# --------------------------------------------------------------------------- #

WINDOW="$(human_window "$REPORT_HOURS")"

err="$(mktemp)"
trap 'rm -f "$err"' EXIT

report=""
rc=0
report="$(GOTIFY_DB="$GOTIFY_DB" "$AUDIT" --since-hours "$REPORT_HOURS" --report 2>"$err")" || rc=$?
if [ "$rc" -ne 0 ]; then
  fatal "report failed (exit ${rc}): $(tr '\n' ' ' < "$err")"
fi
[ -n "$report" ] || fatal "report produced no output for ${REPORT_HOURS}h window"

# The true total, independent of the table's default row limit: -n 0 means
# "no limit", so a busy window is not silently reported as 20 alerts.
count=""
rc=0
count="$(GOTIFY_DB="$GOTIFY_DB" "$AUDIT" --since-hours "$REPORT_HOURS" --count -n 0 2>>"$err")" || rc=$?
if [ "$rc" -ne 0 ]; then
  fatal "count failed (exit ${rc}): $(tr '\n' ' ' < "$err")"
fi
case "$count" in
  ''|*[!0-9]*) fatal "count produced an unexpected value: '${count}'" ;;
esac

# The report already decides which monitor fires most and which way the window
# is moving; lift both verdicts into the header so the digest can be triaged
# from its first lines.  The direction leads, because it is what an operator
# acts on.
busiest="$(printf '%s\n' "$report" | sed -n 's/^  busiest: //p' | head -1)"
trend="$(printf '%s\n' "$report" | sed -n 's/^  trend: //p' | head -1)"

body="Gotify alert digest — ${HOST}
Window:   past ${WINDOW} (${REPORT_HOURS}h)
Database: ${GOTIFY_DB}
Alerts:   ${count} delivered in the window"
if [ -n "$trend" ]; then
  body="${body}
Trend:    ${trend}"
fi
if [ -n "$busiest" ]; then
  body="${body}
Busiest:  ${busiest}"
fi
body="${body}

${report}

--
Sent by gotify-report-digest.sh on ${HOST}."

subject="📊 Gotify alert digest — ${HOST} — ${count} alert(s) in ${WINDOW}"

# --------------------------------------------------------------------------- #
# Deliver
# --------------------------------------------------------------------------- #

if [ -n "$DRY_RUN" ]; then
  echo "$subject"
  echo
  echo "$body"
  echo "$(timestamp) DRY-RUN digest: alerts=${count} window=${REPORT_HOURS}h channel=$(preferred_email_channel)" >> "$LOG"
  exit 0
fi

sent="$(send_email_report "$subject" "$body")"

if [ -n "$sent" ]; then
  echo "$(timestamp) OK digest sent via ${sent}: alerts=${count} window=${REPORT_HOURS}h" >> "$LOG"
else
  # Say plainly that nothing was delivered, rather than claiming a send.
  echo "$(timestamp) NOTE digest not sent: no email channel configured (need ALERT_EMAIL plus BREVO_API_KEY, or mail(1))" >> "$LOG"
fi

exit 0
