#!/usr/bin/env bash
# ============================================================================
# Hermetic suite for tool/identity_allowlist_sync.sh — no VM, no docker daemon,
# no network, nothing written outside a temp sandbox.
#
# How: the real tool runs in --local mode against a sandbox stack dir, with stub
# `docker` / `sleep` / `ssh` / `scp` on PATH and a stub alert library, so the
# convergence, the recreate, the live verification, the restore-on-failure and
# the alert transitions are all exercised for real.
#
# The claims that matter, each asserted below:
#   - the declaration is well-formed and holds the native scheme entry that
#     breaks sign-in silently when dropped, plus the `site_url` directive the
#     nightly probe asserts on;
#   - a `key=value` directive is never counted as an entry and never reaches
#     ADDITIONAL_REDIRECT_URLS;
#   - the DECLARED SITE URL is converged on both sides (the .env and the running
#     auth), verified after the recreate, healed by the scheduled run, refused
#     when malformed or duplicated, and left completely alone when a
#     declaration carries no `site_url` directive at all;
#   - a missing declared entry is DRIFT: plan writes nothing and exits 1;
#   - an .env that is right while the RUNNING auth is behind is also DRIFT (the
#     entry is effectively missing at runtime);
#   - --apply converges, preserves every pre-existing entry and its order, backs
#     the .env up first, recreates only auth, and verifies the live process
#     byte for byte;
#   - a key missing entirely is inserted beside SITE_URL (a .env rebuilt from a
#     template cannot end up without the key);
#   - a duplicated key, an empty declaration and an unverifiable result are
#     REFUSED — and the previous .env is restored — rather than half-applied;
#   - an undeclared live entry is kept and warned about, and only --prune
#     removes it;
#   - --check is a gate: one line, exit 0/1, and --alert notifies once per
#     outage plus a recovery notice, never once per run;
#   - remote mode deploys the tool and the declaration, and refuses a
#     declaration that is not the repo one.
#
# Usage: bash tool/test_identity_allowlist_sync.sh
# ============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$REPO/tool/identity_allowlist_sync.sh"
DECL="$REPO/tool/identity-redirect-allowlist.txt"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
has() { grep -qF -- "$2" <<<"$1"; }
lacks() { ! grep -qF -- "$2" <<<"$1"; }

SB="$WORK/sb"
BIN="$SB/bin"
STACK="$SB/stack"
mkdir -p "$BIN" "$STACK" "$SB/logs"
LIST="$SB/declaration.txt"
cp "$DECL" "$LIST"
LIVE="$SB/live"
LIVE_SITE="$SB/live-site"
LOG="$SB/logs/identity-allowlist.log"
STATE="$SB/logs/identity-allowlist.state"

CANON="https://mediasart.com/en/oauth-callback/,https://mediasart.com/it/oauth-callback/,katalogus://auth-callback"
NATIVE="katalogus://auth-callback"
# The `site_url` directive in the repo declaration — the fixture .env must agree
# with it or every "in sync" case below would be a site-URL drift.
SITE="https://katalogus.mediasart.com"

# ------------------------------------------------------------------- stubs --- #
cat >"$BIN/docker" <<'STUB'
#!/usr/bin/env bash
# docker stub: compose ps/up, inspect, exec — the calls the tool makes.
cmd="${1:-}"; shift || true
case "$cmd" in
  compose)
    sub="${1:-}"; shift || true
    case "$sub" in
      ps) printf 'fake-auth-id\n'; exit 0 ;;
      up)
        [ -n "${KAT_FAKE_COMPOSE_FAIL:-}" ] && { echo "Error response from daemon: boom" >&2; exit 1; }
        # a recreate re-reads .env, so the "running process" picks up the new value
        sed -n 's/^ADDITIONAL_REDIRECT_URLS=//p' "$STACK_DIR/.env" | head -1 >"$KAT_LIVE"
        sed -n 's/^SITE_URL=//p' "$STACK_DIR/.env" | head -1 >"$KAT_LIVE_SITE"
        echo " Container fake-auth-1  Recreated"; exit 0 ;;
      *) exit 0 ;;
    esac ;;
  inspect)
    fmt=""; for a in "$@"; do case "$a" in --format=*) fmt="$a" ;; esac; done
    [ -n "$fmt" ] && printf 'healthy\n'
    exit 0 ;;
  exec)
    for a in "$@"; do
      case "$a" in
        GOTRUE_URI_ALLOW_LIST)
          if [ -n "${KAT_FAKE_LIVE_WRONG:-}" ]; then printf '%s' "$KAT_FAKE_LIVE_WRONG"; exit 0; fi
          cat "$KAT_LIVE" 2>/dev/null; exit 0 ;;
        GOTRUE_SITE_URL)
          if [ -n "${KAT_FAKE_LIVE_SITE_WRONG:-}" ]; then printf '%s' "$KAT_FAKE_LIVE_SITE_WRONG"; exit 0; fi
          cat "$KAT_LIVE_SITE" 2>/dev/null; exit 0 ;;
      esac
    done
    exit 1 ;;
  *) exit 1 ;;
esac
STUB

printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/sleep"
chmod +x "$BIN/docker" "$BIN/sleep"
# No ssh/scp needed until the remote phase, which installs its own pair.

ALERT_SINK="$SB/alerts"
cat >"$BIN/alert.sh" <<'STUB'
#!/usr/bin/env bash
# alert.sh stub: records the fan-out, posts nothing.
send_webhook_alert() { printf 'ALERT webhook:: %s\n' "${1//$'\n'/ }" >>"${ALERT_SINK:-/dev/null}"; }
send_gotify_alert()  { printf 'ALERT gotify:: %s\n' "$1" >>"${ALERT_SINK:-/dev/null}"; }
send_email_alert()   { printf 'ALERT email:: %s\n' "$1" >>"${ALERT_SINK:-/dev/null}"; }
send_brevo_alert()   { printf 'ALERT brevo:: %s\n' "$1" >>"${ALERT_SINK:-/dev/null}"; }
send_telegram_alert(){ printf 'ALERT telegram:: %s\n' "$1" >>"${ALERT_SINK:-/dev/null}"; }
STUB
chmod +x "$BIN/alert.sh"

