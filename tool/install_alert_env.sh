#!/usr/bin/env bash
# ============================================================================
# Move the alert credentials out of the VM crontab into ~/etc/alerts.env.
#
# `crontab -l` prints every line, so a Brevo API key or a Gotify app token
# parked in the crontab is readable by anyone who can list the schedule — and
# the crontab is edited in place by prose and schedules alike, so a secret can
# be copied out by accident.  This relocates the alert configuration into a
# mode-0600 env file that alert.sh sources, and strips it from the crontab.
#
#   bash tool/install_alert_env.sh            # plan (default)
#   bash tool/install_alert_env.sh --apply    # migrate + strip the crontab
#   bash tool/install_alert_env.sh --check    # assert it is migrated
#
# What --apply does, in order:
#   1. installs the updated alert.sh (which sources ~/etc/alerts.env) into
#      ~/bin, keeping a timestamped backup of the previous one;
#   2. writes the ALERT_*/BREVO_*/GOTIFY_* values found in the crontab to
#      ~/etc/alerts.env (dir 0700, file 0600) — but ONLY if that file does not
#      already exist, so a re-run never overwrites a rotated token with the
#      stale crontab value;
#   3. removes those assignment lines from the crontab and rewrites the block
#      of comments that described them into a pointer at the new file;
#   4. verifies the crontab holds no such assignment, and that a clean shell
#      sourcing alert.sh sees the values from the file alone.
#
# Nothing else in the crontab is touched: the schedules, the tuning vars
# (RETENTION_DAYS, REPORT_HOURS, MAX_AGE_MINUTES) and every managed block stay.
#
# Env overrides: KAT_SSH_KEY, KAT_VM_HOST, KAT_VM_USER, ALERT_ENV_FILE (the
# path on the VM; default ~/etc/alerts.env).
# ============================================================================
set -uo pipefail

KEY="${KAT_SSH_KEY:-$HOME/.ssh/katalogus}"
[ -f "$KEY" ] || KEY="${KAT_SSH_KEY:-/home/marcuz/Apps/Projects/keys/ssh-private-key.key}"
VM="${KAT_VM_USER:-ubuntu}@${KAT_VM_HOST:-80.225.89.206}"

HERE="$(cd "$(dirname "$0")" && pwd)"
ALERT_SH="$HERE/alert.sh"

MODE=plan
for a in "$@"; do
  case "$a" in
    --apply) MODE=apply ;;
    --check) MODE=check ;;
    -h|--help) sed -n '2,/^set -uo pipefail$/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "install_alert_env: unknown argument: $a" >&2; exit 2 ;;
  esac
done

[ -f "$ALERT_SH" ] || { echo "missing repo file: $ALERT_SH" >&2; exit 2; }
bash -n "$ALERT_SH" || { echo "alert.sh does not parse — refusing" >&2; exit 2; }

