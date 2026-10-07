#!/usr/bin/env bash
# ============================================================================
# oauth_handoff_probe.sh — nightly end-to-end probe of the central identity
# stack's OAuth hand-off.
#
# The allow-list guard (identity_allowlist_sync.sh --check) proves an entry is
# PRESENT in `.env` and in the running auth process.  It cannot prove the entry
# is HONOURED: GoTrue validates `redirect_to` deep inside the flow, and a target
# that is not on the list is not rejected — it is silently rewritten to
# GOTRUE_SITE_URL.  That failure has no error and no metric; it only shows up at
# the end of a real sign-in, on the rare occasion someone notices the app never
# came back.  This probe exercises the real validation and alerts instead.
#
# How it observes the hand-off WITHOUT credentials:
#   1. GET {api}/authorize?provider=<p>&redirect_to=<entry> — a real flow is
#      started; the 302 to the provider echoes the target and carries `state`.
#   2. GET {api}/callback?state=<state>&code=<bogus> — GoTrue resolves the
#      stored target and 302s the browser there, appending `?error=...`.
#   A target that IS on the list appears verbatim in that second Location; a
#   target that is NOT is replaced by GOTRUE_SITE_URL.  Nothing is exchanged,
#   no credentials are used, and the flow is abandoned after step 2.
#
# For each entry it asserts: the /callback Location, cut at the first `?` or
# `#`, equals the declared entry exactly.  It also asserts a CONTROL: a target
# that is deliberately not declared must NOT be honoured.  The control is what
# makes a pass meaningful — without it, a probe that could not fail would look
# identical to a healthy stack.
#
# The same control request answers a second question for free: WHERE an unlisted
# target lands is the running auth's GOTRUE_SITE_URL, observed in flight.  Since
# every dropped entry is rewritten to exactly that origin, a site URL mis-set to
# somewhere that cannot finish a sign-in is invisible the same way a dropped
# entry is — and it is the destination of every drop.  So the probe compares
# that applied value against the `site_url` directive in the declaration, and
# additionally against the running container's own GOTRUE_SITE_URL when docker
# is reachable (that second reading is what distinguishes a `.env` the process
# never picked up from a genuinely mis-set value).  A declaration with no
# `site_url` directive leaves this check reported as undeclared, not passed.
# When the directive IS present, the assertion is required: if neither reading
# can be taken, the probe fails rather than reporting the site URL as checked.
# Exactly three directives mean anything — `site_url`,
# `mail_confirmation_path`, `mail_recovery_path` (the last two below) — so a
# `key=value` line naming any other key fails too: a mistyped directive must not
# silently disable the assertion it was meant to add.
#
# The same run asserts where the two MAIL links point.  A signup confirmation
# and a password recovery are the two mails that hand a member a link, and both
# are built as <GOTRUE_SITE_URL> + one path — so a wrong origin there breaks a
# registration or a password reset at the last step, silently, in exactly the
# shape this probe exists for.  That half needs its own assertion because the
# link is NOT built by GoTrue's templates: the stack delegates every mail to the
# `auth-email` send-email hook (`GOTRUE_HOOK_SEND_EMAIL_*`), which renders the
# link from the `site_url` GoTrue hands it.  So per action the probe holds the
# declaration's `mail_<action>_path` (and the declared `site_url` as its origin)
# to four independent readings:
#   config  — the running auth's own GOTRUE_MAILER_URLPATHS_<ACTION>;
#   in flight — a real GET of the link's origin+path (it must be answered by
#             GoTrue, not by the web app, and must land on the declared origin;
#             with a bogus token the error arrives in the fragment, unlike the
#             OAuth path's `?`);
#   renderer — the hook's rendering as deployed on disk: the path it appends and
#             the fact that its origin comes from `site_url` rather than a
#             hardcoded host, which is the drift no config check can see;
#   armed   — a stack with GOTRUE_MAILER_AUTOCONFIRM=true never mails a
#             confirmation link and one with GOTRUE_EXTERNAL_EMAIL_ENABLED=false
#             never mails anything, so an assertion about those links would be
#             vacuous there; that is reported as a failure, not a pass.
# A mail directive with no `site_url` to root it at is refused for the same
# reason: the origin would be unknowable.
#
# FOOTPRINT: each /authorize persists one `auth.flow_state` row (expired and
# swept by GoTrue's own cleanup).  A run costs one row per declared entry plus
# one for the control — a handful per night — plus two plain GETs for the mail
# half, which are sent to the link's own URL with a bogus token: GoTrue answers
# `otp_expired`, no token is consumed and nothing is mailed.
#
# It also folds in the presence check by invoking the deployed allow-list tool
# in --check mode (IDENTITY_ALLOWLIST_SYNC); if that tool is not present the
# presence half is reported as unknown and the hand-off half still runs.
#
#   bash tool/oauth_handoff_probe.sh           # verbose report; exit 1 on failure
#   bash tool/oauth_handoff_probe.sh --check   # one verdict line (cron/CI)
#   bash tool/oauth_handoff_probe.sh --alert   # transition-only fan-out (cron)
#   bash tool/oauth_handoff_probe.sh --local   # run where the stack lives (VM)
#
# Exit: 0 pass · 1 failure (an entry not honoured, control honoured, the site URL
#       or a mail link mis-set, unserved, unarmed or unobservable, or drift) ·
#       3 usage/configuration error.
#
# Env overrides: IDENTITY_API_BASE, IDENTITY_PROBE_PROVIDER,
#   IDENTITY_PROBE_TIMEOUT, IDENTITY_PROBE_CODE, IDENTITY_PROBE_CONTROL,
#   IDENTITY_ALLOWLIST_LIST, IDENTITY_ALLOWLIST_SYNC, IDENTITY_PROBE_LOG,
#   IDENTITY_PROBE_STATE, IDENTITY_ALERT_LIB, IDENTITY_AUTH_CONTAINER,
#   IDENTITY_STACK_DIR, IDENTITY_MAIL_HOOK_FILE, KAT_SSH_KEY, KAT_VM_HOST,
#   KAT_VM_USER.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE=report
LOCAL=0
ALERT=0
CONTROL=1
LIST="${IDENTITY_ALLOWLIST_LIST:-$SCRIPT_DIR/identity-redirect-allowlist.txt}"
SYNC="${IDENTITY_ALLOWLIST_SYNC:-$HOME/bin/identity_allowlist_sync.sh}"
API="${IDENTITY_API_BASE:-https://auth.mediasart.com/auth/v1}"
PROVIDER="${IDENTITY_PROBE_PROVIDER:-google}"
TIMEOUT="${IDENTITY_PROBE_TIMEOUT:-20}"
CODE="${IDENTITY_PROBE_CODE:-bogus-probe-code}"
CTRL="${IDENTITY_PROBE_CONTROL:-https://unlisted.invalid/oauth-callback/}"
# A second, distinct unlisted target: where IT lands is the running auth's
# GOTRUE_SITE_URL as applied.  Kept distinct from the control so that one being
# honoured cannot mask whether the other fell back.
SITE_PROBE="${IDENTITY_PROBE_SITE_TARGET:-https://unlisted.invalid/site-url-probe/}"
LOG="${IDENTITY_PROBE_LOG:-$HOME/logs/oauth-handoff-probe.log}"
STATE="${IDENTITY_PROBE_STATE:-$HOME/logs/oauth-handoff-probe.state}"
ALERT_LIB="${IDENTITY_ALERT_LIB:-$HOME/bin/alert.sh}"
# The service container that applies the allow list; only ever read (printenv).
AUTH_CONTAINER="${IDENTITY_AUTH_CONTAINER:-identity-auth-1}"
# The deployed stack directory — used for one thing only: reading the
# send-email hook's source, which is what actually renders the confirmation and
# recovery links.  The probe runs on the VM (remote mode re-executes itself
# there), so the default is the VM's deployment path; --local elsewhere needs
# these overridden.
STACK_DIR="${IDENTITY_STACK_DIR:-/home/ubuntu/Projects/kommons/supabase-identity/docker}"
HOOK_FILE="${IDENTITY_MAIL_HOOK_FILE:-$STACK_DIR/volumes/functions/auth-email/index.ts}"

