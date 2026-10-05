#!/usr/bin/env bash
# verify_vm_project.sh — Phase 0 acceptance checks, parameterized for the
# real VM (docs/PHASE1_VM_ROLLOUT.md §4). Run per project stack, AFTER
# its .env carries the shared JWT secret and signup is disabled:
#
#   KIT_AUTH_URL=https://auth.mediasart.com \
#   KIT_ANON_KEY=<identity stack publishable key> \
#   KIT_PROJECT_URL=https://katalogus-staging.mediasart.com \
#   KIT_PROJECT_ANON_KEY=<project stack anon key> \
#   KIT_PROBE_TABLE=profiles \
#   KIT_VM_EMAIL=you@mediasart.com \
#   KIT_BREVO_API_KEY=<optional: auto-fetch the confirmation code> \
#   email_auth_kit/teststack/verify_vm_project.sh
#
# Checks: kit signup → verify → sign-in on the identity host; foreign JWT
# reads a project table; an RLS insert stamps the foreign auth.uid() (and
# is cleaned up); the project's own /auth/v1/signup is refused.
#
# All KIT_* parameters are required unless marked optional — there are no
# localhost defaults here on purpose; this runs against real hosts.
set -euo pipefail

MISSING=()
for v in KIT_AUTH_URL KIT_ANON_KEY KIT_PROJECT_URL KIT_PROJECT_ANON_KEY \
         KIT_PROBE_TABLE KIT_VM_EMAIL; do
  [ -n "${!v:-}" ] || MISSING+=("$v")
done
# Identity-only run: skip the project probes (checks 7-10) when the app's
# data backend does not share the identity JWT secret (no web project
# stack exists yet). The identity mint (checks 1-6, 11) is what the
# phone app exercises.
if [ -n "${KIT_SKIP_PROJECT:-}" ]; then
  echo "== skipping project probes (checks 7-10): KIT_SKIP_PROJECT set"
fi
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "missing required parameters: ${MISSING[*]}" >&2
  echo "full env contract: see the docstring at the top of verify_vm_project.py" >&2
  exit 2
fi

KIT_BREVO_API_KEY=${KIT_BREVO_API_KEY:-}
echo "== verify_vm_project — acceptance checks against the VM"
echo "   identity : $KIT_AUTH_URL"
echo "   project  : $KIT_PROJECT_URL (probe table: $KIT_PROBE_TABLE)"
echo "   mailbox  : $KIT_VM_EMAIL $( [ -n "$KIT_BREVO_API_KEY" ] \
  && echo '(code auto-fetched from Brevo)' || echo '(code entered interactively)')"
echo

exec python3 "$(cd "$(dirname "$0")" && pwd)/verify_vm_project.py"
