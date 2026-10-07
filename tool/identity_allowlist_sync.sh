#!/usr/bin/env bash
# ============================================================================
# identity_allowlist_sync.sh — converge + verify the CENTRAL identity stack's
# GoTrue redirect configuration against the declaration in
# tool/identity-redirect-allowlist.txt: the redirect allow list AND the site URL
# every unmatched redirect falls back to.
#
# The declaration is the source of truth; this tool is the only thing that
# writes `ADDITIONAL_REDIRECT_URLS` and `SITE_URL` in the stack `.env` (compose
# hands them to GoTrue as `GOTRUE_URI_ALLOW_LIST` / `GOTRUE_SITE_URL`). It
# exists because a missing entry never errors — GoTrue silently rewrites the
# redirect to `GOTRUE_SITE_URL`, so a dropped native entry breaks a real sign-in
# at its very last step. The site URL matters for the same reason and then some:
# it is where that rewrite lands, it is the one origin GoTrue allows implicitly
# for ANY path, and it roots every confirmation and recovery link the stack
# mails — so a site URL that disagrees with the declaration is a silent failure
# of exactly that shape, and the destination of every other one.
#
#   bash tool/identity_allowlist_sync.sh            # plan, verbose (exit 1 if drift)
#   bash tool/identity_allowlist_sync.sh --check    # terse gate;  --alert to notify
#   bash tool/identity_allowlist_sync.sh --heal     # converge iff missing, then re-verify
#   bash tool/identity_allowlist_sync.sh --apply    # converge + verify the live process
#   bash tool/identity_allowlist_sync.sh --deploy   # only (re)install it on the VM
#
# Findings, and what each one means:
#   missing declared entry  — the dangerous one: declared here, absent from the
#                             stack. Nothing admits that redirect. DRIFT.
#   live disagrees with .env— the .env is right but the RUNNING auth predates
#                             the edit, so the entry is effectively missing at
#                             runtime. DRIFT; `--apply` recreates auth, and the
#                             scheduled `--heal` does the same.
#   undeclared live entry   — an entry on the stack that this file does not
#                             name. Never removed unless `--prune`; reported as
#                             a WARN so the declaration can be updated.
#   site URL disagrees      — `SITE_URL` in the `.env` and/or `GOTRUE_SITE_URL`
#                             in the RUNNING auth is not the `site_url` the
#                             declaration names. DRIFT, converged the same way.
#                             A declaration with no `site_url` directive leaves
#                             this half of the tool entirely out of the way.
#
# --apply backs the `.env` up, rewrites those keys in ONE pass, recreates ONLY auth
# (`up -d --force-recreate --no-deps auth`; the project name is pinned to
# `identity` in the .env, so this cannot spin up a second stack), waits for it
# to report healthy, asserts the live process carries every declared entry, and
# restores the backup + recreates again if any of that fails.
#
# IMPACT: identity auth is SHARED, so a recreation interrupts sign-in for every
# sibling project for a few seconds (existing JWT sessions stay valid). A run
# that changes nothing never touches the stack, so plans and checks are inert.
#
# The site URL is converged, not merely checked, because there is no second
# authority for it: it is declared here, and the declaration is what the nightly
# probe holds the running auth to. Both must be changed together, and the only
# way to guarantee that is to give the declaration one writer. It is refused
# outright when malformed — converging a broken value would rewrite the root of
# every confirmation and recovery link the stack mails.
#
# SELF-HEAL (`--heal`) is the scheduled mode.  Detecting a dropped entry is not
# enough on its own: the entry is only missing until somebody acts, and the
# whole point of the finding is that a real sign-in is broken until then.  So
# the scheduled run converges the stack itself and then RE-VERIFIES the running
# auth from scratch — a second, independent reading of both the `.env` and the
# live process, taken after the recreate has settled, because "the write
# succeeded" is not the same claim as "the running auth now honours it".
#
# Messaging follows the OUTCOME, never the finding:
#   * healed        — one informational notice per distinct drift, suppressed on
#                     repeat (a flapping `.env` must not spam), and cleared as
#                     soon as the stack is in sync so a recurrence still
#                     notifies.  This is not an alarm: by the time it is sent
#                     the entry is back.
#   * heal FAILED   — the loud drift alarm, transition-guarded like `--check`,
#                     plus a recovery notice when a later run is clean.  This is
#                     the only case that needs a human.
#   * nothing wrong — one line in the ops log, no alert at all.
#
# It converges on exactly the same drift `--apply` does — a declared entry
# missing from the `.env`, or from the running auth, or a site URL that is not
# the declared one — and, like `--apply`, it never removes an undeclared entry
# unless `--prune` is also given (the scheduled entry does not pass `--prune`).
#
# Modes:
#   (default)  plan      — verbose report; nothing is written. exit 1 on drift.
#   --check    check     — one verdict line; for cron/CI. --alert notifies on a
#                          TRANSITION (once per outage, plus a recovery note).
#   --heal     heal      — converge iff a declared entry is missing, re-verify
#                          the running auth, then report the OUTCOME.  The
#                          scheduled self-heal; see above.
#   --apply    apply     — converge. --prune also removes undeclared entries.
#   --deploy             — install the tool + declaration into ~/bin on the VM.
#   --local              — run where the stack lives (implied on the VM; the
#                          remote default streams to this same code path).
#
# Exit: 0 in sync (or converged) · 1 drift (or would change) · 2 failure
#       (refused, or the change failed and the previous .env was restored).
#       `--heal` never returns 1: drift it can fix is fixed, and drift it cannot
#       fix is a failure — 0 healed, 2 the heal failed.  3 usage/config error,
#       including a malformed `site_url` in the declaration (refused, never
#       written).
#
# Env overrides: KAT_SSH_KEY, KAT_VM_HOST, KAT_VM_USER, IDENTITY_STACK_DIR,
#   IDENTITY_ALLOWLIST_LIST, IDENTITY_ALLOWLIST_LOG, IDENTITY_ALLOWLIST_STATE,
#   IDENTITY_ALLOWLIST_HEAL_STATE, IDENTITY_ALERT_LIB.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE=plan
LOCAL=0
DEPLOY=0
ALERT=0
PRUNE=0
LIST="${IDENTITY_ALLOWLIST_LIST:-$SCRIPT_DIR/identity-redirect-allowlist.txt}"
STACK_DIR="${IDENTITY_STACK_DIR:-/home/ubuntu/Projects/kommons/supabase-identity/docker}"

