#!/usr/bin/env bash
# ============================================================================
# Install the nightly OAuth hand-off probe on the identity VM.
#
# The allow-list guard (install_identity_allowlist_check.sh) proves an entry is
# PRESENT every 30 minutes, and converges a drop it finds.  It cannot prove the
# entry is HONOURED end to end —
# which is exactly how a silent rewrite to GOTRUE_SITE_URL survives.  This
# installs the nightly probe that exercises the real hand-off and alerts when a
# declared target comes back rewritten.  The same run asserts the site URL the
# declaration names (that is where every rewritten target lands) and the two
# MAIL links the stack sends — the signup confirmation and the password recovery.
# Those are built as <site URL> + one path, by the send-email hook rather than by
# GoTrue's templates, so a wrong origin or path there breaks a registration or a
# password reset in exactly the same silent way — and nothing else looks at it.
#
#   bash tool/install_identity_oauth_probe.sh            # plan (default)
#   bash tool/install_identity_oauth_probe.sh --apply    # deploy + schedule
#   bash tool/install_identity_oauth_probe.sh --check    # assert installed
#
# --apply deploys the probe to ~/bin, ensures the allow-list tool + declaration
# are deployed (via identity_allowlist_sync.sh --deploy, so that logic stays in
# one place), then rewrites the crontab to hold exactly one managed block.  It
# touches nothing else: a re-run is a no-op, and no other entry is edited.
#
# The probe costs one `auth.flow_state` row per declared entry, one for the
# control and — when the declaration carries a `site_url` directive — one more
# to observe where an unlisted target lands, per night.  The mail half adds two
# plain GETs to the links' own URLs with a bogus token, so GoTrue answers
# `otp_expired`: no token is consumed and nothing is mailed.  GoTrue sweeps
# expired flows itself.
#
# Env overrides: KAT_SSH_KEY, KAT_VM_HOST, KAT_VM_USER,
#   IDENTITY_OAUTH_PROBE_SCHEDULE (default "0 4 * * *").
# ============================================================================
set -uo pipefail

KEY="${KAT_SSH_KEY:-$HOME/.ssh/katalogus}"
[ -f "$KEY" ] || KEY="${KAT_SSH_KEY:-/home/marcuz/Apps/Projects/keys/ssh-private-key.key}"
VM="${KAT_VM_USER:-ubuntu}@${KAT_VM_HOST:-80.225.89.206}"
SCHEDULE="${IDENTITY_OAUTH_PROBE_SCHEDULE:-0 4 * * *}"

HERE="$(cd "$(dirname "$0")" && pwd)"
PROBE_SRC="$HERE/oauth_handoff_probe.sh"
SYNC="$HERE/identity_allowlist_sync.sh"

MODE=plan
for a in "$@"; do
  case "$a" in
    --apply) MODE=apply ;;
    --check) MODE=check ;;
    -h|--help) sed -n '2,/^set -uo pipefail$/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "install_identity_oauth_probe: unknown argument: $a" >&2; exit 2 ;;
  esac
done

for f in "$PROBE_SRC" "$SYNC"; do
  [ -f "$f" ] || { echo "missing repo file: $f" >&2; exit 2; }
done
bash -n "$PROBE_SRC" || { echo "oauth_handoff_probe.sh does not parse — refusing" >&2; exit 2; }