SSH_OPTS=(-i "$KEY" -o BatchMode=yes -o ConnectTimeout=20
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
TMP_ALERT=/tmp/kat-install-alert-sh.sh

REMOTE_FILE="$(mktemp)"
trap 'rm -f "$REMOTE_FILE"' EXIT
cat >"$REMOTE_FILE" <<'REMOTE'
set -uo pipefail
MODE="${MODE:-plan}"
ENV_FILE="${ALERT_ENV_FILE:-$HOME/etc/alerts.env}"
ENV_DIR="$(dirname "$ENV_FILE")"
RUN_ALERT="$HOME/bin/alert.sh"
CONFIG_RE='^(ALERT_|BREVO_|GOTIFY_)[A-Z0-9_]*='

CRON_NOW="$(crontab -l 2>/dev/null || true)"
CRON_IN="${TMPDIR:-/tmp}/kat-alert-env-in.$$"
CRON_OUT="${TMPDIR:-/tmp}/kat-alert-env-out.$$"
printf '%s\n' "$CRON_NOW" > "$CRON_IN"

n_config="$(printf '%s\n' "$CRON_NOW" | grep -cE "$CONFIG_RE")"
have_file=0; [ -f "$ENV_FILE" ] && have_file=1
fmode="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || echo none)"
alert_sources=0; grep -q 'etc/alerts.env' "$RUN_ALERT" 2>/dev/null && alert_sources=1

if [ "$MODE" != apply ]; then
  echo "   env file:    $ENV_FILE $([ "$have_file" = 1 ] && echo "present (mode $fmode)" || echo MISSING)"
  echo "   alert.sh:    $RUN_ALERT $([ "$alert_sources" = 1 ] && echo 'sources the env file' || echo 'does NOT source the env file')"
  echo "   crontab:     $n_config secret/config assignment(s) still inline"
fi

build_crontab() { # <in> <out>
  python3 - "$1" "$2" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
CONFIG = re.compile(r'^(ALERT_|BREVO_|GOTIFY_)[A-Z0-9_]*=')
POINTER = [
    "# Alert configuration (recipient, Brevo key, Gotify URL/token) lives in",
    "# ~/etc/alerts.env (mode 0600), sourced by ~/bin/alert.sh, so no credential",
    "# is readable through `crontab -l`.  Re-run tool/install_alert_env.sh to",
    "# migrate or verify it.",
]
lines = open(src).read().splitlines()
out = []
i = 0
while i < len(lines):
    ln = lines[i]
    if ln.lstrip().startswith('#'):
        j = i
        while j < len(lines) and lines[j].lstrip().startswith('#'):
            j += 1
        run = lines[i:j]
        marker = next((k for k, x in enumerate(run) if 'Configure alerts by setting' in x), None)
        if marker is None:
            out.extend(run)
        else:
            # Keep any header lines above the config doc (the jwt-watch header
            # shares this comment run) and swap the doc block for the pointer.
            out.extend(run[:marker])
            out.extend(POINTER)
        i = j
        continue
    if not CONFIG.match(ln):
        out.append(ln)
    i += 1
collapsed = []
for ln in out:
    if ln.strip() == '' and collapsed and collapsed[-1].strip() == '':
        continue
    collapsed.append(ln)
while collapsed and collapsed[-1].strip() == '':
    collapsed.pop()
open(dst, 'w').write('\n'.join(collapsed) + '\n')
removed = sum(1 for ln in lines if CONFIG.match(ln))
print("   crontab: %d config line(s) removed, comment block rewritten" % removed)
PY
}

build_env() { # <crontab> — the env-file body, values taken from the crontab
  python3 - "$1" <<'PY'
import re, sys
CONFIG = re.compile(r'^((?:ALERT_|BREVO_|GOTIFY_)[A-Z0-9_]*)=(.*)$')
vals = {}
for ln in open(sys.argv[1]).read().splitlines():
    m = CONFIG.match(ln)
    if m:
        vals[m.group(1)] = m.group(2)
def q(v):
    return "'" + v.replace("'", "'\\''") + "'"
header = """# Alert configuration for this host — sourced by ~/bin/alert.sh.
#
# Why a file and not the crontab: `crontab -l` prints every line, so a Brevo
# API key or a Gotify app token kept there is readable by anyone who can list
# the schedule.  This file is mode 0600 and lives outside both the crontab and
# any git repo.
#
# Managed by tool/install_alert_env.sh (kommons).  These are plain shell
# assignments and the file is sourced with `.`, so it is the source of truth:
# edit here, never in the crontab."""
order = ["ALERT_EMAIL", "BREVO_API_KEY", "GOTIFY_URL", "GOTIFY_APP_TOKEN"]
out = [header, ""]
for k in order:
    if k in vals:
        out.append("%s=%s" % (k, q(vals[k])))
for k in sorted(vals):
    if k not in order:
        out.append("%s=%s" % (k, q(vals[k])))
out += ["", "# Optional channels / overrides — uncomment and fill to enable:",
        "# ALERT_WEBHOOK_URL=''", "# BREVO_SENDER='noreply@mediasart.com'",
        "# BREVO_SENDER_NAME='mediasart'", "# GOTIFY_PRIORITY=''",
        "# TELEGRAM_BOT_TOKEN=''", "# TELEGRAM_CHAT_ID=''"]
print("\n".join(out))
PY
}

if [ "$MODE" = check ]; then
  rc=0
  if [ "$alert_sources" = 1 ]; then echo "   ✓ $RUN_ALERT sources the env file"; else echo "   ✗ $RUN_ALERT does not source the env file"; rc=1; fi
  if [ "$have_file" = 1 ]; then echo "   ✓ $ENV_FILE present"; else echo "   ✗ $ENV_FILE missing"; rc=1; fi
  if [ "$fmode" = 600 ]; then echo "   ✓ env file mode is 0600"; else echo "   ✗ env file mode is $fmode (want 600)"; rc=1; fi
  if [ "$n_config" = 0 ]; then echo "   ✓ no alert config left in the crontab"; else echo "   ✗ $n_config config line(s) still in the crontab"; rc=1; fi
  seen="$(env -i HOME="$HOME" PATH="$PATH" bash -c '. '"$RUN_ALERT"' 2>/dev/null; printf "%s" "${BREVO_API_KEY:-}${GOTIFY_APP_TOKEN:-}"' 2>/dev/null)"
  if [ -n "$seen" ]; then echo "   ✓ a clean shell sourcing alert.sh sees the values"; else echo "   ✗ alert.sh does not pick the values up from the file"; rc=1; fi
  [ "$rc" = 0 ] && echo "VERDICT|installed" || echo "VERDICT|not-installed"
  exit 0
fi

if [ "$MODE" = plan ]; then
  build_crontab "$CRON_IN" "$CRON_OUT" || true
  echo "   plan: install alert.sh → $RUN_ALERT (backup kept)"
  echo "   plan: write $ENV_FILE ($([ "$have_file" = 1 ] && echo 'already present — left untouched' || echo 'from the crontab values')); dir $ENV_DIR mode 0700"
  if [ "$have_file" = 0 ] && [ "$n_config" -gt 0 ]; then
    echo "   plan: env file would hold (values masked):"
    printf '%s\n' "$CRON_NOW" | grep -E "$CONFIG_RE" | sed -E 's/=.*/=<set>/' | sed 's/^/     | /'
  fi
  echo "   plan: resulting crontab:"
  sed 's/^/     | /' "$CRON_OUT"
  echo "VERDICT|plan (nothing was changed — re-run with --apply)"
  exit 0
fi

# --- apply ----------------------------------------------------------------- #
[ -f "$TMP_ALERT" ] || { echo "VERDICT|failed (alert.sh not staged at $TMP_ALERT)"; exit 1; }
if [ -f "$RUN_ALERT" ]; then
  cp -a "$RUN_ALERT" "$RUN_ALERT.bak.$(date +%Y%m%d-%H%M%S)" || true
fi
install -m 0755 "$TMP_ALERT" "$RUN_ALERT" || { echo "VERDICT|failed (install alert.sh)"; exit 1; }
bash -n "$RUN_ALERT" || { echo "VERDICT|failed (installed alert.sh does not parse)"; exit 1; }
echo "   installed $RUN_ALERT (backup kept)"

if [ "$have_file" = 0 ]; then
  mkdir -p "$ENV_DIR" || { echo "VERDICT|failed (mkdir $ENV_DIR)"; exit 1; }
  chmod 0700 "$ENV_DIR"
  build_env "$CRON_IN" > "$ENV_FILE" || { echo "VERDICT|failed (write env file)"; exit 1; }
  chmod 0600 "$ENV_FILE"
  echo "   wrote $ENV_FILE (mode 0600, dir 0700)"
else
  echo "   $ENV_FILE already present — left untouched (a rotated token is newer)"
fi

build_crontab "$CRON_IN" "$CRON_OUT" || { echo "VERDICT|failed (crontab rewrite)"; exit 1; }
if crontab "$CRON_OUT"; then
  echo "   crontab rewritten"
else
  echo "VERDICT|failed (crontab install — old crontab untouched)"
  exit 1
fi

CRON_AFTER="$(crontab -l 2>/dev/null || true)"
left="$(printf '%s\n' "$CRON_AFTER" | grep -cE "$CONFIG_RE")"
if [ "$left" != 0 ]; then
  echo "VERDICT|failed ($left config line(s) still in the crontab)"
  exit 1
fi
echo "   verify: no alert config left in the crontab"

seen="$(env -i HOME="$HOME" PATH="$PATH" bash -c '. '"$RUN_ALERT"' 2>/dev/null; printf "%s" "${BREVO_API_KEY:-}${GOTIFY_APP_TOKEN:-}"' 2>/dev/null)"
if [ -n "$seen" ]; then
  echo "   verify: a clean shell sourcing alert.sh sees the values"
else
  echo "VERDICT|failed (alert.sh does not see the values from $ENV_FILE)"
  exit 1
fi
echo "VERDICT|installed"
REMOTE

echo "== $VM =="
if [ "$MODE" = apply ]; then
  scp -q "${SSH_OPTS[@]}" "$ALERT_SH" "$VM:$TMP_ALERT" || { echo "scp of alert.sh failed" >&2; exit 1; }
fi
OUT="$(ssh "${SSH_OPTS[@]}" "$VM" "MODE='$MODE' ALERT_ENV_FILE='${ALERT_ENV_FILE:-}' TMP_ALERT='$TMP_ALERT' bash -s" <"$REMOTE_FILE" 2>&1)"
RC=$?
echo "$OUT"
VERDICT="$(grep -oE 'VERDICT\|.*' <<<"$OUT" | head -1)"
echo
echo "$VERDICT"
case "$VERDICT" in
  *failed*) exit 1 ;;
esac
exit "$RC"
