#!/usr/bin/env bash
# jwt-secret-delivery-watchdog.sh — dead-man's switch for the alert pipeline.
#
# The three JWT-secret monitors alert *through* Gotify, so a broken Gotify
# server, a revoked app token, a full disk or a dead cron makes all of them
# fail silently: the monitoring goes blind and nothing says so.  Only one of
# them sends unconditionally — jwt-secret-daily-summary.sh delivers a digest
# every day, while drift-check.sh and the revert watchdog stay quiet while
# healthy — which makes the daily summary the pipeline's heartbeat.
#
# This watchdog reads the Gotify delivery history (through gotify-messages.sh)
# and alerts when that heartbeat has not arrived within MAX_AGE_HOURS.  It
# fans the alert out to every configured channel — Gotify, webhook, local
# mail and Brevo — on purpose: the component that broke may well be Gotify
# itself, and an email still gets through when a push does not.
#
# Because the heartbeat only proves the pipeline end to end, not that each
# individual monitor ran, pair it with a log-based liveness check for the
# drift/revert crons (they are silent unless they have something to report).
#
# Configuration (set in crontab environment or export):
#   EXPECT_TITLE   heartbeat alert title substring (default: JWT Daily Summary)
#   MAX_AGE_HOURS  alert when the newest matching delivery is older than this
#                  (default: 26 — one daily cycle plus slack)
#   GOTIFY_DB      path to gotify.db (default: $HOME/gotify/data/gotify.db)
#   AUDIT          path to gotify-messages.sh (default: beside this script)
#   LOG            audit log (default: $HOME/logs/jwt-secret-delivery.log)
#   HOST           host name used in alert titles (default: hostname)
#
# Alert configuration (from alert.sh; unset → that channel stays silent):
#   ALERT_WEBHOOK_URL, ALERT_EMAIL, BREVO_API_KEY, GOTIFY_URL,
#   GOTIFY_APP_TOKEN, GOTIFY_PRIORITY (default 8), TELEGRAM_BOT_TOKEN,
#   TELEGRAM_CHAT_ID
#
# Usage:
#   jwt-secret-delivery-watchdog.sh
#
# Exit status: 0 healthy, 1 delivery problem detected (an alert was sent),
# 2 usage or configuration error.
set -euo pipefail

# Source shared alert helpers (send_webhook_alert, send_gotify_alert,
# send_email_alert, send_brevo_alert, send_telegram_alert, timestamp) from
# tool/alert.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=alert.sh
. "${SCRIPT_DIR}/alert.sh"

EXPECT_TITLE="${EXPECT_TITLE:-JWT Daily Summary}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-26}"
GOTIFY_DB="${GOTIFY_DB:-$HOME/gotify/data/gotify.db}"
AUDIT="${AUDIT:-${SCRIPT_DIR}/gotify-messages.sh}"
LOG="${LOG:-$HOME/logs/jwt-secret-delivery.log}"
HOST="${HOST:-$(hostname)}"

case "$MAX_AGE_HOURS" in
  ''|*[!0-9]*)
    echo "jwt-secret-delivery-watchdog: MAX_AGE_HOURS must be a non-negative integer" >&2
    exit 2
    ;;
esac
MAX_AGE_SECONDS=$((MAX_AGE_HOURS * 3600))

if [ ! -f "$AUDIT" ]; then
  echo "jwt-secret-delivery-watchdog: audit helper not found at $AUDIT" >&2
  exit 2
fi

mkdir -p "$(dirname "$LOG")"

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #

# human_age <seconds> — compact age for logs and alerts.
human_age() {
  local s="${1:-0}" d h m
  d=$((s / 86400)); h=$(( (s % 86400) / 3600 )); m=$(( (s % 3600) / 60 ))
  if [ "$d" -gt 0 ]; then
    printf '%dd %02dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then
    printf '%dh %02dm' "$h" "$m"
  else
    printf '%dm' "$m"
  fi
}

