#!/usr/bin/env bash
# ============================================================================
# Self-test for tool/jwt-secret-monitor.sh and its installer
# tool/install_jwt_secret_watch.sh — hermetic: no VM, no docker daemon, no
# network, and nothing written outside the sandbox.
#
# How: the real monitor and the real canonical_secret.sh are copied into a
# sandbox ~/bin, next to stub `alert.sh`, `gotify-messages.sh`, `docker` and
# `sleep`.  HOME is pointed at the sandbox, so every stack path the monitor
# builds from $HOME/Projects lands inside it, and KAT_IDENTITY_ENV points the
# canonical source at the sandbox identity .env.
#
# The claims that matter, each asserted below:
#   - a clean run exits 0, writes exactly one OK line and one heartbeat, and
#     alerts nobody;
#   - ordinary drift is reported and alerted but NEVER auto-repaired (the
#     operator decides), while an exact revert — a secret matching a
#     pre-cutover fingerprint — IS auto-re-cut back to the canonical value,
#     backed up first, and the running auth container is re-verified;
#   - a failed re-cut exits 2 with heartbeat `failed` and says so;
#   - a missing .env is a WARN, not a drift;
#   - no secret VALUE ever reaches the log or the output, only fingerprints;
#   - meta mode alerts once per liveness outage (not once per run), sends a
#     recovery notice, and covers stale / missing / unreadable delivery;
#   - --check changes nothing anywhere;
#   - the daily summary can still parse every line this script writes (the
#     "<TS> <EVENT> <stack>: <detail>" vocabulary and the bare-stack rule);
#   - the installed crontab ends up with exactly three entries (two monitor,
#     one daily-summary) and no retired one, with the env vars the entries need
#     still above them and the daily-summary entry moved inside the managed
#     block.
#
# Usage: bash tool/test_jwt_secret_watch.sh
# ============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$REPO/tool/jwt-secret-monitor.sh"
LIB="$REPO/tool/canonical_secret.sh"
INSTALLER="$REPO/tool/install_jwt_secret_watch.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
has() { grep -qF -- "$2" <<<"$1"; }
lacks() { ! grep -qF -- "$2" <<<"$1"; }

SB="$WORK/sb"
BIN="$SB/bin"
mkdir -p "$BIN" "$SB/home/Projects"
IDENV="$SB/home/Projects/kommons/supabase-identity/docker/.env"

# ---------------------------------------------------------------- fixtures ---
CANON="selftest-canonical-secret-0123456789ab"
STALE="selftest-pre-cutover-old-secret-9876"
STALE2="selftest-pre-cutover-second-5432"
DRIFT="selftest-unknown-drifted-value-abcdef"

STACK_DIRS=(
  kommons/supabase-identity/docker
  katalogus/database/docker
  kalcio/database/docker
  kognitio/database/docker
  kollectio/database/docker
  kapaxinfiniti/database/docker
)

reset_fixtures() {
  for d in "${STACK_DIRS[@]}"; do
    mkdir -p "$SB/home/Projects/$d"
    printf 'JWT_SECRET=%s\n' "$CANON" >"$SB/home/Projects/$d/.env"
  done
  # History snapshots that define the pre-cutover fingerprint registry.
  printf 'JWT_SECRET=%s\n' "$STALE"  >"$SB/home/Projects/katalogus/database/docker/.env.bak.1700000000"
  printf 'JWT_SECRET=%s\n' "$STALE2" >"$SB/home/Projects/kalcio/database/docker/.env.bak.1700000001"
  # Placeholders must never enter the registry.
  printf 'JWT_SECRET=%s\n' "not-a-real-value-secret-here" >"$SB/home/Projects/kognitio/database/docker/.env.bak.1700000002"
}

reset_logs() {
  rm -rf "$SB/home/logs" "$SB/home/.jwt-secret-history" "$SB/alerts"
  mkdir -p "$SB/home/logs"
}
LOG="$SB/home/logs/jwt-secret-drift.log"
LIVENESS_LOG="$SB/home/logs/jwt-secret-liveness.log"
DELIVERY_LOG="$SB/home/logs/jwt-secret-delivery.log"
STATE="$SB/home/logs/jwt-secret-liveness.state"

# ------------------------------------------------------------------- stubs ---
cp "$SUT" "$BIN/jwt-secret-monitor.sh"
cp "$LIB" "$BIN/canonical_secret.sh"

cat >"$BIN/alert.sh" <<'STUB'
#!/usr/bin/env bash
# alert.sh stub: records the fan-out instead of posting anything.
timestamp() { date '+%Y-%m-%dT%H:%M:%S%z'; }
json_escape() { printf '%s' "$1"; }
# Newlines are collapsed so one call is one grep-able line, message and all.
_arec() { printf 'ALERT %s\n' "${1//$'\n'/ }" >>"${ALERT_SINK:-/dev/null}"; }
send_webhook_alert() { _arec "webhook :: $1"; }
send_gotify_alert()  { _arec "gotify :: $1"; }
send_email_alert()   { _arec "email :: $1"; }
send_brevo_alert()   { _arec "brevo :: $1"; }
preferred_email_channel() { printf ''; }
send_email_report() { printf ''; }
STUB