VM="${KAT_VM_USER:-ubuntu}@${KAT_VM_HOST:-80.225.89.206}"
SSH_KEY="${KAT_SSH_KEY:-$HOME/.ssh/katalogus}"
[ -f "$SSH_KEY" ] || SSH_KEY="${KAT_SSH_KEY:-$HOME/Apps/Projects/keys/ssh-private-key.key}"
SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=20
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

usage() { sed -n '2,/^set -uo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d'; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) MODE=check ;;
    --report) MODE=report ;;
    --alert) ALERT=1 ;;
    --local) LOCAL=1 ;;
    --remote) LOCAL=0 ;;
    --no-control) CONTROL=0 ;;
    --list) LIST="${2:?--list needs a file}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "oauth_handoff_probe: unknown argument: $1" >&2; exit 3 ;;
  esac
  shift
done

# --- shared helpers -------------------------------------------------------- #
note() { printf '   %s\n' "$*"; }
warn() { printf '   WARN %s\n' "$*" >&2; }
now() { date '+%Y-%m-%dT%H:%M:%S%z'; }
fp() { printf '%s' "$1" | sha256sum | cut -c1-16; }
NL=$'\n'

log_line() {
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || return 0
  printf '%s\n' "$1" >>"$LOG"
}

read_declared() { # the declared ENTRIES, in file order, one per line
  [ -f "$LIST" ] || { echo "oauth_handoff_probe: declaration not found at $LIST" >&2; exit 3; }
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/ { next }
    { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print }
  ' "$LIST"
}

