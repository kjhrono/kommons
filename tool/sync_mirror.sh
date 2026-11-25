#!/usr/bin/env bash
# ============================================================================
# sync_mirror.sh — the working copy of this repo on mediasart_u26:/srv/kommons.
#
#   tool/sync_mirror.sh            # mirror HEAD
#   tool/sync_mirror.sh <commit>   # mirror one exact commit
#   tool/sync_mirror.sh --check    # compare only: exits 1 when different
#
# Only what is COMMITTED travels (git archive): uncommitted files, build/
# and .dart_tool/ never reach the server. On the server the tree is unpacked
# into a temporary folder inside /srv/kommons, then aligned with
# rsync --delete. The mirrored commit is written to /srv/kommons/.mirror_commit.
#
# Same recipe as kognitio's tool/sync_mirror.sh.
# Variables: HOST (default mediasart_u26), WEB_ROOT (/srv/kommons),
#            SSH_KEY (empty: ~/.ssh/config decides).
# ============================================================================
set -euo pipefail

HOST="${HOST:-mediasart_u26}"
WEB_ROOT="${WEB_ROOT:-/srv/kommons}"
SSH_KEY="${SSH_KEY:-}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
[[ -n "$SSH_KEY" && -f "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK=0; REV="HEAD"
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    -h|--help) awk 'NR==1{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' "$0"; exit 0 ;;
    *) REV="$arg" ;;
  esac
done
SHA="$(git -C "$PROJECT_ROOT" rev-parse --verify "$REV^{commit}")"

REMOTE_SHA="$(ssh "${SSH_OPTS[@]}" "$HOST" "cat '$WEB_ROOT/.mirror_commit' 2>/dev/null || true")"
if [[ "$CHECK" == "1" ]]; then
  if [[ "$REMOTE_SHA" == "$SHA" ]]; then
    echo "mirror matches $SHA"; exit 0
  fi
  echo "mirror on $HOST:$WEB_ROOT = ${REMOTE_SHA:-(none)}, expected $SHA" >&2
  exit 1
fi

echo "   mirror $SHA → $HOST:$WEB_ROOT (was: ${REMOTE_SHA:-none})"
# Two steps: the tar first (ssh's stdin), then the remote script (heredoc).
git -C "$PROJECT_ROOT" archive --format=tar "$SHA" | \
  ssh "${SSH_OPTS[@]}" "$HOST" "mkdir -p '$WEB_ROOT' && cat > '$WEB_ROOT/.mirror.tar'"
ssh "${SSH_OPTS[@]}" "$HOST" bash -s <<REMOTE
set -euo pipefail
ROOT="$WEB_ROOT"
# The temporary source is born with ROOT's own mode (umask 002, setgid
# inherited), so rsync -p never changes ROOT's permissions.
TMP="\$ROOT/.mirror.\$\$"
rm -rf "\$TMP"
(umask 002 && mkdir "\$TMP")
MODE=\$(stat -c %a "\$ROOT")
trap 'rm -rf "\$TMP" "\$ROOT/.mirror.tar"' EXIT
tar -x -C "\$TMP" -f "\$ROOT/.mirror.tar"
rsync -rlpt --delete \\
  --exclude='/.mirror.*' --exclude=/.mirror_commit \\
  "\$TMP/" "\$ROOT/"
if [ "\$(stat -c %a "\$ROOT")" != "\$MODE" ]; then
  echo "   WARNING: \$ROOT permissions changed (\$MODE → \$(stat -c %a "\$ROOT"))" >&2
fi
echo "$SHA" > "\$ROOT/.mirror_commit"
REMOTE
echo "   mirror updated ($(ssh "${SSH_OPTS[@]}" "$HOST" "du -sh '$WEB_ROOT' | cut -f1"))"
