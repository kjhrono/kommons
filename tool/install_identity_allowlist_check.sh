#!/usr/bin/env bash
# ============================================================================
# Install the recurring, SELF-HEALING allow-list guard on the identity VM.
#
# The declaration (tool/identity-redirect-allowlist.txt) and the sync tool
# (tool/identity_allowlist_sync.sh) make the central identity stack's GoTrue
# redirect configuration convergeable — the allow list AND the site URL every
# unmatched redirect falls back to — but nothing touches the LIVE stack on a
# schedule, so a later `.env` rewrite could still drop an entry, or reset the
# site URL, and stay silent until a member's sign-in ends at the website
# instead of the app.
#
#   bash tool/install_identity_allowlist_check.sh            # plan (default)
#   bash tool/install_identity_allowlist_check.sh --apply    # deploy + schedule
#   bash tool/install_identity_allowlist_check.sh --check    # assert installed
#
# The scheduled entry runs `--local --heal --alert`.  It CONVERGES a missing
# entry, or a site URL that is not the one the declaration names, and then
# re-verifies the running auth, rather than only reporting the
# drop: the entry is missing until somebody acts, and the finding is precisely
# that a real sign-in is broken until then, so making it visible without fixing
# it leaves the damage in place between runs.  The cost is that a heal recreates
# the shared auth container — a few seconds of sign-in downtime for every
# project (existing JWT sessions stay valid) — which is why it only ever fires
# when a declared entry is actually missing, and never on a stack that is in
# sync.  Alerts follow the outcome: one informational notice per heal, and the
# loud drift alarm only when the heal fails (see the tool's --heal docs).
#
# --apply deploys the tool + declaration to ~/bin via the sync tool's own
# --deploy path, then rewrites the crontab to hold exactly one managed block.
# It touches nothing else: a re-run is a no-op, and no other entry is edited.
#
# The filename keeps its original "check" wording because it names the managed
# crontab block; renaming it would orphan that block's comment lines on every
# host already carrying one.
#
# Env overrides: KAT_SSH_KEY, KAT_VM_HOST, KAT_VM_USER,
#   IDENTITY_ALLOWLIST_CHECK_SCHEDULE (default "*/30 * * * *").
# ============================================================================
set -uo pipefail

KEY="${KAT_SSH_KEY:-$HOME/.ssh/katalogus}"
[ -f "$KEY" ] || KEY="${KAT_SSH_KEY:-/home/marcuz/Apps/Projects/keys/ssh-private-key.key}"
VM="${KAT_VM_USER:-ubuntu}@${KAT_VM_HOST:-80.225.89.206}"
SCHEDULE="${IDENTITY_ALLOWLIST_CHECK_SCHEDULE:-*/30 * * * *}"

HERE="$(cd "$(dirname "$0")" && pwd)"
SYNC="$HERE/identity_allowlist_sync.sh"

MODE=plan
for a in "$@"; do
  case "$a" in
    --apply) MODE=apply ;;
    --check) MODE=check ;;
    -h|--help) sed -n '2,/^set -uo pipefail$/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "install_identity_allowlist_check: unknown argument: $a" >&2; exit 2 ;;
  esac
done

[ -f "$SYNC" ] || { echo "missing repo file: $SYNC" >&2; exit 2; }
bash -n "$SYNC" || { echo "identity_allowlist_sync.sh does not parse — refusing" >&2; exit 2; }