VM="${KAT_VM_USER:-ubuntu}@${KAT_VM_HOST:-80.225.89.206}"
SSH_KEY="${KAT_SSH_KEY:-$HOME/.ssh/katalogus}"
[ -f "$SSH_KEY" ] || SSH_KEY="${KAT_SSH_KEY:-$HOME/Apps/Projects/keys/ssh-private-key.key}"
SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=20
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

KEY_NAME=ADDITIONAL_REDIRECT_URLS
GOTRUE_KEY=GOTRUE_URI_ALLOW_LIST
# The declaration also NAMES the origin the stack must fall back to (the
# `site_url=` directive), which compose hands to GoTrue as GOTRUE_SITE_URL from
# the .env's SITE_URL.  Same contract as the list, same treatment — see the
# header.
SITE_KEY_NAME=SITE_URL
GOTRUE_SITE_KEY=GOTRUE_SITE_URL
SERVICE=auth
ENV_FILE="$STACK_DIR/.env"
LOG="${IDENTITY_ALLOWLIST_LOG:-$HOME/logs/identity-allowlist.log}"
STATE="${IDENTITY_ALLOWLIST_STATE:-$HOME/logs/identity-allowlist.state}"
# Separate from STATE: STATE guards the DRIFT alarm (transition-only), this one
# guards the informational self-heal notice, which is not an alarm and must not
# make the next clean run announce a "recovery" that never happened.
HEAL_STATE="${IDENTITY_ALLOWLIST_HEAL_STATE:-$HOME/logs/identity-allowlist-heal.state}"
ALERT_LIB="${IDENTITY_ALERT_LIB:-$HOME/bin/alert.sh}"

usage() { sed -n '2,/^set -uo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d'; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) [ "$MODE" != plan ] && { echo "usage: --apply, --check and --heal are mutually exclusive" >&2; exit 3; }; MODE=apply ;;
    --check) [ "$MODE" != plan ] && { echo "usage: --apply, --check and --heal are mutually exclusive" >&2; exit 3; }; MODE=check ;;
    --heal)  [ "$MODE" != plan ] && { echo "usage: --apply, --check and --heal are mutually exclusive" >&2; exit 3; }; MODE=heal ;;
    --local) LOCAL=1 ;;
    --remote) LOCAL=0 ;;
    --deploy) DEPLOY=1 ;;
    --alert) ALERT=1 ;;
    --prune) PRUNE=1 ;;
    --list) LIST="${2:?--list needs a file}"; shift ;;
    --stack-dir) STACK_DIR="${2:?--stack-dir needs a path}"; ENV_FILE="$STACK_DIR/.env"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "identity_allowlist_sync: unknown argument: $1" >&2; echo "usage: identity_allowlist_sync.sh [--apply|--check|--heal] [--local] [--deploy] [--alert] [--prune] [--list FILE] [--stack-dir DIR]" >&2; exit 3 ;;
  esac
  shift
done

# --- shared helpers -------------------------------------------------------- #

note() { printf '   %s\n' "$*"; }
warn() { printf '   WARN %s\n' "$*" >&2; }

log_line() { # <line> — append to the ops log (never to stdout in check mode)
  mkdir -p "$(dirname "$LOG")" || return 0
  printf '%s\n' "$1" >>"$LOG"
}

now() { date '+%Y-%m-%dT%H:%M:%S%z'; }
fp() { printf '%s' "$1" | sha256sum | cut -c1-16; }
NL=$'\n'

# bullets <multiline> — one indented line per entry, blanks dropped.
bullets() { while IFS= read -r l; do [ -n "$l" ] && printf '     - %s\n' "$l"; done <<<"$1"; }

# one_line <multiline> — the same entries on one comma-separated line.
one_line() { local out="" l; while IFS= read -r l; do [ -n "$l" ] || continue; out="${out}${out:+, }$l"; done <<<"$1"; printf '%s' "$out"; }

# indented <multiline> — each line of a block, with the report's indent.
indented() { while IFS= read -r l; do printf '   %s\n' "$l"; done <<<"$1"; }

# read_declared — the declared ENTRIES, in file order, one per line.  Rejects
# the shapes that would quietly become dead entries rather than failing at the
# least observable moment.
#
# A `key=value` line is a directive, not an entry: it configures the stack
# around the list (`site_url`).  Skipping directives here is load-bearing — a
# directive read as an entry would be written into ADDITIONAL_REDIRECT_URLS,
# putting `site_url=https://…` on the allow list and dropping it from the
# .env's meaning.  A redirect can never be mistaken for a directive: it starts
# with a scheme, so the text before its first `=` contains `:` or `/`.
read_declared() {
  [ -f "$LIST" ] || { echo "identity_allowlist_sync: declaration not found at $LIST" >&2; exit 3; }
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/ { next }
    { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print }
  ' "$LIST"
}

# declared_directive <key> — the value of a `key=value` directive, or empty.
# Surrounding whitespace and one layer of quotes are stripped; the value is
# never validated here (each consumer decides what it is willing to accept).
declared_directive() {
  [ -f "$LIST" ] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$LIST" \
    | head -1 | tr -d '"' | tr -d '[:space:]'
}