export PATH="$BIN:$PATH"

# --------------------------------------------------------------- helpers ----- #
write_env() { # <value> — a realistic identity .env, SITE_URL as the declaration names it
  printf 'API_EXTERNAL_URL=https://auth.mediasart.com/auth/v1\nSITE_URL=%s\nADDITIONAL_REDIRECT_URLS=%s\nCOMPOSE_PROJECT_NAME=identity\nGOTRUE_JWT_SECRET=<secret-lives-here>\n' "$SITE" "$1" >"$STACK/.env"
}
env_value() { sed -n 's/^ADDITIONAL_REDIRECT_URLS=//p' "$STACK/.env" | head -1; }
env_site() { sed -n 's/^SITE_URL=//p' "$STACK/.env" | head -1; }
write_env_site() { sed -i "s|^SITE_URL=.*|SITE_URL=$1|" "$STACK/.env"; }   # one side of the pair, wrong
# A recreate re-reads BOTH keys, so "what the running auth holds" starts as a
# mirror of the .env; a test that wants a STALE container overrides the site
# half with set_live_site after it.
set_live() { printf '%s' "$1" >"$LIVE"; env_site >"$LIVE_SITE"; }
set_live_site() { printf '%s' "$1" >"$LIVE_SITE"; }
snapshot() { { cat "$STACK/.env" "${LIVE}" "${LIVE_SITE}" 2>/dev/null; } | sha256sum | cut -c1-16; }
backups() { ls -A "$STACK" 2>/dev/null | grep -c '\.env\.bak-.*-allowlist' || true; }
alerts() { [ -f "$ALERT_SINK" ] && grep -c '^ALERT' "$ALERT_SINK" || echo 0; }
logtext() { [ -f "$LOG" ] && cat "$LOG" || echo ''; }
declare -a EXTRA=()

run() { # [extra env in EXTRA] -- <tool args>
  OUT="$(env PATH="$BIN:$PATH" KAT_LIVE="$LIVE" KAT_LIVE_SITE="$LIVE_SITE" STACK_DIR="$STACK" \
             IDENTITY_ALLOWLIST_LOG="$LOG" IDENTITY_ALLOWLIST_STATE="$STATE" \
             IDENTITY_ALERT_LIB="$BIN/alert.sh" ALERT_SINK="$ALERT_SINK" \
             ${EXTRA[@]+"${EXTRA[@]}"} \
             bash "$SUT" --local --stack-dir "$STACK" --list "$LIST" "$@" 2>&1)"
  RC=$?
}
reset_logs() { rm -rf "$SB/logs" "$ALERT_SINK"; mkdir -p "$SB/logs"; }

# ------------------------------------------------------- 0. harness sanity --- #
echo
echo "== 0. harness: the tool, the declaration and the sandbox are in place =="
[ -s "$SUT" ] && ok "tool under test exists ($(wc -l <"$SUT") lines)" || bad "missing $SUT"
[ -s "$DECL" ] && ok "declaration exists ($(wc -l <"$DECL") lines)" || bad "missing $DECL"
for s in docker sleep alert.sh; do [ -x "$BIN/$s" ] || bad "stub '$s' missing/not executable"; done
write_env "$CANON"; set_live "$CANON"
[ "$(env_value)" = "$CANON" ] && ok "sandbox .env fixture is readable (fixture sanity)" \
                              || bad "fixture broken: the sandbox .env does not hold the canonical list"

echo
echo "== 1. the declaration itself =="
# Mirrors the tool's own reading: comments, blanks AND `key=value` directives
# are not entries.  A directive counted here would make this suite agree with a
# buggy tool rather than with the declaration.
declared_entries="$(awk '/^[[:space:]]*#/{next} /^[[:space:]]*$/{next} /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/{next} {gsub(/^[[:space:]]+|[[:space:]]+$/,""); print}' "$DECL")"
n_decl="$(printf '%s\n' "$declared_entries" | grep -c .)"
[ "$n_decl" -ge 2 ] && ok "the declaration holds $n_decl entries" || bad "only $n_decl entries declared"
printf '%s\n' "$declared_entries" | grep -qxF "$NATIVE" \
  && ok "the native scheme entry '$NATIVE' is declared" \
  || bad "the native scheme entry is not declared — the exact silent failure this file exists to prevent"
dups="$(printf '%s\n' "$declared_entries" | sort | uniq -d)"
[ -z "$dups" ] && ok "no entry is declared twice" || bad "duplicated declaration(s): $dups"
if printf '%s\n' "$declared_entries" | grep -q '#'; then
  bad "an entry contains '#' — GoTrue cuts the URL at '#' before matching, so it could never match"
else
  ok "no entry carries a fragment (they would be dead entries)"
fi
if printf '%s\n' "$declared_entries" | grep -q ','; then
  bad "an entry contains ',' — it would split into two"
else
  ok "no entry contains a comma"
fi
# The site URL the nightly probe asserts on lives here as a directive, so the
# probe has something to compare the running auth against.
grep -qE '^[[:space:]]*site_url=' "$DECL" \
  && ok "the declaration carries the site_url directive the nightly probe asserts" \
  || bad "no site_url directive — the probe would have nothing to assert"
if printf '%s\n' "$declared_entries" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*='; then
  bad "a key=value directive is being counted as an entry"
else
  ok "a key=value directive is never counted as an entry"
fi
# The file documents WHY it exists — a future reader must not "tidy" it away.
grep -qi 'silent' "$DECL" && ok "the declaration explains the silent-rewrite failure it guards" \
                         || bad "the declaration does not explain why it exists"