# declared_directive <key> — the value of a `key=value` directive in the
# declaration, or empty.  `site_url`, `mail_confirmation_path` and
# `mail_recovery_path` are the three there are.
declared_directive() {
  [ -f "$LIST" ] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$LIST" \
    | head -1 | tr -d '"' | tr -d '[:space:]'
}

# directive_keys — every `key=value` directive KEY in the declaration, one per
# line.  Used to refuse a directive nothing reads: a mistyped `site_urll=`
# would otherwise disable the site-URL assertion while still reporting a pass.
directive_keys() {
  [ -f "$LIST" ] || return 0
  sed -n 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$LIST"
}

# live_env <KEY> — <KEY> as the RUNNING auth container holds it, or empty when it
# cannot be read (no docker, no such container).  Best-effort and never fatal on
# its own: each caller decides whether an unreadable value is a failure.
live_env() {
  command -v docker >/dev/null 2>&1 || return 0
  docker inspect "$AUTH_CONTAINER" >/dev/null 2>&1 || return 0
  docker exec "$AUTH_CONTAINER" printenv "$1" 2>/dev/null || true
}

# live_env_site_url — GOTRUE_SITE_URL as the RUNNING auth holds it.  The applied
# reading already carries the site-URL assertion; this one exists to name a
# file-versus-process divergence in the failure text.
live_env_site_url() { live_env GOTRUE_SITE_URL; }

# live_mail_env — the whole environment of the RUNNING auth, one `KEY=value` per
# line, or empty when it cannot be read.  The mail half consults six keys; one
# `docker exec` for all of them costs less than the probe's own HTTP work.
live_mail_env() {
  command -v docker >/dev/null 2>&1 || return 0
  docker inspect "$AUTH_CONTAINER" >/dev/null 2>&1 || return 0
  docker exec "$AUTH_CONTAINER" printenv 2>/dev/null || true
}

# live_value <env-dump> <KEY> — the value of KEY in a `printenv` dump, or empty.
live_value() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

# probe_site_url — the origin the running auth resolves an UNLISTED redirect to,
# i.e. GOTRUE_SITE_URL as applied rather than as written down.  Prints the URL,
# or prints nothing and fails when it cannot be observed (no hand-off, or the
# target was honoured so no fallback happened).
probe_site_url() {
  local st loc clean
  st="$(authorize_state "$SITE_PROBE")" || return 1
  [ -n "$st" ] || return 1
  loc="$(callback_target "$st")"
  [ -n "$loc" ] || return 1
  clean="$(clean_loc "$loc")"
  [ "$clean" = "$SITE_PROBE" ] && return 1
  printf '%s' "$clean"
}

# clean_loc <url> — the URL up to the first `?` or `#`; GoTrue appends its error
# params after one of those, and the allow-list match is on the bare target.
clean_loc() { printf '%s' "$1" | sed 's/[?#].*$//'; }

# http_location <curl-args...> — the first Location header of a non-following
# request, or empty.  Reads stdout only; a connection error yields empty.
http_location() {
  curl -sS -D - -o /dev/null --max-time "$TIMEOUT" "$@" 2>/dev/null \
    | awk 'BEGIN{IGNORECASE=1} /^location:[[:space:]]*/ { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }' \
    | tr -d '\r'
}

# authorize_state <redirect_to> — starts a real flow and returns its `state`.
authorize_state() {
  local loc
  loc="$(http_location -G "$API/authorize" \
            --data-urlencode "provider=$PROVIDER" \
            --data-urlencode "redirect_to=$1")"
  [ -n "$loc" ] || return 1
  printf '%s' "$loc" | grep -oE 'state=[^&[:space:]]+' | head -1 | cut -d= -f2-
}

