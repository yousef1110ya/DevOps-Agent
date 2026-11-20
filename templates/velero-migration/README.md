# Velero Cluster-Migration Kit (vendor-neutral)

A reusable, from-scratch guide + scripts for migrating a Kubernetes cluster to a new
cluster using **Velero for the config plane only**. Distilled from a real fleet of
production migrations. Every flag, version-matching requirement, and gotcha here was paid
for in a live incident — they are not theoretical.

> **Placeholders used throughout** (replace with your own values):
> `<src-context>` source kubectl context · `<dst-context>` target kubectl context ·
> `<bucket>` object-storage bucket · `<prefix>` per-cluster BSL prefix · `<s3-endpoint>` /
> `<region>` S3 endpoint + region · `<namespace>` an app namespace · `<cni-ns>` your CNI's
> namespace(s) · `<storage-class>` the PVC storageClassName · `<gap-ns-list>` the
> comma-separated namespaces to restore.
>
> **Safety:** scripts carry `--context` on every `kubectl` call. `velero` is NOT a
> `kubectl` subcommand, so a kubectl guard will not catch `velero restore create` — treat
> every restore as **destructive and operator-run**. Any destructive step needs the cluster
> owner's explicit approval. Prefer writing manifests to a file and `kubectl apply -f <file>`
> over piping a heredoc to `apply -f -`.

---

## 1. What Velero does — and does NOT do — in a migration

Velero backs up and restores **Kubernetes API objects** (and, optionally, volume data via
file-system backup or snapshots). In this kit we deliberately use it for **config only**:

**Velero carries (config plane):**
- Namespaces, Deployments, StatefulSets, DaemonSets, Services, Ingresses
- ConfigMaps, Secrets, ServiceAccounts, RBAC (Roles/RoleBindings)
- CRDs + ClusterRoles/ClusterRoleBindings (cluster-scoped — **only if you ask**, see §5)
- Operators and their Custom Resources (the CR `.spec` **and `.status`** — the status is a trap, §7)
- PVC *definitions* (the claim objects) — **but re-provisioned EMPTY**

**Velero does NOT carry (you install/migrate these yourself):**
- The **CNI** (Calico/Cilium/Flannel/…) — install it on the target first
- The **storage provisioner** (OpenEBS/Longhorn/cloud CSI) and its `StorageClass`
- **cert-manager, ingress controller, metrics-server**, and other platform add-ons
- **Velero itself** and its node-agent
- **Volume DATA** — database contents, object-store buckets, queue messages. These live in
  volumes and migrate on the **data plane** (§2), separately, at/near cutover.
- Container **images** — a fresh cluster must *pull* every image; the source only had them
  cached. Purged upstream tags will fail (§8, "don't repeat").

The one-line mental model: **Velero gives you an empty-but-running copy of the cluster's
structure. Everything with data in it comes up empty and is filled on the data plane.**

---

## 2. The 3-plane migration model

Think of a migration as three independent planes, migrated in this order:

| Plane | What it carries | Tool | When |
|-------|-----------------|------|------|
| **1. Config** | all manifests/CRDs/RBAC/Secrets/PVC defs; empty engines | **Velero** (this kit) | first |
| **2. Data — databases** | DB rows, users, roles, schemas, queue defs | **app-native replication / logical dump-restore** (`pg_dumpall`, `mongodump --dumpDbUsersAndRoles`, ClickHouse `BACKUP/RESTORE TO S3`, cross-site replication) | after config, before cutover |
| **3. Data — blobs** | object-store buckets/objects | **object-store mirror** (`mc mirror` / S3 sync) | after config, before cutover |
| **(DNS)** | — | DNS flip to the new ingress IP | **last**, after all three verify |

Rules that fall out of the model:
- **Config-only DBs come up empty.** Apps will fail DB **auth** (not connectivity) until the
  data plane runs — this is normal, not a bug (§8).
- **Never migrate logs or backup buckets** on the blob plane. They are the bulk of storage,
  logs re-fill on the new cluster, and copying backups risks clobbering **shared** backup
  buckets. Identify exclusions **by purpose, per cluster** (bucket names differ everywhere).
