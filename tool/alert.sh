#!/usr/bin/env bash
# alert.sh — shared alert helpers sourced by the jwt-secret monitoring scripts.
#
# This file is not meant to be executed directly.  Source it from each
# monitoring script:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "${SCRIPT_DIR}/alert.sh"
#
# Provided functions:
#   timestamp()          — ISO-8601 timestamp string
#   json_escape()        — escape a string for JSON string values
#   send_webhook_alert() — POST a JSON message to ALERT_WEBHOOK_URL
#   send_gotify_alert()  — POST a message to the Gotify /message endpoint
#   send_email_alert()   — send a local mail(1) notification
#   send_brevo_alert()   — send an email via the Brevo REST API
#   preferred_email_channel() — the single channel routine reports use
#   send_email_report()  — deliver a routine report through that one channel
#
# Alert configuration (set in crontab environment or export):
#   ALERT_WEBHOOK_URL  — incoming-webhook URL for real-time alerts
#   ALERT_EMAIL        — recipient for mail(1) or Brevo API alerts
#   BREVO_API_KEY      — Brevo (Sendinblue) API key for email alerts via REST API
#   BREVO_SENDER       — sender email (default: noreply@mediasart.com)
#   BREVO_SENDER_NAME  — sender name (default: mediasart)
#   GOTIFY_URL         — Gotify server base URL (e.g. https://notify.mediasart.com)
#   GOTIFY_APP_TOKEN   — Gotify application token for the alert app
#   GOTIFY_PRIORITY    — default priority for Gotify alerts (default: 5)
#
# All functions are no-ops when their required env vars are absent.

# --- shared utilities ---

timestamp() { date '+%Y-%m-%dT%H:%M:%S%z'; }

# Escape a string for inclusion in a JSON string value:
# backslash → \\, double-quote → \", newline → \n
json_escape() {
  printf '%s' "$1" \
    | sed 's/\\/\\\\/g' \
    | sed 's/"/\\"/g' \
    | sed ':a;N;$!ba;s/\n/\\n/g'
}

# --- alert helpers ---

# send_webhook_alert <message>
#   POSTs {"text":"<message>"} to ALERT_WEBHOOK_URL as JSON.
#   No-op when ALERT_WEBHOOK_URL is empty.
send_webhook_alert() {
  local message="$1"
  [ -n "${ALERT_WEBHOOK_URL:-}" ] || return 0
  local safe
  safe="$(json_escape "$message")"
  curl -s -o /dev/null --max-time 10 \
    -X POST "$ALERT_WEBHOOK_URL" \
    -H 'Content-Type: application/json' \
    -d "{\"text\":\"${safe}\"}" || true
}

# send_gotify_alert <title> <message> [priority]
#   POSTs a message to Gotify's /message endpoint using the app token.
#   Uses GOTIFY_PRIORITY env var (default 5) when priority is omitted.
#   No-op when GOTIFY_URL or GOTIFY_APP_TOKEN is empty.
send_gotify_alert() {
  local title="$1" message="$2" priority="${3:-${GOTIFY_PRIORITY:-5}}"
  [ -n "${GOTIFY_URL:-}" ] || return 0
  [ -n "${GOTIFY_APP_TOKEN:-}" ] || return 0
  curl -s -o /dev/null --max-time 10 \
    -X POST "${GOTIFY_URL}/message?token=${GOTIFY_APP_TOKEN}" \
    -F "title=${title}" \
    -F "message=${message}" \
    -F "priority=${priority}" || true
}

# send_email_alert <subject> <body>
#   Sends a local mail(1) notification.  No-op when ALERT_EMAIL is empty
#   or mail is not installed.
send_email_alert() {
  local subject="$1" body="$2"
  if [ -n "${ALERT_EMAIL:-}" ] && command -v mail >/dev/null 2>&1; then
    printf '%s\n' "$body" | mail -s "$subject" "$ALERT_EMAIL" || true
  fi
}

# send_brevo_alert <subject> <body>
#   Sends an email via the Brevo (Sendinblue) REST API.
#   No-op when BREVO_API_KEY or ALERT_EMAIL is empty.
send_brevo_alert() {
  local subject="$1" body="$2"
  if [ -z "${BREVO_API_KEY:-}" ] || [ -z "${ALERT_EMAIL:-}" ]; then
    return 0
  fi
  local sender="${BREVO_SENDER:-noreply@mediasart.com}"
  local sender_name="${BREVO_SENDER_NAME:-mediasart}"
  local esc_body esc_subject
  esc_body="$(json_escape "$body")"
  esc_subject="$(json_escape "$subject")"
  curl -s -o /dev/null --max-time 15 \
    -X POST "https://api.brevo.com/v3/smtp/email" \
    -H "api-key: ${BREVO_API_KEY}" \
    -H 'Content-Type: application/json' \
    -d "{\"sender\":{\"email\":\"${sender}\",\"name\":\"${sender_name}\"},\"to\":[{\"email\":\"${ALERT_EMAIL}\"}],\"subject\":\"${esc_subject}\",\"textContent\":\"${esc_body}\"}" || true
}

# --- routine reports: one copy, not several ---
#
# Alerts deliberately fan out to every configured channel, because the channel
# that broke may be the very one being reported on.  A routine report has no
# such excuse: delivering the daily summary through both mail(1) and Brevo
# sends the recipient the same message twice, which is noise mistaken for
# redundancy.  Reports therefore pick a single channel.

# preferred_email_channel()
#   Prints the one email channel a routine report should use, or nothing when
#   none is configured.  Brevo wins when it is set up, because it does not
#   depend on the host having a working MTA; local mail(1) is the fallback.
preferred_email_channel() {
  if [ -n "${ALERT_EMAIL:-}" ] && [ -n "${BREVO_API_KEY:-}" ]; then
    printf 'brevo'
  elif [ -n "${ALERT_EMAIL:-}" ] && command -v mail >/dev/null 2>&1; then
    printf 'mail'
  else
    printf ''
  fi
}

# send_email_report <subject> <body>
#   Delivers a routine report through that single channel and prints the
#   channel's name (empty when there was nowhere to send it), so callers can
#   log honestly whether anything was actually delivered.
send_email_report() {
  local channel
  channel="$(preferred_email_channel)"
  case "$channel" in
    brevo) send_brevo_alert "$1" "$2" ;;
    mail)  send_email_alert "$1" "$2" ;;
  esac
  printf '%s' "$channel"
}