# callback_target <state> — the target GoTrue resolves for that flow.
callback_target() {
  http_location -G "$API/callback" \
    --data-urlencode "state=$1" \
    --data-urlencode "code=$CODE"
}

# probe_one <entry> — echoes "OK <finding>" or "FAIL <finding>".  The status
# rides in the output because a command substitution runs in a subshell, so a
# variable set inside would not reach the caller.
probe_one() {
  local entry="$1" st loc clean
  st="$(authorize_state "$entry")" || { printf 'FAIL no /authorize hand-off (%s unreachable or provider disabled)' "$API"; return; }
  [ -n "$st" ] || { printf 'FAIL no state in the /authorize redirect'; return; }
  loc="$(callback_target "$st")"
  [ -n "$loc" ] || { printf 'FAIL no /callback redirect for state %s' "$st"; return; }
  clean="$(clean_loc "$loc")"
  if [ "$clean" = "$entry" ]; then
    printf 'OK honoured → %s' "$clean"
  else
    printf 'FAIL REWRITTEN to %s (declared %s)' "${clean:-<empty>}" "$entry"
  fi
}

# --- the mail links: signup confirmation and password recovery ------------- #
#
# Both links GoTrue mails a member are <GOTRUE_SITE_URL> + one path, and — with
# the send-email hook enabled — they are rendered by the hook, not by GoTrue's
# templates.  The origin therefore has two authorities that must agree (the
# declaration's `site_url` and whatever the renderer uses), and the path three
# (the declaration, the stack's MAILER_URLPATHS_*, and the renderer's literal).
# Each is asserted per action, so a failure says which link broke.

# mail_actions — "<name> <action>" for every mail link the declaration names,
# one per line.  `name` is the word the directive uses, `action` is the GoTrue
# email action type the link carries in its `type=` parameter.
mail_actions() {
  local name
  for name in confirmation recovery; do
    [ -n "$(declared_directive "mail_${name}_path")" ] || continue
    case "$name" in
      confirmation) printf '%s signup\n' "$name" ;;
      recovery)     printf '%s recovery\n' "$name" ;;
    esac
  done
}

# mail_prefix <name> — how the running auth spells that action's env key.
mail_prefix() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# verify_response <url> — "<status>|<location>" for a request that does NOT
# follow redirects, or nothing when the request could not be made at all.  The
# status is what tells GoTrue's own answer apart from the web app's.
verify_response() {
  local hdrs st loc
  hdrs="$(curl -sS -D - -o /dev/null --max-time "$TIMEOUT" "$1" 2>/dev/null)" || hdrs=""
  [ -n "$hdrs" ] || return 1
  st="$(printf '%s\n' "$hdrs" | awk 'BEGIN{IGNORECASE=1} /^HTTP\// {c=$2} END{print c}' | tr -d '\r')"
  loc="$(printf '%s\n' "$hdrs" | awk 'BEGIN{IGNORECASE=1} /^location:[[:space:]]*/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' | tr -d '\r')"
  printf '%s|%s' "$st" "$loc"
}

# hook_rendered_path <file> — the path the send-email hook appends to its base,
# read out of the deployed source (`${base}/auth/v1/verify?...`), or empty when
# it cannot be found.  This is the only place the mailed link is actually built.
hook_rendered_path() { sed -n 's/.*`\${base}\([^?`]*\)?.*/\1/p' "$1" | head -1; }

