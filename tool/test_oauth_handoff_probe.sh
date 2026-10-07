#!/usr/bin/env bash
# ============================================================================
# Hermetic suite for tool/oauth_handoff_probe.sh — no VM, no network, nothing
# written outside a temp sandbox.
#
# How: the real probe runs in --local mode with stub `curl` / alert library /
# allow-list tool on PATH.  The curl stub IS GoTrue's validation, reduced to its
# observable essence: /authorize hands back a state that remembers the requested
# target; /callback resolves that state to the target IF the target is in the
# stub's allow list and to GOTRUE_SITE_URL otherwise.  That is exactly the
# behaviour the live stack showed, so the probe's assertions are exercised for
# real rather than mocked away.
#
# The claims that matter, each asserted below:
#   - a healthy stack PASSES, in report and in --check mode, and report mode
#     explains itself while --check stays one line;
#   - a declared entry the stack does NOT honour is FAIL, and the finding names
#     the fallback to the site URL — the silent-rewrite case this exists for;
#   - the match is EQUALITY, not a prefix: a target that merely starts with the
#     declared entry still fails (a `scheme://host/path` entry must not admit
#     `scheme://host/path/extra`);
#   - the CONTROL matters: if an undeclared target is honoured, the probe fails,
#     because a probe that cannot fail is worthless — and --no-control opts out;
#   - the presence half (delegated to the allow-list tool) can fail the probe on
#     its own, and is reported as unknown when that tool is absent;
#   - an unreachable API fails every entry with a clear reason;
#   - the site URL the declaration assumes is asserted against the RUNNING auth
#     both as APPLIED (where an unlisted target lands) and as the container
#     holds it; a disagreeing value fails, and an UNOBSERVABLE one fails too
#     rather than passing unchecked;
#   - a `key=value` directive is read as configuration, never probed as an
#     entry, and the extra /authorize it costs is spent only when declared;
#   - a directive key nothing asserts (`site_urll=`) fails the probe, so a typo
#     cannot silently disable the assertion it was meant to add.
#
# Usage: bash tool/test_oauth_handoff_probe.sh
# ============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$REPO/tool/oauth_handoff_probe.sh"
DECL="$REPO/tool/identity-redirect-allowlist.txt"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
has() { grep -qF -- "$2" <<<"$1"; }
lacks() { ! grep -qF -- "$2" <<<"$1"; }

BIN="$WORK/bin"; STATES="$WORK/states"; LOGS="$WORK/logs"
mkdir -p "$BIN" "$STATES" "$LOGS"
LIST="$WORK/declaration.txt"
cp "$DECL" "$LIST"
ALLOW="$WORK/allow.txt"
CALLS="$WORK/alert-calls"
SITE="https://katalogus.mediasart.com"
NATIVE="katalogus://auth-callback"
WEB_EN="https://mediasart.com/en/oauth-callback/"
WEB_IT="https://mediasart.com/it/oauth-callback/"

# ------------------------------------------------------------------- stubs --- #
cat >"$BIN/curl" <<'STUB'
#!/usr/bin/env bash
# curl stub == GoTrue's redirect validation, reduced to its observable essence.
[ "${KAT_STUB_AUTHFAIL:-0}" = 1 ] && exit 7
url=""; target=""; state=""
for a in "$@"; do
  case "$a" in
    redirect_to=*) target="${a#redirect_to=}" ;;
    state=*)       state="${a#state=}" ;;
    http*)         url="$a" ;;
  esac
