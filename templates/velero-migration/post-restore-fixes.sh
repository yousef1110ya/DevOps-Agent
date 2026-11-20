#!/usr/bin/env bash
# =============================================================================
# Post-restore fixes  —  vendor-neutral, parameterized, READ-ONLY BY DEFAULT
#
# After a config-only Velero restore, the empty-but-running cluster needs a handful of
# common repairs to get every tier Running. This script is a MENU: each step is a function
# you call explicitly. By default (no args) it runs only the READ-ONLY DETECTORS so you can
# see what needs fixing without changing anything. Mutating steps PRINT the exact command
# and only execute when you pass APPLY=1 — and every mutating command needs the cluster
# owner's explicit approval (and a single-use approval token if your guard requires one).
#
# Every kubectl call carries --context (never changes the active context).
# On Git-Bash/Windows, prefix patches with MSYS_NO_PATHCONV=1 (paths starting with / get
# mangled otherwise) and pipe any name-producing jq through `tr -d '\r'` (CRLF trap).
#
# USAGE:
#   DST_CONTEXT=<dst-context> bash post-restore-fixes.sh detect            # read-only scan (default)
#   DST_CONTEXT=<dst-context> APPLY=1 bash post-restore-fixes.sh orphan_pvcs
#   DST_CONTEXT=<dst-context> APPLY=1 bash post-restore-fixes.sh ext_traffic_policy
#   DST_CONTEXT=<dst-context> APPLY=1 BITNAMI_NS=<namespace> bash post-restore-fixes.sh bitnami_repoint
#   DST_CONTEXT=<dst-context> APPLY=1 bash post-restore-fixes.sh suspend_cronjobs
#   DST_CONTEXT=<dst-context> APPLY=1 CNPG_NS=<ns> CNPG_CLUSTER=<name> bash post-restore-fixes.sh recreate_cnpg
#   DST_CONTEXT=<dst-context> APPLY=1 ACME_NS=<ns> bash post-restore-fixes.sh clean_acme
# =============================================================================
set -uo pipefail

: "${DST_CONTEXT:?set DST_CONTEXT=<dst-context>}"
APPLY="${APPLY:-0}"
K() { kubectl --context "$DST_CONTEXT" "$@"; }

run() { # print the command; execute only if APPLY=1
  echo "    + $*"
  if [ "$APPLY" = "1" ]; then MSYS_NO_PATHCONV=1 "$@"; else echo "      (dry-run — set APPLY=1 + get owner approval to execute)"; fi
}

