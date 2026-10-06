#!/usr/bin/env bash
# test_watchdog_identity_skip.sh
#
# Verifies that the JWT-secret monitors treat the kommons (identity) stack
# as the source of truth for the shared secret.  The identity stack defines
# what "correct" is, so no monitor may re-cut it, leave a backup beside it,
# report it as drifting, or attribute an incident to it — while every other
# stack must still be checked normally.
#
#   jwt-secret-revert-watchdog.sh — must never re-cut kommons (Phases 1-3).
#   jwt-secret-drift-check.sh     — must use kommons as the reference and
#                                   never report it as drifting (Phases 4-5).
#   jwt-secret-daily-summary.sh   — must digest real runs without blaming
#                                   kommons, yet still report an incident if
#                                   one ever appeared (Phase 6).
#
# The test is hermetic: it runs the real scripts with HOME pointed at a
# throwaway sandbox and stubbed `docker`/`curl` on PATH, so no project .env,
# container, or log outside the sandbox is touched.
#
# Phases
#   Phase 1  behaviour        — real script, real STACKS layout.  A stored
#                               pre-cutover secret in kalcio's .env is
#                               re-cut while kommons is left untouched.
#   Phase 2  guard            — the same script with ONLY the kommons STACKS
#                               entry decoupled onto a probe .env, so the
#                               identity-skip guard is load-bearing: the
#                               probe holds a registry-matching secret and
#                               must still be left alone.
#   Phase 3  negative control — Phase 2's script with the guard line removed
#                               MUST re-cut the probe.  This proves the
#                               Phase 2 fixture is "hot" (it would fail
#                               without the guard) instead of passing
#                               vacuously.
#   Phase 4  drift-check      — kommons is the reference, never a drifting
#                               stack, and the other stacks are still
#                               compared; a clean tree still exits 0.
#   Phase 5  drift-check      — a missing identity .env is FATAL, not a
#                               silently skipped stack.
#   Phase 6  daily summary    — a real watchdog + drift-check run is digested
#                               without mentioning kommons, plus a negative
#                               control proving a kommons incident WOULD be
#                               reported if the guard ever failed.
#
# Usage:
#   tool/test_watchdog_identity_skip.sh
#   WATCHDOG=~/bin/jwt-secret-revert-watchdog.sh tool/test_watchdog_identity_skip.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Prefer copies sitting beside this test — the deployed ~/bin layout — and
# fall back to the in-repo tool/ directory.  Both resolve to tool/ in the
# repo, so only the deployed case changes.
if [ -f "${SCRIPT_DIR}/jwt-secret-revert-watchdog.sh" ]; then
  DEFAULT_DIR="$SCRIPT_DIR"
else
  DEFAULT_DIR="$REPO_ROOT/tool"
fi

WATCHDOG="${WATCHDOG:-$DEFAULT_DIR/jwt-secret-revert-watchdog.sh}"
DRIFT_CHECK="${DRIFT_CHECK:-$DEFAULT_DIR/jwt-secret-drift-check.sh}"
SUMMARY="${SUMMARY:-$DEFAULT_DIR/jwt-secret-daily-summary.sh}"

for script in "$WATCHDOG" "$DRIFT_CHECK" "$SUMMARY"; do
  if [ ! -f "$script" ]; then
    echo "FATAL: script not found at $script" >&2
    exit 2
  fi
  # Each of these sources alert.sh from its own directory.
  if [ ! -f "$(dirname "$script")/alert.sh" ]; then
    echo "FATAL: alert.sh not found beside $script" >&2
    exit 2
  fi
done

# Fixture secret values — never real secrets, only distinguishable strings.
IDENTITY_VALUE='identity-secret-AAAA'
PRECUTOVER_VALUE='pre-cutover-secret-BBBB'
UNKNOWN_VALUE='unknown-secret-CCCC'

