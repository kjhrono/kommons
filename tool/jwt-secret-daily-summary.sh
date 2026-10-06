#!/usr/bin/env bash
# jwt-secret-daily-summary.sh
#
# Daily digest of JWT-secret health spanning the past 24h (configurable
# via WINDOW_HOURS).  The shared drift-watchdog log is condensed rather than
# reprinted: clean runs and registry rebuilds run into the dozens every day
# and carry no new information, so they become counts, while DRIFT, WARN,
# REVERT, FATAL and DONE events are grouped under the stack they belong to.
#
# A DONE: line is the one incident that names no stack of its own: it is the
# revert watchdog's per-run summary ("at least one exact revert was auto-re-cut",
# "re-cut FAILED") and stands for the reverts that run just handled.  It is
# therefore attributed to the stack(s) of the REVERT lines in the same run
# rather than filed under a vague host-level heading.  A run is delimited by the
# REGISTRY line the revert watchdog writes at its start; when a run's reverts
# fall outside the window there is nothing to attribute the summary to, and it
# stays host-level.
#
# It also folds in the delivery watchdog's status, so a single message
# covers both secret health and alert-pipeline health.  The watchdog's own
# log is read over the same window: a run that found no stall means the
# pipeline is healthy, a STALL line means it is not, and no line at all
# means the pipeline's health is simply unverified — a watchdog that stopped
# running being exactly the sort of silent failure this digest must not
# paper over.
#
# Pipeline health is reported twice over, because the watchdog's log is stale
# by construction: it only runs hourly, so its log describes the pipeline as
# of its last check.  The digest therefore samples the Gotify delivery
# history itself, at send time, and prints the heartbeat's current age beside
# the watchdog's verdict — then calls out any disagreement between the two.
# Both directions matter: a log reading healthy while the live history shows
# the heartbeat past MAX_AGE_HOURS means the pipeline died after the last
# check, and a log reading stalled while the heartbeat is current means
# delivery has since resumed.  A live reading that cannot be taken is reported
# as such rather than guessed at.  A disagreement escalates the subject in its
# own right (`pipeline disagreement`), so the conflict is visible without
# opening the message: two readings that contradict each other mean one of them
# is wrong, which is not the same thing as either of them being bad, and it is
# what tells a stalled pipeline apart from a stalled watchdog.
#
# Delivered via incoming-webhook (when ALERT_WEBHOOK_URL is set) and by email
# — same alert env-var scheme as drift-check.sh and
# jwt-secret-revert-watchdog.sh.
#
# Unlike those urgent alerts, this is a routine report, so it picks ONE email
# channel — Brevo when configured, else local mail(1) — instead of sending the
# recipient the identical digest twice.  See send_email_report in alert.sh.
#
# Alert env vars:
#   ALERT_WEBHOOK_URL  — incoming-webhook URL for real-time alerts;
#                        empty → silent no-op
#   ALERT_EMAIL        — email recipient
#   BREVO_API_KEY      — Brevo REST API key for email delivery
#   BREVO_SENDER       — sender email (default: noreply@mediasart.com)
#   BREVO_SENDER_NAME  — sender name (default: mediasart)
#   GOTIFY_URL         — Gotify server base URL (e.g. https://notify.mediasart.com)
#   GOTIFY_APP_TOKEN   — Gotify application token for the alert app
#   GOTIFY_PRIORITY    — default priority for Gotify alerts (default: 5)
#
# Operational env vars:
#   LOG                — path to log file (default: ~/logs/jwt-secret-drift.log)
#   DELIVERY_LOG       — delivery-watchdog log folded into the digest as the
#                        pipeline-health section
#                        (default: ~/logs/jwt-secret-delivery.log)
#   WINDOW_HOURS       — summary window in hours (default: 24; set to 4 for testing)
#
# Live pipeline-check env vars — these must match the delivery watchdog's, so
# that the two readings describe the same heartbeat and can be compared:
#   GOTIFY_DB          — path to the Gotify SQLite history
#                        (default: ~/gotify/data/gotify.db)
#   AUDIT              — path to gotify-messages.sh (default: beside this script)
#   EXPECT_TITLE       — heartbeat alert title substring
#                        (default: JWT Daily Summary)
#   MAX_AGE_HOURS      — live heartbeat threshold (default: 26)
set -euo pipefail