# --- the site URL the declaration names ------------------------------------ #
# Read once, here (after declared_directive exists), so every mode agrees on
# what the stack must fall back to.  EMPTY means "not declared": a declaration
# written before `site_url` existed must keep working exactly as it did, with
# SITE_URL left alone.
#
# A malformed value is a DECLARATION error, not drift.  Converging it would
# rewrite the root of every confirmation and recovery link the stack mails, so
# it is refused before anything at all is written — fail closed, like an empty
# allow list.
DSITE="$(declared_directive site_url)"
SITE_DECLARED=0
[ -n "$DSITE" ] && SITE_DECLARED=1
# Run-wide facts about the site URL, filled in by run_local and read by the
# report, converge and verify paths.  Initialized here because set -u is on and
# a declaration without the directive skips the site half entirely.
ENV_SITE=""          # SITE_URL as the stack .env holds it
LIVE_SITE=""         # GOTRUE_SITE_URL as the RUNNING container holds it
LIVE_SITE_KNOWN=0    # 1 when the running value could be read
SITE_DRIFT=0         # 1 when either side disagrees with the declaration
if [ "$SITE_DECLARED" = 1 ]; then
  case "$DSITE" in
    *://*) : ;;
    *) echo "identity_allowlist_sync: the declaration's site_url '$DSITE' is not a <scheme>://<host> URL — refusing" >&2; exit 3 ;;
  esac
  case "$DSITE" in
    *,*) echo "identity_allowlist_sync: the declaration's site_url '$DSITE' contains ',' — refusing" >&2; exit 3 ;;
    *#*) echo "identity_allowlist_sync: the declaration's site_url '$DSITE' contains '#' — refusing" >&2; exit 3 ;;
  esac
  if [ -z "${DSITE%%://*}" ] || [ -z "${DSITE#*://}" ]; then
    echo "identity_allowlist_sync: the declaration's site_url '$DSITE' has an empty scheme or host — refusing" >&2; exit 3
  fi
fi

validate_declared() { # <declared-multiline>
  local e seen="" bad=0
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    case "$e" in
      *#*) warn "entry '$e' contains '#' — GoTrue cuts the URL at '#' before matching, so this entry can never match"; bad=1 ;;
    esac
    case "$e" in
      *,*) warn "entry '$e' contains ',' — it would split into two entries"; bad=1 ;;
    esac
    if printf '%s\n' "$seen" | grep -qxF -- "$e"; then
      warn "entry '$e' is declared twice"; bad=1
    fi
    seen="$seen$e
"
  done <<<"$1"
  [ "$bad" = 0 ]
}

# --- reading the stack ------------------------------------------------------ #

split_value() { tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$'; }

# read_key_of <KEY> — the .env value of a key (empty when absent), and
# key_count_of <KEY> — how many times it appears.  More than one is refused
# where it is read: which line the stack gets depends on the parser's order, so
# a duplicate is an accident waiting to happen.
read_key_of() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-; }
key_count_of() { grep -cE "^$1=" "$ENV_FILE" 2>/dev/null || true; }

key_count() { key_count_of "$KEY_NAME"; }
read_current() { read_key_of "$KEY_NAME"; }

# auth_container — the running auth container, or empty.  `docker compose ps`
# is preferred (it knows the project's own naming); the .env's pinned project
# name is the fallback, and `docker inspect` is what decides.
auth_container() {
  local id proj
  id="$( (cd "$STACK_DIR" && docker compose ps -q "$SERVICE") 2>/dev/null || true )"
  if [ -z "$id" ]; then
    proj="$(grep -E '^COMPOSE_PROJECT_NAME=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-)"
    id="${proj:-identity}-${SERVICE}-1"
  fi
  if docker inspect "$id" >/dev/null 2>&1; then printf '%s' "$id"; fi
}

# in_list <entry> <multiline> — membership test that cannot be fooled by an
# entry being a prefix of another (grep -x, whole line).
in_list() {
  local needle="$1"
  [ -n "$2" ] || return 1
  printf '%s\n' "$2" | grep -qxF -- "$needle"
}

# --- the verdict ----------------------------------------------------------- #

