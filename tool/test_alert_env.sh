#!/usr/bin/env bash
# ============================================================================
# Hermetic suite for tool/install_alert_env.sh — no VM, no network, nothing
# written outside a temp sandbox.
#
# How: the installer's remote payload is executed LOCALLY by stubbing ssh/scp/
# crontab, with HOME pointed at a sandbox that holds a real alert.sh.  The
# crontab is a file, so the rewrite is exercised for real.
#
# The claims that matter, each asserted below:
#   - plan changes nothing;
#   - apply writes ~/etc/alerts.env mode 0600 in a 0700 dir, taking the values
#     from the crontab and shell-quoting them;
#   - apply strips the ALERT_*/BREVO_*/GOTIFY_* assignments from the crontab,
#     swaps the config doc block for a pointer, and KEEPS the jwt-watch header,
#     the tuning vars and every schedule;
#   - the whole point: a clean shell that sources alert.sh (and nothing else)
#     sees the credentials from the file;
#   - a re-run never overwrites an existing env file (a rotated token stays);
#   - --check distinguishes installed from not-installed.
#
# Usage: bash tool/test_alert_env.sh
# ============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$REPO/tool/install_alert_env.sh"
ALERT_SH="$REPO/tool/alert.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
has() { grep -qF -- "$2" <<<"$1"; }
lacks() { ! grep -qF -- "$2" <<<"$1"; }

BIN="$WORK/stubbin"
SB_HOME="$WORK/home"
CRON_FILE="$WORK/crontab"
mkdir -p "$BIN" "$SB_HOME/bin"
cp "$ALERT_SH" "$SB_HOME/bin/alert.sh"
export SB_HOME CRON_FILE

cat >"$BIN/ssh" <<'STUB'
#!/usr/bin/env bash
cmd="${*: -1}"
exec env HOME="$SB_HOME" PATH="$PATH" bash -c "$cmd"
STUB
cat >"$BIN/scp" <<'STUB'
#!/usr/bin/env bash
src="${*: -2:1}"; dest="${*: -1}"
cp "$src" "${dest#*:}"
STUB
cat >"$BIN/crontab" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  -l) cat "$CRON_FILE" ;;
  *)  cp "$1" "$CRON_FILE" ;;
esac
STUB
chmod +x "$BIN/ssh" "$BIN/scp" "$BIN/crontab"
export PATH="$BIN:$PATH"

# A crontab shaped like the VM's: the jwt-watch header and the alert-config doc
# share one comment run, then the four assignments, then the tuning + schedules.
write_cron_fixture() {
  cat >"$CRON_FILE" <<'CRON'
# JWT secret watch — one program on two entries (see the managed block below)
# Configure alerts by setting ONE OR MORE of:
#   ALERT_WEBHOOK_URL=<your-incoming-webhook-url>
#   ALERT_EMAIL=<recipient@example.com>
#   BREVO_API_KEY=<brevo-sendinblue-api-key>
#   GOTIFY_URL=<gotify-server-url>    (e.g. https://notify.mediasart.com)
#   GOTIFY_APP_TOKEN=<gotify-app-token>
# Gotify used when GOTIFY_URL + GOTIFY_APP_TOKEN are set (priority default:
#   8 for drift/revert alerts, 5 for daily summary).
ALERT_EMAIL=kjhrono@gmail.com
BREVO_API_KEY=xkeysib-TESTKEY-abc123
GOTIFY_URL=https://notify.mediasart.com
GOTIFY_APP_TOKEN=TESTTOKEN012345
0 9 * * * ~/bin/jwt-secret-daily-summary.sh >/dev/null 2>&1

RETENTION_DAYS=30
0 3 * * 0 ~/bin/cleanup-env-backups.sh >/dev/null 2>&1

REPORT_HOURS=168
0 8 * * 1 ~/bin/gotify-report-digest.sh >/dev/null 2>&1

MAX_AGE_MINUTES=45

# >>> jwt-secret watch (managed by tool/install_jwt_secret_watch.sh) >>>
*/15 * * * * ~/bin/jwt-secret-monitor.sh monitor >/dev/null 2>&1
# <<< jwt-secret watch
CRON
}
fresh() {
  write_cron_fixture
  rm -f "$SB_HOME/etc/alerts.env"
  rm -rf "$SB_HOME/etc"
  cp "$ALERT_SH" "$SB_HOME/bin/alert.sh"
}
run() { bash "$INSTALLER" "$@"; }

# ------------------------------------------------------------ 1. sanity --- #
echo "== 1. harness sanity =="
[ -x "$INSTALLER" ] || { echo "installer not executable"; exit 1; }
bash -n "$INSTALLER" && ok "installer parses" || bad "installer does not parse"
fresh
"$BIN/crontab" -l | grep -q BREVO_API_KEY && ok "crontab fixture carries an inline secret" || bad "fixture wrong"
env -i HOME="$WORK/nohome" PATH="$PATH" bash -c ". '$SB_HOME/bin/alert.sh'; [ -z \"\${BREVO_API_KEY:-}\" ]" && ok "alert.sh sees nothing without the env file" || bad "alert.sh leaked a value"

# --------------------------------------------------------------- 2. plan --- #
echo
echo "== 2. plan changes nothing =="
out="$(run 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "plan exits 0" || bad "plan exited $rc"
has "$out" "VERDICT|plan" && ok "plan prints a verdict" || bad "no plan verdict"
[ ! -e "$SB_HOME/etc/alerts.env" ] && ok "plan wrote no env file" || bad "plan wrote a file"
"$BIN/crontab" -l | grep -q '^BREVO_API_KEY=' && ok "plan left the crontab unchanged" || bad "plan edited the crontab"
has "$out" "BREVO_API_KEY=<set>" && ok "plan masks the values" || bad "plan did not mask"
lacks "$out" "xkeysib-TESTKEY-abc123" && ok "the real key never appears in plan output" || bad "plan leaked the key"