# Source shared alert helpers (send_webhook_alert, send_gotify_alert,
# send_email_alert, send_brevo_alert, timestamp, json_escape) from tool/alert.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=alert.sh
. "${SCRIPT_DIR}/alert.sh"

# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #

LOG="${LOG:-$HOME/logs/jwt-secret-drift.log}"
DELIVERY_LOG="${DELIVERY_LOG:-$HOME/logs/jwt-secret-delivery.log}"
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
GOTIFY_URL="${GOTIFY_URL:-}"
GOTIFY_APP_TOKEN="${GOTIFY_APP_TOKEN:-}"
GOTIFY_PRIORITY="${GOTIFY_PRIORITY:-5}"

# Live pipeline check — same helpers, defaults and threshold as
# jwt-secret-delivery-watchdog.sh, so the digest's reading and the watchdog's
# log describe the same heartbeat and a mismatch means something real.
GOTIFY_DB="${GOTIFY_DB:-$HOME/gotify/data/gotify.db}"
AUDIT="${AUDIT:-${SCRIPT_DIR}/gotify-messages.sh}"
EXPECT_TITLE="${EXPECT_TITLE:-JWT Daily Summary}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-26}"

case "$MAX_AGE_HOURS" in
  ''|*[!0-9]*)
    echo "jwt-secret-daily-summary: MAX_AGE_HOURS must be a non-negative integer" >&2
    exit 2
    ;;
esac
MAX_AGE_SECONDS=$((MAX_AGE_HOURS * 3600))

HOST=$(hostname)
EMAIL_CHANNEL=""

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #

ts_to_epoch() {
  local ts="$1"
  date -d "${ts}" +%s 2>/dev/null || echo 0
}

# human_age <seconds> — compact age for the digest.  Deliberately identical to
# the delivery watchdog's formatting, so the live reading and the log's quoted
# age can be compared at a glance.
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

# live_delivery_age — seconds since the newest delivery matching EXPECT_TITLE,
# -1 when none match, or "ERR <reason>".  Queries the Gotify history directly
# through the same audit helper the delivery watchdog uses, so the digest
# reports the pipeline's state *now* rather than replaying the watchdog's last
# (up to an hour old) snapshot.
#
# The reason travels on stdout rather than through a global because this
# function is always called from a command substitution, whose subshell would
# discard any variable it set.
live_delivery_age() {
  local out err rc=0
  if [ ! -f "$AUDIT" ]; then
    printf 'ERR audit helper not found at %s' "$AUDIT"
    return 0
  fi
  err="$(mktemp)"
  out="$(GOTIFY_DB="$GOTIFY_DB" "$AUDIT" --age-seconds --title "$EXPECT_TITLE" 2>"$err")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'ERR %s' "$(tr '\n' ' ' < "$err")"
    rm -f "$err"
    return 0
  fi
  rm -f "$err"
  printf '%s' "$out"
}

send_summary_alerts() {
  local subject="$1" body="$2"
  send_webhook_alert "📊 JWT Daily Summary — ${HOST}

${body}"
  # The Gotify title deliberately keeps the bare "JWT Daily Summary" phrase:
  # jwt-secret-delivery-watchdog.sh finds this heartbeat by that exact
  # substring (EXPECT_TITLE), so decorating it would make every push read as
  # a dead monitor.  The escalation lives in the body and the subject.
  send_gotify_alert "JWT Daily Summary — ${HOST}" "$body" "${GOTIFY_PRIORITY:-5}"
  # One email, not two: send_email_report picks a single channel (and reports
  # which one it used, or none) instead of mailing the digest twice.
  EMAIL_CHANNEL="$(send_email_report "${subject}" "${body}")"
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

# Every incident line in log order, with the stack it is attributed to (empty
# for a genuinely host-level event).  Kept in log order rather than by category
# so grouping can also see which run a DONE: summary belongs to.
INCIDENT_LINES=()
INCIDENT_STACKS=()
# Distinct stacks named by REVERT lines since the current revert-watchdog run
# started — the incidents a run's DONE: summary concludes.
RUN_STACKS=()

# The delivery watchdog logs to its own file in the same
# "<ISO timestamp> <EVENT> <details>" shape, so the same window filter
# applies.  DELIVERY_LOG_PRESENT distinguishes "the watchdog never wrote
# anything" from "it wrote once but has since gone quiet".
DELIVERY_OK_LINES=()
DELIVERY_STALL_LINES=()
DELIVERY_ALERT_LINES=()
DELIVERY_LOG_PRESENT=0
PIPELINE="unverified"

# Live reading of the same heartbeat, taken from the Gotify history at send
# time rather than replayed from the watchdog's log.
LIVE_AGE=""
LIVE_VERDICT="unreadable"
LIVE_DETAIL=""
DISAGREEMENT=""

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
      DRIFT*)           DRIFT_LINES+=("$line"); incident_add "$line" ;;
      WARN*)            WARN_LINES+=("$line"); incident_add "$line" ;;
      REVERT\ DETECTED*) REVERT_LINES+=("$line"); revert_add "$line" ;;
      REVERT*)          REVERT_LINES+=("$line"); revert_add "$line" ;;
      DONE:*)           DONE_LINES+=("$line"); done_add "$line" ;;
      REGISTRY*)        REGISTRY_LINES+=("$line"); RUN_STACKS=() ;;
      FATAL*)           FATAL_LINES+=("$line"); incident_add "$line" ;;
      *)                # skip unrecognised lines silently ;;
    esac
  done < "$LOG"
}

