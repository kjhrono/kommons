#!/usr/bin/env bash
# jwt-secret-daily-summary.sh
#
# Daily digest of JWT-secret health spanning the past 24h (configurable
# via WINDOW_HOURS).  Reports all OK runs plus any DRIFT, WARN, and
# REVERT incidents found in the shared drift-watchdog log.
#
# Delivered via incoming-webhook (when ALERT_WEBHOOK_URL is set)
# and Brevo email (when BREVO_API_KEY is set) — same alert env-var scheme
# as drift-check.sh and jwt-secret-revert-watchdog.sh.
#
# Alert env vars:
#   ALERT_WEBHOOK_URL  — incoming-webhook URL for real-time alerts;
#                        empty → silent no-op
#   ALERT_EMAIL        — email recipient
#   BREVO_API_KEY      — Brevo REST API key for email delivery
#   BREVO_SENDER       — sender email (default: noreply@mediasart.com)
#   BREVO_SENDER_NAME  — sender name (default: mediasart)
#
# Operational env vars:
#   LOG                — path to log file (default: ~/logs/jwt-secret-drift.log)
#   WINDOW_HOURS       — summary window in hours (default: 24; set to 4 for testing)
set -euo pipefail

# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #

LOG="${LOG:-$HOME/logs/jwt-secret-drift.log}"
WINDOW_HOURS="${WINDOW_HOURS:-24}"
WINDOW_SECONDS=$((WINDOW_HOURS * 60 * 60))
NOW_EPOCH=$(date +%s)
CUTOFF_EPOCH=$((NOW_EPOCH - WINDOW_SECONDS))

# Alert config (same env vars as drift-check.sh / watchdog)
# ALERT_WEBHOOK_URL is a generic incoming-webhook URL accepted by any
# webhook-compatible notification target (Gotify, Telegram bot, etc.).
ALERT_WEBHOOK_URL="${ALERT_WEBHOOK_URL:-}"
ALERT_EMAIL="${ALERT_EMAIL:-}"
BREVO_API_KEY="${BREVO_API_KEY:-}"
BREVO_SENDER="${BREVO_SENDER:-noreply@mediasart.com}"
BREVO_SENDER_NAME="${BREVO_SENDER_NAME:-mediasart}"

HOST=$(hostname)

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #

ts_to_epoch() {
  local ts="$1"
  date -d "${ts}" +%s 2>/dev/null || echo 0
}

# Escape a string for JSON: backslash → \\, quote → \", newline → \n
json_escape() {
  printf '%s' "$1" \
    | sed 's/\\/\\\\/g' \
    | sed 's/"/\\"/g' \
    | sed ':a;N;$!ba;s/\n/\\n/g'
}

# --------------------------------------------------------------------------- #
# Alert helpers (same pattern as jwt-secret-drift-check.sh / watchdog)
# --------------------------------------------------------------------------- #

send_webhook_alert() {
  local message="$1"
  [ -n "${ALERT_WEBHOOK_URL:-}" ] || return 0
  local safe
  safe=$(json_escape "$message")
  curl -s -o /dev/null --max-time 10 \
    -X POST "$ALERT_WEBHOOK_URL" \
    -H 'Content-Type: application/json' \
    -d "{\"text\":\"${safe}\"}" || true
}

send_email_alert() {
  local subject="$1" body="$2"
  if [ -n "${ALERT_EMAIL:-}" ] && command -v mail >/dev/null 2>&1; then
    printf '%s\n' "$body" | mail -s "$subject" "$ALERT_EMAIL" || true
  fi
}

send_brevo_alert() {
  local subject="$1" body="$2"
  if [ -z "${BREVO_API_KEY:-}" ] || [ -z "${ALERT_EMAIL:-}" ]; then
    return 0
  fi
  local sender="${BREVO_SENDER:-noreply@mediasart.com}"
  local sender_name="${BREVO_SENDER_NAME:-mediasart}"
  local esc_body esc_subject
  esc_body=$(json_escape "$body")
  esc_subject=$(json_escape "$subject")
  curl -s -o /dev/null --max-time 15 \
    -X POST "https://api.brevo.com/v3/smtp/email" \
    -H "api-key: ${BREVO_API_KEY}" \
    -H 'Content-Type: application/json' \
    -d "{\"sender\":{\"email\":\"${sender}\",\"name\":\"${sender_name}\"},\"to\":[{\"email\":\"${ALERT_EMAIL}\"}],\"subject\":\"${esc_subject}\",\"textContent\":\"${esc_body}\"}" || true
}

send_summary_alerts() {
  local subject="$1" body="$2"
  send_webhook_alert "📊 JWT Daily Summary — ${HOST}

${body}"
  send_email_alert "${subject}" "${body}"
  send_brevo_alert "${subject}" "${body}"
}

# --------------------------------------------------------------------------- #
# Parse log: collect entries within the window, categorized by event type
# --------------------------------------------------------------------------- #

# Globals populated by parse_log
OK_LINES=()
DRIFT_LINES=()
REVERT_LINES=()
WARN_LINES=()
DONE_LINES=()
REGISTRY_LINES=()
FATAL_LINES=()
TOTAL_OK=0