- **DNS flips last.** Until it does, keep target app workloads scaled to 0 so they don't
  mutate their own empty DBs (a live target app corrupts data parity — proven repeatedly).

---

## 3. Prerequisites on the TARGET (install these FIRST — Velero carries none)

Do all of this **before** any restore. The restore will fail or half-work otherwise.

1. **CNI** installed and healthy (e.g. Calico). The restore must **exclude** the CNI
   namespaces so it never touches them (hard rule — see §5, §8). `get pods -n <cni-ns>` green.
2. **Storage provisioner + StorageClass** whose **name exactly matches** the source PVCs'
   `storageClassName` (e.g. `<storage-class>`), backed by a working provisioner. A missing or
   mis-named SC leaves every PVC `Pending` forever. `kubectl --context <dst-context> get sc`.
3. **cert-manager** (+ its CRDs) if the source uses it.
4. **Ingress controller** (e.g. ingress-nginx).
5. **Operators you want pre-seeded** — some targets are pre-seeded with MongoDB/Postgres
   operators etc. by hand; others are bare. **Inventory the target first** (§4) so you restore
   only the *gap*, never over a live tier.
6. **Velero + node-agent at MATCHING versions** on BOTH source and target, pointed at the
   SAME object-storage bucket + prefix.
   - **Version parity matters.** Restoring a backup taken by a much newer/older Velero is
     unsupported; keep source and target Velero on the same minor.
   - **node-agent is only needed for file-system/volume-data backup.** This kit uses
     `--snapshot-volumes=false` and does NOT back up volume data, so node-agent is optional —
     if it is broken on install (§8, Windows backslash hostPaths), you can simply delete the
     node-agent DaemonSet; the Velero server pod is what does config backup/restore.

---

## 4. Ordered steps

### Phase 0 — Pre-flight (READ-ONLY)

1. **Confirm source and target are distinct clusters** (different API server URLs).
2. **Compute the namespace GAP** = source namespaces the target does not already have:
   ```bash
   comm -23 <(kubectl --context <src-context> get ns -o name | sed 's#namespace/##' | sort) \
            <(kubectl --context <dst-context> get ns -o name | sed 's#namespace/##' | sort)
   ```
   - **Prefer `--include-namespaces <gap>` over `--exclude-namespaces` on a pre-seeded
     target** — include is surgical: it can only create namespaces you name, so it can NEVER
     touch a live infra/data tier. Watch for **namespace-name drift** between source and
     target (e.g. a storage namespace renamed) — another reason include-list is safer.
   - **Always exclude / never include:** CNI namespaces (`<cni-ns>`, e.g. `calico-system`,
     `calico-apiserver`, `tigera-operator`, `kube-flannel`), `kube-system`, `kube-public`,
     `kube-node-lease`, `default`, `velero`, the **target's own** storage-provisioner
     namespace, and anything already pre-seeded on the target.
   - **Manifests only, NO data:** logging (loki) and monitoring (prometheus) namespaces —
     include for structure, never migrate their bucket/volume data.
3. **StorageClass parity** check (§3.2).
4. **Velero present + BSL `Available` on both?** If a shared bucket's BSL is `Unavailable`
   with "invalid top-level directories", scope each cluster to its **own prefix** (§8).
5. **Inventory the stateful tiers + their images.** Record each DB engine, object store,
   message broker, and the exact image reference — this drives the post-restore fixes. Only a
   **real `ImagePullBackOff` on the target** is an image to fix; CrashLoop/PodInitializing
   pods are pulling fine.

### Phase 1 — Config migration

1. **Scope the BSL prefix** on both (if sharing a bucket) → both `Available`.
2. **Backup** on the source, config-only: `./backup.sh` (see flags in §6).
   → expect **Completed, 0 errors** (it reads no volume data).
