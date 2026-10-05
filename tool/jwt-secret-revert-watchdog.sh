#!/usr/bin/env bash
# jwt-secret-revert-watchdog.sh
#
# Companion to jwt-secret-drift-check.sh.
#
# The drift check flags any JWT_SECRET that differs from the identity
# stack — but a drift could be anything (a typo, a new rotation in
# progress, a half-done manual edit).  This watchdog adds *exact
# revert* detection: it builds a fingerprint registry from every
# .env.bak.* history file and, when a stack's JWT_SECRET matches a
# known pre-cutover fingerprint, it means someone rolled the .env
# back to an old local secret.  That breaks central identity, so the
# watchdog force-re-cuts automatically:
#
#   1. backs up the reverted .env
#   2. restores the identity-stack shared JWT_SECRET
#   3. runs `docker compose up -d --force-recreate` (non-blocking; polls auth health)
#   4. verifies the secret landed
#   5. alerts on the revert + re-cut
#
# Alert configuration (same env vars as drift-check.sh):
#   ALERT_WEBHOOK_URL  — incoming-webhook URL for real-time alerts
#   ALERT_EMAIL        — recipient for Brevo/mail alerts
#   BREVO_API_KEY      — Brevo REST API key for email alerts
#   BREVO_SENDER       — sender email (default: noreply@mediasart.com)
#   BREVO_SENDER_NAME  — sender name (default: mediasart)
set -euo pipefail

# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #

LOG="$HOME/logs/jwt-secret-drift.log"
IDENTITY_ENV="$HOME/Projects/kommons/supabase-identity/docker/.env"
REGISTRY_DIR="$HOME/.jwt-secret-history"
REGISTRY_FILE="$REGISTRY_DIR/registry.sha256"
mkdir -p "$HOME/logs" "$REGISTRY_DIR"

# Stacks: name|env_path|compose_dir
# kommons is the identity reference — checked for completeness but
# never re-cut (it IS the source of truth).
STACKS=(
  "kommons|${IDENTITY_ENV}|${HOME}/Projects/kommons/supabase-identity/docker"
  "katalogus|${HOME}/Projects/katalogus/database/docker/.env|${HOME}/Projects/katalogus/database/docker"
  "katalogus-staging|${HOME}/Projects/katalogus/staging/docker/.env|${HOME}/Projects/katalogus/staging/docker"
  "kalcio|${HOME}/Projects/kalcio/database/docker/.env|${HOME}/Projects/kalcio/database/docker"
  "kognitio|${HOME}/Projects/kognitio/database/docker/.env|${HOME}/Projects/kognitio/database/docker"
  "kollectio|${HOME}/Projects/kollectio/database/docker/.env|${HOME}/Projects/kollectio/database/docker"
  "kapaxinfiniti|${HOME}/Projects/kapaxinfiniti/database/docker/.env|${HOME}/Projects/kapaxinfiniti/database/docker"
)

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #

timestamp() { date '+%Y-%m-%dT%H:%M:%S%z'; }