done
case "$url" in
  */authorize)
    n="$(cat "$STATEDIR/counter" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" >"$STATEDIR/counter"
    st="fs-$(printf '%04d' "$n")"
    printf '%s' "$target" >"$STATEDIR/$st"
    printf 'HTTP/2 302\r\nlocation: https://accounts.google.com/o/oauth2/v2/auth?redirect_to=%s&state=%s\r\n' "$target" "$st"
    ;;
  */callback)
    resolved="$(cat "$STATEDIR/$state" 2>/dev/null || echo '')"
    [ -n "${KAT_STUB_FORCE_TARGET:-}" ] && resolved="$KAT_STUB_FORCE_TARGET"
    [ -z "$resolved" ] && { printf 'HTTP/2 400\r\n'; exit 0; }
    honored=0
    if [ -f "${KAT_STUB_ALLOWLIST:-/nonexistent}" ]; then
      while IFS= read -r line; do
        line="${line%%[?#]*}"; [ -n "$line" ] || continue
        [ "$line" = "$resolved" ] && honored=1
      done <"$KAT_STUB_ALLOWLIST"
    fi
    if [ "$honored" = 1 ]; then
      printf 'HTTP/2 302\r\nlocation: %s?error=server_error&sb=\r\n' "$resolved"
    else
      printf 'HTTP/2 302\r\nlocation: %s?error=server_error&sb=\r\n' "${KAT_STUB_SITE_URL:-$SITE}"
    fi
    ;;
  *verify*)
    # GoTrue's /verify on a bogus token: 303 to the site URL with the error in
    # the FRAGMENT (the OAuth path puts its error after a `?`).  A stack whose
    # origin does not route the path to GoTrue answers with the web app instead
    # — modelled by KAT_STUB_VERIFY_PATH, so a declaration naming a path GoTrue
    # does not serve is caught rather than answered by the stub's goodwill.
    n="$(cat "$STATEDIR/verifies" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" >"$STATEDIR/verifies"
    st="${KAT_STUB_VERIFY_STATUS:-303}"
    if [ "$st" = 303 ]; then
      case "$url" in
        *"${KAT_STUB_VERIFY_PATH:-/auth/v1/verify}"*)
          printf 'HTTP/2 303\r\ncontent-type: text/html; charset=utf-8\r\nlocation: %s#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired\r\n' \
            "${KAT_STUB_VERIFY_LANDING:-${KAT_STUB_SITE_URL:-$SITE}}"
          ;;
        *) printf 'HTTP/2 404\r\ncontent-type: text/html\r\n' ;;
      esac
    else
      printf 'HTTP/2 %s\r\ncontent-type: text/html\r\n' "$st"
    fi
    ;;
  *) printf 'HTTP/2 404\r\n' ;;
esac
STUB

cat >"$BIN/identity_allowlist_sync.sh" <<'STUB'
#!/usr/bin/env bash
exit "${KAT_STUB_SYNC_EXIT:-0}"
STUB

cat >"$BIN/docker" <<'STUB'
#!/usr/bin/env bash
# docker stub: only the reads the probe makes (inspect, exec printenv).  The
# single-key form is what the site half uses; the BULK form is the environment
# dump the mail half reads once, with each key independently overridable.
cmd="${1:-}"; shift || true
case "$cmd" in
  inspect) exit 0 ;;
  exec)
    shift || true                      # container name
    if [ "${1:-}" = printenv ]; then
      key="${2:-}"
      if [ -n "$key" ]; then
        case "$key" in
          GOTRUE_SITE_URL) printf '%s' "${KAT_STUB_CONTAINER_SITE:-}" ;;
        esac
        exit 0
      fi
      [ "${KAT_STUB_NO_ENV:-0}" = 1 ] && exit 0
      printf 'GOTRUE_SITE_URL=%s\n' "${KAT_STUB_CONTAINER_SITE:-${KAT_STUB_SITE_URL:-}}"
      # Single-dash defaults: an explicitly EMPTY value (e.g. a hook with no
      # URI) must survive as empty, not fall back to the healthy default.
      printf 'GOTRUE_MAILER_URLPATHS_CONFIRMATION=%s\n' "${KAT_STUB_PATHS_CONFIRMATION-/auth/v1/verify}"
      printf 'GOTRUE_MAILER_URLPATHS_RECOVERY=%s\n' "${KAT_STUB_PATHS_RECOVERY-/auth/v1/verify}"
      printf 'GOTRUE_MAILER_AUTOCONFIRM=%s\n' "${KAT_STUB_AUTOCONFIRM-false}"
      printf 'GOTRUE_EXTERNAL_EMAIL_ENABLED=%s\n' "${KAT_STUB_EMAIL_ENABLED-true}"
      printf 'GOTRUE_HOOK_SEND_EMAIL_ENABLED=%s\n' "${KAT_STUB_HOOK_ON-true}"
      printf 'GOTRUE_HOOK_SEND_EMAIL_URI=%s\n' "${KAT_STUB_HOOK_URI-https://auth.test/functions/v1/auth-email}"
      exit 0
    fi
    exit 1 ;;
  *) exit 1 ;;
esac
STUB

cat >"$BIN/alert.sh" <<'STUB'
send_webhook_alert()  { echo webhook  >>"$CALLS"; }
send_gotify_alert()   { echo gotify   >>"$CALLS"; }
send_email_alert()    { echo email    >>"$CALLS"; }
send_brevo_alert()    { echo brevo    >>"$CALLS"; }
send_telegram_alert() { echo telegram >>"$CALLS"; }
STUB
chmod +x "$BIN/curl" "$BIN/identity_allowlist_sync.sh" "$BIN/docker"