3. **Apply the resource-modifiers ConfigMap** on the target (`resource-modifiers.yaml`), then
   **restore**: `./restore.sh`.
   - **`PartiallyFailed` is EXPECTED** — PV "no such file" warnings (we excluded PVs) and
     "CRD already exists" for pre-installed infra. Not a problem.
   - **BSL-sync lag (~20s):** the target may say `backup not found` on the first try. Poll
     `velero --kubecontext <dst-context> backup get` until it appears, then restore.
   - Verify: `get pvc -A | grep -v Bound` is empty; `get cronjobs -A` all `SUSPEND=True`.
4. **Scale the app tier to 0 immediately** — stops the crashloop cascade AND keeps target
   apps from mutating their own empty DBs before the data migration. Record the **source**
   replica counts (authoritative) for scale-back at cutover; scaling to 0 overwrites them.

### Phase 2 — Stateful-tier fixes (make the empty engines Run)

Run `post-restore-fixes.sh` steps for the tiers you actually have. Verify over **minutes**,
not a 20-second window (restore loops have quiet gaps that look "fixed"). Covers: orphan-PVC
cleanup, externalTrafficPolicy, bitnami→bitnamilegacy image repoint, suspend shared-bucket
CronJobs, recreate operator-managed DBs fresh, object-store image/operator fixes, loki bucket
parity, stale ACME object cleanup.

### Phase 3 — Data plane (separate pass, at/near cutover)

Migrate DB data + object-store blobs (§2). **Keep target app workloads at 0 for the whole
sync.** Verify by **exact row/doc count**, never by size (a fresh restore legitimately
compacts). Then scale apps back up to the recorded source counts and flip DNS.

---

## 5. Cutover checklist

- [ ] Target CNI, StorageClass, cert-manager, ingress, operators all healthy (§3)
- [ ] Velero version parity, BSL `Available` on both (own prefix if shared bucket)
- [ ] Config restore done; `PartiallyFailed` is OK; all PVCs `Bound` & empty
- [ ] All CronJobs `SUSPEND=True` (nothing fires at shared backup buckets)
- [ ] CRDs count matches source (`--include-cluster-resources=true` was on the **restore**)
- [ ] Images: every `bitnami/*` → `bitnamilegacy/*` (incl. **initContainers**); object-store
      image repointed; no `ImagePullBackOff` left
- [ ] Operator-managed DBs recreated fresh (CNPG/psmdb) and healthy
- [ ] externalTrafficPolicy on restored LoadBalancer Services = `Cluster` (not `Local`)
- [ ] Loki/object-store buckets exist (parity); no backup/log **data** copied
- [ ] Stale restored ACME `Order`/`Challenge`/solver pods cleaned up; certs `Ready`
- [ ] **Data plane:** DB data + buckets migrated; verified by exact row/doc counts
- [ ] Target app tier scaled back to **source** replica counts
- [ ] Ingress TLS cert valid (restored certs can be past renewal — see TLS gotcha below)
- [ ] **DNS flipped last**, after everything above verifies
- [ ] Decommission the source only after a stable soak

---

## 6. Backup & restore flags (the proven set)

**Backup (config-only, read-only on source):**
```
velero backup create <name> \
  --include-cluster-resources=true \
  --snapshot-volumes=false \
  --default-volumes-to-fs-backup=false \
  --exclude-resources persistentvolumes \
  --include-namespaces <gap-ns-list> \      # OR --exclude-namespaces for a bare target
  --ttl 720h0m0s --wait
```
**Restore (destructive — operator-run):**
```
velero restore create <name> --from-backup <backup> \
  --include-cluster-resources=true \        # MANDATORY on the RESTORE too — not just backup
  --resource-modifier-configmap velero-restore-modifiers \
  --existing-resource-policy=none \         # skip existing objects, never overwrite
  --exclude-resources persistentvolumes,jobs.batch,apiservices.apiregistration.k8s.io \
  --include-namespaces <gap-ns-list> \
  --wait
```

---

## 7. What we did wrong / don't repeat (the ⛔ lessons)

Every item below is a real failure that cost time. Read them before your first run.

