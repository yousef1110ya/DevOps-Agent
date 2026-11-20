# Storage & disk — triage, attribution, ENOSPC

Reusable DevSecOps lessons for diagnosing and fixing disk pressure on Kubernetes clusters, especially hostpath-provisioned storage where all PVCs share one node filesystem.

## Disk & filesystem triage (OpenEBS hostpath, /shared-fs)

### `kubelet top nodes` shows no disk — use node-exporter via Prometheus for real used %
**Symptom:** Need "how full is every node" but `kubectl top nodes` only reports CPU/memory, and Node objects show capacity, not usage.
**Cause:** Neither the metrics-server nor the Node API exposes live filesystem usage. The best source is node-exporter's `node_filesystem_*` series (if a monitoring stack is present).
**Fix:** Query Prometheus through the API proxy. `used% = (size − avail) / size`:
```bash
PROM="<namespace>/pods/<prometheus-pod>:9090"
Q='(1-node_filesystem_avail_bytes{fstype=~"ext4|xfs"}/node_filesystem_size_bytes{fstype=~"ext4|xfs"})*100'
ENC=$(printf '%s' "$Q" | jq -sRr @uri)
kubectl --context <context> get --raw "/api/v1/namespaces/$PROM/proxy/api/v1/query?query=$ENC" \
  | jq -r '.data.result[]|[.metric.instance,.metric.mountpoint,((.value[1]|tonumber)*10|round/10)]|@tsv' | sort
```
**Note:** Some clusters disable the kubelet stats API — `kubectl get --raw /api/v1/nodes/<node>/proxy/stats/summary` returns `NotFound`; fall back to the Prometheus path. On single data-drive hostpath setups, the mount that matters is the dedicated data drive (often `/<shared-fs>`, e.g. `/media/data`), not root `/`.

### A high disk % is only alarming if it's *rising* — compute days-to-full from the trend
**Symptom:** A node reads 85% and you don't know whether to act.
**Cause:** A high-but-flat filesystem is fine; a steadily rising one is the real risk. A bare percentage can't tell them apart.
**Fix:** `days-to-full = avail / daily-fill-rate` over the last 7d. Negative = shrinking/flat (safe):
```bash
Q='node_filesystem_avail_bytes{mountpoint="/<shared-fs>",fstype=~"ext4|xfs"} / (-deriv(node_filesystem_avail_bytes{mountpoint="/<shared-fs>",fstype=~"ext4|xfs"}[7d])) / 86400'
```
**Note:** A raw `deriv()` is skewed by a single large backup step inside the window. If the number looks off, pull `query_range` of `node_filesystem_avail_bytes` and compute the rate either side of any step. When df "swings weirdly" (e.g. 87%↔99% within hours), it's usually a daily backup create/prune square wave — pull the hourly series to see *shape/period* before naming a cause; use `min/max_over_time` only to spot amplitude.

### hostpath has NO per-PVC quota — a PVC's declared size is cosmetic
**Symptom:** A "2Gi" PVC is holding 200+GB on disk; PVCs seem to "fill up" without regard to their requested size.
**Cause:** On hostpath provisioners (e.g. `openebs-hostpath`), every PVC is just a directory on the node's one shared filesystem with no quota enforcement. A volume grows until the *node's* shared drive fills.
**Fix:** Stop ranking by declared PVC size (meaningless). Bound growth at the app layer (DB retention/compaction, object-store lifecycle) or add disk. Verify real sizes with on-node `du` (next section).
**Note:** When df hits 100% (ENOSPC), every stateful pod with a PV on that node crash-loops with `No space left on device` simultaneously — this co-location is the tell that it's one shared drive, not N independent faults.

### `KubePersistentVolumeFillingUp` flooding across many PVCs at once = shared-disk noise, not N problems
**Symptom:** The `KubePersistentVolumeFillingUp` warning fires on many/all PVCs across unrelated namespaces at nearly the same % at once.
**Cause:** On a hostpath cluster every PVC shares the node's single filesystem, so `kubelet_volume_stats_available_bytes/…capacity_bytes` echoes the **node filesystem free %** for every PVC. They all fire together with near-identical values that **group by node, not by app**.
**Fix:** Confirm in one query — plot `available/capacity*100` per PVC; the values collapse into a handful of identical numbers grouped by node (a Postgres, an object-store drive, a Loki vol on the same node all report the SAME %). Treat only the **node-level High Disk usage** alert as real; silence/drop `KubePersistentVolumeFillingUp` on hostpath clusters — it can never be meaningful there.
**Note:** The underlying capacity lever is still the per-cluster disk fill (usually an object-store backup pile); fix that, not the alert.

## Per-PVC / per-consumer attribution (how to answer "what's using the disk")

### Disk answers MUST name the top consumers — never just "X% full"
**Symptom:** Owner asks about disk usage; a bare "85% full" is not an acceptable answer.
**Cause:** The actionable information is *which* pods/apps (and their PVCs) are eating the space.
**Fix:** Always return a **ranked list of the biggest consumers with their actual on-disk sizes**, backed by proof. Map big PV UIDs back to `<namespace>/<pvc>` and the owning app with `kubectl get pv`. If an object store (MinIO/RustFS) is a top consumer, **break it down per bucket** (see object-store notes).
**Note:** Record the ranked consumers in the cluster KB, dated and cited, so the next disk question is faster.