# probe_mail_one <name> <action> <origin> <path> <env-dump> — echoes
# "OK <finding>" or "FAIL <finding>", like probe_one: the status rides in the
# output because a command substitution runs in a subshell.
probe_mail_one() {
  local name="$1" action="$2" origin="$3" want="$4" dump="$5"
  local prefix urlpath armed_lc url resp st loc landing renderer rpath

  prefix="$(mail_prefix "$name")"
  urlpath="$(live_value "$dump" "GOTRUE_MAILER_URLPATHS_${prefix}")"
  url="${origin}${want}"

  # 1. The action must be armed, or no such mail — and so no such link — is ever
  #    produced and everything below would be checking a link nobody receives.
  #    (An unreadable dump is caught in step 2, so an empty value cannot pass.)
  case "$name" in
    confirmation)
      armed_lc="$(printf '%s' "$(live_value "$dump" GOTRUE_MAILER_AUTOCONFIRM)" | tr '[:upper:]' '[:lower:]')"
      [ "$armed_lc" = true ] && { printf 'FAIL the confirmation link is DEAD: GOTRUE_MAILER_AUTOCONFIRM=true, so no confirmation mail (and so no link) is ever sent'; return; } ;;
    recovery)
      armed_lc="$(printf '%s' "$(live_value "$dump" GOTRUE_EXTERNAL_EMAIL_ENABLED)" | tr '[:upper:]' '[:lower:]')"
      [ "$armed_lc" = false ] && { printf 'FAIL the recovery link is DEAD: GOTRUE_EXTERNAL_EMAIL_ENABLED=false, so no recovery mail (and so no link) is ever sent'; return; } ;;
  esac

  # 2. The stack's own urlpath for this action (also the read that proves the
  #    running auth could be read at all).
  if [ -z "$urlpath" ]; then
    printf 'FAIL %s link UNVERIFIED: the running auth reports no GOTRUE_MAILER_URLPATHS_%s (no docker, or the container is unreachable)' "$name" "$prefix"
    return
  fi
  if [ "$urlpath" != "$want" ]; then
    printf 'FAIL %s link MISMATCH: the running auth mails %s%s, the declaration names %s%s' "$name" "$origin" "$urlpath" "$origin" "$want"
    return
  fi

  # 3. The link's own request, with a bogus token: GoTrue must answer it (the
  #    web app answering instead means the link dead-ends) and must land back on
  #    the declared origin.  With a bogus token that error arrives in the
  #    FRAGMENT, unlike the OAuth path's `?` — clean_loc cuts at both.
  if ! resp="$(verify_response "$url?token=$CODE&type=$action")"; then
    printf 'FAIL %s link UNVERIFIED: %s did not answer, so the link the mail carries could not be followed' "$name" "$url"
    return
  fi
  st="${resp%%|*}"; loc="${resp#*|}"
  if [ "$st" = 429 ]; then
    printf 'FAIL %s link UNVERIFIED: %s answered HTTP 429 (rate limited), so the link could not be observed' "$name" "$url"
    return
  fi
  if [ "${st#3}" = "$st" ]; then
    printf 'FAIL %s link NOT SERVED: %s answered HTTP %s, not GoTrue — that origin does not route %s there, so the link in the mail dead-ends' \
      "$name" "$url" "${st:-<none>}" "$want"
    return
  fi
  landing="$(clean_loc "$loc")"
  if [ "$landing" != "$origin" ]; then
    printf 'FAIL %s link MISMATCH: the link resolves to %s, the declaration assumes %s' "$name" "${landing:-<none>}" "$origin"
    return
  fi

  # 4. The renderer.  With the hook enabled GoTrue's templates are not used at
  #    all: the hook assembles the link from the `site_url` GoTrue hands it plus
  #    a path of its own, so both halves are asserted — and an unreadable
  #    renderer is a failure, not a pass (declare a link, prove the link).
  case "$(printf '%s' "$(live_value "$dump" GOTRUE_HOOK_SEND_EMAIL_ENABLED)" | tr '[:upper:]' '[:lower:]')" in
    true)
      if [ -z "$(live_value "$dump" GOTRUE_HOOK_SEND_EMAIL_URI)" ]; then
        printf 'FAIL %s link UNVERIFIED: the send-email hook is enabled with no GOTRUE_HOOK_SEND_EMAIL_URI, so no mail (and so no link) is delivered at all' "$name"
        return
      fi
      if [ ! -f "$HOOK_FILE" ]; then
        printf 'FAIL %s link UNVERIFIED: the send-email hook renders the link but its source could not be read at %s' "$name" "$HOOK_FILE"
        return
      fi
      rpath="$(hook_rendered_path "$HOOK_FILE")"
      if [ -z "$rpath" ]; then
        printf 'FAIL %s link UNVERIFIED: the hook renders the link but its path could not be read from %s' "$name" "$HOOK_FILE"
        return
      fi
      if [ "$rpath" != "$want" ]; then
        printf 'FAIL %s link MISMATCH: the hook renders %s%s, the declaration names %s%s' "$name" "$origin" "$rpath" "$origin" "$want"
        return
      fi
      # The renderer's base must BE the site_url GoTrue hands it — a hardcoded
      # host here would be a second authority for the link origin, invisible to
      # every config check.
      if ! grep -qE 'base.*site_url' "$HOOK_FILE"; then
        printf 'FAIL %s link MISMATCH: the hook does not build the link from site_url, so the origin it mails is not the declared one' "$name"
        return
      fi
      renderer="hook renders the same link" ;;
    *)
      renderer="GoTrue's own templates (hook off)" ;;
  esac

  printf 'OK %s link served at %s, lands on the declared origin, %s, armed ✓' "$name" "$url" "$renderer"
}