SSH_OPTS=(-i "$KEY" -o BatchMode=yes -o ConnectTimeout=20
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
TMP_PROBE=/tmp/kat-install-oauth-probe.sh

REMOTE_FILE="$(mktemp)"
trap 'rm -f "$REMOTE_FILE"' EXIT
cat >"$REMOTE_FILE" <<'REMOTE'
set -uo pipefail
MODE="${MODE:-plan}"
PROBE_TMP="$PROBE_TMP"
BIN="$HOME/bin"
PROBE="$BIN/oauth_handoff_probe.sh"
LIST="$BIN/identity-redirect-allowlist.txt"
SYNC="$BIN/identity_allowlist_sync.sh"
BEGIN='# >>> oauth hand-off probe'
END='# <<< oauth hand-off probe'
ENTRY_RE='oauth_handoff_probe\.sh'

CRON_NOW="$(crontab -l 2>/dev/null || true)"
CRON_IN="${TMPDIR:-/tmp}/kat-oauth-probe-cron-in.$$"
CRON_OUT="${TMPDIR:-/tmp}/kat-oauth-probe-cron-out.$$"
printf '%s\n' "$CRON_NOW" > "$CRON_IN"

have() { [ -f "$1" ] && echo present || echo MISSING; }
n_entry="$(printf '%s\n' "$CRON_NOW" | grep -cE "$ENTRY_RE")"

if [ "$MODE" != apply ]; then
  echo "   probe:       $PROBE $(have "$PROBE")"
  echo "   declaration: $LIST $(have "$LIST")"
  echo "   allowlist tool: $SYNC $(have "$SYNC")"
  echo "   cron:        $n_entry existing probe entry/entries, schedule '$SCHEDULE'"
fi

build_crontab() { # <in> <out>
  python3 - "$1" "$2" <<'PY'
import os, sys
src, dst = sys.argv[1], sys.argv[2]
SCHEDULE = os.environ["SCHEDULE"]
BEGIN, END = "# >>> oauth hand-off probe", "# <<< oauth hand-off probe"
ENTRY_RE = "oauth_handoff_probe.sh"

lines = open(src).read().splitlines()
keep = [True] * len(lines)
in_block = False
for i, ln in enumerate(lines):
    if ln.startswith(BEGIN):
        in_block = True
    if in_block:
        keep[i] = False
    if ln.startswith(END):
        in_block = False
for i, ln in enumerate(lines):
    if ENTRY_RE in ln:
        keep[i] = False

out = [ln for i, ln in enumerate(lines) if keep[i]]
collapsed = []
for ln in out:
    if ln.strip() == "" and collapsed and collapsed[-1].strip() == "":
        continue
    collapsed.append(ln)
while collapsed and collapsed[-1].strip() == "":
    collapsed.pop()

block = [
    "",
    BEGIN + " (managed by tool/install_identity_oauth_probe.sh) >>>",
    "# Nightly end-to-end hand-off check.  It starts a real /authorize flow for",
    "# each declared redirect and reads where GoTrue resolves it at /callback:",
    "# an entry that is not honoured comes back rewritten to GOTRUE_SITE_URL.",
    "# It also follows the confirmation and password-recovery links the stack",
    "# mails, holding their origin and path to the declaration and to the hook",
    "# that renders them.",
    "# Read-only: an abandoned flow per target plus one GET per mail link;",
    "# nothing is exchanged, no credentials, no recreate.",
    "%s ~/bin/oauth_handoff_probe.sh --local --check --alert >/dev/null 2>&1" % SCHEDULE,
    END,
    "",
]
open(dst, "w").write("\n".join(collapsed + block) + "\n")
print("   crontab: wrote 1 managed entry (schedule '%s')" % SCHEDULE)
PY
}

if [ "$MODE" = check ]; then
  rc=0
  if [ -x "$PROBE" ]; then echo "   ✓ $PROBE installed and executable"; else echo "   ✗ $PROBE missing/not executable"; rc=1; fi
  if [ -f "$LIST" ]; then echo "   ✓ $LIST present"; else echo "   ✗ $LIST missing"; rc=1; fi
  if [ -f "$SYNC" ]; then echo "   ✓ $SYNC present (presence half)"; else echo "   ✗ $SYNC missing"; rc=1; fi
  if [ -f "$BIN/alert.sh" ]; then echo "   ✓ $BIN/alert.sh present (--alert fans out through it)"; else echo "   ✗ $BIN/alert.sh missing"; rc=1; fi
  if [ "$n_entry" = 1 ]; then echo "   ✓ one nightly probe cron entry"; else echo "   ✗ expected 1 cron entry, found $n_entry"; rc=1; fi
  [ "$rc" = 0 ] && echo "VERDICT|installed" || echo "VERDICT|not-installed"
  exit 0
fi

if [ "$MODE" = plan ]; then
  build_crontab "$CRON_IN" "$CRON_OUT" || true
  echo "   plan: install oauth_handoff_probe.sh → $PROBE"
  echo "   plan: ensure tool + declaration deployed (identity_allowlist_sync.sh --deploy)"
  echo "   plan: resulting crontab:"
  sed 's/^/     | /' "$CRON_OUT"
  echo "VERDICT|plan (nothing was changed — re-run with --apply)"
  exit 0
fi

# --- apply ----------------------------------------------------------------- #
[ -f "$PROBE_TMP" ] || { echo "VERDICT|failed (probe not staged at $PROBE_TMP)"; exit 1; }
install -m 0755 "$PROBE_TMP" "$PROBE" || { echo "VERDICT|failed (install probe)"; exit 1; }
if ! bash -n "$PROBE"; then
  echo "VERDICT|failed (installed probe does not parse)"; exit 1
fi
echo "   installed $PROBE"

build_crontab "$CRON_IN" "$CRON_OUT" || { echo "VERDICT|failed (crontab rewrite)"; exit 1; }
if crontab "$CRON_OUT"; then
  echo "   crontab rewritten"
else
  echo "VERDICT|failed (crontab install — old crontab untouched)"
  exit 1
fi

CRON_AFTER="$(crontab -l 2>/dev/null || true)"
n_after="$(printf '%s\n' "$CRON_AFTER" | grep -cE "$ENTRY_RE")"
if [ "$n_after" != 1 ]; then
  echo "VERDICT|failed (crontab verification: want 1 entry, found $n_after)"
  exit 1
fi
echo "   verify: 1 nightly probe entry"

echo
echo "   smoke test (read-only, no --alert):"
"$PROBE" --local --check 2>&1 | sed 's/^/     | /'
echo "     exit ${PIPESTATUS[0]}"
echo "VERDICT|installed"
REMOTE

echo "== $VM =="
if [ "$MODE" = apply ]; then
  # Ensure the allow-list tool + declaration are present (the probe calls the
  # tool for its presence half); keep that install logic in one place.
  bash "$SYNC" --deploy || { echo "deploy of the allow-list tool failed" >&2; exit 1; }
  scp -q "${SSH_OPTS[@]}" "$PROBE_SRC" "$VM:$TMP_PROBE" || { echo "scp of the probe failed" >&2; exit 1; }
fi

OUT="$(ssh "${SSH_OPTS[@]}" "$VM" \
  "MODE='$MODE' SCHEDULE='$SCHEDULE' PROBE_TMP='$TMP_PROBE' bash -s" <"$REMOTE_FILE" 2>&1)"
RC=$?
echo "$OUT"
VERDICT="$(grep -oE 'VERDICT\|.*' <<<"$OUT" | head -1)"
echo
echo "$VERDICT"
case "$VERDICT" in
  *failed*) exit 1 ;;
esac
exit "$RC"
