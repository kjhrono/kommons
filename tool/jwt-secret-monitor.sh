#!/usr/bin/env bash
# ============================================================================
# jwt-secret-monitor.sh — the single program behind the JWT-secret cron watch.
#
# Source of truth: kommons tool/.  It is installed on the VM as
# ~/bin/jwt-secret-monitor.sh by tool/install_jwt_secret_watch.sh, which also
# deploys the helpers this file sources and writes the three cron entries.
#
# It replaces FOUR separate scripts that each re-implemented part of the same
# idea (jwt-secret-drift-check, -revert-watchdog, -delivery-watchdog and
# -liveness-check).  One file, two cron lines:
#
#   *  monitor   (every 15 min) — the secret watch itself:
#        - compares every project stack's JWT_SECRET with the CANONICAL value.
#          The canonical value is the identity stack's JWT_SECRET, defined once
#          in canonical_secret.sh — the same definition the operator repair
#          (tool/dev/repair_jwt_secret_drift.sh) converges TO, so the thing that
#          compares and the thing that repairs cannot disagree;
#        - fingerprints each stack's .env.bak.* history and force-re-cuts a
#          stack whose secret matches a known PRE-CUTOVER fingerprint, i.e. an
#          exact revert: restore the identity secret, recreate, verify;
#        - writes one "<ts> HEARTBEAT monitor <verdict>" line per run whatever
#          the outcome, so "did not run" stays distinguishable from "ran and
#          found nothing".
#
#   *  meta      (every 30 min) — the watch on the watch:
#        - liveness: reads the shared log and alerts when the monitor's newest
#          heartbeat is older than MAX_AGE_MINUTES.  Catches a deleted cron
#          entry, a script that lost its executable bit, a host that rebooted
#          into a broken crontab.  Alerts on transitions only, with a recovery
#          notice, so an outage has a visible end;
#        - delivery: reads the Gotify delivery history and alerts when the daily
#          summary's delivery — the alert pipeline's heartbeat — is older than
#          MAX_AGE_HOURS.  Covers a broken Gotify server, a revoked token, a
#          dead daily-summary cron.
#
# Liveness deliberately lives on a SEPARATE cron entry from the monitor it
# watches: inside the monitor it would be silenced by the very failure it
# exists to report.
#
# Log vocabulary is load-bearing — jwt-secret-daily-summary.sh parses the shared
# log into "<TS> <EVENT> <stack>: <detail>" groups: OK, DRIFT, WARN,
# "REVERT DETECTED", REVERT, "DONE:", REGISTRY, FATAL, HEARTBEAT.  Keep it.
# Secrets are never printed: lengths and fingerprints only.
#
# Usage:
#   jwt-secret-monitor.sh monitor [--check]   # drift + revert watch (cron: */15)
#   jwt-secret-monitor.sh meta    [--check]   # liveness + delivery (cron: 0,30)
#   jwt-secret-monitor.sh --check             # monitor mode, report only
#   jwt-secret-monitor.sh --stacks            # print the watched stack names, one
#                                             # per line, and exit — this is the
#                                             # authority on what is still watched,
#                                             # which other tools consult rather
#                                             # than guess (see the daily summary)
#
# --check never alerts, never writes a log line, never re-cuts anything; it
# prints what a real run would do.  Use it to smoke-test after an install.
#
# Exit status:
#   monitor : 0 clean, 1 drift detected or a revert was auto-re-cut, 2 a re-cut
#             FAILED (manual intervention), 1 fatal (canonical source unreadable)
#   meta    : 0 healthy, 1 a monitor or the delivery heartbeat looks wrong,
#             2 usage or configuration error
#
# Configuration (crontab environment or export):
#   LOG               shared monitor log (default: ~/logs/jwt-secret-drift.log)
#   LIVENESS_LOG      liveness findings (default: ~/logs/jwt-secret-liveness.log)
#   DELIVERY_LOG      delivery findings (default: ~/logs/jwt-secret-delivery.log)
#   STATE             liveness alert state (default: ~/logs/jwt-secret-liveness.state)
#   MONITORS          heartbeats to watch in meta mode (default: "monitor")
#   MAX_AGE_MINUTES   heartbeat staleness threshold (default: 45)
#   MAX_AGE_HOURS     delivery staleness threshold (default: 26)
#   EXPECT_TITLE      delivery heartbeat title substring (default: JWT Daily Summary)
#   GOTIFY_DB         Gotify database (default: ~/gotify/data/gotify.db)
#   AUDIT             gotify-messages.sh path (default: beside this script)
#   KAT_IDENTITY_ENV  override the canonical .env (default: see canonical_secret.sh)
#   ALERT_WEBHOOK_URL, ALERT_EMAIL, BREVO_API_KEY, BREVO_SENDER, BREVO_SENDER_NAME,
#   GOTIFY_URL, GOTIFY_APP_TOKEN, GOTIFY_PRIORITY — alert channels (see alert.sh)
#
# Requires alert.sh, canonical_secret.sh and gotify-messages.sh beside this
# script.  tool/install_jwt_secret_watch.sh installs the whole set — the
# program, every helper it sources, and every cron entry — in one run.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=alert.sh
. "${SCRIPT_DIR}/alert.sh"
# shellcheck source=canonical_secret.sh
. "${SCRIPT_DIR}/canonical_secret.sh"