# Read the raw JWT_SECRET value from an env file (handles quoted values)
get_jwt_secret() {
  local env_file="$1" val=""
  val="$(grep -E '^JWT_SECRET=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  case "$val" in
    \"*\") val="${val#\"}"; val="${val%\"}" ;;
    \'*\') val="${val#\'}"; val="${val%\'}" ;;
  esac
  printf '%s\n' "$val"
}

# SHA-256 fingerprint of a secret value — never store raw secrets
fingerprint() {
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}

# --------------------------------------------------------------------------- #
# Alert helpers (same pattern as jwt-secret-drift-check.sh)
# --------------------------------------------------------------------------- #

send_webhook_alert() {
  local message="$1"
  [ -n "${ALERT_WEBHOOK_URL:-}" ] || return 0
  local safe
  safe=$(printf '%s\n' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g')
  curl -s -o /dev/null --max-time 10 \
    -X POST "$ALERT_WEBHOOK_URL" \
    -H 'Content-Type: application/json' \
    -d "{\"text\":\"${safe}\"}" || true
}

send_email_alert() {
  local subject="$1" body="$2"
  if [ -n "${ALERT_EMAIL:-}" ] && command -v mail >/dev/null 2>&1; then
    printf '%s\n' "$body" | mail -s "$subject" "$ALERT_EMAIL" || true
  fi
}

send_brevo_alert() {
  local subject="$1" body="$2"
  if [ -z "${BREVO_API_KEY:-}" ] || [ -z "${ALERT_EMAIL:-}" ]; then
    return 0
  fi
  local sender="${BREVO_SENDER:-noreply@mediasart.com}"
  local sender_name="${BREVO_SENDER_NAME:-mediasart}"
  local esc_body esc_subject
  esc_body=$(printf '%s' "$body" | sed 's/\\/\\\\/g; s/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
  esc_subject=$(printf '%s' "$subject" | sed 's/\\/\\\\/g; s/"/\\"/g')
  curl -s -o /dev/null --max-time 15 \
    -X POST "https://api.brevo.com/v3/smtp/email" \
    -H "api-key: ${BREVO_API_KEY}" \
    -H 'Content-Type: application/json' \
    -d "{\"sender\":{\"email\":\"${sender}\",\"name\":\"${sender_name}\"},\"to\":[{\"email\":\"${ALERT_EMAIL}\"}],\"subject\":\"${esc_subject}\",\"textContent\":\"${esc_body}\"}" || true
}

send_revert_alerts() {
  local details="$1"
  local host msg
  host="$(hostname)"
  msg="🔄 JWT Exact-Revert + Auto Re-cut — ${host}\n\n${details}\n\n"
  send_webhook_alert "$msg"
  send_email_alert "[Revert Alert] JWT Secret Re-cut — ${host}" "$msg"
  send_brevo_alert "[Revert Alert] JWT Secret Re-cut — ${host}" "$msg"
}

# --------------------------------------------------------------------------- #
# Registry: build the pre-cutover secret-fingerprint set
# --------------------------------------------------------------------------- #

build_registry() {
  local identity_secret identity_fp
  identity_secret="$(get_jwt_secret "$IDENTITY_ENV")"
  if [ -z "$identity_secret" ]; then
    echo "$(timestamp) FATAL: could not read identity JWT_SECRET from $IDENTITY_ENV" >> "$LOG"
    send_revert_alerts "Could not read identity JWT_SECRET from $IDENTITY_ENV — registry build failed."
    exit 1
  fi
  identity_fp="$(fingerprint "$identity_secret")"

  local tmpfile
  tmpfile="$(mktemp)"

  # Scan every .env.bak.* history file under ~/Projects for a JWT_SECRET
  # `find` returns non-zero when it hits root-owned PostgreSQL volume dirs
  # that the ubuntu user can't traverse — that's expected.  `|| true` keeps
  # set -e + pipefail from aborting the script.
  find "$HOME/Projects" -name ".env.bak.*" -type f 2>/dev/null \
    | sort \
    | while IFS= read -r bak; do
        local sec
        sec="$(get_jwt_secret "$bak")"
        [ -n "$sec" ] || continue
        # Skip test/drill placeholders that never were real secrets
        case "$sec" in
          *stale-drill*|*not-a-real-value*|*secret-here*|*test-secret*)
            continue ;;
        esac
        local fp
        fp="$(fingerprint "$sec")"
        # Exclude the current identity secret — that's post-cutover, not pre-cutover
        if [ "$fp" = "$identity_fp" ]; then continue; fi
        printf '%s\n' "$fp"
      done | sort -u > "$tmpfile" || true

  mv "$tmpfile" "$REGISTRY_FILE"
  local count
  count="$(wc -l < "$REGISTRY_FILE" | tr -d ' ')"
  echo "$(timestamp) REGISTRY built: ${count} pre-cutover fingerprints (identity=${identity_fp:0:16}…)" >> "$LOG"
}

# --------------------------------------------------------------------------- #
# Force re-cut: restore identity secret + restart stack
# --------------------------------------------------------------------------- #

force_recut() {
  local stack="$1" env_file="$2" compose_dir="$3" identity_secret="$4"

  local epoch backup
  epoch="$(date +%s)"
  backup="${env_file}.bak.recut-auto.${epoch}"

  echo "$(timestamp) REVERT $stack: JWT_SECRET matches pre-cutover fingerprint — force re-cut" >> "$LOG"

  # 1. Back up the reverted .env
  if ! cp "$env_file" "$backup" 2>/dev/null; then
    echo "$(timestamp) REVERT $stack: FAILED to back up $env_file" >> "$LOG"
    send_revert_alerts "Exact revert detected in ${stack} but could not back up ${env_file} — manual intervention required."
    return 1
  fi
  echo "$(timestamp) REVERT $stack: backed up $env_file → $backup" >> "$LOG"

  # 2. Restore the identity-stack JWT_SECRET
  if grep -q '^JWT_SECRET=' "$env_file"; then
    sed -i "s|^JWT_SECRET=.*$|JWT_SECRET=${identity_secret}|" "$env_file"
  else
    echo "JWT_SECRET=${identity_secret}" >> "$env_file"
  fi

  # 3. Verify the replacement took hold
  local new_secret
  new_secret="$(get_jwt_secret "$env_file")"
  if [ "$new_secret" != "$identity_secret" ]; then
    echo "$(timestamp) REVERT $stack: FAILED to update JWT_SECRET — restored from $backup" >> "$LOG"
    # Roll back the failed edit
    cp "$backup" "$env_file"
    send_revert_alerts "Re-cut FAILED for ${stack}: JWT_SECRET could not be updated.  Backup restored.\nFile: ${env_file}\nManual intervention required."
    return 1
  fi
  echo "$(timestamp) REVERT $stack: JWT_SECRET restored in $env_file" >> "$LOG"

  # 4. Force-recreate the stack so containers pick up the new env.
  #    We deliberately omit --wait: Supabase stacks include a realtime
  #    container whose healthcheck is intermittently flaky (WebSocket ping
  #    under load), so `docker compose up --wait` blocks until its timeout
  #    and the watchdog treats a successful secret restore as a failure.
  #    Instead we fire `up -d` (non-blocking) and poll the auth/gotr ue
  #    container health separately.
  echo "$(timestamp) REVERT $stack: docker compose up -d --force-recreate in $compose_dir" >> "$LOG"

  if ! (cd "$compose_dir" && docker compose up -d --force-recreate) >> "$LOG" 2>&1; then
    echo "$(timestamp) REVERT $stack: docker compose up -d --force-recreate failed — check $LOG" >> "$LOG"
    send_revert_alerts "Exact revert detected in ${stack}: JWT_SECRET was restored in ${env_file} but\n\
docker compose up --force-recreate failed.\n\
Backup: ${backup}\n\
Manual intervention required: verify stack health manually."
    return 1
  fi

  # 5. Poll for the auth/gotr ue container to become healthy.  Up to 30
  #    attempts × 10s = 5 min tolerance (slow image pulls, DB migrations).
  echo "$(timestamp) REVERT $stack: waiting for auth container to become healthy…" >> "$LOG"
  local auth_container="" auth_check="" poll=0
  local max_poll=30
  until [ "$poll" -ge "$max_poll" ]; do
    auth_container="$(cd "$compose_dir" && docker compose ps -q auth 2>/dev/null || true)"
    if [ -z "$auth_container" ]; then
      auth_container="$(cd "$compose_dir" && docker compose ps -q gotrue 2>/dev/null || true)"
    fi
    if [ -n "$auth_container" ]; then
      local hc_status
      hc_status="$(docker inspect --format='{{.State.Health.Status}}' "$auth_container" 2>/dev/null || true)"
      # "healthy" or empty (no healthcheck) = ready to proceed
      if [ "$hc_status" = "healthy" ] || [ -z "$hc_status" ]; then
        break
      fi
    fi
    poll=$((poll + 1))
    sleep 10
  done

  # 6. Confirm the secret landed in the running auth container
  if [ -n "$auth_container" ]; then
    auth_check="$(docker exec "$auth_container" printenv GOTRUE_JWT_SECRET 2>/dev/null || true)"
    if [ "$auth_check" = "$identity_secret" ]; then
      echo "$(timestamp) REVERT $stack: ✓ running auth container confirms JWT_SECRET matches identity" >> "$LOG"
    else
      echo "$(timestamp) REVERT $stack: ⚠ running auth container JWT_SECRET mismatch (container may still be starting)" >> "$LOG"
    fi
  fi

  echo "$(timestamp) REVERT $stack: re-cut complete" >> "$LOG"
  send_revert_alerts "Exact JWT_SECRET revert auto-repaired.\n\n\
Stack:      ${stack}\n\
Env:        ${env_file}\n\
Action:     JWT_SECRET restored to identity-stack shared secret + docker compose --force-recreate\n\
Backup:     ${backup}\n\
Log:        $(readlink -f "$LOG")"
  return 0
}

# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

# Verify identity env exists
if [ ! -f "$IDENTITY_ENV" ]; then
  echo "$(timestamp) FATAL identity .env not found at $IDENTITY_ENV" >> "$LOG"
  send_revert_alerts "Identity .env not found at $IDENTITY_ENV — cannot determine reference JWT_SECRET."
  exit 1
fi

# Build the pre-cutover fingerprint registry from all .env.bak.* files
build_registry

# Read the reference (identity) secret + its fingerprint
IDENTITY_SECRET="$(get_jwt_secret "$IDENTITY_ENV")"
IDENTITY_FP="$(fingerprint "$IDENTITY_SECRET")"

reverted=0
for entry in "${STACKS[@]}"; do
  stack="${entry%%|*}"
  rest="${entry#*|}"
  env_file="${rest%%|*}"
  compose_dir="${rest#*|}"

  # The identity stack is the source of truth — skip it for revert checks
  if [ "$stack" = "kommons" ]; then continue; fi

  if [ ! -f "$env_file" ]; then
    echo "$(timestamp) WARN $stack: .env not found at $env_file — skipping" >> "$LOG"
    continue
  fi

  current_secret="$(get_jwt_secret "$env_file")"
  if [ -z "$current_secret" ]; then
    echo "$(timestamp) WARN $stack: JWT_SECRET empty in $env_file — skipping" >> "$LOG"
    continue
  fi

  current_fp="$(fingerprint "$current_secret")"

  # Case 1: already matches identity — healthy, nothing to do
  if [ "$current_fp" = "$IDENTITY_FP" ]; then
    continue
  fi

  # Case 2: exact revert — current secret matches a known pre-cutover fingerprint
  if [ -f "$REGISTRY_FILE" ] && grep -qFx "$current_fp" "$REGISTRY_FILE"; then
    echo "$(timestamp) REVERT DETECTED $stack: $(fingerprint "$current_secret") = pre-cutover secret — triggering auto re-cut" >> "$LOG"
    if force_recut "$stack" "$env_file" "$compose_dir" "$IDENTITY_SECRET"; then
      reverted=1
    else
      reverted=2  # re-cut failed
    fi
  else
    # Case 3: drift but not a known revert — log for the drift-check.sh alarm
    echo "$(timestamp) DRIFT $stack: JWT_SECRET differs from identity and is not a known pre-cutover secret" >> "$LOG"
  fi
done

# Summary
if [ "$reverted" -eq 1 ]; then
  echo "$(timestamp) DONE: at least one exact revert was auto-re-cut" >> "$LOG"
  exit 1
elif [ "$reverted" -eq 2 ]; then
  echo "$(timestamp) DONE: revert detected but re-cut FAILED — manual intervention required" >> "$LOG"
  exit 2
fi

echo "$(timestamp) OK no exact reverts detected across project stacks" >> "$LOG"
exit 0
