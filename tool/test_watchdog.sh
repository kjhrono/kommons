#!/usr/bin/env bash
# Test the watchdog's registry building and fingerprint detection
set -euo pipefail

get_jwt_secret() {
  local env_file="$1" val=""
  val="$(grep -E '^JWT_SECRET=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  case "$val" in
    \"*\") val="${val#\"}"; val="${val%\"}" ;;
    \'*\') val="${val#\'}"; val="${val%\'}" ;;
  esac
  printf '%s\n' "$val"
}

fingerprint() {
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}

IDENTITY_ENV="$HOME/Projects/kommons/supabase-identity/docker/.env"
identity_secret="$(get_jwt_secret "$IDENTITY_ENV")"
identity_fp="$(fingerprint "$identity_secret")"
echo "identity secret: $identity_secret"
echo "identity fp:     $identity_fp"
echo ""

echo "=== pre-cutover fingerprints from .env.bak.* files ==="
echo "  (secrets != identity, excluding drill/test values)"
echo ""
find "$HOME/Projects" -name ".env.bak.*" -type f 2>/dev/null | sort | while IFS= read -r f; do
  s="$(get_jwt_secret "$f")"
  if [ -n "$s" ]; then
    fp="$(fingerprint "$s")"
    rel_f="$(realpath --relative-to="$HOME" "$f" 2>/dev/null || echo "$f")"
    if [ "$fp" = "$identity_fp" ]; then
      echo "  [post-cutover] $fp ← $rel_f"
    elif echo "$s" | grep -qE 'stale-drill|not-a-real-value|secret-here|test-secret'; then
      echo "  [skip-drill]   $fp ← $rel_f"
    else
      echo "  [pre-cutover]  $fp ← $rel_f"
    fi
  fi
done
echo ""

echo "=== current state per stack ==="
echo "  (OK if fp matches identity; REVERT if fp matches a pre-cutover entry)"
echo ""
# First, collect pre-cutover fingerprints into a temp file
REG_TMP="$(mktemp)"
find "$HOME/Projects" -name ".env.bak.*" -type f 2>/dev/null | sort | while IFS= read -r f; do
  s="$(get_jwt_secret "$f")"
  [ -n "$s" ] || continue
  fp="$(fingerprint "$s")"
  [ "$fp" = "$identity_fp" ] && continue
  echo "$s" | grep -qE 'stale-drill|not-a-real-value|secret-here|test-secret' && continue
  echo "$fp"
done | sort -u > "$REG_TMP"

for entry in \
  "kommons|$HOME/Projects/kommons/supabase-identity/docker/.env" \
  "katalogus|$HOME/Projects/katalogus/database/docker/.env" \
  "katalogus-staging|$HOME/Projects/katalogus/staging/docker/.env" \
  "kalcio|$HOME/Projects/kalcio/database/docker/.env" \
  "kognitio|$HOME/Projects/kognitio/database/docker/.env" \
  "kollectio|$HOME/Projects/kollectio/database/docker/.env" \
  "kapaxinfiniti|$HOME/Projects/kapaxinfiniti/database/docker/.env"; do
  stack="${entry%%|*}"
  env_file="${entry#*|}"
  s="$(get_jwt_secret "$env_file" 2>/dev/null || echo "")"
  if [ -z "$s" ]; then
    echo "  $stack: .env not found — SKIP"
    continue
  fi
  fp="$(fingerprint "$s")"
  if [ "$fp" = "$identity_fp" ]; then
    echo "  $stack: OK (matches identity)"
  elif grep -qFx "$fp" "$REG_TMP" 2>/dev/null; then
    echo "  $stack: EXACT REVERT DETECTED (matches pre-cutover fingerprint)"
  else
    echo "  $stack: DRIFT (unknown secret, not a known revert)"
  fi
done
rm -f "$REG_TMP"