# --- arguments ------------------------------------------------------------- #

MODE="monitor"
CHECK=0
PRINT_STACKS=0

usage() { sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d'; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    monitor|meta) MODE="$1" ;;
    --check|--dry-run) CHECK=1 ;;
    --stacks) PRINT_STACKS=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "jwt-secret-monitor: unknown argument: $1" >&2
      echo "usage: jwt-secret-monitor.sh [monitor|meta] [--check] [--stacks]" >&2
      exit 2
      ;;
  esac
  shift
done

# --- configuration --------------------------------------------------------- #

IDENTITY_ENV="$(kat_canonical_env)"

LOG="${LOG:-$HOME/logs/jwt-secret-drift.log}"
LIVENESS_LOG="${LIVENESS_LOG:-$HOME/logs/jwt-secret-liveness.log}"
DELIVERY_LOG="${DELIVERY_LOG:-$HOME/logs/jwt-secret-delivery.log}"
STATE="${STATE:-$HOME/logs/jwt-secret-liveness.state}"
MONITOR_LOG="${MONITOR_LOG:-$LOG}"
MONITORS="${MONITORS:-monitor}"
MAX_AGE_MINUTES="${MAX_AGE_MINUTES:-45}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-26}"
EXPECT_TITLE="${EXPECT_TITLE:-JWT Daily Summary}"
GOTIFY_DB="${GOTIFY_DB:-$HOME/gotify/data/gotify.db}"
AUDIT="${AUDIT:-${SCRIPT_DIR}/gotify-messages.sh}"
HOST="${HOST:-$(hostname)}"

REGISTRY_DIR="$HOME/.jwt-secret-history"
REGISTRY_FILE="$REGISTRY_DIR/registry.sha256"

# Stacks: name|env_path|compose_dir.
# kommons is the identity reference — it IS the canonical source, so it is
# listed for completeness but never re-cut.  A stack whose checkout is gone
# does not belong here: it would log a WARN every 15 minutes forever.
STACKS=(
  "kommons|${IDENTITY_ENV}|${HOME}/Projects/kommons/supabase-identity/docker"
  "katalogus|${HOME}/Projects/katalogus/database/docker/.env|${HOME}/Projects/katalogus/database/docker"
  "kalcio|${HOME}/Projects/kalcio/database/docker/.env|${HOME}/Projects/kalcio/database/docker"
  "kognitio|${HOME}/Projects/kognitio/database/docker/.env|${HOME}/Projects/kognitio/database/docker"
  "kollectio|${HOME}/Projects/kollectio/database/docker/.env|${HOME}/Projects/kollectio/database/docker"
  "kapaxinfiniti|${HOME}/Projects/kapaxinfiniti/database/docker/.env|${HOME}/Projects/kapaxinfiniti/database/docker"
)