parse_log() {
  if [ ! -f "$LOG" ]; then
    # Log doesn't exist yet — treat as a clean window
    return 0
  fi

  local line ts epoch rest
  while IFS= read -r line || [ -n "$line" ]; do
    # Each line: "<ISO timestamp> <EVENT> <details>"
    ts="${line%% *}"          # first token = timestamp
    [ -n "$ts" ] || continue

    epoch=$(ts_to_epoch "$ts")
    [ "$epoch" -gt 0 ] || continue
    [ "$epoch" -ge "$CUTOFF_EPOCH" ] || continue     # filter to window

    rest="${line#* }"         # everything after timestamp

    case "$rest" in
      OK*)              OK_LINES+=("$line"); TOTAL_OK=$((TOTAL_OK + 1)) ;;
      DRIFT*)           DRIFT_LINES+=("$line") ;;
      WARN*)            WARN_LINES+=("$line") ;;
      REVERT\ DETECTED*) REVERT_LINES+=("$line") ;;
      REVERT*)          REVERT_LINES+=("$line") ;;
      DONE:*)           DONE_LINES+=("$line") ;;
      REGISTRY*)        REGISTRY_LINES+=("$line") ;;
      FATAL*)           FATAL_LINES+=("$line") ;;
      *)                # skip unrecognised lines silently ;;
    esac
  done < "$LOG"
}

# --------------------------------------------------------------------------- #
# Build the summary body (plain text — newlines are actual newline chars so
# json_escape can convert them properly for webhook / Brevo delivery)
# --------------------------------------------------------------------------- #

build_summary_body() {
  local cutoff_human window_end
  cutoff_human=$(date -d "@${CUTOFF_EPOCH}" '+%Y-%m-%d %H:%M UTC')
  window_end=$(date -d "@${NOW_EPOCH}" '+%Y-%m-%d %H:%M UTC')

  # Use an array + join for clean multi-line text
  local lines=()
  lines+=("Window: ${cutoff_human}  →  ${window_end} (past ${WINDOW_HOURS}h)")
  lines+=("Log: ${LOG}")
  lines+=("")
  lines+=("${TOTAL_OK} OK run(s):")
  if [ "${#OK_LINES[@]}" -gt 0 ]; then
    for l in "${OK_LINES[@]}"; do
      lines+=("  ${l}")
    done
  else
    lines+=("  (none)")
  fi
  lines+=("")
  lines+=("Drift / revert incidents:")

  if [ "${#DRIFT_LINES[@]}" -gt 0 ]; then
    lines+=("  DRIFT events (${#DRIFT_LINES[@]}):")
    for l in "${DRIFT_LINES[@]}"; do
      lines+=("    ${l}")
    done
  fi
  if [ "${#REVERT_LINES[@]}" -gt 0 ]; then
    lines+=("  REVERT events (${#REVERT_LINES[@]}):")
    for l in "${REVERT_LINES[@]}"; do
      lines+=("    ${l}")
    done
  fi
  if [ "${#DONE_LINES[@]}" -gt 0 ]; then
    lines+=("  DONE summaries (${#DONE_LINES[@]}):")
    for l in "${DONE_LINES[@]}"; do
      lines+=("    ${l}")
    done
  fi
  if [ "${#WARN_LINES[@]}" -gt 0 ]; then
    lines+=("  WARN events (${#WARN_LINES[@]}):")
    for l in "${WARN_LINES[@]}"; do
      lines+=("    ${l}")
    done
  fi
  if [ "${#FATAL_LINES[@]}" -gt 0 ]; then
    lines+=("  FATAL events (${#FATAL_LINES[@]}):")
    for l in "${FATAL_LINES[@]}"; do
      lines+=("    ${l}")
    done
  fi
  if [ "${#REGISTRY_LINES[@]}" -gt 0 ]; then
    lines+=("  REGISTRY events (${#REGISTRY_LINES[@]}):")
    for l in "${REGISTRY_LINES[@]}"; do
      lines+=("    ${l}")
    done
  fi

  # If no incidents at all
  if [ "${#DRIFT_LINES[@]}" -eq 0 ] && [ "${#REVERT_LINES[@]}" -eq 0 ] \
     && [ "${#WARN_LINES[@]}" -eq 0 ] && [ "${#FATAL_LINES[@]}" -eq 0 ]; then
    lines+=("  (none — all stacks were green)")
  fi
  lines+=("")
  lines+=("Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')")

  # Join lines with actual newlines
  local body=""
  for l in "${lines[@]}"; do
    body+="${l}"$'\n'
  done
  printf '%s' "$body"
}

# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

parse_log

BODY=$(build_summary_body)

# Subject line reflects whether any incidents occurred
SUBJECT="JWT Secret Daily Summary — ${HOST} — ${TOTAL_OK} OK run(s)"
if [ "${#DRIFT_LINES[@]}" -gt 0 ] || [ "${#REVERT_LINES[@]}" -gt 0 ] \
   || [ "${#WARN_LINES[@]}" -gt 0 ] || [ "${#FATAL_LINES[@]}" -gt 0 ]; then
  SUBJECT="⚠️ JWT Secret Daily Summary — ${HOST} — incidents reported"
fi

send_summary_alerts "$SUBJECT" "$BODY"

echo "$(date '+%Y-%m-%dT%H:%M:%S%z') Daily summary sent: OK=${TOTAL_OK} DRIFT=${#DRIFT_LINES[@]} REVERT=${#REVERT_LINES[@]} WARN=${#WARN_LINES[@]}" >> "$LOG"

exit 0