run_local() {
  [ -d "$STACK_DIR" ] || { echo "identity_allowlist_sync: no stack dir $STACK_DIR" >&2; exit 3; }
  [ -f "$ENV_FILE" ] || { echo "identity_allowlist_sync: no $ENV_FILE" >&2; exit 3; }

  local declared n_declared e
  declared="$(read_declared)"
  [ -n "$declared" ] || { echo "identity_allowlist_sync: the declaration $LIST holds no entries" >&2; exit 3; }
  validate_declared "$declared" || exit 3
  n_declared="$(printf '%s\n' "$declared" | grep -c .)"

  local count; count="$(key_count)"
  if [ "${count:-0}" -gt 1 ]; then
    echo "identity_allowlist_sync: $KEY_NAME appears $count times in $ENV_FILE (expected at most 1) — refusing" >&2
    exit 2
  fi

  # --- the site URL: the same .env, the same container, one more key --------
  if [ "$SITE_DECLARED" = 1 ]; then
    local site_count
    site_count="$(key_count_of "$SITE_KEY_NAME")"
    if [ "${site_count:-0}" -gt 1 ]; then
      echo "identity_allowlist_sync: $SITE_KEY_NAME appears $site_count times in $ENV_FILE (expected at most 1) — refusing" >&2
      exit 2
    fi
    ENV_SITE="$(read_key_of "$SITE_KEY_NAME")"
  fi

  local current cur_entries=""
  current="$(read_current)"
  [ -n "$current" ] && cur_entries="$(printf '%s' "$current" | split_value)"

  # memberships
  local missing="" undeclared=""
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    in_list "$e" "$cur_entries" || missing="${missing}${e}${NL}"
  done <<<"$declared"
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    in_list "$e" "$declared" || undeclared="${undeclared}${e}${NL}"
  done <<<"$cur_entries"

  # the list the stack must end up with: declared first, then (unless --prune)
  # whatever else is live, so nothing is ever dropped without being asked.
  local -a want=()
  while IFS= read -r e; do [ -n "$e" ] && want+=("$e"); done <<<"$declared"
  if [ "$PRUNE" = 0 ]; then
    while IFS= read -r e; do [ -n "$e" ] && want+=("$e"); done <<<"$undeclared"
  fi
  local desired=""
  [ "${#want[@]}" -gt 0 ] && desired="$(IFS=,; printf '%s' "${want[*]}")"

  # the runtime
  local container="" live="" live_readable=0
  container="$(auth_container)"
  if [ -n "$container" ]; then
    live="$(docker exec "$container" printenv "$GOTRUE_KEY" 2>/dev/null || true)"
    live_readable=1
    if [ "$SITE_DECLARED" = 1 ]; then
      LIVE_SITE="$(docker exec "$container" printenv "$GOTRUE_SITE_KEY" 2>/dev/null || true)"
      LIVE_SITE_KNOWN=1
    fi
  fi

  local missing_live=""
  if [ "$live_readable" = 1 ]; then
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      in_list "$e" "$(printf '%s' "$live" | split_value)" || missing_live="${missing_live}${e}${NL}"
    done <<<"$declared"
  fi

  local need_write=0
  [ "$desired" != "$current" ] && need_write=1

  # Drift is only ever a *missing* declared entry, a runtime that does not
  # carry one, or (with --prune) an undeclared entry waiting to be removed.
  # Undeclared entries that stay are a WARN, never a drift: this tool does not
  # delete what it was not asked to delete.
  local drift=0
  [ "$need_write" = 1 ] && drift=1
  [ -n "$missing" ] && drift=1
  [ -n "$missing_live" ] && drift=1

  # The site URL is the OTHER half of the same contract: GoTrue rewrites every
  # unlisted redirect to it and allows that origin implicitly for any path, so a
  # stack whose site URL is not the one the declaration names is mis-set in
  # exactly the way a dropped entry is — and it is WHERE a dropped entry lands.
  # Both sides are compared: the .env (what a recreate will read) and the
  # running container (what the process actually resolved to right now).
  if [ "$SITE_DECLARED" = 1 ]; then
    [ "$ENV_SITE" != "$DSITE" ] && SITE_DRIFT=1
    [ "$LIVE_SITE_KNOWN" = 1 ] && [ "$LIVE_SITE" != "$DSITE" ] && SITE_DRIFT=1
    [ "$SITE_DRIFT" = 1 ] && drift=1
  fi

  # --heal drives itself: it alerts on the OUTCOME, not on the finding, so it
  # does not go through report (whose check path alerts on the finding).
  if [ "$MODE" = heal ]; then
    heal "$declared" "$n_declared" "$missing" "$missing_live" "$undeclared" \
         "$desired" "$drift" "$live_readable"
    return $?
  fi

  report "$declared" "$n_declared" "$cur_entries" "$current" "$container" "$live" \
         "$live_readable" "$missing" "$missing_live" "$undeclared" "$desired" "$drift"

  if [ "$MODE" = apply ] && [ "$drift" = 1 ]; then
    apply_change "$desired" "$declared"
    return $?
  fi

  if [ "$drift" = 1 ]; then return 1; fi
  return 0
}

# --- reporting ------------------------------------------------------------- #

report() { # <declared> <n> <cur_entries> <current> <container> <live> <live_ok> \
           #   <missing> <missing_live> <undeclared> <desired> <drift>
  local declared="$1" n="$2" cur="$3" current="$4" container="$5" live="$6" live_ok="$7"
  local missing="$8" missing_live="$9" undeclared="${10}" desired="${11}" drift="${12}"

  if [ "$MODE" = check ]; then
    report_check "$declared" "$n" "$missing" "$missing_live" "$undeclared" "$drift" "$live_ok"
    return 0
  fi

  echo "== stack =="
  note "dir:         $STACK_DIR"
  note "declaration: $LIST ($n entries)"
  note "key:         $KEY_NAME  (compose hands it to GoTrue as $GOTRUE_KEY)"
  if [ "$SITE_DECLARED" = 1 ]; then
    note "site url:    $SITE_KEY_NAME → $GOTRUE_SITE_KEY  (the origin an unlisted redirect is rewritten to)"
  else
    note "site url:    not declared — $SITE_KEY_NAME is left exactly as it is"
  fi
  if [ -n "$container" ]; then
    local st; st="$(docker inspect "$container" --format '{{.State.Status}}/{{.State.Health.Status}}' 2>/dev/null || true)"
    note "auth:        $container ${st:-?}"
  else
    note "auth:        not running — the runtime cannot be verified"
  fi

  echo
  echo "== declared (the source of truth) =="
  indented "$declared"

  echo
  echo "== on the stack now =="
  if [ -z "$cur" ]; then
    note "(the key is absent from $ENV_FILE)"
  else
    indented "$cur"
  fi
  [ "$live_ok" = 1 ] && note "live process: ${live:-<empty>}"
  if [ "$SITE_DECLARED" = 1 ]; then
    note "$SITE_KEY_NAME:     ${ENV_SITE:-<absent from $ENV_FILE>}"
    [ "$LIVE_SITE_KNOWN" = 1 ] && note "live $GOTRUE_SITE_KEY: ${LIVE_SITE:-<empty>}"
    note "$SITE_KEY_NAME (declared): $DSITE"
  fi

  echo
  echo "== findings =="
  local any=0
  if [ -n "$missing" ]; then
    any=1
    echo "   DRIFT — declared but ABSENT from the stack:"
    bullets "$missing"
  fi
  if [ -n "$missing_live" ]; then
    any=1
    echo "   DRIFT — absent from the RUNNING auth process (the .env is fine; the container predates it):"
    bullets "$missing_live"
  fi
  if [ -n "$undeclared" ]; then
    echo "   WARN — on the stack but not declared here (kept; add them to the declaration):"
    bullets "$undeclared"
  fi
  if [ "$SITE_DRIFT" = 1 ]; then
    any=1
    if [ "$ENV_SITE" != "$DSITE" ]; then
      echo "   DRIFT — $SITE_KEY_NAME on the stack is not the site URL the declaration names:"
      bullets "$SITE_KEY_NAME=${ENV_SITE:-<absent>}$NL${SITE_KEY_NAME} (declared)=$DSITE"
    fi
    if [ "$LIVE_SITE_KNOWN" = 1 ] && [ "$LIVE_SITE" != "$DSITE" ]; then
      echo "   DRIFT — the RUNNING auth's $GOTRUE_SITE_KEY is not the site URL the declaration names:"
      bullets "$GOTRUE_SITE_KEY=${LIVE_SITE:-<empty>}$NL$GOTRUE_SITE_KEY (declared)=$DSITE"
    fi
  fi
  if [ "$any" = 0 ]; then
    note "none — every declared entry is on the stack and in the running process ✓"
  fi

  echo
  if [ "$drift" = 0 ]; then
    echo "IN SYNC — nothing to do."
    return 0
  fi
  echo "PLANNED VALUE"
  note "$KEY_NAME=$desired"
  [ "$SITE_DECLARED" = 1 ] && note "$SITE_KEY_NAME=$DSITE"
  if [ "$MODE" = apply ]; then return 0; fi
  echo
  echo "DRY RUN — nothing changed. Re-run with --apply to converge the shared"
  echo "auth container (a few seconds of sign-in downtime for every project)."
  return 0
}

