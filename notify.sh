#!/usr/bin/env bash
# notify.sh — one copy-paste helper for sending push alerts to a Gotify server.
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "${SCRIPT_DIR}/notify.sh"
#
#   send_gotify_alert "Backup finished — myhost" "3 snapshots pruned, 1.2 GiB freed"        # routine (priority 5)
#   send_gotify_alert "Drift detected — myhost" "$details" 8                                # high-priority alert (priority 8)
#
# Push is a silent no-op when GOTIFY_URL or GOTIFY_APP_TOKEN is empty, so the
# same monitor / cron runs on a laptop with no Gotify configured and on the
# server with it configured, with no branching.
#
# Two copies of the same alert are not redundancy — they are noise.  The send
# helper handles the Gotify channel only.  If you want redundancy, add a second
# off-host channel (an email / webhook / Telegram leg) alongside it, and fan a
# critical alert out to every channel while picking exactly one channel for
# routine reports — because the channel that is broken is often the one
# reporting on itself.  The No-op contract and the title / priority conventions
# below are what make that layering drop in cleanly.

# --- shared utilities ---

json_escape() {
  printf '%s' "$1" \
    | sed 's/\\/\\\\/g' \
    | sed 's/"/\\"/g' \
    | sed ':a;N;$!ba;s/\n/\\n/g'
}

# send_gotify_alert <title> <message> [priority]
#   POSTs a message to Gotify's /message endpoint using the app token.
#   Uses GOTIFY_PRIORITY (default 5) when priority is omitted.
#   No-op (silent, succeeds) when GOTIFY_URL or GOTIFY_APP_TOKEN is empty.
#
#   title     — the bold line on the notification (keep it short).
#   message   — the body (Markdown renders in the web UI).
#   priority  — 0..10; 5 is a good routine level, 8-10 is "attention now".
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

# --- titles / priorities used by kommons (copy as conventions, not requirements) ---

# Title convention: "<what> — <host>".  The em dash separates the two readable
# halves; the host half is what tells two identical monitors on two machines
# apart in the same notification list.
#
#   "JWT Secret Drift Detected — default-vnic"
#   "Backup finished — myhost"
#
# Priority convention:
#   routine report  -> GOTIFY_PRIORITY (default 5)
#   alert: something is broken now -> 8
#   (0 = silent, still stored; 1-3 low; 4-7 normal; 8-10 noisy/vibrating)

# GOTIFY_URL         — server base URL without trailing slash (unset -> no-op)
# GOTIFY_APP_TOKEN   — application token, send-only secret (unset -> no-op)
# GOTIFY_PRIORITY    — default priority when callers omit it (default 5)
#
# Keep GOTIFY_APP_TOKEN out of the repo: put it in the crontab environment or
# an env file, exactly like any other secret.  The token is per-application,
# so a project usually has one for "reports" and one for "alerts".
