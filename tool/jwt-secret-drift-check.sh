#!/usr/bin/env bash
# jwt-secret-drift-check.sh
#
# Compares every project stack's JWT_SECRET against the identity stack's.
# Logs to ~/logs/jwt-secret-drift.log (always — audit trail).
# Sends real-time alerts on drift if ALERT_WEBHOOK_URL, ALERT_EMAIL, or
# BREVO_API_KEY is set.
# Run from cron every 15 min.
#
# Every run writes one "HEARTBEAT drift-check <verdict>" line, whichever way
# it ends.  The clean result is only logged when no alert channel is
# configured, so without the heartbeat a monitor that had stopped running
# would look identical to one with nothing to report.
# jwt-secret-liveness-check.sh alerts on a heartbeat that goes stale.
#
# Alert configuration (set in crontab environment or export):
#   ALERT_WEBHOOK_URL  — incoming-webhook URL for real-time alerts
#   ALERT_EMAIL        — recipient for mail(1) or Brevo API alerts
#   BREVO_API_KEY      — Brevo (Sendinblue) API key for email alerts via REST API
#   BREVO_SENDER       — sender email (default: noreply@mediasart.com)
#   BREVO_SENDER_NAME  — sender name (default: mediasart)
#   GOTIFY_URL         — Gotify server base URL (unset → no push)
#   GOTIFY_APP_TOKEN   — Gotify application token (unset → no push)
#   TELEGRAM_BOT_TOKEN — Telegram bot token (external push; unset → silent)
#   TELEGRAM_CHAT_ID   — Telegram chat to deliver to (unset → silent)
#   GOTIFY_URL         — Gotify server base URL (e.g. https://notify.mediasart.com)
#   GOTIFY_APP_TOKEN   — Gotify application token for the alert app
#   mail(1) must be installed for local mail() alerts.
set -euo pipefail

# Source shared alert helpers (send_webhook_alert, send_gotify_alert,
# send_email_alert, send_brevo_alert, send_telegram_alert, timestamp,
# json_escape) from tool/alert.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=alert.sh
. "${SCRIPT_DIR}/alert.sh"

LOG="$HOME/logs/jwt-secret-drift.log"
IDENTITY_ENV="$HOME/Projects/kommons/supabase-identity/docker/.env"

mkdir -p "$(dirname "$LOG")"

# --------------------------------------------------------------------------- #
# Liveness heartbeat
# --------------------------------------------------------------------------- #

MONITOR_ID="drift-check"
HEARTBEAT_VERDICT="ok"
heartbeat() { echo "$(timestamp) HEARTBEAT ${MONITOR_ID} ${HEARTBEAT_VERDICT}" >> "$LOG"; }
# On EXIT rather than at the end, so every path — including an unexpected
# `set -e` abort — leaves exactly one heartbeat behind.
trap heartbeat EXIT

ENV_PATHS=(
  "kommons|${IDENTITY_ENV}"
  "katalogus|${HOME}/Projects/katalogus/database/docker/.env"
  "katalogus-staging|${HOME}/Projects/katalogus/staging/docker/.env"
  "kalcio|${HOME}/Projects/kalcio/database/docker/.env"
  "kognitio|${HOME}/Projects/kognitio/database/docker/.env"
  "kollectio|${HOME}/Projects/kollectio/database/docker/.env"
  "kapaxinfiniti|${HOME}/Projects/kapaxinfiniti/database/docker/.env"
)

get_secret() {
  local env_file="$1" val=""
  val="$(grep -E '^(JWT_SECRET|POSTGRES_PASSWORD)=' "$env_file" 2>/dev/null \
        | grep 'JWT_SECRET=' | head -1 | cut -d= -f2- || true)"
  if [ -z "$val" ]; then
    val="$(grep -E '^POSTGRES_PASSWORD=' "$env_file" 2>/dev/null \
          | head -1 | cut -d= -f2- || true)"
  fi
  case "$val" in
    \"*\") val="${val#\"}"; val="${val%\"}" ;;
    \'*\') val="${val#\'}"; val="${val%\'}" ;;
  esac
  printf '%s\n' "$val"
}

send_drift_alerts() {
  local details="$1"
  local host msg
  host="$(hostname)"
  msg="🚨 JWT Secret Drift Detected — ${host}
${details}
Action: re-cut affected stacks to match identity-secret and force-recreate their containers.
Log:   $(readlink -f "$LOG")"
  send_webhook_alert "$msg"
  send_gotify_alert "JWT Secret Drift Detected — ${host}" "$msg" 8
  send_email_alert "[Drift Alert] JWT Secret Mismatch — ${host}" "$msg"
  send_brevo_alert "[Drift Alert] JWT Secret Mismatch — ${host}" "$msg"
  send_telegram_alert "[Drift Alert] JWT Secret Mismatch — ${host}" "$msg"
}

# --- main ---

if [ ! -f "$IDENTITY_ENV" ]; then
  line="$(timestamp) FATAL identity .env not found at $IDENTITY_ENV"
  echo "$line" >> "$LOG"
  send_drift_alerts "identity .env not found at $IDENTITY_ENV"
  HEARTBEAT_VERDICT="fatal"
  exit 1
fi

REF="$(get_secret "$IDENTITY_ENV")"
if [ -z "$REF" ]; then
  line="$(timestamp) FATAL could not read reference JWT_SECRET from identity .env"
  echo "$line" >> "$LOG"
  send_drift_alerts "could not read reference JWT_SECRET from identity .env"
  HEARTBEAT_VERDICT="fatal"
  exit 1
fi

mismatch=0
drift_details=""
for entry in "${ENV_PATHS[@]}"; do
  stack="${entry%%|*}"
  env_file="${entry#*|}"
  if [ ! -f "$env_file" ]; then
    echo "$(timestamp) WARN $stack: .env not found at $env_file" >> "$LOG"
    continue
  fi
  sec="$(get_secret "$env_file")"
  if [ -z "$sec" ]; then
    echo "$(timestamp) WARN $stack: JWT_SECRET empty in $env_file" >> "$LOG"
    continue
  fi
  if [ "$sec" != "$REF" ]; then
    echo "$(timestamp) DRIFT $stack: JWT_SECRET differs from identity ($env_file)" >> "$LOG"
    drift_details="${drift_details}  • ${stack} — differs from identity ($env_file)\n"
    mismatch=1
  fi
done

if [ "$mismatch" -eq 1 ]; then
  HEARTBEAT_VERDICT="drift"
  send_drift_alerts "$drift_details"
elif [ -z "${ALERT_WEBHOOK_URL:-}" ] && [ -z "${ALERT_EMAIL:-}" ] && [ -z "${BREVO_API_KEY:-}" ]; then
  echo "$(timestamp) OK all stacks match identity JWT_SECRET" >> "$LOG"
fi

exit "$mismatch"