report_check() { # <declared> <n> <missing> <missing_live> <undeclared> <drift> <live_ok>
  local declared="$1" n="$2" missing="$3" missing_live="$4" undeclared="$5" drift="$6" live_ok="$7"
  local line what="" names="" site_names=""

  if [ -n "$missing" ]; then what="absent from the stack .env"; fi
  if [ -n "$missing_live" ]; then
    what="${what}${what:+ and }absent from the running auth process"
  fi
  names="$( { printf '%s' "$missing"; printf '%s' "$missing_live"; } | grep -v '^$' | sort -u | tr '\n' ' ' )"
  names="${names% }"

  # The site URL rides in the same verdict line and the same alert: it is one
  # contract, and an operator who has to read two places to learn the stack is
  # mis-set has been handed a worse tool for no gain.
  if [ "$SITE_DRIFT" = 1 ]; then
    if [ "$ENV_SITE" != "$DSITE" ]; then
      what="${what}${what:+ and }$SITE_KEY_NAME is not the declared site URL"
      site_names="${SITE_KEY_NAME}=${ENV_SITE:-<absent>} (declared $DSITE)"
    fi
    if [ "$LIVE_SITE_KNOWN" = 1 ] && [ "$LIVE_SITE" != "$DSITE" ]; then
      what="${what}${what:+ and }the running auth's $GOTRUE_SITE_KEY is not the declared site URL"
      site_names="${site_names}${site_names:+; }${GOTRUE_SITE_KEY}=${LIVE_SITE:-<empty>} (declared $DSITE)"
    fi
    names="${names}${names:+; }${site_names}"
  fi

  if [ "$drift" = 0 ]; then
    line="$(now) OK identity: all $n declared redirect entries are on the stack and in the running auth process"
    [ "$SITE_DECLARED" = 1 ] && line="$line, and $SITE_KEY_NAME=$DSITE matches"
    printf '%s\n' "$line"
    log_line "$line"
    if [ "$live_ok" != 1 ]; then
      line="$(now) NOTE identity: auth is not running, so only the .env could be checked"
      printf '%s\n' "$line"
      log_line "$line"
    fi
    if [ -n "$undeclared" ]; then
      line="$(now) WARN identity: on the stack but not declared (kept): $(one_line "$undeclared")"
      printf '%s\n' "$line"
      log_line "$line"
    fi
    alert_transition 0 "all $n declared entries present"
    return 0
  fi

  line="$(now) DRIFT identity: $what — $(one_line "$names")"
  printf '%s\n' "$line"
  log_line "$line"
  if [ -n "$undeclared" ]; then
    log_line "$(now) WARN identity: on the stack but not declared (kept): $(one_line "$undeclared")"
  fi
  alert_transition 1 "$what: $(one_line "$names")"
  return 0
}

# --- alerting (transition-only) --------------------------------------------- #

# send_fanout <subject> <body> — every channel alert.sh can offer, each
# guarded: the deployed helper may be an older revision without every sender,
# and a missing one must not sink the alert.
send_fanout() {
  local subject="$1" body="$2"
  if command -v send_webhook_alert >/dev/null 2>&1; then send_webhook_alert "$subject

$body"; fi
  if command -v send_gotify_alert >/dev/null 2>&1; then send_gotify_alert "$subject" "$body" 8; fi
  if command -v send_email_alert >/dev/null 2>&1; then send_email_alert "$subject" "$body"; fi
  if command -v send_brevo_alert >/dev/null 2>&1; then send_brevo_alert "$subject" "$body"; fi
  if command -v send_telegram_alert >/dev/null 2>&1; then send_telegram_alert "$subject" "$body"; fi
  return 0
}

# alert_transition <0|1> <detail> — notify on the way IN to drift and on the
# way back out, and stay quiet while the drift is unchanged: an alert that
# repeats forever is one nobody reads.  State is the fingerprint of the drift.
alert_transition() {
  local drifted="$1" detail="$2"
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

  if [ "$drifted" = 1 ]; then
    if [ "$seen" = "$here" ]; then
      log_line "$(now) NOTE identity: drift unchanged since the last alert (not repeating)"
      return 0
    fi
    send_fanout "🚨 identity redirect allow list DRIFT — $(hostname)" \
"The central identity stack disagrees with tool/identity-redirect-allowlist.txt:
a declared OAuth redirect target is missing, or the stack's site URL is not the
one the declaration names.  Either way GoTrue rewrites the affected redirect to
GOTRUE_SITE_URL, so a real sign-in completes at the provider and then returns to
the wrong place — or to somewhere the app cannot receive it.

Finding: $detail
Declaration: $LIST
Stack: $STACK_DIR

Converge with:
  bash tool/identity_allowlist_sync.sh --apply"
    printf '%s\n' "$here" >"$STATE"
    log_line "$(now) ALERT identity: drift alert sent ($detail)"
    return 0
  fi

  if [ -n "$seen" ]; then
    local recovered="Every declared OAuth redirect target is back on the central identity stack, and the running auth process carries it."
    [ "$SITE_DECLARED" = 1 ] && recovered="The central identity stack matches $LIST again: every declared redirect target is on the allow list, and $SITE_KEY_NAME is the site URL the declaration names."
    send_fanout "✅ identity redirect allow list in sync again — $(hostname)" \
"$recovered

Detail: $detail"
    rm -f "$STATE"
    log_line "$(now) ALERT identity: recovery notice sent"
  fi
  return 0
}