# --stacks: the watched stack names, one per line, and nothing else.  This is
# the one authority on which stacks a watch still contains; the daily summary
# consults it so a RETIRED stack's lingering log lines are not reported as live
# incidents (see the "retired stack" handling there).
if [ "$PRINT_STACKS" = 1 ]; then
  for _stack_spec in "${STACKS[@]}"; do printf '%s\n' "${_stack_spec%%|*}"; done
  exit 0
fi

# --- shared helpers -------------------------------------------------------- #

# log_line <file> <line> — append to a log, or echo it in --check mode.  In
# check mode nothing is written anywhere, so a smoke test cannot pollute the
# audit trail the daily summary reads.
log_line() {
  if [ "$CHECK" = 1 ]; then
    printf '%s\n' "$2"
  else
    printf '%s\n' "$2" >> "$1"
  fi
}

# alert_if_live <fn> [args...] — suppress alert fan-out in --check mode.
alert_if_live() {
  if [ "$CHECK" = 1 ]; then return 0; fi
  "$@"
}

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

# --- alert fan-out --------------------------------------------------------- #
#
# Alerts deliberately go to EVERY configured channel: the channel that broke may
# be the one being reported on.  Routine reports (the daily digest, the weekly
# trend) are the ones that must pick a single channel — see alert.sh.

send_drift_alerts() {
  local details="$1" msg
  msg="🚨 JWT Secret Drift Detected — ${HOST}
${details}
Action: converge the affected stacks onto the identity secret.
        bash tool/dev/repair_jwt_secret_drift.sh          # plan
        bash tool/dev/repair_jwt_secret_drift.sh --apply  # converge
Log:   $(readlink -f "$LOG")"
  send_webhook_alert "$msg"
  send_gotify_alert "JWT Secret Drift Detected — ${HOST}" "$msg" 8
  send_email_alert "[Drift Alert] JWT Secret Mismatch — ${HOST}" "$msg"
  send_brevo_alert "[Drift Alert] JWT Secret Mismatch — ${HOST}" "$msg"
}

send_revert_alerts() {
  local details="$1" msg
  msg="🔄 JWT Exact-Revert + Auto Re-cut — ${HOST}

${details}

"
  send_webhook_alert "$msg"
  send_gotify_alert "JWT Revert + Auto Re-cut — ${HOST}" "$msg" "${GOTIFY_PRIORITY:-8}"
  send_email_alert "[Revert Alert] JWT Secret Re-cut — ${HOST}" "$msg"
  send_brevo_alert "[Revert Alert] JWT Secret Re-cut — ${HOST}" "$msg"
}

# =========================================================================== #
# monitor mode: drift detection + exact-revert auto re-cut
# =========================================================================== #

MONITOR_ID="monitor"
HEARTBEAT_VERDICT="ok"
heartbeat() { printf '%s\n' "$(timestamp) HEARTBEAT ${MONITOR_ID} ${HEARTBEAT_VERDICT}" >> "$LOG"; }