cat >"$BIN/gotify-messages.sh" <<'STUB'
#!/usr/bin/env bash
# gotify-messages.sh stub: --age-seconds [--title T]
title=""
while [ "$#" -gt 0 ]; do
  case "$1" in --title) shift; title="${1:-}" ;; esac
  shift
done
if [ -n "${GOTIFY_FAKE_ERR:-}" ]; then printf 'gotify.db: unable to open\n' >&2; exit 1; fi
if [ -n "$title" ]; then
  printf '%s' "${GOTIFY_FAKE_AGE_TITLE:-60}"
else
  printf '%s' "${GOTIFY_FAKE_AGE_ANY:-30}"
fi
STUB

cat >"$BIN/docker" <<'STUB'
#!/usr/bin/env bash
# docker stub: the exact calls force_recut makes, and nothing else.
cmd="${1:?}"; shift
case "$cmd" in
  compose)
    sub="${1:?}"; shift
    case "$sub" in
      up)
        if [ -n "${KAT_FAKE_COMPOSE_FAIL:-}" ]; then echo "Error response from daemon: boom" >&2; exit 1; fi
        echo " Container selftest-auth-1  Recreated"; exit 0 ;;
      ps) echo "cafed00d"; exit 0 ;;
      *)  exit 0 ;;
    esac ;;
  inspect) printf 'healthy\n'; exit 0 ;;
  exec)
    while [ "$#" -gt 0 ]; do
      case "$1" in printenv) shift; var="${1:-}"; break ;; *) shift ;; esac
    done
    [ "${var:-}" = "GOTRUE_JWT_SECRET" ] || exit 1
    cat "${KAT_FAKE_AUTH_SECRET_FILE:?}" 2>/dev/null
    exit 0 ;;
  *) exit 1 ;;
esac
STUB

printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/sleep"
chmod +x "$BIN/jwt-secret-monitor.sh" "$BIN/alert.sh" "$BIN/gotify-messages.sh" "$BIN/docker" "$BIN/sleep"
printf '%s' "$CANON" >"$SB/canon"

export PATH="$BIN:$PATH"
MON=("$BIN/jwt-secret-monitor.sh")
declare -a EXTRA=()

# run <args...> — drives the real monitor in the sandbox; sets OUT and RC
run() {
  OUT="$(env HOME="$SB/home" KAT_IDENTITY_ENV="$IDENV" PATH="$BIN:$PATH" \
             ALERT_SINK="$SB/alerts" KAT_FAKE_AUTH_SECRET_FILE="$SB/canon" \
             ${EXTRA[@]+"${EXTRA[@]}"} bash "${MON[@]}" "$@" 2>&1)"
  RC=$?
}

alerts()     { [ -f "$SB/alerts" ] && grep -c '^ALERT' "$SB/alerts" || echo 0; }
alert_text() { [ -f "$SB/alerts" ] && cat "$SB/alerts" || echo ''; }
log()        { [ -f "$1" ] && cat "$1" || echo ''; }
lines()      { [ -f "$1" ] && wc -l <"$1" | tr -d ' ' || echo 0; }
count_in()   { grep -c -- "$2" "$1" 2>/dev/null || echo 0; }
env_secret() { sed -n 's/^JWT_SECRET=//p' "$1" | head -1; }
# seed_hb [<age-seconds>] — plant a monitor heartbeat in the shared log so the
# meta cases start from a known freshness instead of "never ran".
seed_hb() {
  local age="${1:-0}" ts
  mkdir -p "$(dirname "$LOG")"
  ts="$(date -d "@$(( $(date +%s) - age ))" '+%Y-%m-%dT%H:%M:%S%z')"
  printf '%s HEARTBEAT monitor ok\n' "$ts" >>"$LOG"
}
fingerprint(){ printf '%s' "$1" | sha256sum | awk '{print $1}'; }

# ------------------------------------------------------- 0. harness sanity ---
echo
echo "== 0. harness: every fixture, stub and seam is in place =="
[ -s "$SUT" ] && ok "the script under test exists ($(wc -l <"$SUT") lines)" || bad "missing $SUT"
[ -s "$LIB" ] && ok "the shared canonical-source library exists ($(wc -l <"$LIB") lines)" || bad "missing $LIB"
for s in docker sleep alert.sh gotify-messages.sh jwt-secret-monitor.sh canonical_secret.sh; do
  [ -e "$BIN/$s" ] || bad "stub/copy '$s' missing from the sandbox bin"
done
reset_fixtures
reset_logs
if [ "$(env_secret "$IDENV")" = "$CANON" ]; then
  ok "the sandbox canonical source is readable (fixture sanity)"
else
  bad "fixture broken: the sandbox identity .env does not hold the canonical secret"