parse_delivery_log() {
  if [ ! -f "$DELIVERY_LOG" ]; then
    # No watchdog history at all: the pipeline's health is unverified.
    return 0
  fi
  DELIVERY_LOG_PRESENT=1

  local line ts epoch rest
  while IFS= read -r line || [ -n "$line" ]; do
    ts="${line%% *}"
    [ -n "$ts" ] || continue

    epoch=$(ts_to_epoch "$ts")
    [ "$epoch" -gt 0 ] || continue
    [ "$epoch" -ge "$CUTOFF_EPOCH" ] || continue     # filter to window

    rest="${line#* }"

    case "$rest" in
      OK\ delivery\ heartbeat*) DELIVERY_OK_LINES+=("$line") ;;
      STALL*)                   DELIVERY_STALL_LINES+=("$line") ;;
      ALERT\ delivery\ watchdog*) DELIVERY_ALERT_LINES+=("$line") ;;
      *)                        # skip unrecognised lines silently ;;
    esac
  done < "$DELIVERY_LOG"
}

# classify_pipeline — reduce the watchdog's window to one word.
#   stalled    — the watchdog saw a delivery problem in the window
#   healthy    — it ran and saw none
#   unverified — it produced no line in the window, so health is unknown
classify_pipeline() {
  if [ "${#DELIVERY_STALL_LINES[@]}" -gt 0 ]; then
    PIPELINE="stalled"
  elif [ "${#DELIVERY_OK_LINES[@]}" -gt 0 ]; then
    PIPELINE="healthy"
  else
    PIPELINE="unverified"
  fi
}

# read_live_pipeline — take the live reading and reduce it to one verdict:
#   ok         — the heartbeat is current
#   stale      — it is older than MAX_AGE_HOURS
#   missing    — no heartbeat exists in the history at all
#   unparsable — the history answered with something that is not an age
#   unreadable — the history could not be read
read_live_pipeline() {
  LIVE_AGE="$(live_delivery_age)"
  LIVE_DETAIL=""
  case "$LIVE_AGE" in
    ERR*)
      LIVE_VERDICT="unreadable"
      LIVE_DETAIL="${LIVE_AGE#ERR }"
      [ -n "$LIVE_DETAIL" ] || LIVE_DETAIL="(no error output from the audit helper)"
      ;;
    -1)
      LIVE_VERDICT="missing"
      ;;
    ''|*[!0-9]*)
      LIVE_VERDICT="unparsable"
      ;;
    *)
      if [ "$LIVE_AGE" -gt "$MAX_AGE_SECONDS" ]; then
        LIVE_VERDICT="stale"
      else
        LIVE_VERDICT="ok"
      fi
      ;;
  esac
}