# build_registry <canonical-fingerprint> — the pre-cutover fingerprint set,
# harvested from every .env.bak.* history file on the host.  A .env whose
# secret matches one of these was rolled back to a value from before the
# cutover; a .env whose secret merely differs is ordinary drift.
build_registry() {
  local canon_fp="$1"
  local tmpfile count
  tmpfile="$(mktemp)"

  # `find` returns non-zero when it hits root-owned PostgreSQL volume dirs the
  # ubuntu user cannot traverse — expected, hence `|| true` (and this function
  # must not fail the run either).
  find "$HOME/Projects" -name ".env.bak.*" -type f 2>/dev/null \
    | sort \
    | while IFS= read -r bak; do
        local sec fpv
        sec="$(read_env "$bak" JWT_SECRET)"
        [ -n "$sec" ] || continue
        # Skip test/drill placeholders that never were real secrets.
        case "$sec" in
          *stale-drill*|*not-a-real-value*|*secret-here*|*test-secret*) continue ;;
        esac
        fpv="$(secret_fp_full "$sec")"
        # The current identity secret is post-cutover, not pre-cutover.
        [ "$fpv" = "$canon_fp" ] && continue
        printf '%s\n' "$fpv"
      done | sort -u > "$tmpfile" || true

  mv "$tmpfile" "$REGISTRY_FILE"
  count="$(wc -l < "$REGISTRY_FILE" | tr -d ' ')"
  log_line "$LOG" "$(timestamp) REGISTRY built: ${count} pre-cutover fingerprints (identity=${canon_fp:0:16}…)"
}

# force_recut <stack> <env_file> <compose_dir> <canonical-secret>
force_recut() {
  local stack="$1" env_file="$2" compose_dir="$3" canon="$4"
  local backup new_secret auth_container="" auth_check="" poll=0 max_poll=30

  backup="${env_file}.bak.recut-auto.$(date +%s)"

  log_line "$LOG" "$(timestamp) REVERT $stack: JWT_SECRET matches pre-cutover fingerprint — force re-cut"

  # 1. Back up the reverted .env before touching it.
  if ! cp "$env_file" "$backup" 2>/dev/null; then
    log_line "$LOG" "$(timestamp) REVERT $stack: FAILED to back up $env_file"
    alert_if_live send_revert_alerts "Exact revert detected in ${stack} but could not back up ${env_file} — manual intervention required."
    return 1
  fi
  log_line "$LOG" "$(timestamp) REVERT $stack: backed up $env_file → $backup"

  # 2. Restore the canonical (identity) secret.
  if grep -q '^JWT_SECRET=' "$env_file"; then
    sed -i "s|^JWT_SECRET=.*$|JWT_SECRET=${canon}|" "$env_file"
  else
    printf 'JWT_SECRET=%s\n' "$canon" >> "$env_file"
  fi

  # 3. Verify the edit took hold, and roll it back if it did not.
  new_secret="$(read_env "$env_file" JWT_SECRET)"
  if [ "$new_secret" != "$canon" ]; then
    log_line "$LOG" "$(timestamp) REVERT $stack: FAILED to update JWT_SECRET — restored from $backup"
    cp "$backup" "$env_file"
    alert_if_live send_revert_alerts "Re-cut FAILED for ${stack}: JWT_SECRET could not be updated.  Backup restored.
File: ${env_file}
Manual intervention required."
    return 1
  fi
  log_line "$LOG" "$(timestamp) REVERT $stack: JWT_SECRET restored in $env_file"

  # 4. Force-recreate the stack so containers pick the new env up.  `--wait` is
  #    deliberately omitted: Supabase stacks include a realtime container whose
  #    healthcheck is intermittently flaky (WebSocket ping under load), so
  #    --wait blocks until its timeout and a successful secret restore would
  #    read as a failure.  Fire `up -d` and poll auth health separately.
  log_line "$LOG" "$(timestamp) REVERT $stack: docker compose up -d --force-recreate in $compose_dir"
  if ! (cd "$compose_dir" && docker compose up -d --force-recreate) >> "$LOG" 2>&1; then
    log_line "$LOG" "$(timestamp) REVERT $stack: docker compose up -d --force-recreate failed — check $LOG"
    alert_if_live send_revert_alerts "Exact revert detected in ${stack}: JWT_SECRET was restored in ${env_file} but
docker compose up --force-recreate failed.
Backup: ${backup}
Manual intervention required: verify stack health manually."
    return 1
  fi

  # 5. Poll the auth/gotrue container to a usable state: up to 30 x 10s = 5 min
  #    of tolerance for slow image pulls and DB migrations.
  log_line "$LOG" "$(timestamp) REVERT $stack: waiting for auth container to become healthy…"
  while [ "$poll" -lt "$max_poll" ]; do
    auth_container="$(cd "$compose_dir" && docker compose ps -q auth 2>/dev/null || true)"
    if [ -z "$auth_container" ]; then
      auth_container="$(cd "$compose_dir" && docker compose ps -q gotrue 2>/dev/null || true)"
    fi
    if [ -n "$auth_container" ]; then
      local hc_status
      hc_status="$(docker inspect --format='{{.State.Health.Status}}' "$auth_container" 2>/dev/null || true)"
      # "healthy", or empty when the container has no healthcheck = ready.
      if [ "$hc_status" = "healthy" ] || [ -z "$hc_status" ]; then break; fi
    fi
    poll=$((poll + 1))
    sleep 10
  done

  # 6. Confirm the secret landed in the running auth container.
  if [ -n "$auth_container" ]; then
    auth_check="$(docker exec "$auth_container" printenv GOTRUE_JWT_SECRET 2>/dev/null || true)"
    if [ "$auth_check" = "$canon" ]; then
      log_line "$LOG" "$(timestamp) REVERT $stack: ✓ running auth container confirms JWT_SECRET matches identity"
    else
      log_line "$LOG" "$(timestamp) REVERT $stack: ⚠ running auth container JWT_SECRET mismatch (container may still be starting)"
    fi
  fi

  log_line "$LOG" "$(timestamp) REVERT $stack: re-cut complete"
  alert_if_live send_revert_alerts "Exact JWT_SECRET revert auto-repaired.

Stack:      ${stack}
Env:        ${env_file}
Action:     JWT_SECRET restored to the identity-stack secret + docker compose --force-recreate
Backup:     ${backup}
Log:        $(readlink -f "$LOG")"
  return 0
}