export PATH="$BIN:$PATH"
export STATEDIR="$STATES" SITE="$SITE" CALLS="$CALLS"
export KAT_STUB_SITE_URL="$SITE"
export KAT_STUB_ALLOWLIST="$ALLOW"
export IDENTITY_ALLOWLIST_LIST="$LIST"
export IDENTITY_ALLOWLIST_SYNC="$BIN/identity_allowlist_sync.sh"
export IDENTITY_API_BASE="https://api.test/v1"
export IDENTITY_PROBE_LOG="$LOGS/probe.log"
export IDENTITY_PROBE_STATE="$LOGS/probe.state"
export IDENTITY_ALERT_LIB="$BIN/alert.sh"

# The deployed send-email hook, which is what actually renders the two mail
# links.  The fixture mirrors the real renderer: the base comes from the
# `site_url` GoTrue hands it, and the path is appended there.
HOOK_FIXTURE="$WORK/hook/index.ts"
mkdir -p "$WORK/hook"
write_hook() { # <path> — the healthy renderer
  cat >"$1" <<'HOOK'
function verifyLink(d: EmailData, tokenHash?: string): string {
  const base = (d.site_url ?? "").replace(/\/+$/, "");
  return `${base}/auth/v1/verify?token=${encodeURIComponent(tokenHash ?? "")}&type=${d.email_action_type}`;
}
HOOK
}
write_hook_other() { # <path> — renders a path the declaration does not name
  cat >"$1" <<'HOOK'
function verifyLink(d: EmailData): string {
  const base = (d.site_url ?? "").replace(/\/+$/, "");
  return `${base}/auth/v1/verify-other?token=${encodeURIComponent(d.token ?? "")}&type=${d.email_action_type}`;
}
HOOK
}
write_hook_hardcoded() { # <path> — an origin of its own, not the one GoTrue hands it
  cat >"$1" <<'HOOK'
function verifyLink(d: EmailData): string {
  const base = "https://katalogus.mediasart.com";
  return `${base}/auth/v1/verify?token=${encodeURIComponent(d.token ?? "")}&type=${d.email_action_type}`;
}
HOOK
}
write_hook "$HOOK_FIXTURE"
export IDENTITY_MAIL_HOOK_FILE="$HOOK_FIXTURE"

probe() { bash "$SUT" --local "$@"; }
allow() { printf '%s\n' "$@" >"$ALLOW"; }        # what the stub stack HONOURS
reset_alert() { : >"$CALLS"; rm -f "$IDENTITY_PROBE_STATE"; }
# How many /authorize flows the stub stack has started (one per probed target).
authorizes() { cat "$STATES/counter" 2>/dev/null || echo 0; }
# How many /verify requests the mail half has made (one per declared mail link).
verifies() { cat "$STATES/verifies" 2>/dev/null || echo 0; }

# --------------------------------------------------------- 1. harness sanity --- #
echo "== 1. harness sanity =="
[ -x "$SUT" ] || { echo "probe not executable"; exit 1; }
head -1 "$SUT" | grep -q '^#!/usr/bin/env bash' && ok "probe has a bash shebang" || bad "missing shebang"
[ -x "$BIN/curl" ] && ok "stub curl is executable and first on PATH" || bad "stub curl not on PATH"
"$BIN/curl" -G "https://api.test/v1/authorize" redirect_to=x >/dev/null && ok "stub curl answers /authorize" || bad "stub curl broken"
bash -n "$SUT" && ok "probe parses" || bad "probe does not parse"

# ------------------------------------------------ 2. healthy stack passes --- #
echo
echo "== 2. a healthy stack passes =="
allow "$WEB_EN" "$WEB_IT" "$NATIVE"
out="$(probe)"; rc=$?
[ "$rc" = 0 ] && ok "healthy run exits 0" || bad "healthy run exited $rc"
has "$out" "PASS — the stack honours every declared redirect." && ok "report says PASS" || bad "no PASS line"
has "$out" "✓ $NATIVE — honoured → $NATIVE" && ok "the native entry is reported honoured" || bad "native entry not reported honoured"
has "$out" "(control) ✓ control not honoured" && ok "control is exercised and not honoured" || bad "control line missing/unexpected"
has "$out" "allow list:  in sync" && ok "presence half reports in sync" || bad "presence not reported in sync"

# ------------------------------------------------ 3. --check is one line --- #
echo
echo "== 3. --check is a one-line gate =="
out="$(probe --check)"; rc=$?
[ "$rc" = 0 ] && ok "--check exits 0 when healthy" || bad "--check exited $rc"
[ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] && ok "--check prints exactly one line" || bad "--check printed $(printf '%s\n' "$out" | grep -c .) lines"
has "$out" "PASS oauth-handoff:" && ok "--check verdict line is present" || bad "no verdict line"
lacks "$out" "== verdict ==" && ok "--check omits the report sections" || bad "--check printed report sections"

