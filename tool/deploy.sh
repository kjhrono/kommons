#!/usr/bin/env bash
# deploy.sh — commit, push to GitHub, then ship a kjhrono game to its VM.
#
# Lives in kjhrono_commons; every game repo keeps a thin delegating
# scripts/deploy.sh plus its own deploy.config (see deploy.config.example):
#
#   bash scripts/deploy.sh                    # full: commit+push+sync+migrate+build+publish
#   bash scripts/deploy.sh --no-commit        # skip git, just sync+migrate+build+publish
#   bash scripts/deploy.sh --dry-run          # print every step without touching anything
#   bash scripts/deploy.sh --message "text"   # custom commit message
#   bash scripts/deploy.sh --config PATH      # deploy.config elsewhere (default: repo root)
#
# deploy.config keys (all optional unless noted; see deploy.config.example):
#   git_remote        push target, default origin
#   git_paths         whitespace-separated paths to commit, default "lib test server scripts .."
#   host              (needed for VM sync) the VM address
#   ssh_user          SSH user on the VM, default ubuntu
#   ssh_key           path to the SSH identity (never commit it); falls back to
#                     <repo>/ssh-private-key.key when present
#   target_dir        remote directory under $HOME, default kapax
#   web_root          remote nginx webroot for the build, default /var/www/<name>
#   db_container      Supabase Postgres container for migrations, default <name>-db-1
#   web_dirs          extra local dirs synced verbatim into target_dir, default "server scripts"
#   web_publish       publish the web build, default true
#   app_name          display name for logs, default the repo folder name
#
# Anything this script doesn't cover (nginx bootstrap, first-time Supabase
# install) stays in the game's own scripts — this tool only keeps a configured
# VM up to date.
set -euo pipefail

usage() { grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; }

CONFIG=""
MESSAGE=""
DRY_RUN=false
COMMIT=true
FORCE_MIGRATE=false
NO_BUILD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="${2:?}"; shift 2 ;;
    --message) MESSAGE="${2:?}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --no-commit) COMMIT=false; shift ;;
    --force-migrate) FORCE_MIGRATE=true; shift ;;
    --no-build) NO_BUILD=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG="${CONFIG:-$root/deploy.config}"
if [[ ! -f "$CONFIG" ]]; then
  echo "deploy.config not found at $CONFIG" >&2
  echo "Copy deploy.config.example from kjhrono_commons and fill in your VM." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG"

APP_NAME="${app_name:-$(basename "$root")}"
GIT_REMOTE="${git_remote:-origin}"
GIT_PATHS="${git_paths:-lib test server scripts pubspec.yaml pubspec.lock}"
SSH_USER="${ssh_user:-ubuntu}"
SSH_KEY="${ssh_key:-}"
TARGET_DIR="${target_dir:-kapax}"
WEB_DIRS="${web_dirs:-server scripts}"
WEB_PUBLISH="${web_publish:-true}"
DB_CONTAINER="${db_container:-${APP_NAME}-db-1}"
WEB_ROOT="${web_root:-/var/www/${APP_NAME}}"
if [[ -z "$SSH_KEY" && -f "$root/ssh-private-key.key" ]]; then
  SSH_KEY="$root/ssh-private-key.key"
fi

if $DRY_RUN; then
  echo "==> DRY RUN — nothing will be modified. Configuration:"
  echo "    app:        $APP_NAME"
  echo "    repo:       $root"
  echo "    git remote: $GIT_REMOTE ($GIT_PATHS)"
  echo "    vm:         ${SSH_USER}@${host:-<unset>} → ~/$TARGET_DIR"
  echo "    ssh key:    ${SSH_KEY:-<agent default>}"
  echo "    web root:   $WEB_ROOT (publish: $WEB_PUBLISH)"
  echo "    db:         $DB_CONTAINER (migrate on schema change)"
  [[ -n "$MESSAGE" ]] && echo "    commit msg: $MESSAGE"
  exit 0
fi

if [[ -z "${host:-}" ]]; then
  echo "deploy.config: set host=<vm-address> (or run --dry-run to inspect)" >&2
  exit 1
fi

HOST="$host"

REMOTE="${SSH_USER}@${HOST}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
RSYNC_SSH="ssh -o BatchMode=yes -o ConnectTimeout=10${SSH_KEY:+ -i $SSH_KEY}"
if [[ -n "$SSH_KEY" ]]; then
  SSH_OPTS+=(-i "$SSH_KEY")
fi

echo "==> ${APP_NAME} deploy → ${REMOTE}:~/${TARGET_DIR}"