run_monitor() {
  local canon canon_fp
  local drift=0 recut=0 recut_failed=0 drift_details=""
  local stack env_file compose_dir rest secret fpv

  if [ "$CHECK" = 0 ]; then trap heartbeat EXIT; fi

  # --- the canonical value, from its single definition -------------------- #
  if [ ! -f "$IDENTITY_ENV" ]; then
    log_line "$LOG" "$(timestamp) FATAL identity .env not found at $IDENTITY_ENV"
    alert_if_live send_drift_alerts "identity .env not found at $IDENTITY_ENV"
    HEARTBEAT_VERDICT="fatal"
    return 1
  fi
  canon="$(kat_canonical_secret)"
  if [ -z "$canon" ]; then
    log_line "$LOG" "$(timestamp) FATAL could not read reference JWT_SECRET from $IDENTITY_ENV"
    alert_if_live send_drift_alerts "could not read reference JWT_SECRET from $IDENTITY_ENV"
    HEARTBEAT_VERDICT="fatal"
    return 1
  fi
  canon_fp="$(secret_fp_full "$canon")"

  if [ "$CHECK" = 1 ]; then
    printf 'canonical source: %s (len %s, fp %s)\n' "$IDENTITY_ENV" "${#canon}" "$(secret_fp "$canon")"
  else
    build_registry "$canon_fp"
  fi

  # --- every stack, in one pass: drift OR an exact revert ----------------- #
  for entry in "${STACKS[@]}"; do
    stack="${entry%%|*}"
    rest="${entry#*|}"
    env_file="${rest%%|*}"
    compose_dir="${rest#*|}"

    if [ ! -f "$env_file" ]; then
      log_line "$LOG" "$(timestamp) WARN $stack: .env not found at $env_file"
      continue
    fi
    secret="$(read_env "$env_file" JWT_SECRET)"
    if [ -z "$secret" ]; then
      log_line "$LOG" "$(timestamp) WARN $stack: JWT_SECRET empty in $env_file"
      continue
    fi

    fpv="$(secret_fp_full "$secret")"
    if [ "$CHECK" = 1 ]; then
      local state="matches canonical"
      [ "$fpv" = "$canon_fp" ] || state="DIFFERS"
      printf '  %-14s len %-4s fp %-17s %s\n' "$stack" "${#secret}" "$(secret_fp "$secret")" "$state"
    fi
    if [ "$fpv" = "$canon_fp" ]; then continue; fi

    # The identity stack IS the canonical source, so it cannot drift from
    # itself; never re-cut it.
    if [ "$stack" = "kommons" ]; then continue; fi

    if [ -f "$REGISTRY_FILE" ] && grep -qFx "$fpv" "$REGISTRY_FILE"; then
      log_line "$LOG" "$(timestamp) REVERT DETECTED $stack: $fpv = pre-cutover secret — triggering auto re-cut"
      if [ "$CHECK" = 1 ]; then
        log_line "$LOG" "$(timestamp) REVERT $stack: (check mode — the re-cut was not performed)"
        recut=1
        continue
      fi
      if force_recut "$stack" "$env_file" "$compose_dir" "$canon"; then
        recut=1
      else
        recut_failed=1
      fi
    else
      log_line "$LOG" "$(timestamp) DRIFT $stack: JWT_SECRET differs from identity and is not a known pre-cutover secret ($env_file)"
      drift=1
      drift_details="${drift_details}  • ${stack} — differs from identity ($env_file)\n"
    fi
  done

  if [ "$CHECK" = 1 ]; then
    if [ "$drift" = 1 ]; then
      printf 'verdict: drift (plan only — nothing was changed)\n'
    elif [ "$recut" = 1 ]; then
      printf 'verdict: revert detected (plan only — a real run would re-cut)\n'
    else
      printf 'verdict: clean (every stack matches the identity secret)\n'
    fi
    if [ "$drift" = 1 ] || [ "$recut" = 1 ]; then return 1; fi
    return 0
  fi

  # --- verdict + alerts ---------------------------------------------------- #
  if [ "$drift" = 1 ]; then
    send_drift_alerts "$drift_details"
  fi

  if [ "$recut_failed" = 1 ]; then
    log_line "$LOG" "$(timestamp) DONE: revert detected but re-cut FAILED — manual intervention required"
    HEARTBEAT_VERDICT="failed"
    return 2
  fi
  if [ "$recut" = 1 ]; then
    log_line "$LOG" "$(timestamp) DONE: at least one exact revert was auto-re-cut"
    HEARTBEAT_VERDICT="recut"
    return 1
  fi
  if [ "$drift" = 1 ]; then
    HEARTBEAT_VERDICT="drift"
    return 1
  fi

  log_line "$LOG" "$(timestamp) OK all stacks match identity JWT_SECRET"
  return 0
}