# -------------------------------- 4. the silent rewrite is caught (core) --- #
echo
echo "== 4. a declared entry the stack does not honour is FAIL =="
allow "$WEB_EN" "$WEB_IT"          # native entry dropped from the stack
out="$(probe)"; rc=$?
[ "$rc" = 1 ] && ok "dropped entry -> exit 1" || bad "expected exit 1, got $rc"
has "$out" "✗ $NATIVE — REWRITTEN to $SITE" && ok "finding names the rewrite to the site URL" || bad "finding did not name the rewrite"
has "$out" "FAIL — a declared redirect is not honoured" && ok "report says FAIL" || bad "no FAIL line"
out="$(probe --check)"; rc=$?
[ "$rc" = 1 ] && has "$out" "FAIL oauth-handoff:" && ok "--check gate fails on the drop" || bad "--check did not fail on the drop"

# -------------------------------- 5. the match is equality, not prefix --- #
echo
echo "== 5. a prefix of the entry must not pass =="
allow "$WEB_EN" "${WEB_EN}extra"        # the stack honours the LONGER target
LIST2="$WORK/declaration-prefix.txt"
printf '%s\n' "$WEB_EN" >"$LIST2"          # declared: the shorter one
export KAT_STUB_FORCE_TARGET="${WEB_EN}extra"
out="$(probe --no-control --list "$LIST2")"; rc=$?
[ "$rc" = 1 ] && ok "a target that merely starts with the entry still fails" || bad "prefix match slipped through (exit $rc)"
has "$out" "REWRITTEN to ${WEB_EN}extra" && ok "finding shows the diverging longer target" || bad "finding did not show divergence"
unset KAT_STUB_FORCE_TARGET

# ------------------------------------------------ 6. the control bites --- #
echo
echo "== 6. an honoured control target fails the probe =="
allow "$WEB_EN" "$WEB_IT" "$NATIVE" "https://unlisted.invalid/oauth-callback/"
out="$(probe)"; rc=$?
[ "$rc" = 1 ] && ok "control honoured -> exit 1" || bad "expected exit 1, got $rc"
has "$out" "control target WAS honoured" && ok "finding explains the probe cannot distinguish" || bad "no control finding"
out="$(probe --no-control)"; rc=$?
[ "$rc" = 0 ] && ok "--no-control opts out and passes" || bad "--no-control did not opt out ($rc)"

# ------------------------------------------------ 7. presence half --- #
echo
echo "== 7. the presence half is folded in =="
allow "$WEB_EN" "$WEB_IT" "$NATIVE"
out="$(KAT_STUB_SYNC_EXIT=1 probe)"; rc=$?
[ "$rc" = 1 ] && has "$out" "allow list:  DRIFT" && ok "a DRIFT from the allow-list tool fails the probe" || bad "presence DRIFT not propagated ($rc)"
out="$(IDENTITY_ALLOWLIST_SYNC=/nonexistent probe)"; rc=$?
[ "$rc" = 0 ] && has "$out" "allow list:  unknown" && ok "absent allow-list tool degrades to unknown, hand-off still passes" || bad "absent tool mishandled ($rc)"

# ------------------------------------------------ 8. unreachable API --- #
echo
echo "== 8. an unreachable API fails every entry =="
out="$(KAT_STUB_AUTHFAIL=1 probe)"; rc=$?
[ "$rc" = 1 ] && ok "unreachable API -> exit 1" || bad "expected exit 1, got $rc"
has "$out" "no /authorize hand-off" && ok "finding names the unreachable API" || bad "unreachable API not explained"

# ------------------------------------------------ 9. alert transitions --- #
echo
echo "== 9. --alert notifies once per failure, and on recovery =="
allow "$WEB_EN" "$WEB_IT"          # native dropped
reset_alert
probe --alert >/dev/null 2>&1
n1="$(grep -c . "$CALLS" 2>/dev/null || echo 0)"
[ "$n1" = 5 ] && ok "first failure fans out to all five channels" || bad "expected 5 alert calls, got $n1"
[ -f "$IDENTITY_PROBE_STATE" ] && ok "failure state was recorded" || bad "no state file after a failure"
probe --alert >/dev/null 2>&1
n2="$(grep -c . "$CALLS" 2>/dev/null || echo 0)"
[ "$n2" = 5 ] && ok "an unchanged failure does not re-alert" || bad "re-alerted on unchanged failure ($n1 -> $n2)"
grep -q "not repeating" "$IDENTITY_PROBE_LOG" && ok "the log records the suppression" || bad "no suppression log line"
allow "$WEB_EN" "$WEB_IT" "$NATIVE"   # recovered
probe --alert >/dev/null 2>&1
n3="$(grep -c . "$CALLS" 2>/dev/null || echo 0)"
[ "$n3" = 10 ] && ok "recovery fans out once more" || bad "expected 10 total calls, got $n3"
[ ! -f "$IDENTITY_PROBE_STATE" ] && ok "recovery clears the state" || bad "state not cleared on recovery"

