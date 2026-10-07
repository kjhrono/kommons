#!/usr/bin/env bash
# ============================================================================
# Install the COMPLETE JWT-secret watch on the VM: the monitor program and
# every helper and schedule it needs to actually run and alert.
#
#   bash tool/install_jwt_secret_watch.sh            # plan (default)
#   bash tool/install_jwt_secret_watch.sh --apply    # install + rewire cron
#   bash tool/install_jwt_secret_watch.sh --check    # assert the whole watch
#
# This is the ONE entry point that turns a fresh checkout into a working watch.
# The monitor is a single program, but it sources helpers that live beside it in
# ~/bin — alert.sh (the fan-out), canonical_secret.sh (the canonical definition)
# and gotify-messages.sh (the delivery-history reader) — and it is only useful
# with the schedule that runs it.  An installer that deployed the program alone
# produced a monitor that could not source its helpers, and no repo file wrote
# the daily-summary cron entry at all.  All of that is this installer's job now.
#
# What --apply does, in order:
#   1. delegates alert.sh + the credential env file (~/etc/alerts.env, mode
#      0600) to install_alert_env.sh, so that logic keeps ONE owner;
#   2. retires the four separate JWT-secret watchdogs this replaced, if any are
#      still present, into ~/bin/retired-jwt-watchdogs-<ts>/ with a rollback
#      bundle (they have usually been retired already — a second run is a no-op);
#   3. installs jwt-secret-monitor.sh, canonical_secret.sh, gotify-messages.sh
#      and jwt-secret-daily-summary.sh into ~/bin (previous copies differing from
#      the repo ones are kept as timestamped .bak backups);
#   4. rewrites the crontab to hold ONE managed block of three entries:
#        */15 * * * *  monitor        drift + exact-revert watch (heartbeat)
#        0,30 * * * *  meta           liveness + alert-delivery checks
#        0 9 * * *     daily-summary  the digest / delivery heartbeat
#   5. runs the monitor once (plants the heartbeat meta watches) and smoke-tests
#      both modes read-only.
#
# Nothing else in the crontab is touched: the alert-configuration pointer, the
# tuning vars (RETENTION_DAYS, REPORT_HOURS, MAX_AGE_MINUTES) and the other
# managed blocks stay exactly as they are.  The three entries live in one block
# but stay on separate *lines* so a deleted entry is still reported by its peers.
#
# Env overrides: KAT_SSH_KEY, KAT_VM_HOST, KAT_VM_USER, ALERT_ENV_FILE (forwarded
# to install_alert_env.sh), JWT_WATCH_SUMMARY_SCHEDULE (default "0 9 * * *").
# ============================================================================
set -uo pipefail

KEY="${KAT_SSH_KEY:-$HOME/.ssh/katalogus}"
[ -f "$KEY" ] || KEY="${KAT_SSH_KEY:-/home/marcuz/Apps/Projects/keys/ssh-private-key.key}"
VM="${KAT_VM_USER:-ubuntu}@${KAT_VM_HOST:-80.225.89.206}"
SUMMARY_SCHEDULE="${JWT_WATCH_SUMMARY_SCHEDULE:-0 9 * * *}"

HERE="$(cd "$(dirname "$0")" && pwd)"
ALERT_INSTALLER="$HERE/install_alert_env.sh"
MONITOR_SRC="$HERE/jwt-secret-monitor.sh"
LIB_SRC="$HERE/canonical_secret.sh"
GOTIFY_SRC="$HERE/gotify-messages.sh"
SUMMARY_SRC="$HERE/jwt-secret-daily-summary.sh"

MODE=plan
for a in "$@"; do
  case "$a" in
    --apply) MODE=apply ;;
    --check) MODE=check ;;
    -h|--help) sed -n '2,/^set -uo pipefail$/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "install_jwt_secret_watch: unknown argument: $a" >&2; exit 2 ;;
  esac
done

for f in "$ALERT_INSTALLER" "$MONITOR_SRC" "$LIB_SRC" "$GOTIFY_SRC" "$SUMMARY_SRC"; do
  [ -f "$f" ] || { echo "missing repo file: $f" >&2; exit 2; }
done
for f in "$MONITOR_SRC" "$LIB_SRC" "$GOTIFY_SRC" "$SUMMARY_SRC"; do
  bash -n "$f" || { echo "$(basename "$f") does not parse — refusing to install" >&2; exit 2; }
