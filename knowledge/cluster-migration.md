# Cluster migration patterns

Generalized, reusable lessons for moving Kubernetes clusters between providers with minimal downtime.

### The 3-plane rule — don't move everything with one tool
**Symptom:** Planning a cluster move to a new provider; tempting to back up and restore the whole thing with one tool.
**Cause:** A filesystem/volume backup of a **live** database captures torn, inconsistent files; and config-backup tools don't carry storage drivers or CNI.
**Fix:** Split the migration into three planes: **(1) Config/control plane → Velero** (one backup, `--include-cluster-resources=true` for RBAC/CRDs, `--exclude-resources persistentvolumes`, no volume data — PVCs re-provision empty; exclude the target's own infra namespaces: `kube-system`, `velero`, CNI (`calico-*`/`tigera-operator`), `default`). **(2) Database data plane → app-native replication** (Mongo = cross-site replication per replica-set; Postgres = streaming-replica/`pg_dumpall` then promote; ClickHouse = native BACKUP/RESTORE; MySQL/MariaDB = GTID; Redis = `replicaof` or empty-if-cache; RabbitMQ/EMQX = definitions/config only) — consistent **and** enables near-zero-downtime cutover. **(3) Object storage → `mc mirror --watch`** incremental, with a final delta at cutover.
**Note:** Stand the new cluster up **beside** the old, sync, and **flip DNS last**. App log stores (e.g. Loki, whose chunks live in object storage) migrate with the object store — just repoint. Give each cluster's Velero its **own bucket prefix** — a shared bucket at root goes Unavailable if a sibling process writes a top-level dir into it.

### Lift-and-shift VM-clone tools corrupt Kubernetes nodes — rebuild + data-migrate instead
**Symptom:** Considering a machine-level V2V/P2V (block/rsync VM clone) to lift Kubernetes nodes to a new provider.
**Cause:** Single-machine clone tools are not cluster-aware: node IPs change → etcd quorum/cert-SAN/kubelet/CNI breakage; members copied at different times = **etcd split-brain**; node-pinned local-path/hostpath PVs don't move; cross-hypervisor boot needs the right virtio drivers in initramfs; and cloud-specific CSI/LB/metadata dependencies die on the new provider.
**Fix:** Prefer **rebuild + data-migrate**: build fresh clusters on the target (same k8s + CNI versions), install the platform layer yourself (CNI, storage provisioner, operators, cert-manager, ingress, Velero+node-agent at matching versions — Velero carries none of these), reapply manifests/Helm, then migrate data via the 3-plane model. Gives clean IPs/certs/etcd and sidesteps node-pinning (data re-provisions fresh). If a cold lift-and-shift is truly required, it's only viable done **cold (full shutdown, etcd snapshot first)**, preserving node IPs+hostnames, dev-first.
**Note:** The destination StorageClass **name must match the source's** PVC `storageClassName` exactly or restored PVCs never bind (else use a change-storage-class mapping).

### Config-only Velero restore — empty-but-running traps
**Symptom:** After a config-only restore, operators crashloop, PVCs stick Pending, backup CronJobs point at shared buckets, and apps fail on DB **auth**.
**Cause / Fix (each a known trap):**
- **`volumeName` trap:** `--exclude-resources persistentvolumes` alone does NOT reset PVCs — Velero keeps the source `spec.volumeName`, statically binds to a nonexistent PV, all PVCs Pending. `volumeName` is immutable. **Fix:** a Velero Resource-Modifiers ConfigMap that `mergePatch`-nulls `spec.volumeName`+bind annotations on all PVCs (and sets `suspend: true` on all CronJobs) → PVCs re-provision empty in one step.
- **`--include-cluster-resources=true` is required on the RESTORE too, not just the backup** — otherwise with `--exclude-namespaces` Velero skips cluster-scoped objects → operator CRDs + ClusterRoles never land → every operator crashloops `forbidden`.
- **Restored CronJobs come back un-suspended** pointing at the *shared* backup buckets (would clobber the source's real backups) — suspend them all (the modifier does it) and exclude one-shot Jobs (`--exclude-resources …,jobs.batch`).
- **Empty DBs have no app users/schemas** — apps crashloop on DB auth (not connectivity); the engine is up but users/roles/databases live in the data. Don't debug as a DB outage — the data-plane pass carries users+schemas, or seed them manually.
- **Operator-managed DBs** may refuse to init onto empty restored PVCs (CNPG `pg_controldata: exit status 1`, resumes instead of `initdb`) → **recreate the Cluster fresh** (strip status from the spec, remove any barman/plugins pointing at the source's shared bucket, delete+re-apply). Standalone DBs self-init fine.
**Note:** A consumer-less restored PVC Pending forever on a `WaitForFirstConsumer` StorageClass (owner scaled to 0, workload not restored, or operator re-provisions its own ordinals) fires a false `PersistentVolumeClaimPending` alert — it's an orphan, not a storage fault; delete it (safe on an empty target).

### Purged upstream images and `externalTrafficPolicy: Local` bite at migration
**Symptom:** On the rebuilt cluster, Bitnami images `ImagePullBackOff`; MinIO pods `ImagePullBackOff`/license-fatal; and the public endpoint is dead right after DNS cutover.
**Cause / Fix:**
- **Bitnami Docker Hub tags were purged** → repoint `docker.io/bitnami/*` → `docker.io/bitnamilegacy/*` via `kubectl set image` (no reinstall). **Repoint initContainers too** (RabbitMQ `prepare-plugins-dir`, Kafka `kafka-init`/`auto-discovery`) — they carry their own `bitnami/*` images. A stuck `ImagePullBackOff` pod blocks the RollingUpdate; delete it after patching the template. `OnDelete`-strategy STS need the pods deleted manually.
- **MinIO:** the vendor-gated server images are auth-walled or commercial-license-fatal; a working anonymous AGPL image (e.g. the Chainguard `minio` image, pinned by digest on free tiers) is the drop-in. For operator-managed tenants, patch the **Tenant CR** `spec.image` (the operator reverts a direct STS image edit).
- **Endpoint dead at cutover:** an ingress-controller Service with `externalTrafficPolicy: Local` drops traffic when the public IP lands on a node that isn't running the controller → patch the Service to `externalTrafficPolicy: Cluster`.
**Note:** Migrate a data store **before** scaling its writer app up — a live writer blocks RESTORE ("table already contains data"); keep the target app tier at 0 through the whole data sync so target apps don't drift their own empty DBs and break parity.