# ------------------------------------------------ 10. declaration handling --- #
echo
echo "== 10. the declaration is the only place entries come from =="
cat >"$LIST" <<'LIST'
# a comment
https://mediasart.com/en/oauth-callback/

   # an indented comment
katalogus://auth-callback
LIST
allow "https://mediasart.com/en/oauth-callback/" "$NATIVE"
out="$(probe --no-control)"; rc=$?
[ "$rc" = 0 ] && ok "comments and blanks are ignored; only real entries are probed" || bad "declaration parsing wrong ($rc)"
has "$out" "declaration: $LIST (2 entries)" && ok "entry count reflects the real lines" || bad "entry count wrong"
empty="$WORK/empty.txt"; : >"$empty"
out="$(probe --list "$empty" 2>&1)"; rc=$?
[ "$rc" = 3 ] && ok "an empty declaration is a configuration error (exit 3)" || bad "empty declaration not refused ($rc)"

# -------------------------------------------- 11. the site URL assertion --- #
echo
echo "== 11. the site URL the declaration assumes is asserted =="
cp "$DECL" "$LIST"                                   # phase 10 overwrote it
allow "$WEB_EN" "$WEB_IT" "$NATIVE"
out="$(probe --no-control)"; rc=$?
[ "$rc" = 0 ] && ok "a healthy site URL passes" || bad "healthy site URL run exited $rc"
has "$out" "== site URL (where an unlisted redirect lands) ==" && ok "report has a site URL section" || bad "no site URL section"
has "$out" "declared:  $SITE" && ok "the declared site URL is shown" || bad "declared site URL not shown"
has "$out" "applied:   $SITE" && ok "the fallback the running auth actually applied is shown" || bad "applied reading not shown"
has "$out" "✓ the running auth still falls back to the declared site URL" && ok "the match is asserted, not assumed" || bad "no site URL verdict"
has "$out" "site url $SITE" && ok "the PASS summary names the asserted site URL" || bad "PASS summary omits the site URL"

# the APPLIED reading: an unlisted target lands on some other origin
echo
out="$(KAT_STUB_SITE_URL=https://elsewhere.example probe --no-control)"; rc=$?
[ "$rc" = 1 ] && ok "a fallback other than the declared one fails the probe" || bad "expected exit 1 for a mis-set site URL, got $rc"
has "$out" "site URL MISMATCH: an unmatched redirect resolves to https://elsewhere.example, the declaration assumes $SITE" \
  && ok "the mismatch names both the applied and the declared origin" || bad "the site URL mismatch is not explained"
has "$out" "site URL MISMATCH" && ok "the mismatch rides into the summary" || bad "mismatch missing from the summary"
# A mis-set site URL is also visible in the mail half (the confirmation and
# recovery links land on it), so the verdict may name both halves — what it must
# not do is blame a redirect that was in fact honoured.
has "$out" "FAIL — the redirects are honoured, but the site URL" \
  && ok "the verdict names the site URL rather than blaming a redirect" || bad "the verdict misattributes the failure"
lacks "$out" "a declared redirect is not honoured" && ok "the verdict does not blame a redirect that was honoured" || bad "the verdict blames a redirect"
out="$(KAT_STUB_SITE_URL=https://elsewhere.example probe --check)"; rc=$?
[ "$rc" = 1 ] && has "$out" "FAIL oauth-handoff:" && ok "--check gates on a mis-set site URL" || bad "--check missed the site URL ($rc)"

# the CONTAINER reading: a process running a value the stack no longer holds
echo
out="$(KAT_STUB_CONTAINER_SITE=https://stale.example probe --no-control)"; rc=$?
[ "$rc" = 1 ] && ok "a container GOTRUE_SITE_URL that disagrees fails" || bad "expected exit 1 for a stale container reading, got $rc"
has "$out" "the running auth's GOTRUE_SITE_URL is https://stale.example, the declaration assumes $SITE" \
  && ok "the container reading is the one blamed" || bad "container reading not named"

# An assertion that cannot be taken is not a pass.  Here every declared entry is
# honoured, so only the site check can fail — the probe target is allow-listed,
# so where an unlisted target lands (and thus the site URL) cannot be observed.
echo
SITE_UNLISTED="https://unlisted.invalid/site-url-probe/"
allow "$WEB_EN" "$WEB_IT" "$NATIVE" "$SITE_UNLISTED"
out="$(probe --no-control)"; rc=$?
[ "$rc" = 1 ] && ok "an unobservable site URL fails even though every entry is honoured" \
  || bad "an unobservable site URL was reported as checked ($rc)"
