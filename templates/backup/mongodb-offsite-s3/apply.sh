#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# apply.sh — apply the MongoDB off-site S3 CronJob + fire one test run.
#
# WHY A WRAPPER: applying/creating objects is a MUTATING action. In a guarded
#   workspace it needs (a) the OWNER's explicit approval for THIS command, and
#   (b) a single-use APPROVE_NEXT token the guard consumes. It must be applied
#   FROM A FILE — the heredoc form (apply -f - <<EOF) is blocked by the guard.
#   Every kubectl below carries --context <CTX> explicitly.
#
# USAGE (owner runs this, from the repo root):
#   CTX=<your-kubectl-context> NS=<namespace> \
#   YAML=/path/to/cronjob.yaml \
#   WEBHOOK_SECRET=<notify-webhook-secret-name> \
#   WEBHOOK_URL='<https://your-chat-webhook>' \
#     bash apply.sh
#
#   WEBHOOK_URL is OPTIONAL — only needed the first time, to create the webhook
#   secret. Omit it if the secret already exists.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

CTX="${CTX:?set CTX=<kubectl context>}"
NS="${NS:?set NS=<namespace>}"
YAML="${YAML:?set YAML=<path to the filled-in cronjob.yaml>}"
WEBHOOK_SECRET="${WEBHOOK_SECRET:-notify-webhook}"
CRONJOB_NAME="mongodb-offsite-backup-s3"
TOKEN=".claude/state/APPROVE_NEXT"   # adjust to your guard's token path, or ignore if unguarded

[ -f "$YAML" ] || { echo "YAML not found: $YAML"; exit 1; }

# 0) READ-ONLY sanity: cluster reachable + namespace exists (safe, no token needed).
echo "== 0. verify context/namespace (read-only) =="
kubectl --context "$CTX" --request-timeout=30s get ns "$NS" >/dev/null \
  || { echo "  namespace $NS not reachable on $CTX"; exit 1; }

# 1) Webhook secret for the notify container (idempotent). Only if WEBHOOK_URL given.
echo "== 1. notify webhook secret $WEBHOOK_SECRET =="
if kubectl --context "$CTX" --request-timeout=30s -n "$NS" get secret "$WEBHOOK_SECRET" >/dev/null 2>&1; then
  echo "  already exists — skipping (delete first to replace)"
elif [ -n "${WEBHOOK_URL:-}" ]; then
  kubectl --context "$CTX" --request-timeout=30s -n "$NS" create secret generic "$WEBHOOK_SECRET" \
    --from-literal=WEBHOOK_URL="$WEBHOOK_URL" && echo "  created" || { echo "  FAILED"; exit 1; }
else
  echo "  MISSING and no WEBHOOK_URL given — set WEBHOOK_URL=... and re-run, or create it manually."; exit 1
fi

# 2) Apply the CronJob (mutating → single-use APPROVE_NEXT token, consumed by the guard).
#    NOTE: the owner must have approved THIS apply in chat first.
echo "== 2. apply CronJob $CRONJOB_NAME from $YAML =="
: > "$TOKEN"
kubectl --context "$CTX" apply -f "$YAML" || { echo "  apply FAILED"; rm -f "$TOKEN"; exit 1; }
rm -f "$TOKEN"   # belt-and-suspenders: never leave a stale token behind

# 3) On-demand TEST run now (don't wait for the first schedule). create job = mutating → fresh token.
echo "== 3. on-demand test run =="
TESTJOB="offsite-test-$(date -u +%Y%m%d-%H%M%S)"
: > "$TOKEN"
kubectl --context "$CTX" -n "$NS" create job --from=cronjob/"$CRONJOB_NAME" "$TESTJOB" \
  || echo "  test create FAILED"
rm -f "$TOKEN"

echo
echo "== watch the test (read-only; safe to Ctrl-C) =="
echo "kubectl --context $CTX -n $NS get job $TESTJOB -w"
echo "kubectl --context $CTX -n $NS logs -l job-name=$TESTJOB -c dump   --tail=40"
echo "kubectl --context $CTX -n $NS logs -l job-name=$TESTJOB -c upload --tail=40"
echo
echo "Confirm the object landed in the bucket (or let the success notification confirm it)."
