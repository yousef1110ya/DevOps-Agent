#!/usr/bin/env bash
# =============================================================================
# Velero config-only backup  —  vendor-neutral, parameterized
#
# Captures every namespace + all manifests/CRDs/RBAC/Secrets/PVC *definitions* but
# NO volume data (--snapshot-volumes=false, PVs excluded). This is READ-ONLY on the
# source: it never reads or mutates volume contents. Produces an "empty-but-running"
# copy of the cluster's structure when restored (see restore.sh).
#
# USAGE:
#   SRC_CONTEXT=<src-context> \
#   BACKUP_NAME=migrate-$(date +%Y%m%d) \
#   STORAGE_LOCATION=<bsl-name> \
#   INCLUDE_NS="<ns1>,<ns2>,..." \        # the namespace GAP (preferred on a pre-seeded target)
#   bash backup.sh
#
#   # OR, for a BARE target, exclude infra instead of include:
#   SRC_CONTEXT=<src-context> BACKUP_NAME=... STORAGE_LOCATION=<bsl-name> \
#   EXCLUDE_NS="kube-system,kube-public,kube-node-lease,<cni-ns>,velero,default,<src-storage-ns>" \
#   bash backup.sh
#
# NOTE: `velero` is NOT a kubectl subcommand, so a kubectl guard will not catch it.
#       On a PRODUCTION source, treat this install/backup as an owner-run step even though
#       it is read-only. Pass --kubecontext so velero targets the SOURCE explicitly.
# =============================================================================
set -euo pipefail

: "${SRC_CONTEXT:?set SRC_CONTEXT=<src-context>}"
: "${BACKUP_NAME:?set BACKUP_NAME}"
STORAGE_LOCATION="${STORAGE_LOCATION:-default}"   # a BSL scoped to this cluster's own prefix if sharing a bucket
INCLUDE_NS="${INCLUDE_NS:-}"
EXCLUDE_NS="${EXCLUDE_NS:-}"
TTL="${TTL:-720h0m0s}"

# ---- pre-flight (read-only): confirm Velero + BSL are healthy on the source ----
echo "### pre-flight: velero + BSL on ${SRC_CONTEXT}"
kubectl --context "$SRC_CONTEXT" -n velero get pods,backupstoragelocation -o wide || {
  echo "!! Velero not reachable on the source — install it first (same version as the target, BSL -> <bucket>/<prefix>)"; exit 1; }

# A shared bucket's root may be polluted -> BSL Unavailable. Scope each cluster to its own prefix:
#   velero --kubecontext <src-context> backup-location create <prefix-bsl> \
#     --provider aws --bucket <bucket> --prefix <prefix> --config region=<region>
# then pass STORAGE_LOCATION=<prefix-bsl>.

# ---- build namespace selector ----
NS_FLAGS=()
if [ -n "$INCLUDE_NS" ]; then
  NS_FLAGS=(--include-namespaces "$INCLUDE_NS")
  echo "### scope: INCLUDE namespaces = $INCLUDE_NS"
elif [ -n "$EXCLUDE_NS" ]; then
  NS_FLAGS=(--exclude-namespaces "$EXCLUDE_NS")
  echo "### scope: EXCLUDE namespaces = $EXCLUDE_NS"
else
  echo "!! set INCLUDE_NS (preferred) or EXCLUDE_NS"; exit 1
fi

# ---- the backup (PROVEN config-only flag set) ----
#   --include-cluster-resources=true : carry CRDs + ClusterRoles/Bindings (operators need them)
#   --snapshot-volumes=false         : never read volume data (prod-safe, read-only)
#   --default-volumes-to-fs-backup=false : do not file-system-back-up volumes either
#   --exclude-resources persistentvolumes : no PVs (PVCs re-provision empty on restore via modifiers)
echo "### creating config-only backup: $BACKUP_NAME"
velero --kubecontext "$SRC_CONTEXT" backup create "$BACKUP_NAME" \
  "${NS_FLAGS[@]}" \
  --storage-location "$STORAGE_LOCATION" \
  --include-cluster-resources=true \
  --snapshot-volumes=false \
  --default-volumes-to-fs-backup=false \
  --exclude-resources persistentvolumes \
  --ttl "$TTL" \
  --wait

echo "### result"
velero --kubecontext "$SRC_CONTEXT" backup describe "$BACKUP_NAME" --details | sed -n '1,40p'
# Expect: Phase=Completed, 0 errors/warnings. (It reads no volume data, so a clean run is normal.)
echo "### done — the target will see this backup after ~1 BSL sync (~1 min) if it shares the bucket+prefix."