echo
echo "== 2. in sync: plan writes nothing and exits 0 =="
reset_logs; write_env "$CANON"; set_live "$CANON"
SNAP="$(snapshot)"
run
[ "$RC" = 0 ] && ok "in-sync plan exits 0" || bad "in-sync plan exit=$RC want 0"
has "$OUT" "IN SYNC" && ok "the report says so" || bad "no IN SYNC verdict"
has "$OUT" "none — every declared entry is on the stack and in the running process" \
  && ok "no findings are reported" || bad "phantom findings"
[ "$(snapshot)" = "$SNAP" ] && ok "nothing was written" || bad "plan mutated the sandbox"

echo
echo "== 3. a missing declared entry is DRIFT — the native case =="
reset_logs
write_env "https://mediasart.com/en/oauth-callback/,https://mediasart.com/it/oauth-callback/"
set_live "$(env_value)"
SNAP="$(snapshot)"
run
[ "$RC" = 1 ] && ok "drift exits 1" || bad "drift exit=$RC want 1"
has "$OUT" "declared but ABSENT from the stack" && ok "the finding is named" || bad "no ABSENT finding"
has "$OUT" "katalogus://auth-callback" && ok "the missing entry is named, not just counted" || bad "the missing entry is not named"
[ "$(snapshot)" = "$SNAP" ] && ok "plan changed nothing (no silent repair)" || bad "plan mutated the sandbox"
[ "$(backups)" = 0 ] && ok "plan took no backup (it writes nothing)" || bad "plan wrote a backup"

echo
echo "== 4. the .env is right but the RUNNING auth is behind — still DRIFT =="
reset_logs; write_env "$CANON"; set_live "https://mediasart.com/en/oauth-callback/"
run --check
[ "$RC" = 1 ] && ok "a stale running auth exits 1" || bad "exit=$RC want 1"
has "$OUT" "absent from the running auth process" && ok "--check names the runtime gap" || bad "runtime gap not reported"
has "$OUT" "katalogus://auth-callback" && ok "the entry is named" || bad "entry not named"
[ "$(env_value)" = "$CANON" ] && ok "the .env was left alone" || bad "the .env was rewritten by a check"

echo
echo "== 5. --check on a healthy stack is one line and exit 0 =="
reset_logs; write_env "$CANON"; set_live "$CANON"
run --check
[ "$RC" = 0 ] && ok "healthy --check exits 0" || bad "exit=$RC want 0"
[ "$(printf '%s\n' "$OUT" | grep -c .)" = 1 ] && ok "--check prints exactly one line" \
  || bad "--check printed $(printf '%s\n' "$OUT" | grep -c .) lines"
has "$OUT" "OK identity: all 3 declared redirect entries" && ok "the line states the verdict and the count" || bad "verdict line wrong: $OUT"
has "$(logtext)" "OK identity:" && ok "the verdict is in the ops log" || bad "nothing logged"

echo
echo "== 6. an undeclared live entry is kept, warned about, and never fatal =="
reset_logs; write_env "$CANON,https://other.example/cb"; set_live "$(env_value)"
run --check
[ "$RC" = 0 ] && ok "an undeclared entry does not fail the check" || bad "exit=$RC want 0"
has "$OUT" "not declared (kept): https://other.example/cb" && ok "it is reported as kept" || bad "the undeclared entry is not reported"
[ "$(env_value)" = "$CANON,https://other.example/cb" ] && ok "nothing was removed" || bad "a check removed an entry"

# ---------------------------------------------------------------- applying --- #
echo
echo "== 7. --apply converges a missing entry and verifies the live process =="
reset_logs
write_env "https://mediasart.com/en/oauth-callback/,https://mediasart.com/it/oauth-callback/"
set_live "$(env_value)"
run --apply
[ "$RC" = 0 ] && ok "apply exits 0" || bad "apply exit=$RC want 0"
[ "$(env_value)" = "$CANON" ] && ok "the .env now matches the declaration" || bad ".env is '$(env_value)'"
[ "$(cat "$LIVE")" = "$CANON" ] && ok "the recreated auth picked the value up" || bad "the live process was not updated"
[ "$(backups)" -ge 1 ] && ok "the previous .env was backed up" || bad "no backup was taken"
has "$OUT" "byte for byte ✓" && ok "the live value is verified, not assumed" || bad "no byte-for-byte verification"
[ "$(printf '%s' "$OUT" | grep -c 'declared entry present in the running auth')" = 3 ] \
  && ok "every declared entry is verified individually" || bad "per-entry verification missing"
has "$(logtext)" "OK identity: converged the allow list" && ok "the converged state is logged" || bad "no convergence log line"

echo
echo "== 7b. an apply never drops an entry it was not asked to drop =="
reset_logs
write_env "https://mediasart.com/en/oauth-callback/,https://other.example/cb"
set_live "$(env_value)"
run --apply
[ "$RC" = 0 ] && ok "apply exits 0" || bad "exit=$RC want 0"
preserved=0
for e in $(printf '%s' "$CANON" | tr ',' ' ') https://other.example/cb; do
  printf '%s' "$(env_value)" | tr ',' '\n' | grep -qxF -- "$e" && preserved=$((preserved+1))
done
[ "$preserved" = 4 ] && ok "the undeclared entry survived the convergence (all 4 present)" \
  || bad "only $preserved/4 entries survived: $(env_value)"

rm -f "$ALERT_SINK"
run --apply --prune
[ "$RC" = 0 ] && ok "--prune apply exits 0" || bad "prune exit=$RC want 0"
[ "$(env_value)" = "$CANON" ] && ok "--prune removed exactly the undeclared entry" || bad "after prune: $(env_value)"