1. **⛔ `--exclude-resources persistentvolumes` at backup does NOT give empty re-provisioned
   PVCs — it creates ghost PVCs stuck Pending.** Excluding PVs keeps each PVC's source
   `spec.volumeName`, so on restore Velero statically binds the PVC to a PV that doesn't
   exist; the dynamic provisioner ignores any PVC that has a `volumeName`, so **all PVCs sit
   Pending** ("unbound immediate PersistentVolumeClaims"). `spec.volumeName` is **immutable**
   → you cannot patch it empty; you must delete+recreate. **Fix:** null `spec.volumeName` +
   bind annotations at restore with the **resource-modifiers ConfigMap** (`resource-modifiers.yaml`)
   so PVCs re-provision empty in ONE step. This is inherent Velero behaviour, not a version bug.

2. **⛔ Forgetting `--include-cluster-resources=true` on the RESTORE breaks every operator.**
   When the restore filters namespaces (`--include/--exclude-namespaces`), Velero **skips
   cluster-scoped objects** unless you set this flag — so operator **CRDs + ClusterRoles/
   ClusterRoleBindings never land** and every operator crashloops `forbidden` / "cache sync"
   / "no tenants.*". The backup having the flag is **not** enough. Safe to re-run the restore
   with it (`existing-resource-policy=none` skips what exists).

3. **⛔ Restored CronJobs come back un-suspended, pointing at the SHARED backup buckets.** The
   empty target will fire backup CronJobs into the same buckets the source backs up to and
   **overwrite the source's real backups**. **Fix:** the resource-modifiers ConfigMap sets
   `suspend: true` on all CronJobs; also disable operator-driven backup schedules (e.g.
   `psmdb spec.backup.enabled`, CNPG barman). Re-enable only after the target has its **own**
   backup destination.

4. **⛔ Empty DBs fail app auth.** Config-only restore gives the DB **engine** + the app's
   connection **Secret**, but users/roles/databases/schemas live **inside the DB data** (not
   copied). Apps crashloop on `AuthenticationFailed` / `password authentication failed` — this
   is **expected**, not a DB outage. The engine is up; resolve on the data plane.

5. **⛔ Operator-managed DBs refuse to init on empty restored PVCs → recreate fresh.** A
   Velero-restored CNPG `Cluster` (or sharded psmdb) carries its **`.status`**, so the operator
   treats the empty cluster as EXISTING and tries to *resume* on empty PVCs instead of running
   `initdb`/bootstrap → CrashLoop (`pg_controldata: exit status 1`; sharded mongo `cfg`/`mongos`
   deadlock on `smartUpdate`). **Fix:** save a clean spec (strip `.status`), remove any backup
   plugin that points at a shared bucket, `delete` the CR + its instance PVCs, re-apply → fresh
   bootstrap. **Only for bootstrap=initdb clusters**, never a recovery/pg_basebackup one.
   Standalone (non-operator) Postgres self-inits fine — only the operator-managed one needs this.

6. **⛔ The storageClass name must match.** A target with no SC, or one whose name ≠ the
   source PVC's `storageClassName`, leaves PVCs Pending. Install the matching SC **before**
   the restore.

7. **⛔ Restored LoadBalancer Services come back with `externalTrafficPolicy: Local` (and
   stale `externalIPs`/`type: LoadBalancer`) → traffic dropped at cutover.** `Local` only
   serves nodes that happen to run a backend pod; on a freshly-restored cluster that drops
   traffic. Operator-managed Services (e.g. an object-store `minio` svc) also get fought by
   their operator forever ("Service type doesn't match"). **Fix:** patch
   `externalTrafficPolicy: Cluster` (unless you have PROXY-protocol end-to-end carrying the
   real client IP), and for operator-owned Services delete the restored one so the operator
   remakes it correctly (ClusterIP).