### kubelet volume metrics are USELESS for ranking PVCs on hostpath — use on-node `du`
**Symptom:** `kubelet_volume_stats_used_bytes` reports an identical usedGB/used% on *every* PVC on a node (e.g. 433GB / 80% across the board).
**Cause:** With one shared filesystem and no per-volume quota, kubelet reports the **whole filesystem total for every PVC** — it's a filesystem reading, not a per-PVC reading.
**Fix:** Read the node directly with `du` (read-only; needs node/node-shell access):
```bash
# biggest PVC dirs on the node's data drive
kubectl-node_shell --context <context> <node> -- du -xh -d1 /<shared-fs>/openebs/openebs | sort -h | tail -30
# translate each pvc-<uuid> dir to its workload
kubectl --context <context> get pv -o custom-columns='PV:.metadata.name,PVC:.spec.claimRef.name,NS:.spec.claimRef.namespace,CAP:.spec.capacity.storage'
kubectl-node_shell --context <context> <node> -- df -h /<shared-fs> /
```
**Note:** Pass `--context` **after** `node-shell`/to the plugin (kubectl eats a global `--context` before the plugin name). On Windows, call `kubectl-node_shell` directly — kubectl.exe can't run the bash plugin as a subcommand. node-shell runs no shell, so `*` doesn't expand — use `du -d1 <dir>`.

### On a lossy link, node-shell silently drops `du` lines — verify the rows sum to the total
**Symptom:** A `du` sweep is missing a large PVC and some buckets, yet the reported grand total is right.
**Cause:** On a flaky connection node-shell can drop individual output lines mid-stream; the total comes from a separate read so it still looks correct.
**Fix:** Check that the itemized rows sum to the filesystem total. Re-read any missing path individually with `du -sh <path>`.
**Note:** Usual heavy hitters on these clusters: database replica-set members (one full copy per node) and object-store `pool-*`/data volumes. A large *imbalance* between nodes (vs. the normal near-balance from evenly-spread replicas + erasure pairs) points at a lopsided PVC or a stuck/orphaned volume. Cheap reclaim to look for: orphaned/stale PVCs (e.g. leftover restore PVCs), over-long Prometheus/Loki retention, missing object-store lifecycle rules.

## ENOSPC aftermath (what self-heals, what doesn't)

### After a shared-drive ENOSPC, most DBs self-heal on freed space — but torn log/AOF/WAL files do NOT
**Symptom:** The data drive hit 100%; every stateful pod crash-looped (`WT_PANIC`, `{badmatch,{error,enospc}}`, exit 14). After freeing space, most recover but one stays broken.
**Cause:** Mongo, Postgres(CNPG), RabbitMQ, EMQX just need room and recover on their next backoff retry. But a log/AOF/WAL **torn mid-write** stays corrupt after space is free and will NOT self-heal.
**Fix:** Repair the torn file specifically. For Redis: `redis-check-aof --fix <appendonlydir>/appendonly.aof.manifest` (on bitnami the binary is at `/opt/bitnami/redis/bin/redis-check-aof` — **not on PATH**, so "command not found" is a red herring). It truncates only the torn tail; replicas usually re-sync once the master is up.
**Note:** Repair pattern on node-local RWO (hostpath): scale the owning StatefulSet to 0 to release the PV → launch a throwaway pod pinned to that node (`nodeSelector kubernetes.io/hostname: <node>`) mounting the PVC → back up the corrupt file → repair → delete pod → scale STS back up → poll `get` until Ready.

### A DB whose data dir lives on the same drive the nightly backup fills will ENOSPC itself every backup night
**Symptom:** Scheduled backups fail on backup nights (`exitCode 14`, `FileStreamFailed: Failed to write .../diagnostic.data/...`); the DB briefly goes `initializing` and the operator refuses tasks, then self-recovers by morning.
**Cause:** The DB's data dir is a hostpath PV on the **same** shared drive the dump writes to. The ~N-GB logical dump peaks the drive to ~100% → DB hits ENOSPC → crash → cluster `initializing` → operator refuses backup/restore. A self-inflicted loop that recurs every backup night.
**Fix:** The durable fix is to move the DB data dir OFF the shared backup drive (separate hostpath basePath/disk), and/or shrink the nightly footprint (lower `keep`, fewer replicated copies), and/or grow the drive. Restarts/heals only treat symptoms.
**Note:** A single worker that *also* hosts a large Prometheus TSDB will bottom out dangerously low on each daily backup trough while peers stay safe — raise that node's floor (move Prometheus off it / trim TSDB). Distinguish this disk-driven exit-14 from a *file-descriptor*-driven backup-night crash (WiredTiger panic from `nofile` exhaustion) — same exit code, different cause (disk vs FDs); fix the latter by raising mongod's `nofile` ulimit.

### Off-site backup Jobs: a hung dump runs to the blunt Job deadline unless you cap it
**Symptom:** A backup CronJob fails nightly with `DeadlineExceeded`, the Job staying *active* the full `activeDeadlineSeconds` while good runs finish in a fraction of that.
**Cause:** In a multi-container FIFO pipeline (`dump → pipe → upload`) with `restartPolicy: Never`, the pod is "Running" until all containers exit. If the dump blocks (DB memory-pressure-evicted mid-dump, or the upload container OOM-killed so the FIFO reader vanishes and the dumper blocks on write), nothing ends until the blunt deadline.
**Fix:** Wrap the dump in `timeout -s TERM -k 30 <sec>` (inner timeout < notify wait < `activeDeadlineSeconds`) so a hang kills the dump → closes the pipe → upload gets EOF → clean non-zero FAIL + alert. Raise the upload container's mem limit so an OOM-kill (SIGKILL, no EXIT trap) can't orphan the FIFO.
**Note:** On memory-tight single-node clusters, a high-parallelism dump (`--numParallelCollections=4`) tips the node into eviction that breaks the dump — but *over*-lowering parallelism can over-correct into `DeadlineExceeded` (the dump just runs too slow). Tell a slow-dump failure (DB had 0 restarts) from a crash failure before tuning: if it failed on *time*, the lever is **memory headroom (cap the DB cache)**, not dump-job parallelism.
