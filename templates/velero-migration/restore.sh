#!/usr/bin/env bash
# =============================================================================
# Velero restore onto the TARGET  —  vendor-neutral, parameterized
#
# DESTRUCTIVE — operator-run. `velero restore create` writes manifests into the target
# cluster. Get the owner's explicit approval before running. `velero` is NOT a kubectl
# subcommand, so a kubectl guard will NOT catch this.
#
# PREREQS on the target (Velero carries NONE of these — install FIRST):
#   - CNI healthy; StorageClass whose NAME == source PVCs' storageClassName
#   - cert-manager + ingress controller + any operators you want pre-seeded
#   - Velero at the SAME version as the source, BSL Available on the same bucket+prefix
#   - The resource-modifiers ConfigMap applied (this script applies it for you)
#
# USAGE:
#   DST_CONTEXT=<dst-context> \
#   BACKUP_NAME=migrate-YYYYMMDD \
#   RESTORE_NAME=${BACKUP_NAME}-restore \
#   INCLUDE_NS="<ns1>,<ns2>,..." \        # same GAP you backed up (or EXCLUDE_NS for a bare target)
#   MODIFIERS_FILE=./resource-modifiers.yaml \
#   bash restore.sh
# =============================================================================
set -euo pipefail

: "${DST_CONTEXT:?set DST_CONTEXT=<dst-context>}"
: "${BACKUP_NAME:?set BACKUP_NAME}"
RESTORE_NAME="${RESTORE_NAME:-${BACKUP_NAME}-restore}"
INCLUDE_NS="${INCLUDE_NS:-}"
EXCLUDE_NS="${EXCLUDE_NS:-}"
MODIFIERS_FILE="${MODIFIERS_FILE:-./resource-modifiers.yaml}"
MODIFIERS_CM="${MODIFIERS_CM:-velero-restore-modifiers}"

# ---- 1. wait for the target to sync the backup (BSL-sync lag ~20s) ----
echo "### waiting for backup '$BACKUP_NAME' to appear on the target BSL..."
for i in $(seq 1 30); do
  if velero --kubecontext "$DST_CONTEXT" backup get "$BACKUP_NAME" >/dev/null 2>&1; then
    echo "  found."; break
  fi
  echo "  not yet (try $i) — BSL sync lag; sleeping 10s"; sleep 10
done
velero --kubecontext "$DST_CONTEXT" backup get "$BACKUP_NAME" || {
  echo "!! backup not visible on target — check BSL bucket+prefix parity (same as source)"; exit 1; }

# ---- 2. apply the resource-modifiers ConfigMap (nulls PVC volumeName + suspends CronJobs) ----
# Write-to-file then apply (NOT a heredoc to apply -f -). Destructive on the velero ns -> owner-approved.
echo "### applying resource-modifiers ConfigMap from $MODIFIERS_FILE"
kubectl --context "$DST_CONTEXT" apply -f "$MODIFIERS_FILE"

# ---- 3. build namespace selector ----
NS_FLAGS=()
if [ -n "$INCLUDE_NS" ]; then
  NS_FLAGS=(--include-namespaces "$INCLUDE_NS")
elif [ -n "$EXCLUDE_NS" ]; then
  NS_FLAGS=(--exclude-namespaces "$EXCLUDE_NS")
else
  echo "!! set INCLUDE_NS (preferred) or EXCLUDE_NS"; exit 1
fi

# ---- 4. the restore (PROVEN flag set) ----
#   --include-cluster-resources=true : MANDATORY on the RESTORE too, or CRDs/ClusterRoles are
#                                      SKIPPED under namespace filtering -> every operator crashloops
#   --resource-modifier-configmap    : nulls spec.volumeName (PVCs re-provision EMPTY, one step)
#                                      + suspends all CronJobs (protect shared backup buckets)
#   --existing-resource-policy=none  : skip existing objects, never overwrite (safe on pre-seeded target)
#   --exclude-resources              : no PVs (empty volumes); no one-shot Jobs; no aggregation APIServices
#                                      (never touch the CNI/API-aggregation layer)
echo "### creating restore: $RESTORE_NAME"
velero --kubecontext "$DST_CONTEXT" restore create "$RESTORE_NAME" \
  --from-backup "$BACKUP_NAME" \
  "${NS_FLAGS[@]}" \
  --include-cluster-resources=true \
  --resource-modifier-configmap "$MODIFIERS_CM" \
  --existing-resource-policy=none \
  --exclude-resources persistentvolumes,jobs.batch,apiservices.apiregistration.k8s.io \
  --wait

# ---- 5. verify ----
echo "### restore result (PartiallyFailed is EXPECTED: PV 'no such file' + 'CRD already exists' warnings)"
velero --kubecontext "$DST_CONTEXT" restore describe "$RESTORE_NAME" | sed -n '1,30p'

echo "### PVCs that are NOT Bound (should be empty):"
kubectl --context "$DST_CONTEXT" get pvc -A 2>/dev/null | grep -v Bound || echo "  all Bound"

echo "### CronJobs — all should read SUSPEND=True:"
kubectl --context "$DST_CONTEXT" get cronjobs -A 2>/dev/null | head -20

echo "### done. Next: scale the app tier to 0, then run post-restore-fixes.sh for each present tier."