# evaluate_disagreement — compare the live verdict with the log's and state the
# mismatch, or leave DISAGREEMENT empty when they agree.  The watchdog runs
# hourly, so a mismatch is expected in both directions: it can miss a pipeline
# that died since its last check, and it can still be quoting a stall that has
# since been fixed.  An unreadable live reading is not a disagreement — there is
# nothing to compare it against.
evaluate_disagreement() {
  DISAGREEMENT=""
  case "${PIPELINE}:${LIVE_VERDICT}" in
    healthy:stale)
      DISAGREEMENT="the watchdog log reads \"healthy\", but the live history shows the heartbeat $(human_age "$LIVE_AGE") old, past the ${MAX_AGE_HOURS}h threshold — the pipeline went quiet after the watchdog's last check"
      ;;
    healthy:missing)
      DISAGREEMENT="the watchdog log reads \"healthy\", but no delivery matching \"${EXPECT_TITLE}\" exists in the live history"
      ;;
    stalled:ok)
      DISAGREEMENT="the watchdog log reads \"stalled\", but the live history shows the heartbeat $(human_age "$LIVE_AGE") old — delivery is current, so the log's stall is historical"
      ;;
    unverified:ok)
      DISAGREEMENT="the watchdog logged nothing in the window, yet the live history shows the heartbeat $(human_age "$LIVE_AGE") old — the watchdog, not the pipeline, looks down"
      ;;
  esac
}
# --------------------------------------------------------------------------- #
# Log-line helpers for the condensed sections
# --------------------------------------------------------------------------- #

# short_ts <timestamp> — drop seconds and offset: "…T07:15:02+0000" reads as
# "…T07:15", which is all a daily digest needs.
short_ts() { printf '%s' "${1%:*}"; }

# newest_ts <line>... — the newest line's timestamp.  The log is append-only,
# so that is simply the last one.
newest_ts() {
  local last="${!#}"
  printf '%s' "${last%% *}"
}

# stack_of_line <rest-after-timestamp> — the stack a log line belongs to, or
# empty when it names none.  Events read "<EVENT> <stack>: <detail>"; the
# host-level FATAL and DONE lines name no stack at all.
stack_of_line() {
  local rest="$1" head
  rest="${rest#DRIFT }"
  rest="${rest#REVERT DETECTED }"
  rest="${rest#REVERT }"
  rest="${rest#WARN }"
  rest="${rest#FATAL }"
  rest="${rest#DONE: }"
  head="${rest%%:*}"
  case "$head" in
    # A bare word before the colon is a stack; anything else (an event keyword
    # that survived the stripping, a sentence, an empty string) is not.
    ''|OK|DRIFT|REVERT|WARN|FATAL|DONE|REGISTRY|HEARTBEAT) printf '' ;;
    *[!A-Za-z0-9._-]*|*\ *) printf '' ;;
    *) printf '%s' "$head" ;;
  esac
}

# count_outcomes <line>... — one row per distinct outcome, most frequent
# first: "<count>\t<outcome>\t<newest timestamp>".
count_outcomes() {
  local -A counts=() newest=()
  local line rest outcome
  for line in "$@"; do
    rest="${line#* }"      # drop the timestamp
    outcome="${rest#* }"   # drop the event keyword
    counts["$outcome"]=$(( ${counts["$outcome"]:-0} + 1 ))
    newest["$outcome"]="${line%% *}"
  done
  [ "${#counts[@]}" -gt 0 ] || return 0
  local key
  for key in "${!counts[@]}"; do
    printf '%s\t%s\t%s\n' "${counts[$key]}" "$key" "${newest[$key]}"
  done | sort -k1,1nr -k2,2
}

# incident_add <line> — record an incident in log order with the stack it names
# (empty when it names none).
incident_add() {
  INCIDENT_LINES+=("$1")
  INCIDENT_STACKS+=("$(stack_of_line "${1#* }")")
}

# revert_add <line> — a REVERT line records the incident and also joins the
# current run's stack set.
revert_add() {
  local stack
  stack="$(stack_of_line "${1#* }")"
  INCIDENT_LINES+=("$1")
  INCIDENT_STACKS+=("$stack")
  [ -n "$stack" ] || return 0
  case " ${RUN_STACKS[*]-} " in
    *" ${stack} "*) ;;
    *) RUN_STACKS+=("$stack") ;;
  esac
}

# done_add <line> — a DONE: line is the revert watchdog's per-run summary and
# names no stack of its own, so attribute it to the reverts it concludes: the
# stacks this run re-cut.  A run that re-cut several stacks concludes all of
# them, and the summary is shown under each rather than under a vague heading;
# a run whose reverts fell outside the window keeps the host-level fallback,
# since there is then nothing to attribute it to.
done_add() {
  local spec=""
  case "${#RUN_STACKS[@]}" in
    0) spec="" ;;
    1) spec="${RUN_STACKS[0]}" ;;
    *) spec="$(printf '%s|' "${RUN_STACKS[@]}")"; spec="${spec%|}" ;;
  esac
  INCIDENT_LINES+=("$1")
  INCIDENT_STACKS+=("$spec")
}