done

SSH_OPTS=(-i "$KEY" -o BatchMode=yes -o ConnectTimeout=20
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

TMP_MONITOR=/tmp/kat-install-jwt-secret-monitor.sh
TMP_LIB=/tmp/kat-install-canonical-secret.sh
TMP_GOTIFY=/tmp/kat-install-gotify-messages.sh
TMP_SUMMARY=/tmp/kat-install-jwt-secret-daily-summary.sh

REMOTE_FILE="$(mktemp)"
trap 'rm -f "$REMOTE_FILE"' EXIT
cat >"$REMOTE_FILE" <<'REMOTE'
set -uo pipefail
MODE="${MODE:-plan}"
BIN="$HOME/bin"
ENV_FILE="${ALERT_ENV_FILE:-$HOME/etc/alerts.env}"

OLD_RE='jwt-secret-(drift-check|revert-watchdog|delivery-watchdog|liveness-check)\.sh'
NEW_RE='jwt-secret-monitor\.sh'
SUMMARY_RE='jwt-secret-daily-summary\.sh'
BEGIN='# >>> jwt-secret watch'
END='# <<< jwt-secret watch'

WATCH_FILES="jwt-secret-monitor.sh canonical_secret.sh gotify-messages.sh jwt-secret-daily-summary.sh"

CRON_NOW="$(crontab -l 2>/dev/null || true)"
CRON_IN="${TMPDIR:-/tmp}/kat-jwt-watch-cron-in.$$"
CRON_OUT="${TMPDIR:-/tmp}/kat-jwt-watch-cron-out.$$"
printf '%s\n' "$CRON_NOW" > "$CRON_IN"

n_old="$(printf '%s\n' "$CRON_NOW" | grep -cE "$OLD_RE")"
n_mon="$(printf '%s\n' "$CRON_NOW" | grep -cE "$NEW_RE")"
n_sum="$(printf '%s\n' "$CRON_NOW" | grep -cE "$SUMMARY_RE")"
n_blocks="$(printf '%s\n' "$CRON_NOW" | grep -cE "^$BEGIN")"

OLD_FILES=()
for s in jwt-secret-drift-check jwt-secret-revert-watchdog \
         jwt-secret-delivery-watchdog jwt-secret-liveness-check; do
  [ -f "$BIN/$s.sh" ] && OLD_FILES+=("$BIN/$s.sh")
done

if [ "$MODE" != apply ]; then
  echo "   files:   $(for f in $WATCH_FILES; do [ -f "$BIN/$f" ] && printf '%s=present ' "$f" || printf '%s=MISSING ' "$f"; done)"
  echo "   alert.sh: $([ -f "$BIN/alert.sh" ] && echo present || echo MISSING)   env file: $ENV_FILE $([ -f "$ENV_FILE" ] && echo present || echo MISSING)"
  echo "   cron:    $n_mon monitor, $n_sum daily-summary, $n_old retired entry/entries, $n_blocks managed block(s)"
  [ "${#OLD_FILES[@]}" -gt 0 ] && echo "   retire:  ${#OLD_FILES[@]} old watchdog script(s) still in $BIN"
fi

# --- build the new crontab ------------------------------------------------- #
#
# A retired entry is removed TOGETHER WITH the comment run that explains it,
# and only comment runs that actually describe one of the retired entries are
# removed — dropping a single line because it matched a phrase leaves the
# sentence that continued it dangling.  The alert-configuration prose shares a
# comment run with the retired entries' header and is still true, so it is kept.
# The retired entries are matched by script name, so a second run is a no-op.
build_crontab() { # <in> <out>
  python3 - "$1" "$2" <<'PY'
import os, re, sys
src, dst = sys.argv[1], sys.argv[2]
SCHEDULE = os.environ.get("SUMMARY_SCHEDULE", "0 9 * * *")

RETIRED = re.compile(r'jwt-secret-(drift-check|revert-watchdog|delivery-watchdog|liveness-check)\.sh')
MANAGED = re.compile(r'jwt-secret-monitor\.sh')
SUMMARY = re.compile(r'jwt-secret-daily-summary\.sh')
STALE_PROSE = re.compile(r'Dead-man switch|Liveness check for the 15-minute monitors')
# Headers that named the setup this block replaces.  The managed block carries
# its own description now, so both the original header and the interim one are
# dropped rather than rewritten.
STALE_HEADERS = (
    '# JWT secret drift watchdog — runs every 15 min',
    '# JWT secret watch — one program on two entries (see the managed block below)',
)
BEGIN, END = '# >>> jwt-secret watch', '# <<< jwt-secret watch'

src_lines = open(src).read().splitlines()
keep = [True] * len(src_lines)
dropped = 0

# 1. the managed block itself (so a re-run replaces, never duplicates)
in_block = False
for i, ln in enumerate(src_lines):
    if ln.startswith(BEGIN):
        in_block = True
    if in_block:
        keep[i] = False
    if ln.startswith(END):
        in_block = False

# 2. the retired entries, the monitor entries, and any daily-summary entry
#    scheduled outside the block (it is re-written inside it below, so this is
#    also what makes a second run idempotent)
for i, ln in enumerate(src_lines):
    if RETIRED.search(ln) or MANAGED.search(ln) or SUMMARY.search(ln):
        keep[i] = False

# 3. a comment run (consecutive comment lines) that describes a retired entry
#    goes with it — but only if it really describes one.
i = 0
while i < len(src_lines):
    if not src_lines[i].lstrip().startswith('#'):
        i += 1
        continue
    j = i
    while j < len(src_lines) and src_lines[j].lstrip().startswith('#'):
        j += 1
    run = src_lines[i:j]
    if any(STALE_PROSE.search(ln) for ln in run):
        for k in range(i, j):
            if keep[k]:
                keep[k] = False
    i = j

# 4. the legacy header lines, wherever they sit in a comment run
for i, ln in enumerate(src_lines):
    if ln in STALE_HEADERS and keep[i]:
        keep[i] = False

out = []
for i, ln in enumerate(src_lines):
    if not keep[i]:
        dropped += 1
        continue
    out.append(ln)

# Collapse the gaps a removed run leaves behind, and drop trailing blanks.
collapsed = []
for ln in out:
    if ln.strip() == '' and collapsed and collapsed[-1].strip() == '':
        continue
    collapsed.append(ln)
while collapsed and collapsed[-1].strip() == '':
    collapsed.pop()

block = [
    '',
    BEGIN + ' (managed by tool/install_jwt_secret_watch.sh) >>>',
    '# The secret watch.  One program on two entries, plus the routine report:',
    '#   monitor       — drift + exact-revert check every 15 min; its heartbeat',
    '#                   is what the meta entry watches.',
    '#   meta          — liveness and alert-delivery checks every 30 min.',
    '#   daily-summary — the digest at 09:00; its delivery is the pipeline',
    '#                   heartbeat the meta entry and the dead-man switch read.',
    '# They stay on SEPARATE lines so a deleted entry is still reported by the',
    '# others.',
    '*/15 * * * * ~/bin/jwt-secret-monitor.sh monitor >/dev/null 2>&1',
    '0,30 * * * * ~/bin/jwt-secret-monitor.sh meta >/dev/null 2>&1',
    '%s ~/bin/jwt-secret-daily-summary.sh >/dev/null 2>&1' % SCHEDULE,
    END,
    '',
]

open(dst, 'w').write('\n'.join(collapsed + block) + '\n')
print('   crontab: %d line(s) retired, 3 entries written to the managed block' % dropped)
PY
}

# --- check mode ------------------------------------------------------------ #
if [ "$MODE" = check ]; then
  rc=0
  for f in jwt-secret-monitor.sh gotify-messages.sh jwt-secret-daily-summary.sh; do
    if [ -x "$BIN/$f" ]; then echo "   ✓ $BIN/$f installed and executable"; else echo "   ✗ $BIN/$f missing/not executable"; rc=1; fi
  done
  if [ -f "$BIN/canonical_secret.sh" ]; then echo "   ✓ $BIN/canonical_secret.sh installed"; else echo "   ✗ $BIN/canonical_secret.sh missing — the monitor cannot read the canonical secret"; rc=1; fi
  if [ -f "$BIN/alert.sh" ] && grep -q 'etc/alerts.env' "$BIN/alert.sh"; then echo "   ✓ $BIN/alert.sh present and sources the credential file"; else echo "   ✗ $BIN/alert.sh missing or does not source $ENV_FILE — the watch cannot alert"; rc=1; fi
  if [ -f "$ENV_FILE" ]; then echo "   ✓ $ENV_FILE present (mode $(stat -c '%a' "$ENV_FILE" 2>/dev/null))"; else echo "   ✗ $ENV_FILE missing — run tool/install_alert_env.sh --apply"; rc=1; fi
  if [ "$n_old" = 0 ]; then echo "   ✓ no retired cron entries left"; else echo "   ✗ $n_old retired cron entry/entries still scheduled"; rc=1; fi
  if [ "$n_mon" = 2 ]; then echo "   ✓ two jwt-secret-monitor.sh cron entries"; else echo "   ✗ expected 2 monitor entries, found $n_mon"; rc=1; fi
  if [ "$n_sum" = 1 ]; then echo "   ✓ one jwt-secret-daily-summary.sh cron entry"; else echo "   ✗ expected 1 daily-summary entry, found $n_sum"; rc=1; fi
  if [ "$n_blocks" = 1 ]; then echo "   ✓ exactly one jwt-secret watch managed block"; else echo "   ✗ expected 1 managed block, found $n_blocks"; rc=1; fi
  [ "$rc" = 0 ] && echo "VERDICT|installed" || echo "VERDICT|not-installed"
  exit 0
fi

# --- plan ------------------------------------------------------------------ #
if [ "$MODE" = plan ]; then
  build_crontab "$CRON_IN" "$CRON_OUT" || true
  echo "   plan: install jwt-secret-monitor.sh  → $BIN/jwt-secret-monitor.sh"
  echo "   plan: install canonical_secret.sh    → $BIN/canonical_secret.sh"
  echo "   plan: install gotify-messages.sh     → $BIN/gotify-messages.sh"
  echo "   plan: install jwt-secret-daily-summary.sh → $BIN/jwt-secret-daily-summary.sh"
  echo "   plan: delegate alert.sh + $ENV_FILE to install_alert_env.sh"
  echo "   plan: retire ${#OLD_FILES[@]} old script(s) into $BIN/retired-jwt-watchdogs-<ts>/"
  echo "   plan: resulting crontab:"
  sed 's/^/     | /' "$CRON_OUT"
  echo "VERDICT|plan (nothing was changed — re-run with --apply)"
  exit 0
fi

# --- apply ----------------------------------------------------------------- #
TS="$(date +%Y%m%dT%H%M%S)"
RETIRE="$BIN/retired-jwt-watchdogs-$TS"

if [ "${#OLD_FILES[@]}" -gt 0 ]; then
  mkdir -p "$RETIRE"
  for f in "${OLD_FILES[@]}"; do
    mv "$f" "$RETIRE/" || { echo "VERDICT|failed (could not retire $f)"; exit 1; }
  done
  # A rollback has to be self-contained: the scripts alone are useless without
  # the schedule that ran them.
  cp "$CRON_IN" "$RETIRE/crontab.before"
  cat >"$RETIRE/ROLLBACK.txt" <<'ROLLBACK'
Rollback of the JWT-secret watchdog consolidation
=================================================

crontab.before is the crontab exactly as it was before this change.

  1. put the four old scripts back:
       mv ~/bin/retired-jwt-watchdogs-*/jwt-secret-*.sh ~/bin/
  2. restore the old schedule:
       crontab ~/bin/retired-jwt-watchdogs-*/crontab.before
  3. the replacement is inert once its cron entries are gone; to remove it too:
       rm ~/bin/jwt-secret-monitor.sh ~/bin/canonical_secret.sh

Note: canonical_secret.sh on the VM serves the monitor only.
      tool/dev/repair_jwt_secret_drift.sh streams its own copy from the repo.
ROLLBACK
  echo "   retired ${#OLD_FILES[@]} script(s) → $RETIRE (with crontab.before + ROLLBACK.txt)"
else
  echo "   retire: nothing to do (never installed, or already migrated)"
fi

install_one() { # <staged-tmp> <dest-name> <mode>
  local tmp="$1" name="$2" mode="$3" dest="$BIN/$2"
  [ -f "$tmp" ] || { echo "VERDICT|failed ($name not staged at $tmp)"; exit 1; }
  if [ -f "$dest" ] && ! cmp -s "$tmp" "$dest"; then
    cp -a "$dest" "$dest.bak.$TS" || true
  fi
  install -m "$mode" "$tmp" "$dest" || { echo "VERDICT|failed (install $name)"; exit 1; }
  bash -n "$dest" || { echo "VERDICT|failed ($name does not parse)"; exit 1; }
}

install_one "$TMP_MONITOR" jwt-secret-monitor.sh        0755
install_one "$TMP_LIB"     canonical_secret.sh          0644
install_one "$TMP_GOTIFY"  gotify-messages.sh           0755
install_one "$TMP_SUMMARY" jwt-secret-daily-summary.sh  0755
echo "   installed jwt-secret-monitor.sh, canonical_secret.sh, gotify-messages.sh, jwt-secret-daily-summary.sh"

build_crontab "$CRON_IN" "$CRON_OUT" || { echo "VERDICT|failed (crontab rewrite)"; exit 1; }

if crontab "$CRON_OUT"; then
  echo "   crontab rewritten"
else
  echo "VERDICT|failed (crontab install — old crontab untouched)"
  exit 1
fi

CRON_AFTER="$(crontab -l 2>/dev/null || true)"
n_mon="$(printf '%s\n' "$CRON_AFTER" | grep -cE "$NEW_RE")"
n_sum="$(printf '%s\n' "$CRON_AFTER" | grep -cE "$SUMMARY_RE")"
n_old="$(printf '%s\n' "$CRON_AFTER" | grep -cE "$OLD_RE")"
n_blocks="$(printf '%s\n' "$CRON_AFTER" | grep -cE "^$BEGIN")"
echo "   verify: $n_mon monitor / $n_sum daily-summary / $n_old retired entr(ies), $n_blocks block(s)"

if [ "$n_mon" != 2 ] || [ "$n_sum" != 1 ] || [ "$n_old" != 0 ] || [ "$n_blocks" != 1 ]; then
  echo "VERDICT|failed (crontab verification: want 2 monitor + 1 summary, 0 retired, 1 block)"
  echo "   rollback: mv $RETIRE/*.sh $BIN/ and re-add the entries by hand"
  exit 1
fi

echo
# The first REAL monitor run plants the heartbeat meta watches.  Without it the
# first meta run after an install would find no heartbeat and report a monitor
# that has simply never run — a false alarm on the operator's own channels.  It
# also surfaces real drift immediately instead of at the next quarter hour.
echo "   first monitor run (plants the heartbeat meta matches on):"
"$BIN/jwt-secret-monitor.sh" monitor 2>&1 | sed 's/^/     | /'
echo "     exit ${PIPESTATUS[0]}"

echo
echo "   smoke test (read-only):"
"$BIN/jwt-secret-monitor.sh" monitor --check 2>&1 | sed 's/^/     | /'
"$BIN/jwt-secret-monitor.sh" meta --check 2>&1 | sed 's/^/     | /'

echo "VERDICT|installed"
REMOTE

echo "== $VM =="
if [ "$MODE" = apply ]; then
  # alert.sh and the credential file have ONE owner (install_alert_env.sh), so
  # a fresh checkout gets both by running this one installer.
  bash "$ALERT_INSTALLER" --apply || { echo "delegated install_alert_env.sh failed" >&2; exit 1; }
  echo
  scp -q "${SSH_OPTS[@]}" "$MONITOR_SRC" "$VM:$TMP_MONITOR" && \
  scp -q "${SSH_OPTS[@]}" "$LIB_SRC"     "$VM:$TMP_LIB" && \
  scp -q "${SSH_OPTS[@]}" "$GOTIFY_SRC"  "$VM:$TMP_GOTIFY" && \
  scp -q "${SSH_OPTS[@]}" "$SUMMARY_SRC" "$VM:$TMP_SUMMARY" \
    || { echo "scp failed" >&2; exit 1; }
fi

OUT="$(ssh "${SSH_OPTS[@]}" "$VM" \
  "MODE='$MODE' SUMMARY_SCHEDULE='$SUMMARY_SCHEDULE' ALERT_ENV_FILE='${ALERT_ENV_FILE:-}' TMP_MONITOR='$TMP_MONITOR' TMP_LIB='$TMP_LIB' TMP_GOTIFY='$TMP_GOTIFY' TMP_SUMMARY='$TMP_SUMMARY' bash -s" <"$REMOTE_FILE" 2>&1)"
RC=$?
echo "$OUT"
VERDICT="$(grep -oE 'VERDICT\|.*' <<<"$OUT" | head -1)"
echo
echo "$VERDICT"
case "$VERDICT" in
  *failed*) exit 1 ;;
esac
exit "$RC"
