#!/usr/bin/env bash
# cleanup-env-backups.sh — weekly retention sweep for the JWT-secret toolkit.
#
# The drift/revert monitors snapshot .env files as `.env.bak.*` (manual
# edits plus the `.env.bak.recut-auto.<epoch>` files written by
# jwt-secret-revert-watchdog.sh).  Left alone they accumulate forever;
# this sweeps every `.env.bak.*` under BACKUP_ROOT that has not been
# modified in RETENTION_DAYS days.
#
# Safety floor: the KEEP_PER_DIR newest snapshots in each directory are
# always kept, even when older than the window, so every stack retains a
# rollback point.  Set KEEP_PER_DIR=0 for a strict age-only sweep.
#
# Revert-watchdog interaction: jwt-secret-revert-watchdog.sh rebuilds its
# pre-cutover fingerprint registry by scanning the surviving `.env.bak.*`
# files, so pruning shrinks the set of "exact revert" secrets it can
# recognize.  Retained snapshots keep working; pruned ones degrade to
# plain drift detection.  Choosing RETENTION_DAYS >= the age of your
# pre-cutover backups preserves full revert coverage.
#
# Notification: when snapshots are actually pruned, the sweep pushes a
# Gotify summary (through the shared helpers in tool/alert.sh) naming the
# count, the space freed and the removed paths.  It stays completely silent
# when nothing is pruned, and never alerts on --dry-run.
#
# Configuration (set in crontab environment or export):
#   RETENTION_DAYS  delete snapshots older than this many days (default: 30)
#   BACKUP_ROOT     tree to scan                        (default: $HOME/Projects)
#   KEEP_PER_DIR    newest snapshots kept per directory (default: 1; 0 = none)
#   LOG             audit log (default: $HOME/logs/env-backup-cleanup.log)
#   DRY_RUN         non-empty → report only, delete nothing
#   HOST            host name used in alert titles (default: hostname)
#
# Alert configuration (from alert.sh; unset → silent no-op):
#   GOTIFY_URL       Gotify server base URL (e.g. https://notify.mediasart.com)
#   GOTIFY_APP_TOKEN Gotify application token for the alert app
#   GOTIFY_PRIORITY  Gotify priority for the cleanup summary (default: 5)
#
# Usage:
#   cleanup-env-backups.sh            # prune per configuration
#   cleanup-env-backups.sh --dry-run  # preview without deleting
set -euo pipefail

# Source shared helpers (timestamp) from tool/alert.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=alert.sh
. "${SCRIPT_DIR}/alert.sh"

RETENTION_DAYS="${RETENTION_DAYS:-30}"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/Projects}"
KEEP_PER_DIR="${KEEP_PER_DIR:-1}"
LOG="${LOG:-$HOME/logs/env-backup-cleanup.log}"
DRY_RUN="${DRY_RUN:-}"
HOST="${HOST:-$(hostname)}"