has "$out" "site URL UNVERIFIED" && ok "the finding says the assertion could not be made" || bad "no UNVERIFIED finding"
has "$out" "could not be confirmed against the running auth" && ok "the verdict does not claim what was not observed" \
  || bad "the verdict overclaims on an unobservable site URL"
has "$out" "✓ $NATIVE — honoured" && ok "the entries were healthy, so the site check is what failed" || bad "the entries were not healthy in this run"
lacks "$out" "applied:   $SITE" && ok "no applied reading is fabricated" || bad "an applied reading was invented"

# --------------------------------------- 12. directives are never entries --- #
echo
echo "== 12. a directive is never treated as an entry =="
cat >"$LIST" <<LIST
# a directive plus the entries it configures
site_url=$SITE
$WEB_EN
$NATIVE
LIST
allow "$WEB_EN" "$NATIVE"
out="$(probe --no-control)"; rc=$?
[ "$rc" = 0 ] && ok "a declaration carrying a directive still passes" || bad "directive declaration exited $rc"
has "$out" "declaration: $LIST (2 entries)" && ok "the directive is not counted as an entry" || bad "entry count includes the directive"
lacks "$out" "site_url=$SITE" && ok "the directive never reaches the probed entry list" || bad "the directive leaked into the entry list"
has "$out" "declared:  $SITE" && ok "the directive is read as configuration instead" || bad "the directive is not read as configuration"

# a mistyped directive must not silently disable the assertion
cat >"$LIST" <<LIST
site_urll=$SITE
$WEB_EN
$NATIVE
LIST
allow "$WEB_EN" "$NATIVE"
out="$(probe --no-control)"; rc=$?
[ "$rc" = 1 ] && ok "a directive key nothing asserts fails the probe" || bad "a mistyped directive passed ($rc)"
has "$out" "declaration directive(s) nothing asserts: site_urll" && ok "the unknown key is named" || bad "the unknown directive is not named"
lacks "$out" "site url $SITE" && ok "no site URL was reported as checked" || bad "a site URL was claimed despite the typo"

# ------------------------------- 13. the site probe costs one flow, if asked --- #
echo
echo "== 13. the extra /authorize is spent only when site_url is declared =="
cat >"$LIST" <<LIST
$WEB_EN
$NATIVE
LIST
allow "$WEB_EN" "$NATIVE"
rm -f "$STATES/counter"
out="$(probe --no-control)"; rc=$?; n="$(authorizes)"
[ "$rc" = 0 ] && [ "$n" -eq 2 ] && ok "no directive: 2 entries cost 2 flows" || bad "no directive: rc=$rc flows=$n want 2"
has "$out" "· not declared — the declaration carries no site_url directive" && ok "an undeclared site URL is reported, not passed" || bad "undeclared site URL not reported"
lacks "$out" "site url $SITE" && ok "the summary does not claim an unchecked site URL" || bad "summary claims an unchecked site URL"
cp "$DECL" "$LIST"; allow "$WEB_EN" "$WEB_IT" "$NATIVE"
rm -f "$STATES/counter"
out="$(probe --no-control)"; rc=$?; n="$(authorizes)"
[ "$rc" = 0 ] && [ "$n" -eq 4 ] && ok "with a directive: 3 entries + the site probe cost 4 flows" || bad "with directive: rc=$rc flows=$n want 4"

# --------------------------- 14. the mail links are asserted per action --- #
echo
echo "== 14. the confirmation and recovery links are asserted too =="
cp "$DECL" "$LIST"; write_hook "$HOOK_FIXTURE"; allow "$WEB_EN" "$WEB_IT" "$NATIVE"
rm -f "$STATES/counter" "$STATES/verifies"
out="$(probe --no-control)"; rc=$?
[ "$rc" = 0 ] && ok "a healthy mail half passes" || bad "healthy mail run exited $rc"
has "$out" "== email links (confirmation & password recovery) ==" && ok "report has a mail-links section" || bad "no mail-links section"
has "$out" "origin:   $SITE" && ok "the declared site URL is named as the link origin" || bad "link origin not shown"
has "$out" "✓ confirmation link served at $SITE/auth/v1/verify" && ok "the confirmation link is followed for real" || bad "confirmation link not asserted"
has "$out" "✓ recovery link served at $SITE/auth/v1/verify" && ok "the recovery link is followed for real" || bad "recovery link not asserted"
has "$out" "hook renders the same link" && ok "the renderer that actually builds them is held to the declaration" || bad "renderer not asserted"
has "$out" "mail links served ✓" && ok "the PASS summary names the mail links" || bad "summary omits the mail links"
[ "$(verifies)" = 2 ] && ok "exactly one request per declared mail link" || bad "verifies=$(verifies) want 2"
[ "$(authorizes)" = 4 ] && ok "the mail half spends no /authorize flow" || bad "authorizes=$(authorizes) want 4"
out="$(probe --no-control --check)"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] && ok "--check is still a one-line gate with the mail half" || bad "--check regressed with the mail half (rc=$rc)"