# The declaration's `site_url` directive configures the stack; it is not an
# allow-list entry.  If it were written into the key, the value would contain
# '=' text GoTrue would treat as a literal target — every real redirect would
# then be validated against a mangled list.
echo
echo "== 7c. a directive never reaches ADDITIONAL_REDIRECT_URLS =="
reset_logs
write_env "https://mediasart.com/en/oauth-callback/"
set_live "$(env_value)"
run --apply
[ "$RC" = 0 ] && ok "--apply with a directive in the declaration exits 0" || bad "exit=$RC want 0"
[ "$(env_value)" = "$CANON" ] && ok "the .env holds exactly the declared entries" || bad ".env is '$(env_value)'"
lacks "$(env_value)" 'site_url' && ok "no directive text leaked into the key" || bad "the directive leaked into ADDITIONAL_REDIRECT_URLS"
[ "$(printf '%s' "$(env_value)" | tr ',' '\n' | grep -c '=')" = 0 ] \
  && ok "no entry in the key looks like a directive" || bad "a directive-shaped entry is in the key"
reset_logs; write_env "$CANON"; set_live "$CANON"

# The OTHER half of the declaration's contract: `site_url` names the origin
# every unmatched redirect falls back to.  A stack whose site URL disagrees is
# mis-set in exactly the way a dropped entry is — and it is where a dropped
# entry LANDS — so it is converged the same way, on both sides, not just read.
echo
echo "== 7d. a site URL that disagrees on either side is DRIFT =="
WRONG_SITE="https://wrong.example"
reset_logs; write_env "$CANON"; set_live "$CANON"; set_live_site "$WRONG_SITE"
run
[ "$RC" = 1 ] && ok "a stale RUNNING site URL is drift" || bad "exit=$RC want 1"
has "$OUT" "the RUNNING auth's GOTRUE_SITE_URL is not the site URL the declaration names" \
  && ok "the finding names the running side" || bad "no running-side site finding"
has "$OUT" "GOTRUE_SITE_URL=$WRONG_SITE" && ok "the running value is shown" || bad "the running value is not shown"
has "$OUT" "GOTRUE_SITE_URL (declared)=$SITE" && ok "and the declared one beside it, not just 'drift'" || bad "the declared value is not shown"
[ "$(env_site)" = "$SITE" ] && ok "the .env half was already right and was left alone" || bad ".env site is '$(env_site)'"

# The MIRROR of the case above, and the one a `.env` edit without a recreate
# actually produces: the stack's SITE_URL has moved while the running auth is
# still correct.  Only the .env side can be the finding here — which is exactly
# why the two sides are compared separately.
reset_logs; write_env "$CANON"; write_env_site "$WRONG_SITE"
set_live "$CANON"; set_live_site "$SITE"
run
[ "$RC" = 1 ] && ok "a .env site URL that disagrees while the running auth is right is drift" || bad "exit=$RC want 1"
has "$OUT" "SITE_URL on the stack is not the site URL the declaration names" \
  && ok "the finding names the .env side" || bad "no .env-side site finding"
has "$OUT" "SITE_URL (declared)=$SITE" && ok "with the declared value beside it" || bad "declared value not shown"
has "$OUT" "live GOTRUE_SITE_URL: $SITE" && ok "and the running side is reported as already right" || bad "running side not reported"

reset_logs; write_env "$CANON"; write_env_site "$WRONG_SITE"; set_live "$CANON"
run --check
[ "$RC" = 1 ] && ok "a .env site URL that disagrees is drift" || bad "exit=$RC want 1"
has "$OUT" "SITE_URL is not the declared site URL" && ok "--check names the .env side" || bad "not named in --check"
has "$OUT" "GOTRUE_SITE_URL=$WRONG_SITE (declared $SITE)" && ok "--check names the running side too" || bad "running side missing"

# ... and the pair re-reads as ONE unit when the stack can be recreated.
echo
echo "== 7e. --apply converges the site URL and verifies the running auth =="
run --apply
[ "$RC" = 0 ] && ok "--apply converges a site-URL drift" || bad "exit=$RC want 0"
[ "$(env_site)" = "$SITE" ] && ok "the .env site URL was rewritten" || bad ".env site is '$(env_site)'"
[ "$(cat "$LIVE_SITE")" = "$SITE" ] && ok "the recreated auth picked it up" || bad "live site is '$(cat "$LIVE_SITE")'"
has "$OUT" "live GOTRUE_SITE_URL is the declared site URL ✓" && ok "the live site URL is verified, not assumed" || bad "no live site verification"
[ "$(backups)" -ge 1 ] && ok "one backup covered both keys" || bad "no backup"

reset_logs; write_env "$CANON"; set_live "$CANON"
run --check
[ "$RC" = 0 ] && ok "in-sync --check still exits 0 with a declared site URL" || bad "exit=$RC want 0"
has "$OUT" "and SITE_URL=$SITE matches" && ok "the verdict line states the site URL" || bad "site URL missing from the verdict"

# Back-compat: a declaration written before the directive existed must behave
# exactly as it always did — SITE_URL untouched, no phantom drift.
echo
echo "== 7f. with no site_url directive the site URL is left alone =="
reset_logs
printf '%s\n' "$CANON" | tr ',' '\n' > "$SB/no-directive.txt"
write_env "$CANON"; write_env_site "$WRONG_SITE"; set_live "$CANON"
run --list "$SB/no-directive.txt"
[ "$RC" = 0 ] && ok "a declaration with no site_url is not a site-URL finding" || bad "exit=$RC want 0"
[ "$(env_site)" = "$WRONG_SITE" ] && ok "and the stack's site URL is left exactly as it was" || bad "the .env site URL was touched"
has "$OUT" "site url:    not declared" && ok "the report says the site URL is not declared" || bad "the report does not say so"