GUARD_LINE='if [ "$stack" = "kommons" ]; then continue; fi'

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# The watchdog sources alert.sh from its own directory; the patched copies
# used in phases 2/3 live in the sandbox, so keep a copy beside them.
WATCHDOG_DIR="$(cd "$(dirname "$WATCHDOG")" && pwd)"
if [ ! -f "$WATCHDOG_DIR/alert.sh" ]; then
  echo "FATAL: alert.sh not found beside watchdog at $WATCHDOG_DIR" >&2
  exit 2
fi
cp "$WATCHDOG_DIR/alert.sh" "$SANDBOX/alert.sh"

pass=0
fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi
}
assert_present() {
  if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1 (missing '$3' in $2)"; fi
}
assert_absent() {
  if grep -qF -- "$3" "$2" 2>/dev/null; then bad "$1 (found '$3' in $2)"; else ok "$1"; fi
}

secret_of() {
  local out
  out="$(grep -E '^JWT_SECRET=' "$1" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  out="${out%\"}"; out="${out#\"}"
  printf '%s' "$out"
}

# --------------------------------------------------------------------------- #
# Sandbox construction
# --------------------------------------------------------------------------- #

# Stack layout mirroring the watchdog's STACKS array (name|env|compose dir).
STACK_DIRS=(
  "kommons|Projects/kommons/supabase-identity/docker"
  "katalogus|Projects/katalogus/database/docker"
  "katalogus-staging|Projects/katalogus/staging/docker"
  "kalcio|Projects/kalcio/database/docker"
  "kognitio|Projects/kognitio/database/docker"
  "kollectio|Projects/kollectio/database/docker"
  "kapaxinfiniti|Projects/kapaxinfiniti/database/docker"
)

docker_stub() {
  local root="$1"
  mkdir -p "$root/bin"
  cat > "$root/bin/docker" <<'STUB'
#!/usr/bin/env bash
# Test stub: records every invocation with its working directory.
printf '%s\t%s\n' "$PWD" "$*" >> "$DOCKER_LOG"
case "${1:-}" in
  compose) [ "${2:-}" = "ps" ] && echo "fake-auth-ctr"; exit 0 ;;
  inspect) echo "healthy"; exit 0 ;;
  exec)    printf '%s\n' "$STUB_IDENTITY_SECRET"; exit 0 ;;
esac
exit 0
STUB
  chmod +x "$root/bin/docker"
}

write_secret() { # <file> <value>
  mkdir -p "$(dirname "$1")"
  printf 'JWT_SECRET=%s\n' "$2" > "$1"
}

# Phase 1 fixture: kalcio reverted to a stored pre-cutover secret.
build_behaviour_sandbox() {
  local root="$1"
  mkdir -p "$root/logs"
  for entry in "${STACK_DIRS[@]}"; do
    write_secret "$root/${entry#*|}/.env" "$IDENTITY_VALUE"
  done
  # Registry seed + a genuine exact revert in kalcio.
  write_secret "$root/Projects/kalcio/database/docker/.env.bak.old" "$PRECUTOVER_VALUE"
  write_secret "$root/Projects/kalcio/database/docker/.env" "$PRECUTOVER_VALUE"
  # Plain drift (unknown secret) must not be re-cut.
  write_secret "$root/Projects/kognitio/database/docker/.env" "$UNKNOWN_VALUE"
  docker_stub "$root"
}

# Guard fixture: the identity stack itself presents a registry-matching
# secret, so only the kommons skip can prevent an action.
build_guard_sandbox() {
  local root="$1"
  mkdir -p "$root/logs"
  for entry in "${STACK_DIRS[@]}"; do
    write_secret "$root/${entry#*|}/.env" "$IDENTITY_VALUE"
  done
  write_secret "$root/Projects/kognitio/database/docker/.env.bak.seed" "$PRECUTOVER_VALUE"
  write_secret "$root/Projects/kommons/supabase-identity/docker/.env.kommons-probe" "$PRECUTOVER_VALUE"
  docker_stub "$root"
}

run_watchdog() { # <sandbox root> <script>
  env -i HOME="$1" \
         PATH="$1/bin:/usr/bin:/bin" \
         DOCKER_LOG="$1/docker.log" \
         STUB_IDENTITY_SECRET="$IDENTITY_VALUE" \
         bash "$2"
}