# =========================================================================== #
# meta mode: liveness of the monitor + delivery of the alert pipeline
# =========================================================================== #

# last_heartbeat_ts <monitor-id> — timestamp of that monitor's newest heartbeat.
# The log is append-only, so the last match is the newest; awk reads the whole
# file rather than exiting early, which would send SIGPIPE back up a `tac` and
# make the pipeline look like a failure.
last_heartbeat_ts() {
  local mon="$1"
  [ -f "$MONITOR_LOG" ] || { printf ''; return 0; }
  awk -v m="$mon" '$2 == "HEARTBEAT" && $3 == m { ts = $1 } END { print ts }' "$MONITOR_LOG"
}

ts_to_epoch() { date -d "$1" +%s 2>/dev/null || echo 0; }

alerting() {
  [ -f "$STATE" ] || return 1
  grep -qxF -- "$1" "$STATE" 2>/dev/null
}

mark_alerting() {
  if alerting "$1"; then return 0; fi
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

It drives the drift/revert watch, so the secrets are currently going
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
}

run_liveness() { # <monitors> <max-age-minutes>
  local monitors="$1" max_age_minutes="$2"
  local now_epoch max_age_seconds problems=0 summary_parts=()
  local monitor ts epoch age age_text status

  case "$max_age_minutes" in
    ''|*[!0-9]*)
      printf 'jwt-secret-monitor: MAX_AGE_MINUTES must be a non-negative integer\n' >&2
      return 2
      ;;
  esac
  if [ "$max_age_minutes" -lt 1 ]; then
    printf 'jwt-secret-monitor: MAX_AGE_MINUTES must be at least 1\n' >&2
    return 2
  fi
  if [ -z "${monitors// /}" ]; then
    printf 'jwt-secret-monitor: MONITORS must name at least one monitor\n' >&2
    return 2
  fi

  max_age_seconds=$((max_age_minutes * 60))
  now_epoch="$(date +%s)"

  for monitor in $monitors; do
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
        age=$((now_epoch - epoch))
        if [ "$age" -lt 0 ]; then age=0; fi
        age_text="$(human_age "$age") ago"
        if [ "$age" -gt "$max_age_seconds" ]; then status="stale"; else status="ok"; fi
      fi
    fi

    summary_parts+=("${monitor}=${status}(${age_text})")

    case "$status" in
      ok)
        if alerting "$monitor"; then
          log_line "$LIVENESS_LOG" "$(timestamp) RECOVERED ${monitor}: heartbeats resumed (${age_text})"
          if [ "$CHECK" = 0 ]; then
            send_recovery_alert "$monitor" "$age_text"
            mark_recovered "$monitor"
          fi
        fi
        ;;
      *)
        problems=1
        if alerting "$monitor"; then
          log_line "$LIVENESS_LOG" "$(timestamp) STALE ${monitor}: ${age_text} (threshold ${max_age_minutes}m) — alert already sent, not repeating"
        else
          log_line "$LIVENESS_LOG" "$(timestamp) STALE ${monitor}: ${age_text} (threshold ${max_age_minutes}m)"
          if [ "$CHECK" = 0 ]; then
            send_liveness_alert "$monitor" "$status" "$age_text"
            if any_channel; then
              printf '%s\n' "$(timestamp) ALERT liveness alert sent for ${monitor}" >> "$LIVENESS_LOG"
            else
              printf '%s\n' "$(timestamp) NOTE liveness alert not sent for ${monitor}: no alert channel configured" >> "$LIVENESS_LOG"
            fi
            mark_alerting "$monitor"
          fi
        fi
        ;;
    esac
  done

  local detail
  detail="$(printf '%s ' "${summary_parts[@]}")"
  detail="${detail% }"

  if [ "$CHECK" = 1 ]; then
    printf 'liveness: %s (threshold %sm)\n' "$detail" "$max_age_minutes"
    return "$problems"
  fi

  if [ "$problems" -eq 0 ]; then
    printf '%s\n' "$(timestamp) OK all monitors running: ${detail} (threshold ${max_age_minutes}m)" >> "$LIVENESS_LOG"
  else
    printf '%s\n' "$(timestamp) PROBLEM monitor(s) not running: ${detail} (threshold ${max_age_minutes}m)" >> "$LIVENESS_LOG"
  fi
  return "$problems"
}