# group_by_stack — "<stack>\t<line>" per (line, stack) pair, in log order, with
# genuinely stack-less events collected under "(host-level)".  A line
# attributed to several stacks yields one row per stack.
group_by_stack() {
  local i line spec stack
  for i in "${!INCIDENT_LINES[@]}"; do
    line="${INCIDENT_LINES[$i]}"
    spec="${INCIDENT_STACKS[$i]}"
    if [ -z "$spec" ]; then
      printf '(host-level)\t%s\n' "$line"
      continue
    fi
    # The `|| [ -n ... ]` guard matters: a spec with no trailing newline is
    # still a spec, and `read` alone would drop it at EOF.
    while IFS= read -r stack || [ -n "$stack" ]; do
      [ -n "$stack" ] || continue
      printf '%s\t%s\n' "$stack" "$line"
    done < <(printf '%s' "$spec" | tr '|' '\n')
  done
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
  # --- clean runs: counted per outcome, never listed one by one ---
  lines+=("Clean runs (${TOTAL_OK}):")
  if [ "${#OK_LINES[@]}" -eq 0 ]; then
    lines+=("  (none)")
  else
    local n outcome stamped
    while IFS=$'\t' read -r n outcome stamped; do
      [ -n "$outcome" ] || continue
      lines+=("  ${n} x ${outcome}  (last $(short_ts "$stamped"))")
    done < <(count_outcomes "${OK_LINES[@]}")
  fi

  # --- registry rebuilds: routine and near-identical, so just a count ---
  if [ "${#REGISTRY_LINES[@]}" -gt 0 ]; then
    lines+=("")
    local registry_last distinct
    registry_last="$(short_ts "$(newest_ts "${REGISTRY_LINES[@]}")")"
    distinct="$(count_outcomes "${REGISTRY_LINES[@]}" | wc -l | tr -d ' ')"
    lines+=("REGISTRY rebuilds (${#REGISTRY_LINES[@]}), last ${registry_last}")
    # More than one distinct line means the fingerprint set changed, which is
    # the one registry event actually worth reading.
    if [ "$distinct" -gt 1 ]; then
      lines+=("  ! ${distinct} distinct outcomes — the fingerprint set changed")
    fi
  fi

  # --- incidents: grouped under the stack they name ---
  lines+=("")
  if [ "$(( ${#DRIFT_LINES[@]} + ${#REVERT_LINES[@]} + ${#WARN_LINES[@]} + ${#FATAL_LINES[@]} + ${#DONE_LINES[@]} ))" -eq 0 ]; then
    lines+=("Incidents:")
    lines+=("  (none — all stacks were green)")
  else
    lines+=("Incidents by stack:")
    local grouped order stack count text
    grouped="$(group_by_stack)"
    # Most-affected stack first: the count is what makes grouping useful.
    order="$(printf '%s\n' "$grouped" | cut -f1 \
      | sort | uniq -c | sort -k1,1nr -k2,2 | awk '{print $2}')"
    for stack in $order; do
      count="$(printf '%s\n' "$grouped" \
        | awk -F'\t' -v s="$stack" '$1 == s { n++ } END { print n+0 }')"
      lines+=("  ${stack} — ${count} event(s):")
      while IFS= read -r text; do
        lines+=("    ${text}")
      done < <(printf '%s\n' "$grouped" \
        | awk -F'\t' -v s="$stack" '$1 == s { print $2 }' | sort)
    done
  fi

  # --- pipeline health: a live reading, cross-checked against the watchdog ---
  lines+=("")
  lines+=("Pipeline health:")
  local n_ok=0 l
  # The live reading comes first because it is the current truth; the log
  # below it is a snapshot the watchdog may have taken up to an hour ago.
  case "$LIVE_VERDICT" in
    ok)
      lines+=("  Live: \"${EXPECT_TITLE}\" last delivered $(human_age "$LIVE_AGE") ago (threshold ${MAX_AGE_HOURS}h) — OK")
      ;;
    stale)
      lines+=("  Live: \"${EXPECT_TITLE}\" last delivered $(human_age "$LIVE_AGE") ago (threshold ${MAX_AGE_HOURS}h) — STALE")
      ;;
    missing)
      lines+=("  Live: no delivery matching \"${EXPECT_TITLE}\" in the history — MISSING")
      ;;
    unparsable)
      lines+=("  Live: unexpected age reading from the history: '${LIVE_AGE}'")
      ;;
    *)
      lines+=("  Live: unavailable — ${LIVE_DETAIL}")
      ;;
  esac

  case "$PIPELINE" in
    healthy)
      n_ok=${#DELIVERY_OK_LINES[@]}
      lines+=("  Watchdog log: Healthy — ${n_ok} heartbeat check(s) in the window")
      ;;
    stalled)
      lines+=("  Watchdog log: STALLED — ${#DELIVERY_STALL_LINES[@]} stall(s) in the window")
      ;;
    *)
      lines+=("  Watchdog log: UNVERIFIED — the watchdog logged nothing in the window")
      if [ "$DELIVERY_LOG_PRESENT" -eq 1 ]; then
        lines+=("  (the log exists but holds no entry inside the window)")
      fi
      ;;
  esac

  # Two readings of the same pipeline: saying so when they diverge is the whole
  # point of taking both.
  if [ -n "$DISAGREEMENT" ]; then
    lines+=("  ⚠ DISAGREEMENT — ${DISAGREEMENT}")
  fi

  if [ "$PIPELINE" = "healthy" ] && [ "$n_ok" -gt 0 ]; then
    lines+=("  Newest: ${DELIVERY_OK_LINES[$((n_ok - 1))]}")
  fi
  if [ "$PIPELINE" = "stalled" ]; then
    for l in "${DELIVERY_STALL_LINES[@]}"; do
      lines+=("    ${l}")
    done
  fi
  lines+=("  Log: ${DELIVERY_LOG}")

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
parse_delivery_log
classify_pipeline
read_live_pipeline
evaluate_disagreement