run_drift_check() { # <sandbox root> [script]
  # No alert env vars, so the script also logs its OK line for a clean tree.
  env -i HOME="$1" PATH="$1/bin:/usr/bin:/bin" bash "${2:-$DRIFT_CHECK}"
}

run_summary() { # <sandbox root> <curl capture file>
  # The webhook channel is enabled so the digest body can be captured.
  env -i HOME="$1" PATH="$1/bin:/usr/bin:/bin" \
         LOG="$1/logs/jwt-secret-drift.log" \
         ALERT_WEBHOOK_URL="https://webhook.invalid/hook" \
         CURL_LOG="$2" \
         bash "$SUMMARY"
}

curl_stub() { # <root>
  mkdir -p "$1/bin"
  cat > "$1/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf -- '--- curl call ---\n' >> "$CURL_LOG"
for arg in "$@"; do printf '%s\n' "$arg" >> "$CURL_LOG"; done
exit 0
STUB
  chmod +x "$1/bin/curl"
}

# Every stack present with the identity secret; callers then introduce drift.
build_stack_tree() { # <root>
  mkdir -p "$1/logs"
  for entry in "${STACK_DIRS[@]}"; do
    write_secret "$1/${entry#*|}/.env" "$IDENTITY_VALUE"
  done
}

# --------------------------------------------------------------------------- #
# Phase 1 — behaviour on the real script
# --------------------------------------------------------------------------- #

echo "Phase 1: real watchdog ignores kommons while re-cutting a genuine revert"
P1="$SANDBOX/phase1"
build_behaviour_sandbox "$P1"

rc=0
run_watchdog "$P1" "$WATCHDOG" > "$P1/watchdog.out" 2>&1 || rc=$?
LOG1="$P1/logs/jwt-secret-drift.log"
IDENTITY_ENV1="$P1/Projects/kommons/supabase-identity/docker/.env"
KALCIO_ENV1="$P1/Projects/kalcio/database/docker/.env"

echo "  (watchdog exit $rc; log tail:)"
sed 's/^/    /' "$LOG1" 2>/dev/null | tail -6

# The run must actually have done something, or the assertions are vacuous.
assert_present "watchdog ran to completion" "$LOG1" "REGISTRY built"
assert_present "genuine revert in kalcio detected and re-cut" "$LOG1" "REVERT DETECTED kalcio"
assert_eq "kalcio .env restored to the identity secret" "$(secret_of "$KALCIO_ENV1")" "$IDENTITY_VALUE"
if [ -n "$(find "$P1/Projects/kalcio/database/docker" -name '.env.bak.recut-auto.*' -print -quit 2>/dev/null)" ]; then
  ok "kalcio received a re-cut backup"
else
  bad "kalcio received a re-cut backup (none found)"
fi
assert_eq "plain drift in kognitio left alone" \
  "$(secret_of "$P1/Projects/kognitio/database/docker/.env")" "$UNKNOWN_VALUE"

# kommons / identity must be untouched.
assert_eq "identity .env unchanged" "$(secret_of "$IDENTITY_ENV1")" "$IDENTITY_VALUE"
assert_absent "no REVERT line for kommons in the log" "$LOG1" "kommons"
if [ -n "$(find "$P1/Projects/kommons/supabase-identity/docker" -name '.env.bak.*' -print -quit 2>/dev/null)" ]; then
  bad "no backup written beside the identity .env (found one)"
else
  ok "no backup written beside the identity .env"
fi
assert_absent "docker never invoked from the identity stack directory" "$P1/docker.log" "$P1/Projects/kommons/"
assert_present "docker was invoked from the kalcio stack directory" "$P1/docker.log" "$P1/Projects/kalcio/"

# --------------------------------------------------------------------------- #
# Phase 2 / 3 — the guard itself
# --------------------------------------------------------------------------- #

echo
echo "Phase 2: identity-skip guard is load-bearing (decoupled kommons fixture)"

if ! grep -qF -- "$GUARD_LINE" "$WATCHDOG"; then
  bad "could not find the identity-skip guard line in $WATCHDOG"
  bad "update this test to match the watchdog's current guard"