# --- applying -------------------------------------------------------------- #

restore_backup() { # <backup>
  cp -a "$1" "$ENV_FILE"
  (cd "$STACK_DIR" && docker compose up -d --force-recreate --no-deps "$SERVICE" >/dev/null 2>&1) || true
  echo "   restored $ENV_FILE from $1 and recreated $SERVICE" >&2
}

apply_change() { # <desired> <declared>
  local desired="$1" declared="$2"
  local ts bak count setmsg now_value
  ts="$(date +%Y%m%dT%H%M%S)"
  bak="$ENV_FILE.bak-$ts-allowlist"

  # Defence in depth: blanking the allow list is worse than not converging, so
  # an empty result is refused before anything is written or restarted.
  if [ -z "$desired" ]; then
    echo "   refusing to write an empty $KEY_NAME (nothing was changed)" >&2
    return 2
  fi

  cp -a "$ENV_FILE" "$bak" || { echo "   FAILED to back up $ENV_FILE" >&2; return 2; }
  note "backup: $bak"

  # Both keys ride into ONE rewrite, so a failure halfway through can never
  # leave the stack with a converged list and a stale site URL (or the reverse).
  local -a pairs=("$KEY_NAME" "$desired")
  [ "$SITE_DECLARED" = 1 ] && pairs+=("$SITE_KEY_NAME" "$DSITE")

  # The values ride as ARGV, never interpolated into the program text and never
  # on stdin: a heredoc would claim stdin ahead of a pipe (`cmd | python3 - <<PY`
  # hands python the *program* on stdin and leaves the value empty — which is a
  # silent empty write, not a parse error).
  setmsg="$(python3 - "$ENV_FILE" "${pairs[@]}" <<'PY'
import sys
path = sys.argv[1]
args = sys.argv[2:]
if len(args) % 2:
    sys.exit("internal error: key/value arguments are not paired")
pairs = list(zip(args[0::2], args[1::2]))

raw = open(path, encoding="utf-8").read()
lines = raw.splitlines(keepends=True)
eol = "\r\n" if raw.endswith("\r\n") else "\n"
# Where an absent key belongs, so the file keeps its shape: the site pair stays
# adjacent (SITE_URL, then ADDITIONAL_REDIRECT_URLS) rather than one half
# landing at the very end.  Which SIDE of its partner it takes is what keeps
# that order whichever half was missing.
ANCHORS = {
    "ADDITIONAL_REDIRECT_URLS": ("SITE_URL=", "after"),
    "SITE_URL": ("ADDITIONAL_REDIRECT_URLS=", "before"),
}
msgs = []
for key, desired in pairs:
    hits = [i for i, l in enumerate(lines) if l.startswith(key + "=")]
    if len(hits) > 1:
        sys.exit("expected at most one %s= line, found %d" % (key, len(hits)))
    if hits:
        i = hits[0]
        line_eol = "\r\n" if lines[i].endswith("\r\n") else "\n"
        lines[i] = key + "=" + desired + line_eol
        msgs.append("%s set (line %d)" % (key, i + 1))
        continue
    anchor = ANCHORS.get(key)
    idx = None
    where = "appended"
    if anchor:
        partner, side = anchor
        pos = [i for i, l in enumerate(lines) if l.startswith(partner)]
        if pos:
            idx = pos[0] + (1 if side == "after" else 0)
            where = "%s %s" % (side, partner.rstrip("="))
    if idx is None:
        idx = len(lines)
    lines.insert(idx, key + "=" + desired + eol)
    msgs.append("%s inserted (%s)" % (key, where))
open(path, "w", encoding="utf-8").write("".join(lines))
print("; ".join(msgs))
PY
)"
  if [ -z "$setmsg" ]; then
    restore_backup "$bak"
    echo "   the .env rewrite FAILED — .env restored" >&2
    return 2
  fi
  note "$setmsg"

  count="$(key_count)"
  now_value="$(read_current)"
  if [ "${count:-0}" != 1 ] || [ "$now_value" != "$desired" ]; then
    restore_backup "$bak"
    echo "   the rewrite did not land ($KEY_NAME x${count:-0}, value '${now_value:-<empty>}') — restored" >&2
    return 2
  fi
  if [ "$SITE_DECLARED" = 1 ]; then
    local sc sv
    sc="$(key_count_of "$SITE_KEY_NAME")"
    sv="$(read_key_of "$SITE_KEY_NAME")"
    if [ "${sc:-0}" != 1 ] || [ "$sv" != "$DSITE" ]; then
      restore_backup "$bak"
      echo "   the rewrite did not land ($SITE_KEY_NAME x${sc:-0}, value '${sv:-<empty>}') — restored" >&2
      return 2
    fi
  fi

  echo "   recreating $SERVICE (shared auth: a few seconds of sign-in downtime)"
  if ! (cd "$STACK_DIR" && docker compose up -d --force-recreate --no-deps "$SERVICE" 2>&1 | tail -3 | sed 's/^/   /'); then
    restore_backup "$bak"
    echo "   docker compose failed — .env restored, auth recreated" >&2
    return 2
  fi

  echo "   waiting for $SERVICE to report healthy"
  local c="" st="" i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24; do
    c="$(auth_container)"
    if [ -n "$c" ]; then
      st="$(docker inspect "$c" --format '{{.State.Health.Status}}' 2>/dev/null || true)"
      case "$st" in healthy|"") break ;; esac
    fi
    sleep 5
  done
  note "health after the recreate: ${st:-unknown}"

  # Verification, in two parts: the running process must carry the whole list
  # byte for byte, AND every declared entry must be in it (the second survives
  # a future edit to this tool that gets the joining wrong).
  local live_now="" rc=0 e
  c="$(auth_container)"
  [ -n "$c" ] && live_now="$(docker exec "$c" printenv "$GOTRUE_KEY" 2>/dev/null || true)"
  if [ "$live_now" = "$desired" ]; then
    note "live $GOTRUE_KEY carries every entry, byte for byte ✓"
  else
    echo "   live value is NOT what we wrote:" >&2
    echo "     want: $desired" >&2
    echo "     got : ${live_now:-<empty>}" >&2
    rc=1
  fi
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    if printf '%s' "$live_now" | tr ',' '\n' | grep -qxF -- "$e"; then
      note "declared entry present in the running auth: $e ✓"
    else
      echo "   declared entry MISSING from the running auth: $e ✗" >&2
      rc=1
    fi
  done <<<"$declared"

  if [ "$SITE_DECLARED" = 1 ]; then
    local live_site_now=""
    [ -n "$c" ] && live_site_now="$(docker exec "$c" printenv "$GOTRUE_SITE_KEY" 2>/dev/null || true)"
    if [ "$live_site_now" = "$DSITE" ]; then
      note "live $GOTRUE_SITE_KEY is the declared site URL ✓"
    else
      echo "   live $GOTRUE_SITE_KEY is NOT the declared site URL:" >&2
      echo "     want: $DSITE" >&2
      echo "     got : ${live_site_now:-<empty>}" >&2
      rc=1
    fi
  fi

  if [ "$rc" != 0 ]; then
    restore_backup "$bak"
    return 2
  fi

  local site_bit=""
  [ "$SITE_DECLARED" = 1 ] && site_bit=", $SITE_KEY_NAME=$DSITE"
  log_line "$(now) OK identity: converged the allow list from $LIST ($(one_line "$declared"))$site_bit"
  echo
  echo "DONE ✅ — the identity allow list matches $LIST and the running auth carries it$site_bit."
  return 0
}