fi
has "$(cat "$SUT")" 'canonical_secret.sh' && ok "the monitor sources the shared canonical library" \
  || bad "the monitor does not reference canonical_secret.sh"
has "$(cat "$LIB")" 'KAT_IDENTITY_ENV_DEFAULT=/home/ubuntu/Projects/kommons/supabase-identity/docker/.env' \
  && ok "the canonical source path has ONE definition (the library)" \
  || bad "the library does not name the production canonical path"

# ------------------------------------------------ 1. clean run ------------- #
echo
echo "== 1. clean: every stack already matches the canonical secret =="
reset_logs; reset_fixtures
run monitor
[ "$RC" = 0 ] && ok "clean run exits 0" || bad "clean run exit=$RC want 0"
has "$(log "$LOG")" "OK all stacks match identity JWT_SECRET" && ok "a clean run writes the OK line" || bad "no OK line"
[ "$(count_in "$LOG" 'HEARTBEAT monitor ok')" = 1 ] && ok "exactly one heartbeat, verdict ok" || bad "heartbeat wrong: $(grep -c HEARTBEAT "$LOG")"
has "$(log "$LOG")" "REGISTRY built: 2 pre-cutover fingerprints" && ok "the registry holds the 2 real snapshots (placeholders skipped)" || bad "registry wrong: $(grep REGISTRY "$LOG")"
[ "$(alerts)" = 0 ] && ok "a clean run alerts nobody" || bad "a clean run sent $(alerts) alert(s)"
lacks "$(log "$LOG")" "$CANON" && ok "the canonical secret value is never logged" || bad "the canonical value leaked into the log"
has "$(log "$LOG")" "$(printf '%s' "$CANON" | sha256sum | cut -c1-16)" && ok "the fingerprint is logged instead" || bad "no fingerprint in the log"

# ------------------------------------------------ 2. drift ---------------- #
echo
echo "== 2. drift: reported and alerted, but never auto-repaired =="
reset_logs; reset_fixtures
printf 'JWT_SECRET=%s\n' "$DRIFT" >"$SB/home/Projects/kognitio/database/docker/.env"
run monitor
[ "$RC" = 1 ] && ok "drift exits 1" || bad "drift exit=$RC want 1"
has "$(log "$LOG")" "DRIFT kognitio:" && ok "the drifted stack is named" || bad "no DRIFT line: $(grep DRIFT "$LOG")"
[ "$(count_in "$LOG" 'HEARTBEAT monitor drift')" = 1 ] && ok "heartbeat verdict is drift" || bad "heartbeat wrong"
[ "$(env_secret "$SB/home/Projects/kognitio/database/docker/.env")" = "$DRIFT" ] \
  && ok "drift is NOT auto-repaired (the operator decides)" || bad "the monitor rewrote a merely-drifted .env"
has "$(alert_text)" "JWT Secret Drift Detected" && ok "a drift alert was fanned out" || bad "no drift alert"
[ "$(alerts)" = 4 ] && ok "the drift alert reached all four channels" || bad "alert count=$(alerts) want 4"
lacks "$(log "$LOG")" "$DRIFT" && ok "the drifted value is never logged" || bad "the drifted value leaked"

# ------------------------------------------------ 3. exact revert --------- #
echo
echo "== 3. exact revert: force-re-cut back to the canonical secret =="
reset_logs; reset_fixtures
printf 'JWT_SECRET=%s\n' "$STALE" >"$SB/home/Projects/katalogus/database/docker/.env"
run monitor
[ "$RC" = 1 ] && ok "a re-cut exits 1" || bad "re-cut exit=$RC want 1"
has "$(log "$LOG")" "REVERT DETECTED katalogus:" && ok "the exact revert is named as such" || bad "no REVERT DETECTED line"
has "$(log "$LOG")" "$(fingerprint "$STALE")" && ok "the pre-cutover fingerprint is logged (not the value)" || bad "fingerprint missing"
[ "$(env_secret "$SB/home/Projects/katalogus/database/docker/.env")" = "$CANON" ] \
  && ok "the .env was restored to the canonical secret" || bad "the .env is '$(env_secret "$SB/home/Projects/katalogus/database/docker/.env")'"
ls "$SB/home/Projects/katalogus/database/docker"/.env.bak.recut-auto.* >/dev/null 2>&1 \
  && ok "the reverted .env was backed up first" || bad "no re-cut backup"
has "$(log "$LOG")" "✓ running auth container confirms JWT_SECRET matches identity" \
  && ok "the running auth container was re-verified" || bad "auth verification missing: $(grep 'auth container' "$LOG")"
has "$(log "$LOG")" "DONE: at least one exact revert was auto-re-cut" && ok "the run concludes with the DONE summary" || bad "no DONE line"
[ "$(count_in "$LOG" 'HEARTBEAT monitor recut')" = 1 ] && ok "heartbeat verdict is recut" || bad "heartbeat wrong"
has "$(alert_text)" "JWT Exact-Revert + Auto Re-cut" && ok "the revert alert was fanned out" || bad "no revert alert"
lacks "$(log "$LOG")" "$STALE" && ok "the pre-cutover value itself is never logged" || bad "the reverted value leaked"

