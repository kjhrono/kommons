#!/usr/bin/env bash
# test_watchdog_revert.sh
#
# End-to-end test for jwt-secret-revert-watchdog.sh:
#   1. Pick a non-critical stack (kognitio) as test target.
#   2. Save the current JWT_SECRET.
#   3. Revert .env JWT_SECRET to a known pre-cutover secret (1lvYfMhu5mUDSIjnE6ObPptoBLiArYPWOujtmShPJvA=).
#   4. Run the watchdog.
#   5. Verify the watchdog detected the revert, restored the identity secret, and logged "re-cut complete".
#   6. Restore the original .env if the watchdog didn't (e.g., docker compose failed).

set -euo pipefail

ENV_FILE="$HOME/Projects/kognitio/database/docker/.env"
IDENTITY_ENV="$HOME/Projects/kommons/supabase-identity/docker/.env"
WATCHDOG="$HOME/bin/jwt-secret-revert-watchdog.sh"

# Pre-cutover secret for kognitio (from .env.bak.* history — NOT the current identity secret)
PRE_CUTOVER_SECRET="1lvYfMhu5mUDSIjnE6ObPptoBLiArYPWOujtmShPJvA="

# Step 1: Save current JWT_SECRET
CURRENT_SECRET=$(grep -E '^JWT_SECRET=' "$ENV_FILE" | head -1 | cut -d= -f2-)
echo "Test target: kognitio"
echo "Current (post-cutover) JWT_SECRET: ${CURRENT_SECRET:0:16}..."

# Step 2: Revert to pre-cutover secret
echo ""
echo "Step 2: Reverting JWT_SECRET to pre-cutover value..."
sed -i "s|^JWT_SECRET=.*|JWT_SECRET=${PRE_CUTOVER_SECRET}|" "$ENV_FILE"
REVERTED=$(grep -E '^JWT_SECRET=' "$ENV_FILE" | head -1 | cut -d= -f2-)
echo "Reverted JWT_SECRET: ${REVERTED:0:16}..."

# Step 3: Run the watchdog
echo ""
echo "Step 3: Running watchdog..."
# Disable set -e — watchdog exits 1 on successful re-cut, 2 on failure
# We capture and evaluate the exit code manually below.
set +e
bash "$WATCHDOG"
WATCHDOG_EXIT=$?
set -e
echo "Watchdog exit code: $WATCHDOG_EXIT"
if [ "$WATCHDOG_EXIT" -eq 1 ]; then
  echo "  (exit 1 = revert detected + re-cut attempted, expected)"
elif [ "$WATCHDOG_EXIT" -eq 2 ]; then
  echo "  (exit 2 = revert detected but re-cut FAILED)"
elif [ "$WATCHDOG_EXIT" -eq 0 ]; then
  echo "  (exit 0 = no revert detected — watchdog may not have found the registry)"
fi

# Step 4: Check the log for revert detection
echo ""
echo "Step 4: Checking log for revert detection..."
tail -20 "$HOME/logs/jwt-secret-drift.log"
if grep -q "re-cut complete" "$HOME/logs/jwt-secret-drift.log" 2>/dev/null; then
  echo "  Found 're-cut complete' in log"
else
  echo "  NOTE: 're-cut complete' not yet in log"
fi

# Step 5: Verify the .env was restored to identity secret
echo ""
echo "Step 5: Verifying .env was restored..."
RESTORED=$(grep -E '^JWT_SECRET=' "$ENV_FILE" | head -1 | cut -d= -f2-)
IDENTITY_SECRET=$(grep -E '^JWT_SECRET=' "$IDENTITY_ENV" | head -1 | cut -d= -f2-)
if [ "$RESTORED" = "$IDENTITY_SECRET" ]; then
  echo "PASS: .env JWT_SECRET matches identity-stack secret (auto-recut succeeded)"
  RESULT=0
else
  echo "FAIL: .env JWT_SECRET does not match identity-stack secret"
  echo "  Restored: ${RESTORED:0:16}..."
  echo "  Identity: ${IDENTITY_SECRET:0:16}..."
  echo "Restoring original .env as fallback..."
  sed -i "s|^JWT_SECRET=.*|JWT_SECRET=${CURRENT_SECRET}|" "$ENV_FILE"
  RESULT=1
fi

echo ""
if [ "$RESULT" -eq 0 ]; then
  echo "=== TEST PASSED ==="
else
  echo "=== TEST FAILED (but original .env restored) ==="
fi
exit $RESULT
