#!/usr/bin/env bash
# jwt-secret-drift-check.sh
#
# Compares every project stack's JWT_SECRET against the identity stack's.
# Logs to ~/logs/jwt-secret-drift.log (always — audit trail).
# Sends real-time alerts on drift if ALERT_WEBHOOK_URL, ALERT_EMAIL, or
# BREVO_API_KEY is set.
# Run from cron every 15 min.
#
# Alert configuration (set in crontab environment or export):
#   ALERT_WEBHOOK_URL  — incoming-webhook URL for real-time alerts
#   ALERT_EMAIL        — recipient for mail(1) or Brevo API alerts
#   BREVO_API_KEY      — Brevo (Sendinblue) API key for email alerts via REST API
#   BREVO_SENDER       — sender email (default: noreply@mediasart.com)
#   BREVO_SENDER_NAME  — sender name (default: mediasart)
#   mail(1) must be installed for local mail() alerts.
set -euo pipefail

LOG="$HOME/logs/jwt-secret-drift.log"
IDENTITY_ENV="$HOME/Projects/kommons/supabase-identity/docker/.env"

ENV_PATHS=(
  "kommons|${IDENTITY_ENV}"
  "katalogus|${HOME}/Projects/katalogus/database/docker/.env"
  "katalogus-staging|${HOME}/Projects/katalogus/staging/docker/.env"
  "kalcio|${HOME}/Projects/kalcio/database/docker/.env"
  "kognitio|${HOME}/Projects/kognitio/database/docker/.env"
  "kollectio|${HOME}/Projects/kollectio/database/docker/.env"
  "kapaxinfiniti|${HOME}/Projects/kapaxinfiniti/database/docker/.env"
)

timestamp() { date '+%Y-%m-%dT%H:%M:%S%z'; }

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

# --- alert helpers ---

send_webhook_alert() {
  local message="$1"
  [ -n "${ALERT_WEBHOOK_URL:-}" ] || return 0
  local safe
  safe=$(printf '%s\n' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g')
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
  # Escape body for JSON: backslash, double-quotes, newlines -> \n

  local esc_body esc_subject
  esc_body=$(printf '%s' "$body" | sed 's/\\/\\\\/g; s/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
  esc_subject=$(printf '%s' "$subject" | sed 's/\\/\\\\/g; s/"/\\"/g')
  curl -s -o /dev/null --max-time 15 \
    -X POST "https://api.brevo.com/v3/smtp/email" \
    -H "api-key: ${BREVO_API_KEY}" \
    -H 'Content-Type: application/json' \
    -d "{\"sender\":{\"email\":\"${sender}\",\"name\":\"${sender_name}\"},\"to\":[{\"email\":\"${ALERT_EMAIL}\"}],\"subject\":\"${esc_subject}\",\"textContent\":\"${esc_body}\"}" || true
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
  send_email_alert "[Drift Alert] JWT Secret Mismatch — ${host}" "$msg"
  send_brevo_alert "[Drift Alert] JWT Secret Mismatch — ${host}" "$msg"
}

# --- main ---

if [ ! -f "$IDENTITY_ENV" ]; then
  line="$(timestamp) FATAL identity .env not found at $IDENTITY_ENV"
  echo "$line" >> "$LOG"
  send_drift_alerts "identity .env not found at $IDENTITY_ENV"
  exit 1
fi

REF="$(get_secret "$IDENTITY_ENV")"
if [ -z "$REF" ]; then
  line="$(timestamp) FATAL could not read reference JWT_SECRET from identity .env"
  echo "$line" >> "$LOG"
  send_drift_alerts "could not read reference JWT_SECRET from identity .env"
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
  send_drift_alerts "$drift_details"
elif [ -z "${ALERT_WEBHOOK_URL:-}" ] && [ -z "${ALERT_EMAIL:-}" ] && [ -z "${BREVO_API_KEY:-}" ]; then
  echo "$(timestamp) OK all stacks match identity JWT_SECRET" >> "$LOG"
fi

exit "$mismatch"