# --- self-healing (--heal) -------------------------------------------------- #

# heal_line <line> — a line for both the operator and the ops log.  Printed and
# logged but never alerted: in heal mode the alert is chosen from the outcome.
heal_line() { printf '%s\n' "$1"; log_line "$1"; }

# verify_in_sync <declared> — re-read the `.env` and the RUNNING auth and assert
# every declared entry is in both.  Nothing is written.  This is the second,
# independent reading a heal ends on: apply_change verifies its own write, but
# "we wrote the value" is a weaker claim than "the running auth now carries it",
# and only the latter is what a member's sign-in depends on.
verify_in_sync() {
  local declared="$1" cur live="" c e
  cur="$(read_current)"
  c="$(auth_container)"
  [ -n "$c" ] || return 1
  live="$(docker exec "$c" printenv "$GOTRUE_KEY" 2>/dev/null || true)"
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    in_list "$e" "$(printf '%s' "$cur" | split_value)" || return 1
    in_list "$e" "$(printf '%s' "$live" | split_value)" || return 1
  done <<<"$declared"
  # The site URL is re-read here too, from BOTH sides and freshly: the point of
  # a heal is that the RUNNING auth agrees, and after a recreate the container
  # is the side that matters.
  if [ "$SITE_DECLARED" = 1 ]; then
    [ "$(read_key_of "$SITE_KEY_NAME")" = "$DSITE" ] || return 1
    [ "$(docker exec "$c" printenv "$GOTRUE_SITE_KEY" 2>/dev/null || true)" = "$DSITE" ] || return 1
  fi
  return 0
}

# alert_heal <detail> — the self-heal notice, fingerprint-guarded so the same
# drift is announced once rather than every 30 minutes.  Deliberately NOT the
# drift alarm: by the time it is sent the entry is already back.
alert_heal() {
  local detail="$1" here seen=""
  [ "$ALERT" = 1 ] || return 0
  if [ ! -f "$ALERT_LIB" ]; then
    warn "no alert library at $ALERT_LIB — cannot notify (the heal is in $LOG)"
    return 0
  fi
  # shellcheck source=/dev/null
  . "$ALERT_LIB"
  mkdir -p "$(dirname "$HEAL_STATE")" 2>/dev/null || true
  [ -f "$HEAL_STATE" ] && seen="$(head -1 "$HEAL_STATE" 2>/dev/null || true)"
  here="$(fp "$detail")"
  if [ "$seen" = "$here" ]; then
    log_line "$(now) NOTE identity: the same drift was self-healed before (not repeating)"
    return 0
  fi
  local healed="A declared OAuth redirect target had gone missing from the central identity stack and was restored automatically."
  [ "$SITE_DECLARED" = 1 ] && healed="The central identity stack had drifted from the declaration (a dropped redirect target, or a site URL that was not the declared one) and was converged automatically."
  send_fanout "🔧 identity redirect allow list self-healed — $(hostname)" \
"$healed  The running auth process was re-read and
carries the declared allow list AND the declared $SITE_KEY_NAME again, so no
sign-in is affected from here on.

Finding: $detail
Declaration: $LIST
Stack: $STACK_DIR"
  printf '%s\n' "$here" >"$HEAL_STATE"
  log_line "$(now) ALERT identity: self-heal notice sent ($detail)"
  return 0
}

# heal_clear_state — the stack is in sync, so any drift from here is new and
# worth announcing again.
heal_clear_state() { rm -f "$HEAL_STATE" 2>/dev/null || true; }