# age_of [<title-substring>] — seconds since the newest matching delivery, -1
# when none match, or "ERR <reason>" when the history is unreadable.  With no
# argument it considers every delivery.  The reason travels on stdout rather
# than through a global because this is always called from a command
# substitution, whose subshell would discard any variable it set.
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

# send_delivery_alerts <detail> <note> — fans the stall alert out to every
# configured channel, Gotify included: when the heartbeat is missing because
# the daily summary stopped running rather than because Gotify is down, the
# push still lands.
send_delivery_alerts() {
  local detail="$1" note="$2" msg
  msg="🛑 JWT Alert Delivery Stalled — ${HOST}

${detail}
${note}

The JWT-secret monitors deliver through Gotify, so no heartbeat means the
alert pipeline is blind.
Action: check that the monitoring crons are running and that the Gotify
server and app token are healthy.
History: ${GOTIFY_DB}
Log:     ${DELIVERY_LOG}"
  send_webhook_alert "$msg"
  send_gotify_alert "JWT Alert Delivery Stalled — ${HOST}" "$msg" "${GOTIFY_PRIORITY:-8}"
  send_email_alert "[Delivery Alert] JWT alert pipeline stalled — ${HOST}" "$msg"
  send_brevo_alert "[Delivery Alert] JWT alert pipeline stalled — ${HOST}" "$msg"
}