# --- alerting (transition-only) --------------------------------------------- #

# send_fanout <subject> <body> — every channel the deployed helper offers, each
# guarded, so an older alert.sh without some sender cannot sink the alert.
send_fanout() {
  local subject="$1" body="$2"
  if command -v send_webhook_alert  >/dev/null 2>&1; then send_webhook_alert "$subject

$body"; fi
  if command -v send_gotify_alert   >/dev/null 2>&1; then send_gotify_alert "$subject" "$body" 8; fi
  if command -v send_email_alert    >/dev/null 2>&1; then send_email_alert "$subject" "$body"; fi
  if command -v send_brevo_alert    >/dev/null 2>&1; then send_brevo_alert "$subject" "$body"; fi
  if command -v send_telegram_alert >/dev/null 2>&1; then send_telegram_alert "$subject" "$body"; fi
  return 0
}

# alert_transition <0|1> <detail> — notify on the way into failure and back out,
# stay quiet while the failure is unchanged.
alert_transition() {
  local failed="$1" detail="$2"
  [ "$ALERT" = 1 ] || return 0
  if [ ! -f "$ALERT_LIB" ]; then
    warn "no alert library at $ALERT_LIB — cannot notify (the finding is in $LOG)"
    return 0
  fi
  # shellcheck source=/dev/null
  . "$ALERT_LIB"
  mkdir -p "$(dirname "$STATE")" 2>/dev/null || true
  local seen="" here
  [ -f "$STATE" ] && seen="$(head -1 "$STATE" 2>/dev/null || true)"
  here="$(fp "$detail")"

  if [ "$failed" = 1 ]; then
    if [ "$seen" = "$here" ]; then
      log_line "$(now) NOTE oauth-handoff: failure unchanged since the last alert (not repeating)"
      return 0
    fi
    send_fanout "🚨 OAuth hand-off probe FAILED — $(hostname)" \
"The central identity stack did not honour a declared OAuth redirect target.
A target that is not on the allow list is silently rewritten to GOTRUE_SITE_URL,
so the affected sign-in returns to the website instead of the app.

Detail: $detail
API: $API
Declaration: $LIST

Investigate with:
  bash tool/oauth_handoff_probe.sh          # verbose
  bash tool/identity_allowlist_sync.sh --check"
    printf '%s\n' "$here" >"$STATE"
    log_line "$(now) ALERT oauth-handoff: failure alert sent ($detail)"
    return 0
  fi

  if [ -n "$seen" ]; then
    send_fanout "✅ OAuth hand-off probe recovered — $(hostname)" \
"Every declared OAuth redirect target is honoured again by the central identity
stack, and the allow list is in sync.

Detail: $detail"
    rm -f "$STATE"
    log_line "$(now) ALERT oauth-handoff: recovery notice sent"
  fi
  return 0
}

# --- the probe ------------------------------------------------------------- #

