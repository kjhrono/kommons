#!/usr/bin/env bash
# jwt-secret-liveness-check.sh — catch a monitor that has stopped running.
#
# The alert-pipeline dead-man's switch (jwt-secret-delivery-watchdog.sh) proves
# the pipeline end to end by watching for the daily summary's delivery.  It
# cannot see the two 15-minute monitors: drift-check.sh and the revert
# watchdog deliver *through* that same pipeline, and they say nothing at all
# while the secrets are healthy.  A cron entry that was deleted, a script that
# lost its executable bit or a host that rebooted into a broken user crontab
# would therefore leave the secrets unguarded and completely silent.
#
# This check closes that gap from the other direction: it reads the shared
# monitor log and alerts when a monitor's most recent heartbeat is older than
# MAX_AGE_MINUTES.  Each monitor writes one "HEARTBEAT <monitor> <verdict>"
# line per run whichever way it ends, so a stale heartbeat means the monitor
# did not run — not that it ran and found nothing.
#
# Alerts fire on transitions only.  A monitor that stays down would otherwise
# re-alert on every run, and an alert that repeats forever is one nobody
# reads; the state file remembers what has already been reported, and coming
# back up sends a short recovery notice so the episode has a visible end.
#
# This is deliberately not a Gotify delivery: like the digest, it reports on
# the monitoring, so it alerts on every configured channel *including*
# Gotify — see the note in the header of jwt-secret-delivery-watchdog.sh.
#
# Configuration (set in crontab environment or export):
#   MONITOR_LOG      shared monitor log to read
#                    (default: $HOME/logs/jwt-secret-drift.log)
#   MONITORS         monitors to watch, space-separated
#                    (default: "drift-check revert-watchdog")
#   MAX_AGE_MINUTES  alert when a heartbeat is older than this (default: 45,
#                    i.e. three missed 15-minute cycles)
#   STATE            file recording which monitors are already reported
#                    (default: $HOME/logs/jwt-secret-liveness.state)
#   LOG              this check's own log (default: $HOME/logs/jwt-secret-liveness.log)
#   HOST             host name used in alert titles (default: hostname)
#
# Alert configuration (from alert.sh; unset → that channel stays silent):
#   ALERT_WEBHOOK_URL, ALERT_EMAIL, BREVO_API_KEY, GOTIFY_URL,
#   GOTIFY_APP_TOKEN, GOTIFY_PRIORITY (default 8), TELEGRAM_BOT_TOKEN,
#   TELEGRAM_CHAT_ID
#
# Usage:
#   jwt-secret-liveness-check.sh            # check and alert
#   jwt-secret-liveness-check.sh --dry-run  # report without alerting
#
# Exit status: 0 every monitor is running, 1 at least one is stale or missing
# (whether or not the alert was sent), 2 usage or configuration error.
set -euo pipefail

# Source shared alert helpers (send_webhook_alert, send_gotify_alert,
# send_email_alert, send_brevo_alert, send_telegram_alert, timestamp) from
# tool/alert.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=alert.sh
. "${SCRIPT_DIR}/alert.sh"

MONITOR_LOG="${MONITOR_LOG:-$HOME/logs/jwt-secret-drift.log}"
MONITORS="${MONITORS:-drift-check revert-watchdog}"
MAX_AGE_MINUTES="${MAX_AGE_MINUTES:-45}"
STATE="${STATE:-$HOME/logs/jwt-secret-liveness.state}"
LOG="${LOG:-$HOME/logs/jwt-secret-liveness.log}"
HOST="${HOST:-$(hostname)}"
DRY_RUN="${DRY_RUN:-}"

usage_error() { echo "jwt-secret-liveness-check: $1" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d'; exit 0 ;;
    *) usage_error "unknown option: $1" ;;
  esac
  shift
done

case "$MAX_AGE_MINUTES" in
  ''|*[!0-9]*) usage_error "MAX_AGE_MINUTES must be a non-negative integer" ;;
esac
[ "$MAX_AGE_MINUTES" -gt 0 ] || usage_error "MAX_AGE_MINUTES must be at least 1"
[ -n "${MONITORS// /}" ] || usage_error "MONITORS must name at least one monitor"

MAX_AGE_SECONDS=$((MAX_AGE_MINUTES * 60))
NOW_EPOCH="$(date +%s)"

mkdir -p "$(dirname "$LOG")" "$(dirname "$STATE")"

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

ts_to_epoch() {
  date -d "$1" +%s 2>/dev/null || echo 0
}

# last_heartbeat_ts <monitor> — timestamp of that monitor's newest heartbeat,
# or empty.  The log is append-only, so the last match is the newest; awk is
# left to read the whole file rather than exiting early, which would send a
# SIGPIPE back up a `tac` and make the pipeline look like a failure.
last_heartbeat_ts() {
  local mon="$1"
  [ -f "$MONITOR_LOG" ] || { printf ''; return 0; }
  awk -v m="$mon" '$2 == "HEARTBEAT" && $3 == m { ts = $1 } END { print ts }' \
    "$MONITOR_LOG"
}

# --- alert state: which monitors have already been reported as down --------- #

alerting() {
  [ -f "$STATE" ] || return 1
  grep -qxF -- "$1" "$STATE" 2>/dev/null
}

mark_alerting() {
  if alerting "$1"; then
    return 0
  fi
  printf '%s\n' "$1" >> "$STATE"
}

mark_recovered() {
  local tmp
  [ -f "$STATE" ] || return 0
  tmp="$(mktemp)"
  grep -vxF -- "$1" "$STATE" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$STATE"
}