BODY=$(build_summary_body)

# The subject reflects overall health: secret incidents and/or pipeline
# problems.  A stalled or unverified pipeline escalates too — a digest that
# reads serene while nothing is known to be delivering would defeat the very
# purpose of sending it.
SUBJECT="JWT Secret Daily Summary — ${HOST} — ${TOTAL_OK} clean run(s)"
reasons=""
if [ "${#DRIFT_LINES[@]}" -gt 0 ] || [ "${#REVERT_LINES[@]}" -gt 0 ] \
   || [ "${#WARN_LINES[@]}" -gt 0 ] || [ "${#FATAL_LINES[@]}" -gt 0 ]; then
  reasons="secret incidents"
fi
# A live reading that is definitively wrong is current, concrete evidence the
# watchdog's last (up to an hour old) check cannot provide, so it outranks the
# log's verdict; when the live reading is fine or unavailable, the log's
# verdict stands, including the unverified one.
case "$LIVE_VERDICT" in
  stale)   reasons="${reasons:+${reasons} + }pipeline stale" ;;
  missing) reasons="${reasons:+${reasons} + }pipeline missing" ;;
  *)
    case "$PIPELINE" in
      stalled)    reasons="${reasons:+${reasons} + }pipeline stalled" ;;
      unverified) reasons="${reasons:+${reasons} + }pipeline unverified" ;;
    esac
    ;;
esac
# A disagreement is its own escalation, not a footnote to whichever verdict won:
# it means one of the two readings is wrong, so the subject must not present
# either verdict as the whole truth.  Without this, a log reading "stalled"
# beside a live history showing delivery is current would go out as a plain
# pipeline alarm, and a dead watchdog (live fine, log silent) would read as a
# dead pipeline — in both cases blaming the wrong component in the one line the
# recipient actually reads.
if [ -n "$DISAGREEMENT" ]; then
  reasons="${reasons:+${reasons} + }pipeline disagreement"
fi
if [ -n "$reasons" ]; then
  SUBJECT="⚠️ JWT Secret Daily Summary — ${HOST} — ${reasons}"
fi

send_summary_alerts "$SUBJECT" "$BODY"

DISAGREE_FLAG=0
if [ -n "$DISAGREEMENT" ]; then
  DISAGREE_FLAG=1
fi

echo "$(date '+%Y-%m-%dT%H:%M:%S%z') Daily summary sent: OK=${TOTAL_OK} DRIFT=${#DRIFT_LINES[@]} REVERT=${#REVERT_LINES[@]} WARN=${#WARN_LINES[@]} PIPELINE=${PIPELINE} PIPELINE_LIVE=${LIVE_VERDICT} DISAGREE=${DISAGREE_FLAG} DELIVERY_STALLS=${#DELIVERY_STALL_LINES[@]} EMAIL=${EMAIL_CHANNEL:-none}" >> "$LOG"

exit 0
