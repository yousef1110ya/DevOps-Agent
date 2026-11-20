# Playbook — migrate a platform cluster to a new cluster (config-first, NO data)

> **This is a MUTATING operations playbook, not a read-only diagnostic.** Every mutating step runs under
> an approval token; `velero` commands are owner-run (not kubectl-guarded). The CNI/infra HARD guard
> always applies. Substitute your own device's context names for `<SRC>` (source) / `<DST>` (destination).
> **Application DATA is migrated in a SEPARATE later pass** — this playbook only stands up a like-for-like
> **empty-but-running** copy.

This is the reusable **order + decisions + gotchas** for standing up an empty-but-running copy of a
cluster on new infrastructure using Velero for config and app-native tooling for data. The references
R1–R12 below are your own project's numbered rules — keep them in the migration project's notes.

---

## Phase 0 — Pre-flight (READ-ONLY; do all of this before touching anything)

1. **Resolve identity, confirm they're distinct clusters** (by API server URL, not context name):
   ```bash
   bash tools/scans/cluster-identities.sh <SRC>
   bash tools/scans/cluster-identities.sh <DST>
   ```
   Register both in your knowledge library. Create the target knowledge entry.

2. **Namespace GAP = what to restore.** The target is usually **pre-seeded** (not bare) — restore ONLY
   the gap, never the infra/data tiers already there:
   ```bash
   comm -23 <(kubectl --context <SRC> get ns -o name | sed 's#namespace/##' | sort) \
            <(kubectl --context <DST> get ns -o name | sed 's#namespace/##' | sort)
   ```
   - **Always on target, NEVER include:** the pre-seeded DB namespaces, the target's own storage
     namespaces, `cert-manager`, `ingress-nginx`, all CNI (`calico-*`,`tigera-operator`), `kube-*`,
     `default`, `velero`.
   - **Manifests only, NO data:** logging (Loki), monitoring (Prometheus). Include for structure; never
     migrate their bucket/volume data.

3. **StorageClass parity:** target must expose the same storage classes as the source, exact name match
   (`openebs-hostpath` default + `openebs-device`, `openebs.io/local`). `kubectl --context <DST> get sc`.
   If missing → owner installs the storage layer first (Velero does NOT carry storage).

4. **Velero on BOTH?** Check `kubectl --context <ctx> -n velero get pods,backupstoragelocation`.
   - **Source without Velero (e.g. a prod cluster) → owner installs it first** (config-only backup needs
     it; `--snapshot-volumes=false` means it never reads volume data).
   - **A shared bucket BSL goes Unavailable** (`invalid top-level directories: [...]`) when other tooling
     leaves dirs at the bucket root. **Fix = a per-cluster PREFIX** (e.g. `cluster-a-velero`): install/point
     BOTH source & target Velero at the same bucket+prefix. Never point a fresh BSL at the bucket root.

5. **Inventory the stateful tiers + images** (drives the fixes below). For each, `get` the image:
   | Tier | What to record | Fix class |
   |------|----------------|-----------|
   | Object store (MinIO) | tenant name, pool image (`quay.io/minio/minio:*` is auth-gated) | → swap to a pullable image |
   | Redis / RabbitMQ / Kafka | STS name(s) + image; is it a purged `docker.io/<vendor>/*` or already a legacy mirror? | → repoint iff the pull fails |
   | Message broker (EMQX) | CR name, image version, core pod names | → data-plane export/import |
   | PostgreSQL | CNPG `Cluster` (bootstrap? plugins/barman?) + any standalone STS/Deploy | → CNPG recreate fresh |
   | Analytics (ClickHouse) | `chi`/`chk` names, images | → native BACKUP/RESTORE (data-plane) |
   | Other object stores | present? image? | → mirror per store (data-plane) |
   - **Images vary per cluster — never assume.** Only a real `ImagePullBackOff` on the target is a fix.

---

## Phase 1 — Config migration (the empty-but-running cluster)

> Order matters.

1. **BSL prefix** on both → both `Available`.
2. **Source backup**, config-only:
   `velero backup create … --include-namespaces <GAP> --exclude-resources persistentvolumes,jobs.batch
   --include-cluster-resources=true --snapshot-volumes=false --default-volumes-to-fs-backup=false --wait`
   → **Completed**. Carries all manifests/CRDs/RBAC/Secrets/PVC *definitions*, no volume data.
