#!/usr/bin/env bash
# verify_alert_chain.sh — one command to close the kommons→kalcio alert
# loop once its two human prerequisites are in place:
#
#   1. The KOMMONS_NOTIFY_TOKEN secret on kjhrono/kommons (fine-grained
#      PAT: repository_dispatch read/write + contents:read on kalcio).
#   2. GitHub Actions billing healthy (jobs must actually start).
#
# Steps: secret check → empty commit re-runs consumers CI (kalcio should
# gate: 3 consumers, 0 skipped) → manual kommons_changed dispatch →
# watch kalcio's listener.
set -euo pipefail

KOMMONS=${KOMMONS_REPO:-kjhrono/kommons}
KALCIO=${KALCIO_REPO:-kjhrono/kalcio}

echo "== 1. secret present?"
if ! gh api "repos/$KOMMONS/actions/secrets" -q '.secrets[].name' | grep -qx KOMMONS_NOTIFY_TOKEN; then
  echo "✗ KOMMONS_NOTIFY_TOKEN is NOT on $KOMMONS — set it first:"
  echo "    gh secret set KOMMONS_NOTIFY_TOKEN --repo $KOMMONS"
  exit 1
fi
echo "✓ secret present"

echo "== 2. consumers CI re-run (empty commit)"
git pull --ff-only origin master
git commit --allow-empty -m "Re-run consumers CI: verify the kalcio gate"
git push origin master
sleep 8
RUN_ID=$(gh run list --repo "$KOMMONS" --workflow consumers --limit 1 --json databaseId -q '.[0].databaseId')
echo "   watching run $RUN_ID…"
gh run watch "$RUN_ID" --repo "$KOMMONS" --exit-status --interval 20
LOG=$(gh run view "$RUN_ID" --repo "$KOMMONS" --log 2>/dev/null || true)
echo "$LOG" | grep -E '=== kalcio|ALL GATES' | tail -3
if echo "$LOG" | grep -q '=== kalcio'; then
  echo "✓ kalcio is GATED (not skipped)"
else
  echo "✗ kalcio did not run — the checkout step likely failed; inspect:"
  echo "    gh run view $RUN_ID --repo $KOMMONS --log-failed"
  exit 1
fi

echo "== 3. manual kommons_changed dispatch"
SHA=$(git rev-parse origin/master)
gh api "repos/$KALCIO/dispatches" \
  -f event_type=kommons_changed \
  -f "client_payload[sha]=$SHA"
echo "   dispatched @ ${SHA:0:8}; watching the listener…"
sleep 8
DISPATCH_RUN=$(gh run list --repo "$KALCIO" --workflow kommons-changed \
  --event repository_dispatch --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch "$DISPATCH_RUN" --repo "$KALCIO" --exit-status --interval 20
echo "✓ LOOP CLOSED: kommons change → kalcio gate, end to end"