# ------------------------------------------------ 4. failed re-cut -------- #
echo
echo "== 4. a failed re-cut is loud, and says the secret was still restored =="
reset_logs; reset_fixtures
printf 'JWT_SECRET=%s\n' "$STALE2" >"$SB/home/Projects/kalcio/database/docker/.env"
EXTRA=(KAT_FAKE_COMPOSE_FAIL=1)
run monitor
EXTRA=()
[ "$RC" = 2 ] && ok "a failed re-cut exits 2" || bad "failed re-cut exit=$RC want 2"
has "$(log "$LOG")" "DONE: revert detected but re-cut FAILED — manual intervention required" && ok "the DONE summary reports the failure" || bad "no failure DONE line"
[ "$(count_in "$LOG" 'HEARTBEAT monitor failed')" = 1 ] && ok "heartbeat verdict is failed" || bad "heartbeat wrong"
has "$(alert_text)" "docker compose up --force-recreate failed" && ok "the operator alert explains what broke" || bad "failure alert missing"
[ "$(env_secret "$SB/home/Projects/kalcio/database/docker/.env")" = "$CANON" ] \
  && ok "the secret restore itself still happened" || bad "the .env was left reverted"

# ------------------------------------------------ 5. missing .env --------- #
echo
echo "== 5. a missing stack is a WARN, not a drift =="
reset_logs; reset_fixtures
rm -f "$SB/home/Projects/kollectio/database/docker/.env"
run monitor
[ "$RC" = 0 ] && ok "a missing .env does not fail the run" || bad "exit=$RC want 0"
has "$(log "$LOG")" "WARN kollectio: .env not found at" && ok "the missing stack is named" || bad "no WARN line"
[ "$(alerts)" = 0 ] && ok "a missing .env does not alert" || bad "unexpected alert"
[ "$(count_in "$LOG" 'HEARTBEAT monitor ok')" = 1 ] && ok "the monitor is still considered alive (heartbeat ok)" || bad "heartbeat wrong"

# ------------------------------------------------ 6. fatal ----------------- #
echo
echo "== 6. an unreadable canonical source is a FATAL, never a guess =="
reset_logs; reset_fixtures
mv "$IDENV" "$IDENV.gone"
run monitor
mv "$IDENV.gone" "$IDENV"
[ "$RC" = 1 ] && ok "the fatal path exits non-zero" || bad "exit=$RC want 1"
has "$(log "$LOG")" "FATAL identity .env not found at" && ok "the FATAL line names the canonical source" || bad "no FATAL line"
[ "$(count_in "$LOG" 'HEARTBEAT monitor fatal')" = 1 ] && ok "heartbeat verdict is fatal" || bad "heartbeat wrong"
has "$(alert_text)" "identity .env not found" && ok "the operator is alerted" || bad "no alert on the fatal path"

# ------------------------------------------------ 7. meta: liveness -------- #
echo
echo "== 7. meta: liveness alerts once per outage and announces recovery =="
reset_logs; reset_fixtures
seed_hb 7200
run meta
[ "$RC" = 1 ] && ok "a stale heartbeat exits 1" || bad "stale exit=$RC want 1"
has "$(log "$LIVENESS_LOG")" "STALE monitor:" && ok "the stale monitor is named" || bad "no STALE line"
has "$(alert_text)" "JWT Monitor Not Running" && ok "the liveness alert was fanned out" || bad "no liveness alert"
[ "$(alerts)" = 4 ] && ok "the liveness alert reached all four channels" || bad "alert count=$(alerts) want 4"
has "$(log "$STATE")" "monitor" && ok "the outage is remembered in the state file" || bad "state not written"

rm -f "$SB/alerts"
run meta
[ "$(alerts)" = 0 ] && ok "a second stale run does not re-alert" || bad "re-alerted $(alerts) time(s)"
has "$(log "$LIVENESS_LOG")" "alert already sent, not repeating" && ok "the log says why it stayed quiet" || bad "no 'not repeating' line"

rm -f "$SB/alerts"
seed_hb 0
run meta
[ "$RC" = 0 ] && ok "a fresh heartbeat exits 0" || bad "recovered exit=$RC want 0"
has "$(alert_text)" "JWT Monitor Running Again" && ok "recovery is announced" || bad "no recovery alert"
lacks "$(log "$LIVENESS_LOG")" "RECOVERED monitor" && bad "recovery not logged" || ok "recovery is logged"
[ -s "$STATE" ] && bad "the state file still lists the monitor" || ok "the state file was cleared on recovery"