# --------------------------------- 15. every mail-link drift class fails --- #
echo
echo "== 15. a drift in either mail link fails, and says which =="
cp "$DECL" "$LIST"; write_hook "$HOOK_FIXTURE"; allow "$WEB_EN" "$WEB_IT" "$NATIVE"

out="$(KAT_STUB_PATHS_RECOVERY=/auth/v1/verify-other probe --no-control)"; rc=$?
[ "$rc" = 1 ] && ok "a urlpath the declaration does not name fails" || bad "urlpath drift passed ($rc)"
has "$out" "recovery link MISMATCH: the running auth mails $SITE/auth/v1/verify-other, the declaration names $SITE/auth/v1/verify" \
  && ok "the urlpath finding names the action and both paths" || bad "urlpath finding unclear"
has "$out" "✗ recovery link MISMATCH" && ok "the drifted action is the one blamed" || bad "the wrong action was blamed"
has "$out" "✓ confirmation link served" && ok "the healthy action still reads as served" || bad "the healthy action was not reported"

out="$(KAT_STUB_VERIFY_LANDING=https://elsewhere.example probe --no-control)"; rc=$?
[ "$rc" = 1 ] && ok "a link that resolves to another origin fails" || bad "landing drift passed ($rc)"
has "$out" "link MISMATCH: the link resolves to https://elsewhere.example, the declaration assumes $SITE" \
  && ok "the landing finding names both origins" || bad "landing finding unclear"

out="$(KAT_STUB_VERIFY_PATH=/auth/v1/nowhere probe --no-control)"; rc=$?
[ "$rc" = 1 ] && ok "a link the origin does not serve to GoTrue fails" || bad "unserved link passed ($rc)"
has "$out" "NOT SERVED" && has "$out" "answered HTTP 404" && ok "the finding says the link dead-ends" || bad "unserved finding unclear"

printf 'site_url=%s\nmail_confirmation_path=/auth/v1/nope\nmail_recovery_path=/auth/v1/verify\n%s\n%s\n' \
  "$SITE" "$WEB_EN" "$NATIVE" >"$LIST"
out="$(probe --no-control)"; rc=$?
[ "$rc" = 1 ] && ok "a declaration naming a path GoTrue does not serve fails" || bad "unserved declared path passed ($rc)"
has "$out" "the running auth mails $SITE/auth/v1/verify, the declaration names $SITE/auth/v1/nope" \
  && ok "the finding judges both sides to the declaration" || bad "the declaration was not named"

cp "$DECL" "$LIST"
out="$(KAT_STUB_AUTOCONFIRM=true probe --no-control)"; rc=$?
[ "$rc" = 1 ] && ok "auto-confirm makes the confirmation link dead" || bad "auto-confirm passed ($rc)"
has "$out" "the confirmation link is DEAD: GOTRUE_MAILER_AUTOCONFIRM=true" && ok "the finding explains why no link is mailed" || bad "auto-confirm finding unclear"
out="$(KAT_STUB_EMAIL_ENABLED=false probe --no-control)"; rc=$?
[ "$rc" = 1 ] && ok "a disabled email provider makes the recovery link dead" || bad "disabled email passed ($rc)"
has "$out" "the recovery link is DEAD: GOTRUE_EXTERNAL_EMAIL_ENABLED=false" && ok "the finding explains the disabled provider" || bad "disabled-provider finding unclear"

write_hook_other "$HOOK_FIXTURE"
out="$(probe --no-control)"; rc=$?
[ "$rc" = 1 ] && ok "a hook that renders another path fails" || bad "hook path drift passed ($rc)"
has "$out" "link MISMATCH: the hook renders $SITE/auth/v1/verify-other" && ok "the hook's own path is named" || bad "hook path not named"
write_hook_hardcoded "$HOOK_FIXTURE"
out="$(probe --no-control)"; rc=$?
[ "$rc" = 1 ] && ok "a hook with an origin of its own fails" || bad "hardcoded host passed ($rc)"
has "$out" "does not build the link from site_url" && ok "the hardcoded origin is named as the problem" || bad "hardcoded origin not named"