SSH_OPTS=(-i "$KEY" -o BatchMode=yes -o ConnectTimeout=20
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

REMOTE_FILE="$(mktemp)"
trap 'rm -f "$REMOTE_FILE"' EXIT
cat >"$REMOTE_FILE" <<'REMOTE'
set -uo pipefail
MODE="${MODE:-plan}"
BIN="$HOME/bin"
TOOL="$BIN/identity_allowlist_sync.sh"
LIST="$BIN/identity-redirect-allowlist.txt"
BEGIN='# >>> identity allow list check'
END='# <<< identity allow list check'
ENTRY_RE='identity_allowlist_sync\.sh'

CRON_NOW="$(crontab -l 2>/dev/null || true)"
CRON_IN="${TMPDIR:-/tmp}/kat-allowlist-cron-in.$$"
CRON_OUT="${TMPDIR:-/tmp}/kat-allowlist-cron-out.$$"
printf '%s\n' "$CRON_NOW" > "$CRON_IN"

have_tool=0; [ -f "$TOOL" ] && have_tool=1
have_list=0; [ -f "$LIST" ] && have_list=1
n_entry="$(printf '%s\n' "$CRON_NOW" | grep -cE "$ENTRY_RE")"
# A detect-only entry left behind by an older installer must not pass for the
# self-healing guard: it would look installed while never converging anything.
n_heal="$(printf '%s\n' "$CRON_NOW" | grep -cE "$ENTRY_RE.*--heal")"

if [ "$MODE" != apply ]; then
  echo "   tool:        $TOOL $([ "$have_tool" = 1 ] && echo present || echo MISSING)"
  echo "   declaration: $LIST $([ "$have_list" = 1 ] && echo present || echo MISSING)"
  echo "   cron:        $n_entry existing allow-list entry/entries ($n_heal self-healing), schedule '$SCHEDULE'"
fi

# --- build the new crontab: exactly one managed block, nothing else touched -- #
build_crontab() { # <in> <out>
  python3 - "$1" "$2" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
import os
SCHEDULE = os.environ["SCHEDULE"]
BEGIN, END = "# >>> identity allow list check", "# <<< identity allow list check"
ENTRY_RE = "identity_allowlist_sync.sh"

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
    BEGIN + " (managed by tool/install_identity_allowlist_check.sh) >>>",
    "# Self-healing guard: every entry declared in ~/bin/identity-redirect-allowlist.txt",
    "# must be on the stack AND in the running auth process, and the stack's",
    "# SITE_URL must be the site_url that same declaration names.  GoTrue silently",
    "# rewrites an unlisted redirect to GOTRUE_SITE_URL, so a dropped native entry",
    "# — or a site URL that is not the declared one, which is where it LANDS —",
    "# breaks a real sign-in at its last step.  This converges either drift itself",
    "# (rewrite the .env, recreate ONLY auth) and then re-verifies the running",
    "# process.  One notice per heal; the loud alarm only when the heal fails.",
    "# Identity auth is shared, so a heal costs a few seconds of sign-in downtime.",
    "%s ~/bin/identity_allowlist_sync.sh --local --heal --alert >/dev/null 2>&1" % SCHEDULE,
    END,
    "",
]
open(dst, "w").write("\n".join(collapsed + block) + "\n")
print("   crontab: wrote 1 managed entry (schedule '%s')" % SCHEDULE)
PY
}

# --- check mode ------------------------------------------------------------ #
if [ "$MODE" = check ]; then
  rc=0
  if [ "$have_tool" = 1 ]; then echo "   ✓ $TOOL installed"; else echo "   ✗ $TOOL missing"; rc=1; fi
  if [ "$have_list" = 1 ]; then echo "   ✓ $LIST installed"; else echo "   ✗ $LIST missing"; rc=1; fi
  if [ -f "$BIN/alert.sh" ]; then echo "   ✓ $BIN/alert.sh present (--alert fans out through it)"; else echo "   ✗ $BIN/alert.sh missing — the check cannot alert"; rc=1; fi
  if [ "$n_entry" = 1 ]; then echo "   ✓ one allow-list guard cron entry"; else echo "   ✗ expected 1 cron entry, found $n_entry"; rc=1; fi
  if [ "$n_heal" = 1 ]; then echo "   ✓ the scheduled entry self-heals (--heal --alert)"; else echo "   ✗ the scheduled entry does not run --heal — it would only report a drop"; rc=1; fi
  [ "$rc" = 0 ] && echo "VERDICT|installed" || echo "VERDICT|not-installed"
  exit 0
fi

# --- plan ------------------------------------------------------------------ #
if [ "$MODE" = plan ]; then
  build_crontab "$CRON_IN" "$CRON_OUT" || true
  echo "   plan: deploy the tool + declaration to $BIN (via identity_allowlist_sync.sh --deploy)"
  echo "   plan: schedule '$SCHEDULE ~/bin/identity_allowlist_sync.sh --local --heal --alert'"
  echo "   plan: a heal recreates ONLY auth — a few seconds of shared sign-in downtime"
  echo "   plan: resulting crontab:"
  sed 's/^/     | /' "$CRON_OUT"
  echo "VERDICT|plan (nothing was changed — re-run with --apply)"
  exit 0
fi

# --- apply ----------------------------------------------------------------- #
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
echo "   verify: 1 self-healing allow-list guard entry"

echo
echo "   smoke test (read-only):"
"$TOOL" --local --check 2>&1 | sed 's/^/     | /'
echo "     exit ${PIPESTATUS[0]}"
echo "VERDICT|installed"
REMOTE

echo "== $VM =="
if [ "$MODE" = apply ]; then
  # Reuse the sync tool's own deploy path so the install logic stays in one place.
  bash "$SYNC" --deploy || { echo "deploy failed" >&2; exit 1; }
fi

OUT="$(ssh "${SSH_OPTS[@]}" "$VM" \
  "MODE='$MODE' SCHEDULE='$SCHEDULE' bash -s" <"$REMOTE_FILE" 2>&1)"
RC=$?
echo "$OUT"
VERDICT="$(grep -oE 'VERDICT\|.*' <<<"$OUT" | head -1)"
echo
echo "$VERDICT"
case "$VERDICT" in
  *failed*) exit 1 ;;
esac
exit "$RC"