else
  ok "identity-skip guard line present in the watchdog"

  # Decouple only the kommons STACKS env path onto a probe file.
  PATCHED="$SANDBOX/watchdog-probe.sh"
  sed "s#\"kommons|\${IDENTITY_ENV}|#\"kommons|\${HOME}/Projects/kommons/supabase-identity/docker/.env.kommons-probe|#" \
    "$WATCHDOG" > "$PATCHED"
  if grep -qF -- ".env.kommons-probe" "$PATCHED"; then
    ok "kommons STACKS entry decoupled onto the probe .env"
  else
    bad "could not decouple the kommons STACKS entry (watchdog layout changed?)"
  fi

  if grep -qF -- ".env.kommons-probe" "$PATCHED"; then
    P2="$SANDBOX/phase2"
    build_guard_sandbox "$P2"
    rc=0
    run_watchdog "$P2" "$PATCHED" > "$P2/watchdog.out" 2>&1 || rc=$?
    LOG2="$P2/logs/jwt-secret-drift.log"
    PROBE2="$P2/Projects/kommons/supabase-identity/docker/.env.kommons-probe"

    assert_present "patched watchdog ran to completion" "$LOG2" "REGISTRY built"
    assert_present "patched watchdog found nothing to act on" "$LOG2" "no exact reverts detected"
    # The liveness check measures these, so a run must always leave one behind.
    assert_present "the watchdog leaves a liveness heartbeat" "$LOG2" "HEARTBEAT revert-watchdog "
    assert_eq "identity .env unchanged" \
      "$(secret_of "$P2/Projects/kommons/supabase-identity/docker/.env")" "$IDENTITY_VALUE"
    assert_eq "probe (kommons) secret NOT re-cut — guard held" "$(secret_of "$PROBE2")" "$PRECUTOVER_VALUE"
    assert_absent "no REVERT line for kommons in the log" "$LOG2" "kommons"
    assert_absent "docker never invoked from the identity stack directory" "$P2/docker.log" "$P2/Projects/kommons/"
    assert_eq "watchdog reported no reverse action (exit 0)" "$rc" "0"

    echo
    echo "Phase 3: negative control — the same fixture without the guard must act"

    NOGUARD="$SANDBOX/watchdog-probe-noguard.sh"
    grep -vF -- "$GUARD_LINE" "$PATCHED" > "$NOGUARD"
    if grep -qF -- "$GUARD_LINE" "$NOGUARD"; then
      bad "failed to remove the guard line for the negative control"
    else
      ok "guard line removed for the negative control"
      P3="$SANDBOX/phase3"
      build_guard_sandbox "$P3"
      rc=0
      run_watchdog "$P3" "$NOGUARD" > "$P3/watchdog.out" 2>&1 || rc=$?
      LOG3="$P3/logs/jwt-secret-drift.log"
      PROBE3="$P3/Projects/kommons/supabase-identity/docker/.env.kommons-probe"

      assert_present "un-guarded watchdog ran to completion" "$LOG3" "REGISTRY built"
      assert_eq "fixture is hot: probe re-cut without the guard" "$(secret_of "$PROBE3")" "$IDENTITY_VALUE"
      assert_present "probe re-cut logged as a revert without the guard" "$LOG3" "REVERT DETECTED kommons"
      assert_present "docker invoked from the identity stack directory without the guard" \
        "$P3/docker.log" "$P3/Projects/kommons/"
    fi
  fi
fi

# --------------------------------------------------------------------------- #
# Phase 4 — drift-check: kommons is the reference, never a drifting stack
# --------------------------------------------------------------------------- #

echo
echo "Phase 4: drift-check never reports kommons as drifting"

P4="$SANDBOX/phase4"
build_stack_tree "$P4"
docker_stub "$P4"
# One consumer drifts; kommons (the reference) and the rest still match.
write_secret "$P4/Projects/kalcio/database/docker/.env" "$UNKNOWN_VALUE"
IDENTITY4="$P4/Projects/kommons/supabase-identity/docker/.env"
IDENTITY4_MTIME="$(stat -c %Y "$IDENTITY4")"