# heal <declared> <n> <missing> <missing_live> <undeclared> <desired> <drift> <live_ok>
#   The scheduled self-heal.  In sync: one log line, no alert.  Drift: converge,
#   re-verify the running auth, then report the outcome (healed notice, or the
#   loud alarm when the heal failed and the previous .env was restored).
heal() {
  local declared="$1" n="$2" missing="$3" missing_live="$4" undeclared="$5"
  local desired="$6" drift="$7" live_ok="$8"
  local what="" names=""

  if [ "$drift" = 0 ]; then
    heal_clear_state
    report_check "$declared" "$n" "" "" "$undeclared" 0 "$live_ok"
    return 0
  fi

  if [ -n "$missing" ]; then what="absent from the stack .env"; fi
  if [ -n "$missing_live" ]; then
    what="${what}${what:+ and }absent from the running auth process"
  fi
  names="$( { printf '%s' "$missing"; printf '%s' "$missing_live"; } \
    | grep -v '^$' | sort -u | tr '\n' ' ' )"
  names="${names% }"

  # The site URL rides in the same finding: one declaration, one verdict — and a
  # heal that reports only the list would leave the operator looking for a
  # second, silent half of the same drift.
  if [ "$SITE_DRIFT" = 1 ]; then
    local site_what=""
    if [ "$ENV_SITE" != "$DSITE" ]; then site_what="$SITE_KEY_NAME"; fi
    if [ "$LIVE_SITE_KNOWN" = 1 ] && [ "$LIVE_SITE" != "$DSITE" ]; then
      site_what="${site_what}${site_what:+ and }$GOTRUE_SITE_KEY"
    fi
    [ -n "$site_what" ] || site_what="$SITE_KEY_NAME"
    what="${what}${what:+ and }$site_what not the declared site URL ($DSITE)"
    names="${names}${names:+ }$site_what"
  fi

  heal_line "$(now) DRIFT identity: $what — $names (self-healing)"
  if [ -n "$undeclared" ]; then
    heal_line "$(now) WARN identity: on the stack but not declared (kept): $(one_line "$undeclared")"
  fi

  apply_change "$desired" "$declared"
  local rc=$?
  if [ "$rc" != 0 ]; then
    heal_line "$(now) HEAL FAILED identity: could not converge $what — $names (manual intervention required)"
    alert_transition 1 "$what: $names (self-heal failed; the previous .env was restored)"
    return 2
  fi

  if ! verify_in_sync "$declared"; then
    heal_line "$(now) HEAL FAILED identity: the stack was converged but the running auth still does not carry every declared entry — $names"
    alert_transition 1 "$what: $names (converged, but the running auth did not pick it up)"
    return 2
  fi

  heal_line "$(now) HEALED identity: $what — $names restored; the running auth was re-verified"
  # The heal worked, so there is no outage to recover from: clear the drift
  # state the alarm path uses, or the next clean run would announce a recovery
  # for an outage that was never reported.
  rm -f "$STATE" 2>/dev/null || true
  alert_heal "$what: $names"
  return 0
}

# --- remote: deploy, then run the same code where the stack lives ---------- #

REMOTE_TOOL=identity_allowlist_sync.sh
REMOTE_LIST=identity-redirect-allowlist.txt

deploy_files() {
  local spec src base mode local_sha remote_sha
  for spec in "$SCRIPT_DIR/$REMOTE_TOOL:0755" "$SCRIPT_DIR/$REMOTE_LIST:0644"; do
    src="${spec%%:*}"; mode="${spec##*:}"
    base="$(basename "$src")"
    [ -f "$src" ] || { echo "identity_allowlist_sync: missing $src" >&2; return 3; }
    local_sha="$(sha256sum "$src" | cut -d' ' -f1)"
    remote_sha="$(ssh "${SSH_OPTS[@]}" "$VM" "sha256sum ~/bin/$base 2>/dev/null | cut -d' ' -f1" 2>/dev/null || true)"
    if [ "$local_sha" = "$remote_sha" ]; then
      note "~/bin/$base already current"
      continue
    fi
    if ! scp -q "${SSH_OPTS[@]}" "$src" "$VM:bin/.$base.tmp"; then
      echo "identity_allowlist_sync: scp of $base failed" >&2
      return 3
    fi
    # chmod then mv, so a scheduled run never executes a half-copied file.
    if ! ssh "${SSH_OPTS[@]}" "$VM" "chmod $mode ~/bin/.$base.tmp && mv -f ~/bin/.$base.tmp ~/bin/$base"; then
      echo "identity_allowlist_sync: installing ~/bin/$base failed" >&2
      return 3
    fi
    note "~/bin/$base updated"
  done
  return 0
}

run_remote() {
  if [ "$LIST" != "$SCRIPT_DIR/$REMOTE_LIST" ]; then
    echo "identity_allowlist_sync: remote mode always converges to the repo declaration" >&2
    echo "  ($SCRIPT_DIR/$REMOTE_LIST); use --local to point somewhere else" >&2
    exit 3
  fi
  deploy_files || exit 3
  if [ "$DEPLOY" = 1 ]; then
    echo "deployed — nothing was planned, applied or checked (drop --deploy to do that)"
    exit 0
  fi

  local -a args=(--local --stack-dir "$STACK_DIR")
  case "$MODE" in
    apply) args+=(--apply) ;;
    check) args+=(--check) ;;
    heal)  args+=(--heal) ;;
  esac
  [ "$ALERT" = 1 ] && args+=(--alert)
  [ "$PRUNE" = 1 ] && args+=(--prune)

  local quoted="" a
  for a in "${args[@]}"; do quoted="$quoted $(printf %q "$a")"; done
  ssh "${SSH_OPTS[@]}" "$VM" "bash ~/bin/$REMOTE_TOOL$quoted"
}

# --- dispatch -------------------------------------------------------------- #

rc=0
if [ "$LOCAL" = 1 ]; then
  run_local || rc=$?
else
  run_remote || rc=$?
fi
exit "$rc"