# A malformed site URL is refused, never converged: it is the root of every
# confirmation and recovery link the stack mails.
echo
echo "== 7g. a malformed or duplicated site URL is refused, not written =="
reset_logs
printf 'site_url=not-a-url\n%s\n' "$CANON" | tr ',' '\n' > "$SB/bad-site.txt"
write_env "$CANON"; set_live "$CANON"
SNAP="$(snapshot)"
run --list "$SB/bad-site.txt" --apply
[ "$RC" = 3 ] && ok "a site_url that is not a URL is a config error (exit 3)" || bad "exit=$RC want 3"
[ "$(snapshot)" = "$SNAP" ] && ok "nothing was written" || bad "a malformed declaration still wrote"
has "$OUT" "not a <scheme>://<host> URL" && ok "the reason is stated" || bad "no reason given"
printf 'site_url=https://x.example/#frag\n%s\n' "$CANON" | tr ',' '\n' > "$SB/bad-site2.txt"
run --list "$SB/bad-site2.txt"
[ "$RC" = 3 ] && ok "a '#' in the site URL is refused (GoTrue cuts the URL there)" || bad "exit=$RC want 3"

reset_logs
write_env "$CANON"; printf 'SITE_URL=%s\n' "$WRONG_SITE" >>"$STACK/.env"; set_live "$CANON"
SNAP="$(snapshot)"; run --apply
[ "$RC" = 2 ] && ok "a duplicated SITE_URL is refused (exit 2)" || bad "exit=$RC want 2"
[ "$(snapshot)" = "$SNAP" ] && ok "nothing was written" || bad "a refused run wrote"
reset_logs; write_env "$CANON"; set_live "$CANON"

# the last backup must be the PREVIOUS value, or the rollback is a no-op
echo
echo "== 8. the backup holds the value that was there before the change =="
reset_logs; write_env "https://mediasart.com/en/oauth-callback/"; set_live "$(env_value)"
run --apply >/dev/null 2>&1
last_bak="$(ls -t "$STACK"/.env.bak-*-allowlist 2>/dev/null | head -1)"
[ -n "$last_bak" ] && ok "a backup exists" || bad "no backup to inspect"
[ "$(sed -n 's/^ADDITIONAL_REDIRECT_URLS=//p' "$last_bak")" = "https://mediasart.com/en/oauth-callback/" ] \
  && ok "the backup holds the previous value exactly" || bad "the backup does not hold the previous value"

# ------------------------------------------------------- fresh provision ---- #
echo
echo "== 9. a .env rebuilt without the key gets it, beside SITE_URL =="
reset_logs
printf 'API_EXTERNAL_URL=https://auth.mediasart.com/auth/v1\nSITE_URL=%s\nCOMPOSE_PROJECT_NAME=identity\n' "$SITE" >"$STACK/.env"
set_live ""
run --apply
[ "$RC" = 0 ] && ok "apply exits 0 on a key-less .env" || bad "exit=$RC want 0"
[ "$(env_value)" = "$CANON" ] && ok "the key was created with the declared list" || bad "the key is '$(env_value)'"
[ "$(sed -n '3p' "$STACK/.env")" = "ADDITIONAL_REDIRECT_URLS=$CANON" ] \
  && ok "it was inserted directly after SITE_URL" || bad "inserted in the wrong place: $(sed -n '3p' "$STACK/.env")"
grep -q '^COMPOSE_PROJECT_NAME=identity$' "$STACK/.env" && ok "the rest of the file is intact" || bad "the rewrite damaged the file"

# ------------------------------------------------------- refusing / failing --- #
echo
echo "== 10. a duplicated key is refused, and nothing is written =="
reset_logs
printf 'SITE_URL=%s\nADDITIONAL_REDIRECT_URLS=a\nADDITIONAL_REDIRECT_URLS=b\n' "$SITE" >"$STACK/.env"
SNAP="$(snapshot)"
BAKS_BEFORE="$(backups)"
run --apply
[ "$RC" = 2 ] && ok "a duplicate key exits 2" || bad "exit=$RC want 2"
[ "$(snapshot)" = "$SNAP" ] && ok "the .env was not touched" || bad "a refused run still wrote"
[ "$(backups)" = "$BAKS_BEFORE" ] && ok "a refused run takes no backup either" || bad "a refused run took a backup"

reset_logs
printf '# only comments, no entries\n' >"$SB/empty-list.txt"
OUT="$(env PATH="$BIN:$PATH" STACK_DIR="$STACK" IDENTITY_ALLOWLIST_LOG="$LOG" bash "$SUT" --local --stack-dir "$STACK" --list "$SB/empty-list.txt" --apply 2>&1)"; RC=$?
[ "$RC" = 3 ] && ok "an empty declaration is a usage error (exit 3)" || bad "exit=$RC want 3"
has "$OUT" "holds no entries" && ok "the reason is stated" || bad "no reason given"

reset_logs; write_env "https://mediasart.com/en/oauth-callback/"; set_live "$(env_value)"
cp "$STACK/.env" "$SB/before-fail.env"
EXTRA=(KAT_FAKE_COMPOSE_FAIL=1)
run --apply
EXTRA=()
[ "$RC" = 2 ] && ok "a failed recreate exits 2" || bad "exit=$RC want 2"
diff -q "$SB/before-fail.env" "$STACK/.env" >/dev/null && ok "the previous .env was restored" || bad "the .env was left half-changed"
has "$OUT" "restored" && ok "the restore is reported" || bad "the restore is silent"

reset_logs; write_env "https://mediasart.com/en/oauth-callback/"; set_live "$(env_value)"
cp "$STACK/.env" "$SB/before-unverified.env"
EXTRA=(KAT_FAKE_LIVE_WRONG='https://wrong.example/only')
run --apply
EXTRA=()
[ "$RC" = 2 ] && ok "a live result that cannot be verified exits 2" || bad "exit=$RC want 2"
diff -q "$SB/before-unverified.env" "$STACK/.env" >/dev/null && ok "the .env was rolled back" || bad "an unverified change was left in place"
has "$OUT" "NOT what we wrote" && ok "the mismatch is reported" || bad "the mismatch is silent"