rc=0
run_drift_check "$P4" > "$P4/drift.out" 2>&1 || rc=$?
LOG4="$P4/logs/jwt-secret-drift.log"

assert_eq "drift-check exits 1 when a consumer drifts" "$rc" "1"
assert_present "the drifting consumer is reported" "$LOG4" "DRIFT kalcio"
assert_absent "kommons is never reported as drifting" "$LOG4" "DRIFT kommons"
assert_absent "kommons is not mentioned in the drift log at all" "$LOG4" "kommons"
assert_eq "the identity .env is unchanged" "$(secret_of "$IDENTITY4")" "$IDENTITY_VALUE"
assert_eq "the identity .env was not rewritten" "$(stat -c %Y "$IDENTITY4")" "$IDENTITY4_MTIME"
if [ -n "$(find "$P4/Projects/kommons/supabase-identity/docker" -name '.env.bak.*' -print -quit 2>/dev/null)" ]; then
  bad "drift-check left no backup beside the identity .env (found one)"
else
  ok "drift-check left no backup beside the identity .env"
fi
if [ -f "$P4/docker.log" ]; then
  bad "drift-check is read-only and never invoked docker"
else
  ok "drift-check is read-only and never invoked docker"
fi

# A clean tree must exit 0: kommons matching itself must not read as drift.
P4B="$SANDBOX/phase4-clean"
build_stack_tree "$P4B"
rc=0
run_drift_check "$P4B" > "$P4B/drift.out" 2>&1 || rc=$?
LOG4B="$P4B/logs/jwt-secret-drift.log"
assert_eq "a clean tree exits 0" "$rc" "0"
assert_present "a clean run is logged as OK" "$LOG4B" "OK all stacks match identity JWT_SECRET"
assert_present "drift-check leaves a liveness heartbeat" "$LOG4B" "HEARTBEAT drift-check "
assert_absent "the clean log never mentions kommons" "$LOG4B" "kommons"

# Negative control: kommons is spared ONLY because it is the reference itself,
# not because the loop filters it.  Decoupling its ENV_PATHS entry onto a
# probe file holding a different secret must produce a DRIFT for kommons —
# otherwise the assertions above could not fail and would prove nothing.
KOMMONS_ENTRY='  "kommons|${IDENTITY_ENV}"'
if ! grep -qF -- "$KOMMONS_ENTRY" "$DRIFT_CHECK"; then
  bad "could not find the kommons ENV_PATHS entry in drift-check"
  bad "update this test to match drift-check's current layout"
else
  ok "kommons ENV_PATHS entry present in drift-check"

  PATCHED_DRIFT="$SANDBOX/drift-check-probe.sh"
  sed "s#\"kommons|\${IDENTITY_ENV}\"#\"kommons|\${HOME}/Projects/kommons/supabase-identity/docker/.env.kommons-probe\"#" \
    "$DRIFT_CHECK" > "$PATCHED_DRIFT"
  if grep -qF -- ".env.kommons-probe" "$PATCHED_DRIFT"; then
    ok "kommons ENV_PATHS entry decoupled onto the probe .env"
  else
    bad "could not decouple the kommons ENV_PATHS entry (drift-check layout changed?)"
  fi

  if grep -qF -- ".env.kommons-probe" "$PATCHED_DRIFT"; then
    P4C="$SANDBOX/phase4-control"
    build_stack_tree "$P4C"
    write_secret "$P4C/Projects/kommons/supabase-identity/docker/.env.kommons-probe" "$UNKNOWN_VALUE"
    rc=0
    run_drift_check "$P4C" "$PATCHED_DRIFT" > "$P4C/drift.out" 2>&1 || rc=$?
    LOG4C="$P4C/logs/jwt-secret-drift.log"
    assert_present "control fixture is hot: decoupled kommons IS reported" \
      "$LOG4C" "DRIFT kommons"
    assert_eq "control: the real identity .env is still left alone" \
      "$(secret_of "$P4C/Projects/kommons/supabase-identity/docker/.env")" "$IDENTITY_VALUE"
  fi