# -------------------------------------------------------------- 3. apply --- #
echo
echo "== 3. apply migrates and strips =="
fresh
out="$(run --apply 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "apply exits 0" || bad "apply exited $rc"
[ -f "$SB_HOME/etc/alerts.env" ] && ok "env file created" || bad "no env file"
[ "$(stat -c '%a' "$SB_HOME/etc/alerts.env")" = 600 ] && ok "env file is 0600" || bad "env file mode $(stat -c '%a' "$SB_HOME/etc/alerts.env")"
[ "$(stat -c '%a' "$SB_HOME/etc")" = 700 ] && ok "env dir is 0700" || bad "env dir mode $(stat -c '%a' "$SB_HOME/etc")"
envf="$(cat "$SB_HOME/etc/alerts.env")"
has "$envf" "ALERT_EMAIL='kjhrono@gmail.com'" && ok "recipient migrated (quoted)" || bad "recipient missing"
has "$envf" "BREVO_API_KEY='xkeysib-TESTKEY-abc123'" && ok "Brevo key migrated" || bad "brevo key missing"
has "$envf" "GOTIFY_APP_TOKEN='TESTTOKEN012345'" && ok "Gotify token migrated" || bad "gotify token missing"
cron="$(cat "$CRON_FILE")"
lacks "$cron" "xkeysib-TESTKEY-abc123" && ok "crontab no longer holds the key" || bad "key still in crontab"
lacks "$cron" "TESTTOKEN012345" && ok "crontab no longer holds the token" || bad "token still in crontab"
lacks "$cron" '^BREVO_API_KEY=' && ok "no BREVO_ assignment left" || bad "BREVO_ assignment left"
lacks "$cron" '^ALERT_EMAIL=' && ok "no ALERT_ assignment left" || bad "ALERT_ assignment left"
has "$cron" "~/etc/alerts.env (mode 0600)" && ok "config doc replaced with a pointer" || bad "no pointer in crontab"
has "$cron" "# JWT secret watch — one program on two entries" && ok "the jwt-watch header survives" || bad "jwt header was eaten"
has "$cron" "RETENTION_DAYS=30" && ok "tuning var kept" || bad "RETENTION_DAYS lost"
has "$cron" "MAX_AGE_MINUTES=45" && ok "second tuning var kept" || bad "MAX_AGE_MINUTES lost"
has "$cron" "*/15 * * * * ~/bin/jwt-secret-monitor.sh monitor" && ok "the jwt schedule is kept" || bad "jwt schedule lost"

# ------------------------------------------- 4. alert.sh sees the values --- #
echo
echo "== 4. alert.sh picks the values up from the file alone =="
got="$(env -i HOME="$SB_HOME" PATH="$PATH" bash -c ". '$SB_HOME/bin/alert.sh'; printf '%s' \"\${BREVO_API_KEY:-}\":\"\${GOTIFY_APP_TOKEN:-}\"")"
[ "$got" = "xkeysib-TESTKEY-abc123:TESTTOKEN012345" ] && ok "a clean shell sourcing alert.sh sees both secrets" || bad "alert.sh saw '$got'"

# ---------------------------------------------- 5. idempotent + rotation --- #
echo
echo "== 5. a re-run never clobbers an existing env file =="
printf 'GOTIFY_APP_TOKEN=%s\n' "'ROTATED-TOKEN-999'" >>"$SB_HOME/etc/alerts.env"
out="$(run --apply 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "second apply exits 0" || bad "second apply exited $rc"
has "$(cat "$SB_HOME/etc/alerts.env")" "ROTATED-TOKEN-999" && ok "an existing (rotated) env file is left untouched" || bad "re-apply overwrote the env file"
[ "$(grep -cE '^(ALERT_|BREVO_|GOTIFY_)[A-Z0-9_]*=' "$CRON_FILE")" = 0 ] && ok "crontab still has no config assignments" || bad "crontab regained assignments"

# --------------------------------------------- 6. quoting round-trips --- #
echo
echo "== 6. a value with a single quote round-trips =="
fresh
python3 - "$CRON_FILE" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p).read().replace("ALERT_EMAIL=kjhrono@gmail.com", "ALERT_EMAIL=o'brien@example.com")
open(p, "w").write(s)
PY
run --apply >/dev/null 2>&1
got="$(env -i HOME="$SB_HOME" PATH="$PATH" bash -c ". '$SB_HOME/etc/alerts.env'; printf '%s' \"\$ALERT_EMAIL\"")"
[ "$got" = "o'brien@example.com" ] && ok "single-quoted value survives sourcing" || bad "quoting broke: got '$got'"

# -------------------------------------------------------------- 7. check --- #
echo
echo "== 7. --check distinguishes states =="
fresh
out="$(run --check 2>&1)"; rc=$?
[ "$rc" = 0 ] && has "$out" "VERDICT|not-installed" && ok "un-migrated state reports not-installed" || bad "check state wrong ($rc)"
run --apply >/dev/null 2>&1
out="$(run --check 2>&1)"; rc=$?
[ "$rc" = 0 ] && has "$out" "VERDICT|installed" && ok "migrated state reports installed" || bad "check state wrong ($rc)"
# A mode loosened back to world-readable must fail the check.
chmod 0644 "$SB_HOME/etc/alerts.env"
out="$(run --check 2>&1)"
has "$out" "env file mode is 644" && ok "a world-readable env file fails the check" || bad "mode drift not caught"

echo
echo "================================================"
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" = 0 ]