# ---------------------------------------------------------------- alerting --- #
echo
echo "== 11. --alert notifies once per outage, then once on recovery =="
reset_logs
write_env "https://mediasart.com/en/oauth-callback/,https://mediasart.com/it/oauth-callback/"
set_live "$(env_value)"
run --check --alert
[ "$RC" = 1 ] && ok "the drifted check still exits 1" || bad "exit=$RC want 1"
[ "$(alerts)" = 5 ] && ok "the alert reached all five channels" || bad "alert count=$(alerts) want 5"
has "$(cat "$ALERT_SINK" 2>/dev/null || true)" "DRIFT" && ok "the alert names the state" || bad "no DRIFT in the alert"
has "$(cat "$ALERT_SINK" 2>/dev/null || true)" "katalogus://auth-callback" && ok "the alert names the missing entry" || bad "the alert does not name the entry"
[ -s "$STATE" ] && ok "the outage is remembered" || bad "no state written"

rm -f "$ALERT_SINK"
run --check --alert
[ "$(alerts)" = 0 ] && ok "a second drifted run does not re-alert" || bad "re-alerted $(alerts) time(s)"
has "$(logtext)" "not repeating" && ok "the log says why it stayed quiet" || bad "no 'not repeating' note"

rm -f "$ALERT_SINK"
write_env "$CANON"; set_live "$CANON"
run --check --alert
[ "$RC" = 0 ] && ok "the recovered check exits 0" || bad "exit=$RC want 0"
[ "$(alerts)" = 5 ] && ok "recovery is announced on every channel" || bad "alert count=$(alerts) want 5"
has "$(cat "$ALERT_SINK" 2>/dev/null || true)" "in sync again" && ok "the notice says it recovered" || bad "the recovery notice is wrong"
[ ! -s "$STATE" ] && ok "the state was cleared" || bad "the state still claims an outage"

rm -f "$ALERT_SINK"
run --check --alert
[ "$(alerts)" = 0 ] && ok "a further healthy run stays silent" || bad "alerted on a healthy run"

# ----------------------------------------------------------------- healing --- #
echo
echo "== 11b. --heal converges a dropped entry and re-verifies the running auth =="
reset_logs
write_env "https://mediasart.com/en/oauth-callback/,https://mediasart.com/it/oauth-callback/"
set_live "$(env_value)"
SNAP="$(snapshot)"
run --heal
[ "$RC" = 0 ] && ok "a heal exits 0" || bad "heal exit=$RC want 0"
[ "$(env_value)" = "$CANON" ] && ok "the dropped entry was converged onto the stack" || bad ".env is '$(env_value)'"
[ "$(cat "$LIVE")" = "$CANON" ] && ok "the running auth carries the restored entry" || bad "the live process was not updated"
has "$OUT" "DRIFT identity:" && ok "the finding is reported before the fix" || bad "the finding is not reported"
has "$OUT" "self-healing" && ok "the run says it is healing, not merely reporting" || bad "no self-healing marker in the output"
has "$OUT" "HEALED identity:" && ok "the outcome is reported as healed" || bad "no HEALED line"
has "$OUT" "the running auth was re-verified" && ok "the running auth is re-verified after the fix" || bad "no re-verification step"
has "$(logtext)" "HEALED identity:" && ok "the heal is recorded in the ops log" || bad "the heal is not logged"
[ "$(snapshot)" != "$SNAP" ] && ok "the heal really did change the sandbox" || bad "the heal changed nothing (vacuous)"

reset_logs; write_env "$CANON"; set_live "$CANON"
SNAP="$(snapshot)"; BAKS="$(backups)"
run --heal
[ "$RC" = 0 ] && ok "a heal on a healthy stack exits 0" || bad "exit=$RC want 0"
[ "$(alerts)" = 0 ] && ok "a healthy heal alerts nobody" || bad "alerted on a healthy stack"
[ "$(snapshot)" = "$SNAP" ] && [ "$(backups)" = "$BAKS" ] \
  && ok "a healthy heal writes nothing and recreates nothing" || bad "a healthy heal touched the stack"

# A heal is never a mere report: drift it can fix is fixed, drift it cannot fix
# is a failure.  Exit 1 ("drift, go and do something") must never escape it.
echo
echo "== 11c. a heal is not a report: it never exits 1 =="
reset_logs
write_env "https://mediasart.com/en/oauth-callback/"; set_live "$(env_value)"
run --heal
[ "$RC" != 1 ] && ok "a healed run does not exit 1" || bad "the heal left the drift to a human (exit 1)"
reset_logs
write_env "https://mediasart.com/en/oauth-callback/"; set_live "$(env_value)"
EXTRA=(KAT_FAKE_LIVE_WRONG='https://wrong.example/only')
run --heal
EXTRA=()
[ "$RC" = 2 ] && ok "a heal that cannot be verified is a failure (exit 2)" || bad "exit=$RC want 2"

# The scheduled guard alerts on the OUTCOME.  A heal that worked is a notice;
# only a heal that failed is the alarm.  And the notice must not repeat while
# the same drop keeps coming back.
echo
echo "== 11d. heal alerting: one notice per heal, the alarm only on failure =="
reset_logs
write_env "https://mediasart.com/en/oauth-callback/"; set_live "$(env_value)"
run --heal --alert
[ "$RC" = 0 ] && ok "the healing run exits 0" || bad "exit=$RC want 0"
[ "$(alerts)" = 5 ] && ok "the heal notice reached all five channels" || bad "alert count=$(alerts) want 5"
has "$(cat "$ALERT_SINK" 2>/dev/null || true)" "self-healed" && ok "the notice reads self-healed" || bad "the heal notice is wrong"
lacks "$(cat "$ALERT_SINK" 2>/dev/null || true)" "DRIFT" && ok "it is not dressed as the drift alarm" || bad "a successful heal sent the drift alarm"
[ ! -s "$STATE" ] && ok "no drift state is left behind (nothing to 'recover' from)" || bad "the heal left drift state behind"