# any_channel — is there anywhere for an alert to go?
any_channel() {
  if [ -n "${ALERT_WEBHOOK_URL:-}" ]; then return 0; fi
  if [ -n "${GOTIFY_URL:-}" ] && [ -n "${GOTIFY_APP_TOKEN:-}" ]; then return 0; fi
  if [ -n "${BREVO_API_KEY:-}" ] && [ -n "${ALERT_EMAIL:-}" ]; then return 0; fi
  if [ -n "${ALERT_EMAIL:-}" ] && command -v mail >/dev/null 2>&1; then return 0; fi
  return 1
}

send_liveness_alert() { # <monitor> <status> <age-text>
  local monitor="$1" status="$2" age_text="$3" what msg
  if [ "$status" = "missing" ]; then
    what="has never recorded a heartbeat"
  else
    what="last logged a heartbeat ${age_text}"
  fi
  msg="🛑 JWT Monitor Not Running — ${HOST}

The ${monitor} monitor ${what}, past the ${MAX_AGE_MINUTES}m threshold.

It is scheduled every 15 minutes, so the secrets are currently going
unguarded by it.  The alert pipeline itself is healthy — this monitor simply
is not running.
Action: check 'crontab -l' still lists it, that the script is still in ~/bin
        and still executable, and that cron itself is up.
Log:    ${MONITOR_LOG}
State:  ${STATE}"
  send_webhook_alert "$msg"
  send_gotify_alert "JWT Monitor Not Running — ${HOST}" "$msg" "${GOTIFY_PRIORITY:-8}"
  send_email_alert "[Liveness Alert] JWT monitor ${monitor} is not running — ${HOST}" "$msg"
  send_brevo_alert "[Liveness Alert] JWT monitor ${monitor} is not running — ${HOST}" "$msg"
  send_telegram_alert "[Liveness Alert] JWT monitor ${monitor} is not running — ${HOST}" "$msg"
}

send_recovery_alert() { # <monitor> <age-text>
  local monitor="$1" age_text="$2"
  local msg="✅ JWT Monitor Running Again — ${HOST}

The ${monitor} monitor is logging heartbeats again (${age_text}).

Log: ${MONITOR_LOG}"
  send_webhook_alert "$msg"
  send_gotify_alert "JWT Monitor Running Again — ${HOST}" "$msg" "${GOTIFY_PRIORITY:-5}"
  send_email_alert "[Liveness] JWT monitor ${monitor} recovered — ${HOST}" "$msg"
  send_brevo_alert "[Liveness] JWT monitor ${monitor} recovered — ${HOST}" "$msg"
  send_telegram_alert "[Liveness] JWT monitor ${monitor} recovered — ${HOST}" "$msg"
}

# --------------------------------------------------------------------------- #
# Check
# --------------------------------------------------------------------------- #

problems=0
summary_parts=()

for monitor in $MONITORS; do
  ts="$(last_heartbeat_ts "$monitor")"
  age=0
  if [ -z "$ts" ]; then
    status="missing"
    age_text="never"
  else
    epoch="$(ts_to_epoch "$ts")"
    if [ "$epoch" -le 0 ]; then
      status="missing"
      age_text="never (unparsable timestamp '${ts}')"
    else
      age=$((NOW_EPOCH - epoch))
      [ "$age" -lt 0 ] && age=0
      age_text="$(human_age "$age") ago"
      if [ "$age" -gt "$MAX_AGE_SECONDS" ]; then
        status="stale"
      else
        status="ok"
      fi
    fi
  fi

  summary_parts+=("${monitor}=${status}(${age_text})")

  case "$status" in
    ok)
      if alerting "$monitor"; then
        echo "$(timestamp) RECOVERED ${monitor}: heartbeats resumed (${age_text})" >> "$LOG"
        if [ -z "$DRY_RUN" ]; then
          send_recovery_alert "$monitor" "$age_text"
          mark_recovered "$monitor"
        fi
      fi
      ;;
    *)
      problems=1
      if alerting "$monitor"; then
        echo "$(timestamp) STALE ${monitor}: ${age_text} (threshold ${MAX_AGE_MINUTES}m) — alert already sent, not repeating" >> "$LOG"
      else
        echo "$(timestamp) STALE ${monitor}: ${age_text} (threshold ${MAX_AGE_MINUTES}m)" >> "$LOG"
        if [ -z "$DRY_RUN" ]; then
          send_liveness_alert "$monitor" "$status" "$age_text"
          if any_channel; then
            echo "$(timestamp) ALERT liveness alert sent for ${monitor}" >> "$LOG"
          else
            echo "$(timestamp) NOTE liveness alert not sent for ${monitor}: no alert channel configured" >> "$LOG"
          fi
          mark_alerting "$monitor"
        fi
      fi
      ;;
  esac
done

# --------------------------------------------------------------------------- #
# Report
# --------------------------------------------------------------------------- #

detail="$(printf '%s ' "${summary_parts[@]}")"
detail="${detail% }"

if [ -n "$DRY_RUN" ]; then
  line="$(timestamp) DRY-RUN liveness: ${detail} (threshold ${MAX_AGE_MINUTES}m)"
  echo "$line" >> "$LOG"
  echo "$line"
  exit "$problems"
fi

if [ "$problems" -eq 0 ]; then
  echo "$(timestamp) OK all monitors running: ${detail} (threshold ${MAX_AGE_MINUTES}m)" >> "$LOG"
else
  echo "$(timestamp) PROBLEM monitor(s) not running: ${detail} (threshold ${MAX_AGE_MINUTES}m)" >> "$LOG"
fi

echo "$(timestamp) liveness: ${detail} (threshold ${MAX_AGE_MINUTES}m)"
exit "$problems"