# age_of [<title-substring>] — seconds since the newest matching delivery,
# -1 when none match, or "ERR <reason>" when the history is unreadable.
# With no argument it considers every delivery.
#
# The reason travels on stdout rather than through a global because this
# function is always called from a command substitution, whose subshell
# would discard any variable it set.
age_of() {
  local title="${1:-}" out err rc=0
  err="$(mktemp)"
  if [ -n "$title" ]; then
    out="$(GOTIFY_DB="$GOTIFY_DB" "$AUDIT" --age-seconds --title "$title" 2>"$err")" || rc=$?
  else
    out="$(GOTIFY_DB="$GOTIFY_DB" "$AUDIT" --age-seconds 2>"$err")" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    printf 'ERR %s' "$(tr '\n' ' ' < "$err")"
    rm -f "$err"
    return 0
  fi
  rm -f "$err"
  printf '%s' "$out"
}

# send_delivery_alerts <detail> <note>
#   Fans the stall alert out to every configured channel.  Deliberately
#   includes Gotify: when the heartbeat is missing because the daily
#   summary stopped running rather than because Gotify is down, the push
#   still lands.
send_delivery_alerts() {
  local detail="$1" note="$2"
  local msg="🛑 JWT Alert Delivery Stalled — ${HOST}

${detail}
${note}

The JWT-secret monitors deliver through Gotify, so no heartbeat means the
alert pipeline is blind.
Action: check that the monitoring crons are running and that the Gotify
server and app token are healthy.
History: ${GOTIFY_DB}
Log:     ${LOG}"
  send_webhook_alert "$msg"
  send_gotify_alert "JWT Alert Delivery Stalled — ${HOST}" "$msg" "${GOTIFY_PRIORITY:-8}"
  send_email_alert "[Delivery Alert] JWT alert pipeline stalled — ${HOST}" "$msg"
  send_brevo_alert "[Delivery Alert] JWT alert pipeline stalled — ${HOST}" "$msg"
  send_telegram_alert "[Delivery Alert] JWT alert pipeline stalled — ${HOST}" "$msg"
}

# --------------------------------------------------------------------------- #
# Check
# --------------------------------------------------------------------------- #

heartbeat_age="$(age_of "$EXPECT_TITLE")"
any_age="$(age_of "")"

problem=""
detail=""

case "$heartbeat_age" in
  ERR*)
    problem="history-unreadable"
    err_text="${heartbeat_age#ERR }"
    [ -n "$err_text" ] || err_text="(no error output from the audit helper)"
    detail="Could not read the Gotify delivery history at ${GOTIFY_DB}: ${err_text}"
    ;;
  -1)
    problem="heartbeat-missing"
    detail="No delivery matching \"${EXPECT_TITLE}\" exists in the Gotify history at ${GOTIFY_DB}."
    ;;
  ''|*[!0-9]*)
    problem="heartbeat-unparsable"
    detail="Unexpected age reading from the delivery history: '${heartbeat_age}'."
    ;;
  *)
    if [ "$heartbeat_age" -gt "$MAX_AGE_SECONDS" ]; then
      problem="heartbeat-stale"
      detail="The newest \"${EXPECT_TITLE}\" delivery is $(human_age "$heartbeat_age") old, past the ${MAX_AGE_HOURS}h threshold."
    fi
    ;;
esac

if [ -n "$problem" ]; then
  case "$any_age" in
    ERR*) any_note="newest delivery of any kind: unavailable (history unreadable)" ;;
    -1)   any_note="newest delivery of any kind: none recorded" ;;
    *)    any_note="newest delivery of any kind: $(human_age "$any_age") ago" ;;
  esac

  echo "$(timestamp) STALL ${problem}: ${detail} (${any_note})" >> "$LOG"
  send_delivery_alerts "$detail" "$any_note"
  echo "$(timestamp) ALERT delivery watchdog alert sent (${problem})" >> "$LOG"
  exit 1
fi

echo "$(timestamp) OK delivery heartbeat: \"${EXPECT_TITLE}\" last delivered $(human_age "$heartbeat_age") ago (threshold ${MAX_AGE_HOURS}h)" >> "$LOG"
exit 0