# ------------------------------------------------ 8. meta: delivery -------- #
echo
echo "== 8. meta: the delivery dead-man's switch still fires =="
for case in "200000:heartbeat-stale" "-1:heartbeat-missing"; do
  age="${case%%:*}"; want="${case##*:}"
  reset_logs
  EXTRA=(GOTIFY_FAKE_AGE_TITLE="$age")
  run meta
  EXTRA=()
  [ "$RC" = 1 ] && ok "delivery age $age exits 1" || bad "age $age exit=$RC want 1"
  has "$(log "$DELIVERY_LOG")" "STALL $want:" && ok "classified as $want" || bad "want $want: $(grep STALL "$DELIVERY_LOG")"
  has "$(alert_text)" "JWT Alert Delivery Stalled" && ok "the stall alert was fanned out ($want)" || bad "no stall alert for $want"
done

reset_logs
EXTRA=(GOTIFY_FAKE_ERR=1)
run meta
EXTRA=()
[ "$RC" = 1 ] && ok "an unreadable history exits 1" || bad "unreadable exit=$RC want 1"
has "$(log "$DELIVERY_LOG")" "STALL history-unreadable:" && ok "classified as history-unreadable" || bad "wrong classification"

reset_logs; seed_hb 0
run meta
[ "$RC" = 0 ] && ok "a healthy delivery exits 0" || bad "healthy delivery exit=$RC want 0"
has "$(log "$DELIVERY_LOG")" 'OK delivery heartbeat: "JWT Daily Summary"' \
  && ok "the OK line keeps the exact prefix the daily summary parses" || bad "delivery OK line wrong"
has "$(log "$LIVENESS_LOG")" "OK all monitors running: monitor=ok" && ok "liveness reports the monitor healthy" || bad "liveness OK line wrong"
[ "$(alerts)" = 0 ] && ok "a healthy meta run alerts nobody" || bad "unexpected alert"

# ------------------------------------------------ 9. --check -------------- #
echo
echo "== 9. --check reports without touching anything =="
reset_logs; reset_fixtures
printf 'JWT_SECRET=%s\n' "$DRIFT" >"$SB/home/Projects/kognitio/database/docker/.env"
run monitor --check
[ "$RC" = 1 ] && ok "--check reports the drift (exit 1)" || bad "--check exit=$RC want 1"
has "$OUT" "verdict: drift" && ok "--check prints a verdict" || bad "no verdict in --check output"
[ "$(env_secret "$SB/home/Projects/kognitio/database/docker/.env")" = "$DRIFT" ] && ok "--check changed nothing" || bad "--check rewrote a .env"
[ "$(lines "$LOG")" = 0 ] && ok "--check wrote no log line" || bad "--check wrote $(lines "$LOG") log line(s)"
[ "$(alerts)" = 0 ] && ok "--check alerted nobody" || bad "--check alerted"
lacks "$OUT" "$CANON" && ok "--check does not print the secret value" || bad "--check leaked the canonical value"

reset_logs; reset_fixtures; seed_hb 0
run meta --check
[ "$RC" = 0 ] && ok "a healthy meta --check exits 0" || bad "meta --check exit=$RC want 0"
[ "$(lines "$LIVENESS_LOG")" = 0 ] && [ "$(lines "$DELIVERY_LOG")" = 0 ] \
  && ok "meta --check wrote no log line" || bad "meta --check wrote to the logs"
[ "$(alerts)" = 0 ] && ok "meta --check alerted nobody" || bad "meta --check alerted"

# ------------------------------------------------ 10. summary vocabulary --- #
echo
echo "== 10. the daily summary can still parse every line this script writes =="
# Re-implement the summary's two rules exactly: the event keyword set, and the
# bare-word-before-the-colon stack rule.  A line the summary would drop on the
# floor, or mis-attribute, is a regression the daily digest would inherit.
reset_logs; reset_fixtures
printf 'JWT_SECRET=%s\n' "$DRIFT"   >"$SB/home/Projects/kognitio/database/docker/.env"
printf 'JWT_SECRET=%s\n' "$STALE"   >"$SB/home/Projects/katalogus/database/docker/.env"
rm -f "$SB/home/Projects/kollectio/database/docker/.env"
run monitor || true

KNOWN_STACKS="kommons katalogus kalcio kognitio kollectio kapaxinfiniti"
unparsed=0; misattributed=0; unknown_event=0; heartbeat_lines=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  # The summary filters on a parseable timestamp first, so a line without one
  # (docker's own recreate output, appended to the log on purpose) is not an
  # event line at all and must not be judged as one.
  case "${line%% *}" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*) : ;;
    *) continue ;;
  esac
  rest="${line#* }"                       # everything after the timestamp
  case "$rest" in
    OK*)    : ;;
    DRIFT*) : ;;
    WARN*)  : ;;
    "REVERT DETECTED"*) : ;;
    REVERT*) : ;;
    "DONE:"*) : ;;
    REGISTRY*) : ;;
    FATAL*) : ;;
    HEARTBEAT*) heartbeat_lines=$((heartbeat_lines+1)) ;;
    *) unknown_event=$((unknown_event+1)); echo "      | unrecognised: $line" ;;
  esac
  case "$rest" in
    DRIFT*|WARN*|"REVERT DETECTED"*|REVERT*)
      head="${rest%%:*}"
      head="${head#DRIFT }"; head="${head#WARN }"
      head="${head#REVERT DETECTED }"; head="${head#REVERT }"
      case "$head" in
        *[!A-Za-z0-9._-]*|*\ *) misattributed=$((misattributed+1)); echo "      | no stack before colon: $line" ;;
        *) case " $KNOWN_STACKS " in *" $head "*) : ;; *) misattributed=$((misattributed+1)); echo "      | unknown stack '$head': $line" ;; esac ;;
      esac ;;
  esac