rm -f "$ALERT_SINK"
reset_logs
write_env "https://mediasart.com/en/oauth-callback/"; set_live "$(env_value)"
run --heal --alert
[ "$RC" = 0 ] && ok "the same drop recurring is healed again" || bad "exit=$RC want 0"
[ "$(alerts)" = 0 ] && ok "the same heal is not announced a second time" || bad "re-announced $(alerts) time(s)"
has "$(logtext)" "self-healed before (not repeating)" && ok "the log says why it stayed quiet" || bad "no suppression note"

# ... but once the stack is genuinely back in sync the suppression clears, so a
# recurrence months later still notifies.
rm -f "$ALERT_SINK"; reset_logs; write_env "$CANON"; set_live "$CANON"
run --heal --alert
[ "$(alerts)" = 0 ] && ok "the clean run between the two drops is silent" || bad "alerted while in sync"
rm -f "$ALERT_SINK"
write_env "https://mediasart.com/en/oauth-callback/"; set_live "$(env_value)"
run --heal --alert
[ "$(alerts)" = 5 ] && ok "after a clean run, a fresh drop notifies again" || bad "alert count=$(alerts) want 5"

# A heal that fails is the one case that needs a human: the loud transition
# alarm, the previous .env restored, and a recovery notice when it is fixed.
echo
echo "== 11e. a failed heal restores the .env, alarms loudly, and recovers =="
reset_logs
write_env "https://mediasart.com/en/oauth-callback/"; set_live "$(env_value)"
cp "$STACK/.env" "$SB/before-heal-fail.env"
EXTRA=(KAT_FAKE_LIVE_WRONG='https://wrong.example/only')
run --heal --alert
EXTRA=()
[ "$RC" = 2 ] && ok "a heal that cannot converge exits 2" || bad "exit=$RC want 2"
diff -q "$SB/before-heal-fail.env" "$STACK/.env" >/dev/null && ok "the previous .env was restored" \
  || bad "a failed heal left the .env changed"
has "$OUT" "HEAL FAILED identity:" && ok "the failure is named in the output" || bad "no HEAL FAILED line"
has "$(cat "$ALERT_SINK" 2>/dev/null || true)" "DRIFT" && ok "a failed heal raises the loud drift alarm" || bad "a failed heal is not alarmed"
[ -s "$STATE" ] && ok "the failure is remembered" || bad "no state written for the failure"

rm -f "$ALERT_SINK"
write_env "$CANON"; set_live "$CANON"
run --heal --alert
[ "$RC" = 0 ] && ok "the later clean run exits 0" || bad "exit=$RC want 0"
has "$(cat "$ALERT_SINK" 2>/dev/null || true)" "in sync again" && ok "recovery from a failed heal is announced" || bad "no recovery notice"

# The modes are exclusive; combining them is a usage error, not a silent win.
echo
echo "== 11f. --heal cannot be combined with --apply or --check =="
reset_logs; write_env "$CANON"; set_live "$CANON"
run --heal --apply
[ "$RC" = 3 ] && ok "--heal --apply is a usage error (exit 3)" || bad "exit=$RC want 3"
run --check --heal
[ "$RC" = 3 ] && ok "--check --heal is a usage error (exit 3)" || bad "exit=$RC want 3"

# The scheduled guard must self-heal the site URL too: converging it is only
# worth anything if a drift actually comes back on its own.
echo
echo "== 11g. --heal converges a site-URL drift and re-verifies the running auth =="
reset_logs; write_env "$CANON"; set_live "$CANON"; set_live_site "$WRONG_SITE"
run --heal --alert
[ "$RC" = 0 ] && ok "a site-URL drift is healed, not reported (exit 0, never 1)" || bad "exit=$RC want 0"
[ "$(env_site)" = "$SITE" ] && ok "the .env site URL was converged" || bad ".env site is '$(env_site)'"
[ "$(cat "$LIVE_SITE")" = "$SITE" ] && ok "the recreated auth holds it" || bad "live site is '$(cat "$LIVE_SITE")'"
has "$OUT" "HEALED identity:" && ok "the heal reports the outcome" || bad "no HEALED line"
has "$OUT" "GOTRUE_SITE_URL not the declared site URL" && ok "the finding names the site URL" || bad "the heal does not name it"
[ "$(alerts)" = 5 ] && ok "one self-heal notice, on every channel" || bad "alert count=$(alerts) want 5"
has "$(cat "$ALERT_SINK" 2>/dev/null || true)" "self-healed" && ok "the notice reads self-healed" || bad "wrong notice"

# A site URL that cannot be verified is a FAILED heal: the previous .env comes
# back and the loud alarm goes out, exactly as for a broken allow list.
reset_logs; write_env "$CANON"; write_env_site "$WRONG_SITE"
set_live "$CANON"; set_live_site "$WRONG_SITE"
cp "$STACK/.env" "$SB/before-site-heal-fail.env"
EXTRA=(KAT_FAKE_LIVE_SITE_WRONG='https://still-wrong.example')
run --heal --alert
EXTRA=()
[ "$RC" = 2 ] && ok "a site URL that cannot be verified is a failed heal (exit 2)" || bad "exit=$RC want 2"
diff -q "$SB/before-site-heal-fail.env" "$STACK/.env" >/dev/null && ok "the previous .env was restored" \
  || bad "a failed heal left the .env changed"
has "$(cat "$ALERT_SINK" 2>/dev/null || true)" "DRIFT" && ok "and it raises the loud alarm" || bad "no alarm on a failed heal"