# human_size <bytes> — compact size for the notification body.
human_size() {
  local b="${1:-0}"
  if [ "$b" -ge 1048576 ]; then
    printf '%d.%d MB' $((b / 1048576)) $(((b % 1048576) * 10 / 1048576))
  elif [ "$b" -ge 1024 ]; then
    printf '%d.%d KB' $((b / 1024)) $(((b % 1024) * 10 / 1024))
  else
    printf '%d B' "$b"
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$(dirname "$LOG")"

if [ ! -d "$BACKUP_ROOT" ]; then
  echo "$(timestamp) FATAL backup root not found: $BACKUP_ROOT" >> "$LOG"
  exit 1
fi

# --------------------------------------------------------------------------- #
# Inventory
# --------------------------------------------------------------------------- #

inventory="$(mktemp)"
protected="$(mktemp)"
candidates="$(mktemp)"
trap 'rm -f "$inventory" "$protected" "$candidates"' EXIT

# Every snapshot, newest first: "<mtime-epoch>\t<dir>\t<path>"
find "$BACKUP_ROOT" -type f -name '.env.bak.*' -printf '%T@\t%h\t%p\n' 2>/dev/null \
  | sort -t$'\t' -k1,1nr > "$inventory" || true

scanned="$(wc -l < "$inventory" | tr -d ' ')"

# The newest KEEP_PER_DIR per directory form the protected floor.
if [ "${KEEP_PER_DIR:-0}" -gt 0 ] 2>/dev/null; then
  awk -F'\t' -v keep="$KEEP_PER_DIR" \
    '{ seen[$2]++; if (seen[$2] <= keep) print $3 }' "$inventory" > "$protected"
fi
protected_count="$(wc -l < "$protected" | tr -d ' ')"

# Age-based candidates (NUL-separated so odd names survive).
find "$BACKUP_ROOT" -type f -name '.env.bak.*' -mtime +"$RETENTION_DAYS" -print0 2>/dev/null \
  > "$candidates" || true

# --------------------------------------------------------------------------- #
# Sweep
# --------------------------------------------------------------------------- #

matched=0
deleted=0
freed=0
deleted_paths=()

while IFS= read -r -d '' f; do
  [ -n "$f" ] || continue
  if [ "$protected_count" -gt 0 ] && grep -Fxq -- "$f" "$protected"; then
    echo "$(timestamp) KEEP newest-in-dir: $f" >> "$LOG"
    continue
  fi
  matched=$((matched + 1))
  size="$(stat -c %s "$f" 2>/dev/null || echo 0)"
  if [ -n "$DRY_RUN" ]; then
    echo "$(timestamp) WOULD-DELETE $f (${size}B)" >> "$LOG"
  elif rm -f -- "$f"; then
    echo "$(timestamp) DELETED $f (${size}B)" >> "$LOG"
    deleted=$((deleted + 1))
    freed=$((freed + size))
    deleted_paths+=("$f")
  else
    echo "$(timestamp) WARN could not delete $f" >> "$LOG"
  fi
done < "$candidates"

# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #

if [ -n "$DRY_RUN" ]; then
  line="$(timestamp) DRY-RUN cleanup: scanned=${scanned} would-delete=${matched} keep-floor=${protected_count} retention=${RETENTION_DAYS}d"
  echo "$line" >> "$LOG"
  echo "$line"
  exit 0
fi

line="$(timestamp) OK cleanup complete: scanned=${scanned} deleted=${deleted} freed=${freed}B keep-floor=${protected_count} retention=${RETENTION_DAYS}d"
echo "$line" >> "$LOG"
echo "$line"

# --------------------------------------------------------------------------- #
# Notify — only when snapshots were actually pruned
# --------------------------------------------------------------------------- #

# Silence is the signal that nothing needed pruning, so the summary is sent
# exclusively on a non-dry run that deleted at least one snapshot.  Sending
# it is itself a no-op unless GOTIFY_URL and GOTIFY_APP_TOKEN are set.
if [ "$deleted" -gt 0 ]; then
  body="Deleted ${deleted} .env.bak.* snapshot(s), freeing $(human_size "$freed").
Scanned ${scanned}, kept ${protected_count} as the newest-in-dir rollback floor, retention ${RETENTION_DAYS}d.

Removed:"
  shown=0
  for f in "${deleted_paths[@]}"; do
    if [ "$shown" -ge 10 ]; then
      body="${body}
  … and $(( ${#deleted_paths[@]} - 10 )) more"
      break
    fi
    body="${body}
  ${f}"
    shown=$((shown + 1))
  done
  send_gotify_alert ".env.bak Cleanup — ${HOST}" "$body" "${GOTIFY_PRIORITY:-5}"
  echo "$(timestamp) ALERT cleanup summary sent: deleted=${deleted} freed=${freed}B" >> "$LOG"
fi

exit 0