8. **⛔ Bitnami images are purged from Docker Hub.** A fresh cluster can't pull `docker.io/
   bitnami/<repo>:<pinned-tag>` (Redis/RabbitMQ/Kafka/etc.) → `ImagePullBackOff`. **Fix:**
   repoint `bitnami/` → `bitnamilegacy/` (same tag) via `kubectl set image`; no reinstall.
   Three traps: **(a)** repoint **every** workload (Bitnami redis has separate master *and*
   replicas STSs); **(b)** repoint **initContainers too** (RabbitMQ `prepare-plugins-dir`,
   Kafka `kafka-init`/`auto-discovery`) or you get `Init:ImagePullBackOff`; **(c)** an
   `OnDelete` update strategy means `set image` won't recreate the pod — delete it. **And** a
   `:latest`→`bitnamilegacy:latest` repoint is **not version-stable** — the legacy snapshot
   can be OLDER than what `:latest` resolved to and crashloop on a data-format version it
   wrote itself; if the source `:latest` already pulls, leave it alone. Prefer pinning an
   explicit `bitnamilegacy/<repo>:<major>-…` matching the source major.

9. **⛔ A shared-bucket BSL goes `Unavailable`.** If source and target share one bucket and
   DB-migration relays leave foreign top-level dirs there, Velero marks the whole BSL
   Unavailable ("invalid top-level directories"). **Fix:** give each cluster its **own
   prefix** (`velero backup-location create <name> --bucket <bucket> --prefix <prefix>`);
   install/point BOTH sides at the same bucket+prefix. Never point a fresh BSL at the root.

10. **⛔ Object-store server images can be auth-gated** (no free public pull, unlike bitnami's
    legacy repo). Bumping the tag doesn't help. **Fix:** repoint to a community drop-in image
    (pinned by digest), patching the **operator CR** *and*, if the operator won't roll online
    while the tenant is unhealthy, the pool StatefulSet directly + delete the pods. Also do
    the full post-restore object-store cleanup: re-adopt orphaned pool STS, reset the Service
    to ClusterIP, run the operator at a single replica (dual replicas without leader-election
    gating write conflicting images and oscillate the STS forever).

11. **⛔ Velero restores generic-ephemeral-volume PVCs as orphans** (ownerReference stripped)
    → pods stuck Pending ("PVC was not created for pod"). **Fix:** delete those orphaned
    pod-named PVCs; the ephemeral-volume controller recreates them owned by the current pod.
    Same ownerRef-stripping family hits object-store/broker STS adoption and leaves **stale
    cert-manager ACME `Order`/`Challenge`/solver pods** that never GC — delete `challenge`,
    `order`, `certificaterequest` (the real certs stay `Ready`).

12. **⛔ Restored ingress TLS certs can be past renewal even though `Ready=True`** → browser
    `ERR_CERT_DATE_INVALID` at cutover. Restored ACME Orders point at dead upstream order
    URLs and don't cascade-delete. Check `renewalTime` in the past; delete the stale ACME
    objects so cert-manager re-issues cleanly (DNS must already point at the target).

13. **⛔ Don't run target apps during a data re-sync.** A live target app mutates its own DB
    after the restore → row/doc counts drift and never match. Keep app workloads at 0 for the
    whole data sync; verify by **exact count**, not size.

14. **⛔ Windows/Git-Bash hazards.** (a) `velero install` from Windows writes node-agent
    hostPaths with **backslashes** (`\var\lib\kubelet\...`) → `RunContainerError`; use
    `MSYS_NO_PATHCONV=1`, or just delete node-agent (unused for config-only). (b) `jq`/
    `kubectl -o json` emit **CRLF** — any name piped back into `kubectl` needs `| tr -d '\r'`
    or you get `"name\r" not found` no-ops. (c) Velero-on-Windows writes `cloud-credentials`
    with CRLF → breaks in-cluster S3 auth; strip CR when parsing.

---

## 8. Files in this kit

- `README.md` — this guide
- `backup.sh` — parameterized config-only Velero backup
- `restore.sh` — parameterized Velero restore with the proven flags + modifiers
- `resource-modifiers.yaml` — Velero Resource-Modifiers ConfigMap (null volumeName + suspend CronJobs)
- `post-restore-fixes.sh` — common post-restore repairs, read-only-by-default / approval-gated