run_probe() {
  local declared n fails=0 detail=""
  # Set whenever a failure is NOT the site-URL assertion, so a run that failed
  # only on the site URL can be reported as exactly that.
  local non_site_fail=0

  declared="$(read_declared)"
  [ -n "$declared" ] || { echo "oauth_handoff_probe: declaration $LIST holds no entries" >&2; exit 3; }
  n="$(printf '%s\n' "$declared" | grep -c .)"

  # Presence half: reuse the allow-list tool so there is one implementation of
  # "is the entry on the stack and in the running auth process".
  local presence="unknown"
  if [ -f "$SYNC" ]; then
    if bash "$SYNC" --local --check >/dev/null 2>&1; then presence="in sync"; else presence="DRIFT"; fails=1; non_site_fail=1; detail="allow list DRIFT; "; fi
  else
    warn "no allow-list tool at $SYNC — the presence half of this probe was skipped"
  fi

  if [ "$MODE" = report ]; then
    echo "== oauth hand-off probe =="
    note "api:         $API"
    note "provider:    $PROVIDER"
    note "declaration: $LIST ($n entries)"
    note "allow list:  $presence"
    echo
    echo "== declared entries =="
  fi

  local e out status finding mark
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    out="$(probe_one "$e")"
    status="${out%% *}"; finding="${out#* }"
    if [ "$status" = OK ]; then mark="✓"; else mark="✗"; fails=1; non_site_fail=1; detail="${detail}${e}: ${finding}; "; fi
    [ "$MODE" = report ] && printf '   %s %s — %s\n' "$mark" "$e" "$finding"
  done <<<"$declared"

  # Control: a deliberately undeclared target must NOT be honoured.
  local ctrl_note=""
  if [ "$CONTROL" = 1 ]; then
    local cst cloc cclean
    cst="$(authorize_state "$CTRL")" || cst=""
    if [ -n "$cst" ]; then
      cloc="$(callback_target "$cst")"; cclean="$(clean_loc "$cloc")"
      if [ "$cclean" = "$CTRL" ]; then
        fails=1
        non_site_fail=1
        ctrl_note="✗ control target WAS honoured ($cclean) — the probe cannot distinguish"
        detail="${detail}control honoured; "
      else
        ctrl_note="✓ control not honoured (fell back to ${cclean:-<none>})"
      fi
    else
      ctrl_note="· control skipped (/authorize gave no state)"
    fi
    [ "$MODE" = report ] && printf '   (control) %s\n' "$ctrl_note"
  fi

  # --- the site URL every dropped entry is rewritten to -------------------- #
  # Every entry that is not honoured lands here, so a site URL that cannot
  # finish a sign-in is invisible in the same way a dropped entry is — and it
  # is the destination of every drop.  Two readings of the RUNNING auth, both
  # compared against the declaration:
  #   applied — what GoTrue actually resolved an unlisted target to, above;
  #   env     — GOTRUE_SITE_URL as the running container holds it, when docker
  #             is reachable.  When the two disagree, the failure text names
  #             both: that is a process running a value the stack no longer
  #             holds, which is a different fix from a mis-set site URL.
  local want_site live_site applied_site site_note="" site_problem="" site_ok=0
  want_site="$(declared_directive site_url)"
  live_site="$(live_env_site_url)"
  applied_site=""

  # A directive nothing reads is worse than no directive: the declaration looks
  # assertive while the assertion silently does not exist.  Refuse it (fail
  # closed) rather than passing on a check that was never wired up.
  local unknown_dirs="" k
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    case "$k" in
      site_url|mail_confirmation_path|mail_recovery_path) continue ;;
    esac
    unknown_dirs="${unknown_dirs}${k} "
  done <<<"$(directive_keys)"
  unknown_dirs="${unknown_dirs% }"
  if [ -n "$unknown_dirs" ]; then
    fails=1
    non_site_fail=1
    detail="${detail}declaration directive(s) nothing asserts: ${unknown_dirs}; "
  fi

  if [ -z "$want_site" ]; then
    site_note="· not declared — the declaration carries no site_url directive, so the fallback target is unchecked"
  else
    applied_site="$(probe_site_url)"
    if [ -n "$applied_site" ] && [ "$applied_site" != "$want_site" ]; then
      site_problem="site URL MISMATCH: an unmatched redirect resolves to ${applied_site}, the declaration assumes ${want_site}"
    fi
    if [ -n "$live_site" ] && [ "$live_site" != "$want_site" ]; then
      site_problem="${site_problem:+${site_problem}; }site URL MISMATCH: the running auth's GOTRUE_SITE_URL is ${live_site}, the declaration assumes ${want_site}"
    fi
    if [ -n "$site_problem" ]; then
      fails=1
      detail="${detail}${site_problem}; "
      site_note="✗ ${site_problem}"
    elif [ -z "$applied_site" ] && [ -z "$live_site" ]; then
      # The directive promises an assertion.  An assertion that could not be
      # made is not a pass: reporting the site URL as checked when neither
      # reading exists is exactly the "looks fine, was never observed" failure
      # this probe exists to catch.
      fails=1
      site_problem="site URL UNVERIFIED: the running auth's site URL could not be observed (no hand-off, and the container unreadable)"
      detail="${detail}${site_problem}; "
      site_note="✗ ${site_problem}"
    else
      site_ok=1
      site_note="✓ the running auth still falls back to the declared site URL"
    fi
  fi

  if [ "$MODE" = report ]; then
    echo
    echo "== site URL (where an unlisted redirect lands) =="
    note "declared:  ${want_site:-<not declared>}"
    note "applied:   ${applied_site:-<unobserved>}"
    note "container: ${live_site:-<unreadable>}  (GOTRUE_SITE_URL of the running auth)"
    [ -n "$unknown_dirs" ] && note "UNKNOWN DIRECTIVES: $unknown_dirs  (nothing asserts these)"
    note "$site_note"
  fi

  # --- the mail links the declaration names -------------------------------- #
  # Confirmation and recovery are the two mails that carry a link, and both are
  # <site_url> + one path.  The origin is therefore the site URL asserted just
  # above, announced once and never declared twice; what is new here is that each
  # action's link is followed for real and that the hook which actually renders
  # it is held to the declaration.
  local mail_list="" mail_fail=0 mail_ok=0 mail_problems="" mail_report=""
  local m_name m_action m_want m_dump="" m_out
  mail_list="$(mail_actions)"
  if [ -n "$mail_list" ]; then
    if [ -z "$want_site" ]; then
      mail_fail=1
      mail_problems="the mail links are rooted at the site_url directive, which this declaration does not carry; "
    else
      m_dump="$(live_mail_env)"
      while IFS=' ' read -r m_name m_action; do
        [ -n "$m_name" ] || continue
        m_want="$(declared_directive "mail_${m_name}_path")"
        m_out="$(probe_mail_one "$m_name" "$m_action" "$want_site" "$m_want" "$m_dump")"
        if [ "${m_out%% *}" = OK ]; then
          mail_report="${mail_report}   ✓ ${m_out#* }