# -----------------------------------------------------------------------------
# STEP A — orphan PVC cleanup (generic-ephemeral-volume PVCs restored without ownerRef)
#   Velero strips ownerReferences, so a pod's generic-ephemeral PVC (named <pod>-<vol>) comes
#   back un-owned -> kubelet rejects it ("PVC was not created for pod") -> pod Pending forever.
#   FIX: delete the orphaned Pending PVCs; the ephemeral-volume controller recreates them owned
#   by the current pod. Zero data risk (ephemeral = scratch).
# -----------------------------------------------------------------------------
orphan_pvcs() {
  echo "### STEP A — orphaned Pending PVCs (no ownerReference)"
  local list
  list=$(K get pvc -A -o json 2>/dev/null | jq -r '.items[]
    | select(.status.phase=="Pending" and ((.metadata.ownerReferences|length)==0))
    | "\(.metadata.namespace) \(.metadata.name)"' | tr -d '\r')
  if [ -z "$list" ]; then echo "  none found."; return 0; fi
  echo "$list" | while read -r ns name; do
    [ -z "$ns" ] && continue
    run kubectl --context "$DST_CONTEXT" -n "$ns" delete pvc "$name"
  done
}

# -----------------------------------------------------------------------------
# STEP B — externalTrafficPolicy: restored LoadBalancer Services come back as `Local`
#   (and often with stale type=LoadBalancer + externalIPs) -> traffic dropped at cutover.
#   FIX: patch externalTrafficPolicy=Cluster (unless you have PROXY-protocol end-to-end).
#   For OPERATOR-owned Services (object store etc.), prefer deleting the restored svc so the
#   operator remakes it (ClusterIP) — see STEP F.
# -----------------------------------------------------------------------------
ext_traffic_policy() {
  echo "### STEP B — LoadBalancer Services with externalTrafficPolicy=Local"
  local list
  list=$(K get svc -A -o json 2>/dev/null | jq -r '.items[]
    | select(.spec.type=="LoadBalancer" and .spec.externalTrafficPolicy=="Local")
    | "\(.metadata.namespace) \(.metadata.name)"' | tr -d '\r')
  if [ -z "$list" ]; then echo "  none found (or all already Cluster)."; return 0; fi
  echo "$list" | while read -r ns name; do
    [ -z "$ns" ] && continue
    run kubectl --context "$DST_CONTEXT" -n "$ns" patch svc "$name" --type merge \
      -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'
  done
}

# -----------------------------------------------------------------------------
# STEP C — bitnami -> bitnamilegacy image repoint (Docker Hub purged bitnami/* pinned tags)
#   Repoints EVERY container AND initContainer on every workload in BITNAMI_NS that still
#   references docker.io/bitnami/<repo> (not already bitnamilegacy). `set image` names all
#   containers; then delete pods stuck ImagePullBackOff (and OnDelete-strategy STS pods).
#   WARNING: a `:latest` -> `bitnamilegacy:latest` repoint is NOT version-stable and can
#   crashloop on a data-format version it wrote itself — if the source `:latest` already
#   pulls on the target, DO NOT repoint it; prefer pinning an explicit legacy major tag.
# -----------------------------------------------------------------------------
bitnami_repoint() {
  : "${BITNAMI_NS:?set BITNAMI_NS=<namespace>}"
  echo "### STEP C — repoint bitnami/* -> bitnamilegacy/* in $BITNAMI_NS (containers + initContainers)"
  # Detect which workloads still carry a purged bitnami/* image:
  K -n "$BITNAMI_NS" get sts,deploy -o json 2>/dev/null | jq -r '
    .items[] as $w | ($w.spec.template.spec.containers // []) + ($w.spec.template.spec.initContainers // [])
    | .[]? | select(.image | test("docker.io/bitnami/") and (test("bitnamilegacy")|not))
    | "\($w.kind)/\($w.metadata.name)  container=\(.name)  image=\(.image)"' | tr -d '\r' | sort -u | sed 's/^/  found: /'
  # For each workload+container, compute the bitnamilegacy image and set it:
  K -n "$BITNAMI_NS" get sts,deploy -o json 2>/dev/null | jq -r '
    .items[] as $w | ($w.spec.template.spec.containers // []) + ($w.spec.template.spec.initContainers // [])
    | .[]? | select(.image | test("docker.io/bitnami/") and (test("bitnamilegacy")|not))
    | "\(($w.kind|ascii_downcase))/\($w.metadata.name)\t\(.name)\t\(.image | sub("docker.io/bitnami/";"docker.io/bitnamilegacy/"))"' \
    | tr -d '\r' | while IFS=$'\t' read -r workload cname newimg; do
      [ -z "$workload" ] && continue
      run kubectl --context "$DST_CONTEXT" -n "$BITNAMI_NS" set image "$workload" "$cname=$newimg"
    done
  echo "  then delete any pod still stuck ImagePullBackOff (OnDelete STS won't recreate on its own):"
  K -n "$BITNAMI_NS" get pods -o json 2>/dev/null | jq -r '.items[]
    | select([.status.containerStatuses[]?,.status.initContainerStatuses[]?]
             | any(.state.waiting.reason=="ImagePullBackOff" or .state.waiting.reason=="ErrImagePull"))
    | .metadata.name' | tr -d '\r' | while read -r pod; do
      [ -z "$pod" ] && continue
      run kubectl --context "$DST_CONTEXT" -n "$BITNAMI_NS" delete pod "$pod"
    done
}

# -----------------------------------------------------------------------------
# STEP D — suspend any CronJob the restore left un-suspended (belt & braces to the modifier)
#   The resource-modifier should have suspended them all; this catches any that slipped
#   (operator-recreated schedules, psmdb/CNPG backup schedules, etc.).
# -----------------------------------------------------------------------------
suspend_cronjobs() {
  echo "### STEP D — suspend un-suspended CronJobs (protect shared backup buckets)"
  local list
  list=$(K get cronjobs -A -o json 2>/dev/null | jq -r '.items[]
    | select(.spec.suspend != true) | "\(.metadata.namespace) \(.metadata.name)"' | tr -d '\r')
  if [ -z "$list" ]; then echo "  all CronJobs already suspended."; return 0; fi
  echo "$list" | while read -r ns name; do
    [ -z "$ns" ] && continue
    run kubectl --context "$DST_CONTEXT" -n "$ns" patch cronjob "$name" --type merge -p '{"spec":{"suspend":true}}'
  done
  echo "  Also disable operator-driven backup schedules you have, e.g.:"
  echo "    kubectl --context $DST_CONTEXT -n <db-ns> patch psmdb <name> --type merge -p '{\"spec\":{\"backup\":{\"enabled\":false}}}'"
}

# -----------------------------------------------------------------------------
# STEP E — recreate an operator-managed Postgres (CNPG) FRESH
#   A Velero-restored CNPG Cluster carries its .status, so the operator tries to RESUME on
#   empty PVCs instead of running initdb -> CrashLoop (`pg_controldata: exit status 1`).
#   FIX: save a clean spec (strip status), REMOVE any backup plugin pointing at a shared
#   bucket (R2), delete the Cluster + its PVCs, re-apply -> fresh initdb. ONLY for
#   bootstrap=initdb clusters — NEVER a recovery/pg_basebackup one. (The same pattern applies
#   to a sharded psmdb that deadlocks: recreate fresh + delete its retained data PVCs.)
#   This is clearly DESTRUCTIVE — dry-run prints the steps; APPLY=1 + owner approval to run.
# -----------------------------------------------------------------------------
recreate_cnpg() {
  : "${CNPG_NS:?set CNPG_NS=<ns>}"; : "${CNPG_CLUSTER:?set CNPG_CLUSTER=<name>}"
  echo "### STEP E — recreate CNPG Cluster $CNPG_NS/$CNPG_CLUSTER FRESH (initdb only!)"
  echo "  1) verify it is bootstrap=initdb (NOT recovery) before proceeding:"
  echo "       kubectl --context $DST_CONTEXT -n $CNPG_NS get cluster $CNPG_CLUSTER -o jsonpath='{.spec.bootstrap}'; echo"
  echo "  2) save a clean spec (strip status + plugins pointing at a shared backup bucket):"
  echo "       kubectl --context $DST_CONTEXT -n $CNPG_NS get cluster $CNPG_CLUSTER -o json \\"
  echo "         | jq 'del(.status,.metadata.creationTimestamp,.metadata.resourceVersion,.metadata.uid,.spec.plugins)' > cnpg-clean.json"
  echo "  3) delete the Cluster (PVCs GC with it) then re-apply:"
  run kubectl --context "$DST_CONTEXT" -n "$CNPG_NS" delete cluster "$CNPG_CLUSTER"
  run kubectl --context "$DST_CONTEXT" apply -f cnpg-clean.json
  echo "     -> fresh initdb -> 'Cluster in healthy state'. Real data migrates later via pg_dumpall."
}

# -----------------------------------------------------------------------------
# STEP F — object-store (operator-managed) image + adoption repair (generic)
#   A gated server image (e.g. a paid/auth-only object-store build) -> ImagePullBackOff.
#   Repoint to a community drop-in (pinned by DIGEST). The operator often won't roll the
#   image online while the tenant is unhealthy (deadlock) -> patch the CR *and* the pool STS
#   directly + delete the pods. Also re-adopt an orphaned (ownerRef-stripped) pool STS, reset
#   the Service to ClusterIP, and run the operator at a SINGLE replica (two un-gated replicas
#   write conflicting images and oscillate the STS forever).
# -----------------------------------------------------------------------------
objectstore_fix() {
  echo "### STEP F — object-store image + adoption repair (fill in your own values)"
  cat <<'NOTE'
  This tier varies by product; the generic recipe (adapt names):
    OBJ_NS=<namespace> ; CR=<tenant-cr-name> ; IMG='<community-registry>/<image>@sha256:<digest>'
    # 1) repoint the operator CR (durable) AND the pool STS directly (break the online-roll deadlock):
    MSYS_NO_PATHCONV=1 kubectl --context <dst-context> -n $OBJ_NS patch <tenant-kind> $CR --type merge -p "{\"spec\":{\"image\":\"$IMG\"}}"
    for sts in $(kubectl --context <dst-context> -n $OBJ_NS get sts -o name | tr -d '\r'); do
      kubectl --context <dst-context> -n $OBJ_NS set image "$sts" <server-container>="$IMG"; done
    kubectl --context <dst-context> -n $OBJ_NS delete pod -l <tenant-label>
    # 2) re-adopt an orphaned pool STS (keeps pods+PVCs; operator recreates it WITH the ownerRef):
    kubectl --context <dst-context> -n $OBJ_NS delete statefulset <pool-sts> --cascade=orphan
    # 3) reset a restored LoadBalancer Service back to ClusterIP (operator remakes it):
    kubectl --context <dst-context> -n $OBJ_NS delete svc <object-store-svc>
    # 4) run the operator at ONE replica to stop image-oscillation (or pin its image so both agree):
    kubectl --context <dst-context> -n <operator-ns> scale deploy <operator-deploy> --replicas=1
  Pin a community image by DIGEST (moving :latest tags drift). Verify over MINUTES, not 20s.
NOTE
}

# -----------------------------------------------------------------------------
# STEP G — loki / object-store bucket PARITY (create the empty bucket, migrate NO data)
#   A config-only restore gives loki its config (bucket name + endpoint) but the fresh object
#   store has no such bucket -> compactor CrashLoops `NoSuchBucket`. FIX = create the EMPTY
#   bucket (an `mc mb` Job using the object store's root creds), then delete the crashlooping
#   loki pod. Bucket parity only — NEVER migrate loki log data (it re-fills; it's disposable).
# -----------------------------------------------------------------------------
loki_bucket() {
  echo "### STEP G — loki bucket parity (create empty bucket, no data)"
  echo "  Run an mc Job against the object store with its ROOT creds: mc mb <alias>/loki ; then:"
  echo "    kubectl --context $DST_CONTEXT -n <loki-ns> delete pod -l app.kubernetes.io/name=loki"
  echo "  (Bucket must EXIST; its contents are NOT migrated — R12.)"
}

# -----------------------------------------------------------------------------
# STEP H — stale cert-manager ACME objects (orphaned by the ownerRef stripping)
#   Restored Order/Challenge/CertificateRequest lose ownerRefs -> never GC; solver pods
#   linger forever and Challenges point at dead upstream order URLs. The real Certificates are
#   usually already Ready (valid secret restored). FIX = delete those ACME objects; cert-manager
#   re-issues cleanly if needed (DNS must already point at the target). Does NOT touch Ready certs.
# -----------------------------------------------------------------------------
clean_acme() {
  : "${ACME_NS:?set ACME_NS=<ns>}"
  echo "### STEP H — delete stale ACME Challenge/Order/CertificateRequest in $ACME_NS"
  run kubectl --context "$DST_CONTEXT" -n "$ACME_NS" delete challenge --all
  run kubectl --context "$DST_CONTEXT" -n "$ACME_NS" delete order --all
  run kubectl --context "$DST_CONTEXT" -n "$ACME_NS" delete certificaterequest --all
  echo "  Check certs are Ready and not past renewalTime:"
  echo "    kubectl --context $DST_CONTEXT get certificate -A -o wide"
}

# -----------------------------------------------------------------------------
# detect — run ALL read-only detectors (safe default)
# -----------------------------------------------------------------------------
detect() {
  echo "========================= READ-ONLY POST-RESTORE SCAN ========================="
  echo "### not-Running/not-Succeeded pods (NOTE: this does NOT surface CrashLoopBackOff —"
  echo "    a crashlooping pod still reports phase=Running; also check READY columns + CR status):"
  K get pods -A --field-selector status.phase!=Running,status.phase!=Succeeded 2>/dev/null | head -30 || true
  echo; APPLY=0 orphan_pvcs
  echo; APPLY=0 ext_traffic_policy
  echo; APPLY=0 suspend_cronjobs
  echo
  echo "For tier-specific fixes run explicitly: bitnami_repoint | recreate_cnpg | objectstore_fix | loki_bucket | clean_acme"
  echo "==============================================================================="
}

CMD="${1:-detect}"
case "$CMD" in
  detect|orphan_pvcs|ext_traffic_policy|bitnami_repoint|suspend_cronjobs|recreate_cnpg|objectstore_fix|loki_bucket|clean_acme) "$CMD" ;;
  *) echo "unknown step: $CMD"; echo "steps: detect orphan_pvcs ext_traffic_policy bitnami_repoint suspend_cronjobs recreate_cnpg objectstore_fix loki_bucket clean_acme"; exit 1 ;;
esac