write_hook "$HOOK_FIXTURE"
out="$(IDENTITY_MAIL_HOOK_FILE=/nonexistent/index.ts probe --no-control)"; rc=$?
[ "$rc" = 1 ] && ok "an unreadable renderer fails rather than passing" || bad "unreadable renderer passed ($rc)"
has "$out" "its source could not be read" && ok "the finding says the renderer could not be read" || bad "unreadable-renderer finding unclear"
out="$(KAT_STUB_HOOK_URI= probe --no-control)"; rc=$?
[ "$rc" = 1 ] && ok "a hook enabled with no URI fails" || bad "hook with no URI passed ($rc)"
has "$out" "no GOTRUE_HOOK_SEND_EMAIL_URI" && ok "the finding names the missing URI" || bad "missing URI not named"
out="$(KAT_STUB_NO_ENV=1 probe --no-control)"; rc=$?
[ "$rc" = 1 ] && ok "an unreadable running auth fails the mail half" || bad "unreadable auth passed ($rc)"
has "$out" "link UNVERIFIED" && ok "an assertion that could not be taken is not a pass" || bad "an unverified link read as checked"
out="$(KAT_STUB_VERIFY_STATUS=429 probe --no-control)"; rc=$?
[ "$rc" = 1 ] && ok "a rate-limited probe fails rather than reading as healthy" || bad "429 passed ($rc)"
has "$out" "rate limited" && ok "the finding distinguishes rate limiting" || bad "429 finding unclear"
out="$(KAT_STUB_HOOK_ON=false probe --no-control)"; rc=$?
[ "$rc" = 0 ] && ok "with the hook off GoTrue's own templates render the link" || bad "hook-off run exited $rc"
has "$out" "renderer: GoTrue's own templates" && ok "the report says which renderer is in use" || bad "renderer not reported"

# ---------------- 16. the mail half costs no flow, and stays out of the way --- #
echo
echo "== 16. the mail half costs no /authorize flow and stays out of the way =="
write_hook "$HOOK_FIXTURE"; allow "$WEB_EN" "$WEB_IT" "$NATIVE"
printf '%s\n%s\n%s\n%s\n' "site_url=$SITE" "$WEB_EN" "$WEB_IT" "$NATIVE" >"$LIST"
rm -f "$STATES/counter" "$STATES/verifies"
out="$(probe --no-control)"; rc=$?; n="$(authorizes)"; v="$(verifies)"
[ "$rc" = 0 ] && [ "$n" = 4 ] && ok "with no mail directives: still 4 flows" || bad "no mail: rc=$rc flows=$n want 4"
[ "$v" = 0 ] && ok "with no mail directives: no /verify request is spent" || bad "no mail: verifies=$v want 0"
lacks "$out" "== email links" && ok "with no mail directives: the mail half stays out of the way" || bad "mail section printed without directives"
lacks "$out" "mail links served" && ok "the summary claims no mail link it never checked" || bad "summary overclaims"
printf 'mail_confirmation_path=/auth/v1/verify\n%s\n%s\n' "$WEB_EN" "$NATIVE" >"$LIST"
out="$(probe --no-control)"; rc=$?
[ "$rc" = 1 ] && ok "a mail directive with no site_url to root it at is refused" || bad "unrooted mail directive passed ($rc)"
has "$out" "rooted at the site_url directive" && ok "the finding explains the missing origin" || bad "unrooted finding unclear"
printf 'site_url=%s\nmail_confirmation_pathh=/auth/v1/verify\n%s\n%s\n' "$SITE" "$WEB_EN" "$NATIVE" >"$LIST"
out="$(probe --no-control)"; rc=$?
[ "$rc" = 1 ] && has "$out" "nothing asserts: mail_confirmation_pathh" && ok "a typo in a mail directive is caught too" || bad "mail directive typo not caught ($rc)"

# ------------------------ 17. the verdict names which half failed --- #
echo
echo "== 17. the verdict says which half failed =="
cp "$DECL" "$LIST"; write_hook "$HOOK_FIXTURE"; allow "$WEB_EN" "$WEB_IT" "$NATIVE"
out="$(KAT_STUB_AUTOCONFIRM=true probe --no-control)"; rc=$?
[ "$rc" = 1 ] && has "$out" "FAIL — the redirects are honoured, but the confirmation/recovery links the declaration names could not be confirmed against the running stack" \
  && ok "a mail-only failure gets the mail verdict" || bad "mail-only verdict missing"
lacks "$out" "the site URL the declaration assumes could not be confirmed" && ok "the mail-only verdict does not blame the site URL" || bad "the mail-only verdict blames the site URL"
out="$(KAT_STUB_AUTOCONFIRM=true KAT_STUB_SITE_URL=https://elsewhere.example probe --no-control)"; rc=$?
[ "$rc" = 1 ] && has "$out" "the site URL and the mail links the declaration assumes could not be confirmed" \
  && ok "both halves failing are both named" || bad "combined verdict missing"

cp "$DECL" "$LIST"; write_hook "$HOOK_FIXTURE"
echo
echo "================================================"
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" = 0 ]