# ------------------------------------------------------------------ remote --- #
echo
echo "== 12. remote mode deploys, then runs the same code on the VM =="
SSH_LOG="$SB/ssh.log"; : >"$SSH_LOG"
cat >"$BIN/ssh" <<'STUB'
#!/usr/bin/env bash
last="${@: -1}"
printf 'SSH %s\n' "$last" >>"$SSH_LOG"
case "$last" in
  *sha256sum*) exit 0 ;;
  *chmod*) exit 0 ;;
  *identity_allowlist_sync.sh*) printf 'REMOTE-RUN\n'; exit 0 ;;
esac
exit 0
STUB
cat >"$BIN/scp" <<'STUB'
#!/usr/bin/env bash
last="${@: -1}"
printf 'SCP %s\n' "$last" >>"$SSH_LOG"
exit 0
STUB
chmod +x "$BIN/ssh" "$BIN/scp"

OUT="$(env PATH="$BIN:$PATH" SSH_LOG="$SSH_LOG" KAT_SSH_KEY="$BIN/fakekey" bash -c 'touch "$KAT_SSH_KEY"; exec "$0" --check' "$SUT" 2>&1)"; RC=$?
[ "$RC" = 0 ] && ok "a remote check exits 0 when the remote exits 0" || bad "remote check exit=$RC"
has "$OUT" "REMOTE-RUN" && ok "the work ran on the remote side" || bad "the remote was not driven"
has "$(cat "$SSH_LOG")" "sh" && ok "the declaration and the tool were both deployed" || bad "deploy did not happen: $(cat "$SSH_LOG")"
has "$(cat "$SSH_LOG")" "identity-redirect-allowlist.txt" && ok "the declaration was deployed too" || bad "only the tool was deployed"
has "$(cat "$SSH_LOG")" "--check" && ok "--check was forwarded" || bad "--check was not forwarded"

: >"$SSH_LOG"
OUT="$(env PATH="$BIN:$PATH" SSH_LOG="$SSH_LOG" KAT_SSH_KEY="$BIN/fakekey" bash -c 'touch "$KAT_SSH_KEY"; exec "$0" --apply --prune --alert' "$SUT" 2>&1)"; RC=$?
REMOTE_LINE="$(grep '^SSH bash' "$SSH_LOG" | tail -1)"
has "$REMOTE_LINE" "--apply" && ok "--apply is forwarded" || bad "--apply not forwarded: $REMOTE_LINE"
has "$REMOTE_LINE" "--prune" && ok "--prune is forwarded" || bad "--prune not forwarded"
has "$REMOTE_LINE" "--alert" && ok "--alert is forwarded" || bad "--alert not forwarded"
has "$REMOTE_LINE" "--local" && ok "the remote runs the local code path" || bad "--local not forwarded"

: >"$SSH_LOG"
OUT="$(env PATH="$BIN:$PATH" SSH_LOG="$SSH_LOG" KAT_SSH_KEY="$BIN/fakekey" bash -c 'touch "$KAT_SSH_KEY"; exec "$0" --heal --alert' "$SUT" 2>&1)"; RC=$?
REMOTE_LINE="$(grep '^SSH bash' "$SSH_LOG" | tail -1)"
has "$REMOTE_LINE" "--heal" && ok "--heal is forwarded" || bad "--heal not forwarded: $REMOTE_LINE"
has "$REMOTE_LINE" "--alert" && ok "--heal forwards --alert too" || bad "--alert not forwarded with --heal"

OUT="$(env PATH="$BIN:$PATH" SSH_LOG="$SSH_LOG" KAT_SSH_KEY="$BIN/fakekey" bash -c 'touch "$KAT_SSH_KEY"; exec "$0" --list /tmp/somewhere-else.txt' "$SUT" 2>&1)"; RC=$?
[ "$RC" = 3 ] && ok "a foreign declaration is refused in remote mode (exit 3)" || bad "exit=$RC want 3"
has "$OUT" "repo declaration" && ok "the refusal explains where the truth lives" || bad "the refusal is cryptic"

# ------------------------------------------------------------------- wiring --- #
echo
echo "== 13. the tool is runnable the way cron and CI will invoke it =="
[ -x "$SUT" ] && ok "the tool is executable" || bad "the tool is not executable (cron needs the bit)"
head -1 "$SUT" | grep -q 'bash' && ok "it has a shebang" || bad "no shebang"
has "$(cat "$SUT")" 'IDENTITY_ALLOWLIST_STATE' && ok "the alert state path is overridable (cron + tests)" || bad "no state override"
has "$(cat "$SUT")" 'IDENTITY_ALLOWLIST_HEAL_STATE' && ok "the heal-notice state path is overridable" || bad "no heal-notice state override"
# The scheduled guard must self-heal: an installer left scheduling the old
# detect-only entry would look installed while converging nothing.
INSTALLER="$REPO/tool/install_identity_allowlist_check.sh"
has "$(cat "$INSTALLER")" '--local --heal --alert' \
  && ok "the installer schedules the self-healing mode" \
  || bad "the installer does not schedule --heal"
lacks "$(cat "$INSTALLER")" '--local --check --alert' \
  && ok "the installer no longer schedules the detect-only entry" \
  || bad "the installer still schedules the detect-only entry"
has "$(cat "$INSTALLER")" '--heal' && ok "the installer's --check asserts the entry heals" || bad "the installer does not verify --heal"

# ------------------------------------------------------ static declaration --- #
echo
echo "== 14. the declaration is the only place that names the entries =="
has "$(cat "$SUT")" 'identity-redirect-allowlist.txt' && ok "the tool points at the declaration" || bad "the tool does not name its declaration"
if grep -q 'katalogus://auth-callback' "$SUT"; then
  bad "an entry is hardcoded in the tool as well as declared — they can drift apart"
else
  ok "no entry is hardcoded in the tool"
fi

[ "$FAIL" = 0 ] || { echo; echo "================================================"; echo "PASS=$PASS  FAIL=$FAIL"; exit 1; }
echo
echo "================================================"
echo "PASS=$PASS  FAIL=$FAIL"