"
        else
          mail_fail=1
          mail_problems="${mail_problems}${m_out#* }; "
          mail_report="${mail_report}   ✗ ${m_out#* }
"
        fi
      done <<<"$mail_list"
      [ "$mail_fail" = 0 ] && mail_ok=1
    fi
    [ "$mail_fail" = 1 ] && { fails=1; detail="${detail}${mail_problems}"; }

    if [ "$MODE" = report ]; then
      echo
      echo "== email links (confirmation & password recovery) =="
      note "origin:   ${want_site:-<not declared>}  (the declared site URL both links are built from)"
      case "$(printf '%s' "$(live_value "$m_dump" GOTRUE_HOOK_SEND_EMAIL_ENABLED)" | tr '[:upper:]' '[:lower:]')" in
        true) note "renderer: send-email hook → $(live_value "$m_dump" GOTRUE_HOOK_SEND_EMAIL_URI)" ;;
        *)    note "renderer: GoTrue's own templates (the send-email hook is off)" ;;
      esac
      printf '%s' "$mail_report"
    fi
  fi

  local verdict summary
  if [ "$fails" = 0 ]; then
    verdict=PASS
    summary="all $n declared entries honoured, control clear, allow list $presence"
    [ "$site_ok" = 1 ] && summary="$summary, site url $want_site ✓"
    [ "$mail_ok" = 1 ] && summary="$summary, mail links served ✓"
  else
    verdict=FAIL
    summary="${detail%\; }"
  fi

  if [ "$MODE" = report ]; then
    echo
    echo "== verdict =="
    note "$summary"
    echo
    if [ "$verdict" = PASS ]; then
      echo "PASS — the stack honours every declared redirect."
    elif [ "$non_site_fail" = 1 ]; then
      echo "FAIL — a declared redirect is not honoured (see above)."
    elif [ "$mail_fail" = 1 ] && [ -z "$site_problem" ]; then
      echo "FAIL — the redirects are honoured, but the confirmation/recovery links the declaration names could not be confirmed against the running stack (see above)."
    elif [ "$mail_fail" = 1 ]; then
      echo "FAIL — the redirects are honoured, but the site URL and the mail links the declaration assumes could not be confirmed against the running auth (see above)."
    else
      echo "FAIL — the redirects are honoured, but the site URL the declaration assumes could not be confirmed against the running auth (see above)."
    fi
  else
    printf '%s %s oauth-handoff: %s\n' "$(now)" "$verdict" "$summary"
  fi

  log_line "$(now) $verdict oauth-handoff: $summary"

  if [ "$verdict" = PASS ]; then alert_transition 0 "$summary"; return 0; fi
  alert_transition 1 "$summary"
  return 1
}

# --- dispatch -------------------------------------------------------------- #

if [ "$LOCAL" = 1 ]; then
  run_probe
  exit $?
fi

# Remote: run the same code where the stack lives (identity_allowlist_sync.sh is
# deployed there, so the presence half works too).
args=()
[ "$MODE" = check ] && args+=(--check)
[ "$ALERT" = 1 ] && args+=(--alert)
[ "$CONTROL" = 0 ] && args+=(--no-control)
if [ "$LIST" != "$SCRIPT_DIR/identity-redirect-allowlist.txt" ]; then
  echo "oauth_handoff_probe: remote mode uses the deployed declaration" >&2
  exit 3
fi
ssh "${SSH_OPTS[@]}" "$VM" "bash -s -- --local ${args[*]}" <"${BASH_SOURCE[0]}"
exit $?