done <"$LOG"
[ "$unparsed" = 0 ] && [ "$unknown_event" = 0 ] \
  && ok "every event line uses the vocabulary the summary parses" \
  || bad "$unknown_event line(s) use an event the summary ignores"
[ "$misattributed" = 0 ] && ok "every incident line is attributed to a real stack" \
  || bad "$misattributed incident line(s) would be filed host-level or wrong"
[ "$heartbeat_lines" = 1 ] && ok "exactly one heartbeat per run (so liveness can read it)" \
  || bad "$heartbeat_lines heartbeat(s) in one run"
has "$(log "$LOG")" "DRIFT kognitio:" && has "$(log "$LOG")" "REVERT DETECTED katalogus:" && has "$(log "$LOG")" "WARN kollectio:" \
  && ok "the three incident kinds survived the merge in one log" || bad "an incident kind is missing from the merged log"

# ------------------------------------------------ 11. no staging ----------- #
echo
echo "== 11. the stale staging entry is gone for good =="
lacks "$(cat "$SUT")" "katalogus-staging" && ok "the monitor has no staging stack" || bad "a staging reference survived in the monitor"
[ "$(grep -c '^  "' <<<"$(sed -n '/^STACKS=(/,/^)/p' "$SUT")")" = 6 ] \
  && ok "exactly six stacks are watched (identity + five projects)" \
  || bad "stack count wrong: $(sed -n '/^STACKS=(/,/^)/p' "$SUT" | grep -c '|')"

# --stacks is the one authority other tools (the daily summary) consult to
# learn what is still watched, so its output shape is API: names only, one per
# line, nothing else — a stray extra line would be read as a stack name.
STACKS_OUT="$("$BIN/jwt-secret-monitor.sh" --stacks 2>&1)"; STACKS_RC=$?
[ "$STACKS_RC" = 0 ] && ok "--stacks exits 0" || bad "--stacks exit=$STACKS_RC"
[ "$STACKS_OUT" = "$(printf '%s\n' $KNOWN_STACKS)" ] \
  && ok "--stacks prints exactly the watched stack names, one per line" \
  || bad "--stacks output was: $(printf '%s' "$STACKS_OUT" | tr '\n' ' ')"

# ------------------------------------------------ 12. crontab rewire ------- #
echo
echo "== 12. the installer installs the whole watch: three entries, nothing retired =="
# A faithful copy of the live crontab at the time of the switch (credentials
# redacted) — including the multi-line comment runs, because those are what a
# line-by-line rewriter shreds.
CRON_FIX="$WORK/crontab.before"
cat >"$CRON_FIX" <<'CRON'
# JWT secret drift watchdog — runs every 15 min
# Configure alerts by setting ONE OR MORE of:
#   ALERT_WEBHOOK_URL=<your-incoming-webhook-url>
#   ALERT_EMAIL=<recipient@example.com>
#   BREVO_API_KEY=<brevo-sendinblue-api-key>
#   BREVO_SENDER=<sender-email>       (default: noreply@mediasart.com)
#   BREVO_SENDER_NAME=<sender-name>    (default: mediasart)
#   GOTIFY_URL=<gotify-server-url>    (e.g. https://notify.mediasart.com)
#   GOTIFY_APP_TOKEN=<gotify-app-token>
# mail(1) must be installed for local mail() alerts.
# Brevo API used when BREVO_API_KEY + ALERT_EMAIL are set (does not need mailx).
# Gotify used when GOTIFY_URL + GOTIFY_APP_TOKEN are set (priority default:
#   8 for drift/revert alerts, 5 for daily summary).
ALERT_EMAIL=kjhrono@gmail.com
BREVO_API_KEY=not-a-real-key
GOTIFY_URL=https://notify.mediasart.com
GOTIFY_APP_TOKEN=not-a-real-token
*/15 * * * * ~/bin/jwt-secret-drift-check.sh >/dev/null 2>&1
*/15 * * * * ~/bin/jwt-secret-revert-watchdog.sh >/dev/null 2>&1
0 9 * * * ~/bin/jwt-secret-daily-summary.sh >/dev/null 2>&1

# Weekly housekeeping — prune .env.bak.* snapshots older than RETENTION_DAYS
# (keeps the newest snapshot per directory as a rollback floor; set
# KEEP_PER_DIR=0 to disable the floor, RETENTION_DAYS to change the window).
RETENTION_DAYS=30
0 3 * * 0 ~/bin/cleanup-env-backups.sh >/dev/null 2>&1

# Dead-man switch: alert (email/Brevo, not just Gotify) when the alert
# pipeline stops delivering its daily heartbeat.
20 * * * * ~/bin/jwt-secret-delivery-watchdog.sh >/dev/null 2>&1

# Bound the Gotify alert-history database (prunes messages older than
# RETENTION_DAYS days, keeping the newest KEEP_NEWEST rows).
30 3 * * 0 ~/bin/gotify-retention-sweep.sh >/dev/null 2>&1

# Weekly trend digest — emails the Gotify alert-history report so the trend
# arrives unprompted. REPORT_HOURS is the window (168 = one week). Delivery is
# by email (Brevo when BREVO_API_KEY + ALERT_EMAIL are set, else mail(1)) and
# never through Gotify, so the digest stays out of the history it reports on.
REPORT_HOURS=168
0 8 * * 1 ~/bin/gotify-report-digest.sh >/dev/null 2>&1

# Liveness check for the 15-minute monitors. The Gotify heartbeat proves the
# pipeline delivered its daily summary; it cannot prove that drift-check and
# the revert watchdog are still running, because they are silent while the
# secrets are healthy. MAX_AGE_MINUTES is how stale a heartbeat may be before
# it is called dead (45 = three missed 15-minute cycles); reports once per
# outage and once on recovery, with state in ~/logs/jwt-secret-liveness.state.
MAX_AGE_MINUTES=45
0,30 * * * * ~/bin/jwt-secret-liveness-check.sh >/dev/null 2>&1
CRON

CRON_PY="$WORK/build_crontab.py"
awk '/^  python3 - "\$1" "\$2" <<.PY.$/{f=1;next} /^PY$/{f=0} f' "$INSTALLER" >"$CRON_PY"
if [ -s "$CRON_PY" ]; then
  ok "extracted the installer's crontab rewriter ($(wc -l <"$CRON_PY" | tr -d ' ') lines)"
else
  bad "could not extract the crontab rewriter from the installer"
fi
# Retiring the scripts without the schedule that ran them makes the rollback
# half a rollback, so the bundle has to carry the pre-change crontab.
if has "$(cat "$INSTALLER")" 'crontab.before' && has "$(cat "$INSTALLER")" 'ROLLBACK.txt'; then
  ok "the installer leaves a self-contained rollback bundle"
else
  bad "no rollback bundle: the old scripts would be retired with no way back to their schedule"
fi
CRON_AFTER="$WORK/crontab.after"
if python3 "$CRON_PY" "$CRON_FIX" "$CRON_AFTER" >/dev/null 2>&1; then
  ok "the rewriter ran against a replica of the live crontab"
else
  bad "the rewriter failed on the fixture"
fi
if [ -f "$CRON_AFTER" ]; then
  n_new="$(grep -c 'jwt-secret-monitor.sh' "$CRON_AFTER")"
  n_sum="$(grep -c 'jwt-secret-daily-summary.sh' "$CRON_AFTER")"
  n_old="$(grep -cE 'jwt-secret-(drift-check|revert-watchdog|delivery-watchdog|liveness-check)\.sh' "$CRON_AFTER")"
  [ "$n_new" = 2 ] && ok "exactly two jwt-secret-monitor.sh entries" || bad "found $n_new new entries, want 2"
  [ "$n_sum" = 1 ] && ok "exactly one jwt-secret-daily-summary.sh entry (moved into the block)" || bad "found $n_sum daily-summary entries, want 1"
  [ "$n_old" = 0 ] && ok "no retired entry survives" || bad "$n_old retired entry/entries survived"
  has "$(cat "$CRON_AFTER")" "jwt-secret-monitor.sh monitor" && ok "the monitor entry is scheduled" || bad "no monitor entry"
  has "$(cat "$CRON_AFTER")" "jwt-secret-monitor.sh meta" && ok "the meta entry is scheduled" || bad "no meta entry"
  has "$(cat "$CRON_AFTER")" "jwt-secret-daily-summary.sh" && ok "the daily summary entry is scheduled" || bad "the daily summary entry was dropped"
  has "$(cat "$CRON_AFTER")" "gotify-report-digest.sh" && ok "the trend digest entry is untouched" || bad "the trend digest entry was dropped"
  has "$(cat "$CRON_AFTER")" "gotify-retention-sweep.sh" && ok "the Gotify sweep entry is untouched" || bad "the Gotify sweep entry was dropped"
  has "$(cat "$CRON_AFTER")" "cleanup-env-backups.sh" && ok "the backup-prune entry is untouched" || bad "the backup-prune entry was dropped"
  has "$(cat "$CRON_AFTER")" "MAX_AGE_MINUTES=45" && ok "MAX_AGE_MINUTES survives" || bad "MAX_AGE_MINUTES was dropped"
  has "$(cat "$CRON_AFTER")" "RETENTION_DAYS=30" && ok "RETENTION_DAYS survives" || bad "RETENTION_DAYS was dropped"
  has "$(cat "$CRON_AFTER")" "REPORT_HOURS=168" && ok "REPORT_HOURS survives" || bad "REPORT_HOURS was dropped"
  has "$(cat "$CRON_AFTER")" "ALERT_WEBHOOK_URL=<your-incoming-webhook-url>" \
    && ok "the alert-configuration docs survive (the new entries use the same vars)" \
    || bad "the alert-configuration documentation was swept away with the old entries"
  has "$(cat "$CRON_AFTER")" "GOTIFY_APP_TOKEN=<gotify-app-token>" && ok "the Gotify var docs survive" || bad "the Gotify var docs were dropped"
  lacks "$(cat "$CRON_AFTER")" "# pipeline stops delivering its daily heartbeat." \
    && ok "no dangling fragment is left from the retired prose" \
    || bad "a dangling comment fragment survived"
  lacks "$(cat "$CRON_AFTER")" "# pipeline delivered its daily summary" \
    && ok "no dangling fragment is left from the retired liveness prose" \
    || bad "a dangling comment fragment survived"
  lacks "$(cat "$CRON_AFTER")" "JWT secret drift watchdog — runs every 15 min" \
    && ok "the original header line is gone" \
    || bad "the header still names the four-script setup"
  lacks "$(cat "$CRON_AFTER")" "# JWT secret watch — one program on two entries" \
    && ok "the interim header line is gone too" \
    || bad "a legacy header line survived"
  has "$(cat "$CRON_AFTER")" "managed by tool/install_jwt_secret_watch.sh" \
    && ok "the managed block names its installer" \
    || bad "the managed block does not name the installer"
  # All three schedules must sit INSIDE the one managed block, between its
  # markers, so a later run replaces exactly them and nothing else.
  blk="$(sed -n '/^# >>> jwt-secret watch/,/^# <<< jwt-secret watch/p' "$CRON_AFTER")"
  [ "$(printf '%s\n' "$blk" | grep -c 'jwt-secret-monitor.sh monitor')" = 1 ] \
    && [ "$(printf '%s\n' "$blk" | grep -c 'jwt-secret-monitor.sh meta')" = 1 ] \
    && [ "$(printf '%s\n' "$blk" | grep -c 'jwt-secret-daily-summary.sh')" = 1 ] \
    && ok "all three entries live inside the managed block" \
    || bad "an entry sits outside the managed block"
  # An env var set AFTER its entry is invisible to it: the new entries must come
  # last, below every assignment in the file.
  last_env="$(grep -n '^[A-Z_][A-Z0-9_]*=' "$CRON_AFTER" | tail -1 | cut -d: -f1)"
  first_new="$(grep -n 'jwt-secret-monitor.sh' "$CRON_AFTER" | head -1 | cut -d: -f1)"
  [ "$last_env" -lt "$first_new" ] \
    && ok "the new entries sit below every env assignment (they inherit it)" \
    || bad "an env assignment (line $last_env) comes after the entries (line $first_new) — it would not apply"
  has "$(cat "$CRON_AFTER")" "Liveness check for the 15-minute monitors" \
    && bad "a comment describing a retired entry survived" \
    || ok "the retired entries' stale comments are gone"
  [ "$(grep -c '^# >>> jwt-secret watch' "$CRON_AFTER")" = 1 ] && [ "$(grep -c '^# <<< jwt-secret watch' "$CRON_AFTER")" = 1 ] \
    && ok "exactly one managed block" || bad "$(grep -c '^# >>> jwt-secret watch' "$CRON_AFTER") block(s) present"
  # Idempotency: running the rewriter again must not duplicate or lose anything.
  CRON_AGAIN="$WORK/crontab.again"
  python3 "$CRON_PY" "$CRON_AFTER" "$CRON_AGAIN" >/dev/null 2>&1
  [ "$(grep -c 'jwt-secret-monitor.sh' "$CRON_AGAIN")" = 2 ] \
    && [ "$(grep -c 'jwt-secret-daily-summary.sh' "$CRON_AGAIN")" = 1 ] \
    && ok "re-running the rewriter is idempotent" \
    || bad "a second pass produced $(grep -c 'jwt-secret-monitor.sh' "$CRON_AGAIN") monitor + $(grep -c 'jwt-secret-daily-summary.sh' "$CRON_AGAIN") summary entries"
  [ "$(grep -c '^# >>> jwt-secret watch' "$CRON_AGAIN")" = 1 ] \
    && ok "a second pass replaces the block instead of stacking another" \
    || bad "a second pass left $(grep -c '^# >>> jwt-secret watch' "$CRON_AGAIN") managed blocks"
  diff -q <(grep -v '^$' "$CRON_AFTER") <(grep -v '^$' "$CRON_AGAIN") >/dev/null \
    && ok "a second pass is byte-identical (modulo blank lines)" \
    || bad "a second pass changed the file: $(diff <(grep -v '^$' "$CRON_AFTER") <(grep -v '^$' "$CRON_AGAIN") | head -4 | tr '\n' ' ')"
fi

echo
echo "================================================"
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" = 0 ] || exit 1