run_delivery() {
  local max_age_seconds heartbeat_age any_age problem="" detail="" any_note err_text

  case "$MAX_AGE_HOURS" in
    ''|*[!0-9]*)
      printf 'jwt-secret-monitor: MAX_AGE_HOURS must be a non-negative integer\n' >&2
      return 2
      ;;
  esac
  max_age_seconds=$((MAX_AGE_HOURS * 3600))

  if [ ! -f "$AUDIT" ]; then
    printf 'jwt-secret-monitor: audit helper not found at %s\n' "$AUDIT" >&2
    return 2
  fi

  heartbeat_age="$(age_of "$EXPECT_TITLE")"
  any_age="$(age_of "")"

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
      if [ "$heartbeat_age" -gt "$max_age_seconds" ]; then
        problem="heartbeat-stale"
        detail="The newest \"${EXPECT_TITLE}\" delivery is $(human_age "$heartbeat_age") old, past the ${MAX_AGE_HOURS}h threshold."
      fi
      ;;
  esac

  if [ -z "$problem" ]; then
    if [ "$CHECK" = 1 ]; then
      printf 'delivery: healthy, "%s" last delivered %s ago (threshold %sh)\n' \
        "$EXPECT_TITLE" "$(human_age "$heartbeat_age")" "$MAX_AGE_HOURS"
      return 0
    fi
    printf '%s\n' "$(timestamp) OK delivery heartbeat: \"${EXPECT_TITLE}\" last delivered $(human_age "$heartbeat_age") ago (threshold ${MAX_AGE_HOURS}h)" >> "$DELIVERY_LOG"
    return 0
  fi

  case "$any_age" in
    ERR*) any_note="newest delivery of any kind: unavailable (history unreadable)" ;;
    -1)   any_note="newest delivery of any kind: none recorded" ;;
    *)    any_note="newest delivery of any kind: $(human_age "$any_age") ago" ;;
  esac

  log_line "$DELIVERY_LOG" "$(timestamp) STALL ${problem}: ${detail} (${any_note})"
  if [ "$CHECK" = 1 ]; then
    printf 'delivery: %s — %s\n' "$problem" "$detail"
    return 1
  fi
  send_delivery_alerts "$detail" "$any_note"
  printf '%s\n' "$(timestamp) ALERT delivery watchdog alert sent (${problem})" >> "$DELIVERY_LOG"
  return 1
}

run_meta() {
  local lrc=0 drc=0 rc
  run_liveness "$MONITORS" "$MAX_AGE_MINUTES" || lrc=$?
  run_delivery || drc=$?
  if [ "$lrc" = 2 ] || [ "$drc" = 2 ]; then
    rc=2
  elif [ "$lrc" != 0 ] || [ "$drc" != 0 ]; then
    rc=1
  else
    rc=0
  fi
  return "$rc"
}

# =========================================================================== #
# dispatch
# =========================================================================== #

if [ "$CHECK" = 0 ]; then
  mkdir -p "$(dirname "$LOG")" "$(dirname "$LIVENESS_LOG")" \
           "$(dirname "$DELIVERY_LOG")" "$(dirname "$STATE")" "$REGISTRY_DIR"
fi

rc=0
case "$MODE" in
  monitor) run_monitor || rc=$? ;;
  meta)    run_meta    || rc=$? ;;
esac
exit "$rc"