3. **Restore** onto the target: apply a restore-modifiers ConfigMap first (nulls `spec.volumeName` → PVCs
   re-provision empty in ONE step; suspends all CronJobs → protects shared backup buckets), then
   `velero restore create … --include-namespaces <GAP>
   --resource-modifier-configmap velero-restore-modifiers --include-cluster-resources=true
   --existing-resource-policy=none --exclude-resources persistentvolumes,jobs.batch,apiservices.… --wait`.
   - **`PartiallyFailed` is EXPECTED** (PV "no such file" + "CRD already exists" for pre-installed infra).
   - **BSL-sync lag ~20s:** the target may say `backup not found` on the first try — poll
     `velero backup get` on the target until it appears, then restore.
   - Verify: `get pvc -A | grep -v Bound` empty; `get cronjobs -A` all `SUSPEND=True`.
4. **Scale the app tier to 0 IMMEDIATELY** —
   `kubectl -n <platform-ns> scale deployment --all --replicas=0`.
   Why: (a) stops the crashloop cascade while the data tier is empty; (b) keeps target apps from mutating
   their own empty DBs before the data migration (a live target app corrupts parity). Record the SOURCE
   replica counts for scale-back at cutover.

---

## Phase 2 — Stateful-tier fixes (make the empty engines Run)

Run each only for the tiers present; verify over **minutes**, not a 20s window.

- **Object-store image** (MinIO): `patch tenant <name> --image <pullable-image>`. If the operator won't
  roll online (tenant unhealthy — a common deadlock): patch the **pool STS** container image directly +
  `delete pod minio-pool-0-{0,1,2}`. On Git-Bash set `MSYS_NO_PATHCONV=1` to stop path mangling.
- **Redis / RabbitMQ / Kafka:** only if `ImagePullBackOff` → `set image statefulset/<name>
  <container>=<legacy-mirror>/<repo>:<same-tag>`. RollingUpdate STS auto-roll; `OnDelete` STS need a
  `delete pod`. Patch **every** replica set (redis has master AND replicas).
  - ⚠️ **Repoint initContainers too, not just the main container.** RabbitMQ and Kafka carry their OWN
    init images → `Init:ImagePullBackOff` if you only patch the main one. `set image` names every container
    AND init. Sweep to confirm none left: `get sts -o jsonpath` over both `.initContainers[*].image` and
    `.containers[*].image`.
  - ⚠️ A stuck `ImagePullBackOff` pod BLOCKS the RollingUpdate (it never goes Ready) → delete the stuck
    pod(s) after the template is updated so they recreate on the new image.
  - If a tier is `spec.replicas=0` on the SOURCE, the target matches at 0 — that's parity, not a failure;
    the leftover Pending WaitForFirstConsumer PVCs are expected. Still repoint its images so it's
    ready-to-run.
- **PostgreSQL CNPG** (data-plane recreate): a config-only restore leaves CNPG CrashLooping
  `pg_controldata: exit status 1` on empty Bound PVCs (it resumes instead of `initdb`). **Recreate fresh:**
  save clean spec (strip status), **remove `spec.plugins`/barman if it points at the source's shared backup
  bucket**, `delete cluster` (PVCs GC'd), re-apply → `initdb` → healthy. Standalone postgres (STS/Deploy)
  self-init fine; only the OPERATOR-managed CNPG needs this.
- **Message broker (EMQX) config** (data-plane): `emqx ctl data export` (source core-0) → `kubectl cp` via
  a local RELATIVE path → `emqx ctl data import` (target core-0). **EMQX 5.7: put the archive in
  `data/backup/` and import by BASENAME** (abs-path fails "backup file not found"); keep the ORIGINAL
  basename. If the target operator crashloops (empty-status nil-panic): **recreate the CR fresh** (delete
  CR + ownerRef-orphaned `sts,rs,pvc`, re-apply, re-import).
- **Loki bucket parity:** create the empty `loki` bucket on the object store, delete the crashlooping loki
  pod. Bucket parity only — **never migrate loki data**.
- **Final sweep:** `kubectl --context <DST> get pods -A --field-selector status.phase!=Running,status.phase!=Succeeded`
  → expect **No resources found** (app tier intentionally at 0).

---

## Phase 3 — Data plane (LATER; scripts prepared now, NOT run)

Config-only restore gives empty engines. Real data lives in volumes and migrates separately, per cluster,
at/near cutover. Prepare the scripts now; **keep the target app tier at 0 through the whole sync** (a live
target app drifts its own DB and breaks parity). Components:
MongoDB (per-DB dump/restore w/ users), PostgreSQL (`pg_dumpall` per instance), object store (`mc mirror`,
EXCEPT loki + backup buckets), ClickHouse (native BACKUP/RESTORE to S3), Kafka (topics/offsets — often
acceptable empty), RabbitMQ (definitions), Redis (usually empty). **Loki + backup buckets: NEVER migrate.**