fi

# --------------------------------------------------------------------------- #
# Phase 5 — drift-check: a missing identity .env is FATAL
# --------------------------------------------------------------------------- #

echo
echo "Phase 5: a missing identity .env is FATAL, not a skipped stack"

P5="$SANDBOX/phase5"
build_stack_tree "$P5"
rm -f "$P5/Projects/kommons/supabase-identity/docker/.env"
rc=0
run_drift_check "$P5" > "$P5/drift.out" 2>&1 || rc=$?
LOG5="$P5/logs/jwt-secret-drift.log"

assert_eq "drift-check exits 1 without the reference" "$rc" "1"
assert_present "the missing reference is a FATAL naming the identity path" \
  "$LOG5" "FATAL identity .env not found"
# Even a failed run is a run: the heartbeat proves the cron fired.
assert_present "a fatal drift-check run still heartbeats" "$LOG5" "HEARTBEAT drift-check fatal"
assert_absent "kommons is the reference, so no stack is compared without it" "$LOG5" "DRIFT "

# --------------------------------------------------------------------------- #
# Phase 6 — daily summary: digests real runs without blaming kommons
# --------------------------------------------------------------------------- #

echo
echo "Phase 6: the daily summary digests real runs without blaming kommons"

P6="$SANDBOX/phase6"
build_stack_tree "$P6"
curl_stub "$P6"
docker_stub "$P6"
# A genuine pre-cutover revert in kalcio: drift-check reports it as drift and
# the watchdog re-cuts it.  kommons keeps the identity secret throughout.
write_secret "$P6/Projects/kalcio/database/docker/.env" "$PRECUTOVER_VALUE"
write_secret "$P6/Projects/kalcio/database/docker/.env.bak.old" "$PRECUTOVER_VALUE"
LOG6="$P6/logs/jwt-secret-drift.log"

rc=0
run_drift_check "$P6" > "$P6/drift.out" 2>&1 || rc=$?
rc=0
run_watchdog "$P6" "$WATCHDOG" > "$P6/watchdog.out" 2>&1 || rc=$?

# The inputs must really be there, or the digest assertions are vacuous.
assert_present "the source log really holds a kalcio drift" "$LOG6" "DRIFT kalcio"
assert_present "the source log really holds a kalcio revert" "$LOG6" "REVERT DETECTED kalcio"
assert_absent "the source log never mentions kommons" "$LOG6" "kommons"

CURL6="$P6/curl-real.log"
rc=0
run_summary "$P6" "$CURL6" > "$P6/summary.out" 2>&1 || rc=$?
assert_eq "the summary exits 0" "$rc" "0"
assert_present "the digest is delivered" "$CURL6" "JWT Daily Summary"
assert_present "the digest reports the drift" "$CURL6" "DRIFT kalcio"
assert_present "the digest reports the revert" "$CURL6" "REVERT DETECTED kalcio"
assert_absent "the digest never blames kommons" "$CURL6" "kommons"
# Heartbeats are liveness plumbing, not incidents; the digest must ignore them.
assert_absent "heartbeat lines stay out of the digest" "$CURL6" "HEARTBEAT"

# Negative control: the summary is perfectly capable of reporting a kommons
# incident, so the silence above is earned by the identity guard rather than
# by the summary quietly dropping identity-stack events.
echo "$(date '+%Y-%m-%dT%H:%M:%S%z') REVERT DETECTED kommons: synthetic control line" >> "$LOG6"
CURL6C="$P6/curl-control.log"
rc=0
run_summary "$P6" "$CURL6C" > "$P6/summary2.out" 2>&1 || rc=$?
assert_present "control: a kommons incident WOULD be reported" "$CURL6C" "kommons"
assert_present "control: the synthetic incident is attributed to kommons" \
  "$CURL6C" "REVERT DETECTED kommons"

# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #

echo
echo "-------------------------------------------------------------"
if [ "$fail" -eq 0 ]; then
  echo "=== TEST PASSED ($pass checks) ==="
  exit 0
fi
echo "=== TEST FAILED ($fail failed, $pass passed) ==="
exit 1