# ---- 1. commit + push -------------------------------------------------------
if $COMMIT; then
  # shellcheck disable=SC2086
  if [[ -n "$(git status --porcelain -- $GIT_PATHS)" ]]; then
    if [[ -z "$MESSAGE" ]]; then
      MESSAGE="${APP_NAME}: deploy ($(date +%F))"
    fi
    echo "==> Committing: $GIT_PATHS"
    # shellcheck disable=SC2086
    git add -- $GIT_PATHS
    git commit -m "$MESSAGE"
  else
    echo "==> Nothing to commit in: $GIT_PATHS"
  fi
  if git remote get-url "$GIT_REMOTE" >/dev/null 2>&1; then
    echo "==> Pushing to $GIT_REMOTE ..."
    if ! git push "$GIT_REMOTE" HEAD; then
      # HTTPS remotes without stored credentials fail here; retry over SSH
      # (works when an SSH key authenticates with GitHub).
      echo "   plain push failed — retrying over SSH ..."
      if ! git -c url."git@github.com:".insteadOf="https://github.com/" push "$GIT_REMOTE" HEAD; then
        echo "   !! push failed — continuing with the local deploy" >&2
      fi
    fi
  else
    echo "==> No git remote '$GIT_REMOTE' — skipping push."
  fi
else
  echo "==> --no-commit: skipping git steps."
fi

# ---- 2. sync game scripts to the VM -----------------------------------------
if ! command -v rsync >/dev/null 2>&1; then
  echo "rsync is required (sudo apt install rsync)" >&2
  exit 1
fi
ssh "${SSH_OPTS[@]}" "$REMOTE" "mkdir -p \"\$HOME/${TARGET_DIR}\""
for dir in $WEB_DIRS; do
  [[ -d "$root/$dir" ]] || continue
  echo "==> Syncing $dir/ to ${REMOTE}:~/${TARGET_DIR}/$dir/ ..."
  rsync -a --delete -e "$RSYNC_SSH" \
    --exclude '*.swp' --exclude '.applied-hash' \
    "$root/$dir/" "$REMOTE:${TARGET_DIR}/$dir/"
done

# ---- 3. apply the schema only when it changed -------------------------------
SCHEMA="$root/server/supabase/schema.sql"
MIGRATE="$root/server/supabase/migrate.sh"
if [[ -f "$SCHEMA" && -f "$MIGRATE" ]]; then
  local_hash="$(sha256sum "$SCHEMA" | cut -d' ' -f1)"
  remote_hash="$(ssh "${SSH_OPTS[@]}" "$REMOTE" \
    "cat \"\$HOME/${TARGET_DIR}/.applied-hash\" 2>/dev/null || echo none")"
  if [[ "$local_hash" == "$remote_hash" && "$FORCE_MIGRATE" != true ]]; then
    echo "==> Schema unchanged (${local_hash:0:12}…) — migration skipped."
  else
    if [[ "$remote_hash" == "none" ]]; then
      echo "==> First deploy on this VM — applying schema."
    else
      echo "==> Schema changed (${remote_hash:0:12}… → ${local_hash:0:12}…) — migrating."
    fi
    ssh "${SSH_OPTS[@]}" "$REMOTE" \
      "bash \"\$HOME/${TARGET_DIR}/server/supabase/migrate.sh\" --db-container '$DB_CONTAINER'"
    ssh "${SSH_OPTS[@]}" "$REMOTE" "echo '$local_hash' > \"\$HOME/${TARGET_DIR}/.applied-hash\""
  fi
else
  echo "==> No server/supabase schema — skipping migration."
fi

# ---- 4. build the web app (skipped when sources are unchanged) ---------------
if [[ "$WEB_PUBLISH" == true ]] && ! $NO_BUILD; then
  FLUTTER="$(command -v flutter || echo "$HOME/Apps/flutter/bin/flutter")"
  if [[ -x "$FLUTTER" ]]; then
    if [[ ! -f "$root/build/web/index.html" ]]; then
      echo "==> Building web app (no previous build) ..."
      "$FLUTTER" build web --release
    elif [[ -n "$(find lib web pubspec.yaml -type f -newer "$root/build/web/index.html" -print -quit 2>/dev/null)" ]]; then
      echo "==> Sources changed since the last web build — rebuilding ..."
      "$FLUTTER" build web --release
    else
      echo "==> Web build is up to date — skipping flutter build."
    fi
  else
    echo "!! flutter not found — publishing the existing build/web as-is." >&2
  fi
fi

# ---- 5. publish the web build ------------------------------------------------
if [[ "$WEB_PUBLISH" == true ]] && [[ -d "$root/build/web" ]]; then
  echo "==> Publishing web build to ${REMOTE}:${WEB_ROOT}/ ..."
  ssh "${SSH_OPTS[@]}" "$REMOTE" "mkdir -p '$WEB_ROOT' 2>/dev/null || true"
  if ! rsync -a --delete -e "$RSYNC_SSH" "$root/build/web/" "$REMOTE:${WEB_ROOT}/" 2>/dev/null; then
    echo "   webroot not writable yet — if this is the first deploy, run the" >&2
    echo "   game's nginx setup script once, then re-run this deploy." >&2
    exit 1
  fi
elif [[ "$WEB_PUBLISH" == true ]]; then
  echo "==> No web build at build/web — run 'flutter build web --release' to create it."
fi

echo
echo "✔ Deploy complete for ${APP_NAME}."
