# Playbook: disk usage across ALL nodes of a cluster

**Goal:** one-shot "how full is every node, and what's filling it" — fast. Replace `<CTX>` with your
context. All steps are **read-only**. On OpenEBS-hostpath clusters the mount that matters is the
shared data filesystem — `/media/data` is used here as the example mount (hostpath data drive where
every pod PVC lives; **adjust to your own mount**); root `/` is usually fine.

> See also the generic single-node runbook [`disk-usage-high.md`](disk-usage-high.md).

## 1. Fast sweep — usage % + days-to-full for every node (Prometheus, seconds)
If the monitoring stack is present this is the quickest and also gives the *trend*:
```bash
# find the Prometheus pod
kubectl --context <CTX> get pods -A | grep -iE 'prometheus.*prometheus-0'
PROM="<ns>/pods/<prometheus-pod>:9090"
# used% for all real filesystems on all nodes
Q='(1-node_filesystem_avail_bytes{fstype=~"ext4|xfs"}/node_filesystem_size_bytes{fstype=~"ext4|xfs"})*100'
ENC=$(printf '%s' "$Q" | jq -sRr @uri)
kubectl --context <CTX> get --raw "/api/v1/namespaces/$PROM/proxy/api/v1/query?query=$ENC" \
  | jq -r '.data.result[]|[.metric.instance,.metric.mountpoint,((.value[1]|tonumber)*10|round/10|tostring+"%")]|@tsv' | sort
# days-to-full per node for the data mount (see disk-usage-high.md for the deriv() query)
```

## 2. Full picture — usage + per-PVC breakdown on every node (scan script)
Uses node-shell (read-only) under the hood. `df` sweep is fast; `--du` walks the whole data drive
on each node (minutes/node) and resolves every `pvc-<uuid>` to its `namespace/pvc`:
```bash
bash tools/scans/disk-usage-all-nodes.sh <CTX>          # fast: df of the data mount & / per node
bash tools/scans/disk-usage-all-nodes.sh <CTX> --du     # + per-node du, pvc dirs named (SLOW)
```
Prereq: `kubectl-node_shell` on PATH.

## 3. Drill one node by hand (if the script isn't enough)
```bash
kubectl-node_shell --context <CTX> <node> -- df -h /media/data /
kubectl-node_shell --context <CTX> <node> -- du -xh -d1 /media/data/openebs/openebs | sort -h | tail
kubectl --context <CTX> get pv -o custom-columns='PV:.metadata.name,PVC:.spec.claimRef.name,NS:.spec.claimRef.namespace,CAP:.spec.capacity.storage'
```
Placement gotcha: pass `--context` **after** `node-shell` (kubectl eats a global `--context` before
the plugin name). On Windows call `kubectl-node_shell` directly (kubectl.exe can't run the bash plugin).

## 3b. If an object store (e.g. MinIO) is a top consumer → break it down per bucket
A bare "X% full" is not a useful answer — always attribute to the top consumers, and if an object
store is one, report its **per-bucket** sizes, not just its total. Two read-only ways:
```bash
# A. From inside the MinIO pod via mc (no creds echoed to chat; it uses the pod's local alias/env).
#    Find the pod + the local alias first:
kubectl --context <CTX> -n <minio-ns> get pods | grep -i minio
#    Per-bucket usage (mc du reports size per bucket):
kubectl --context <CTX> -n <minio-ns> exec <minio-pod> -c minio -- mc du local/     # 'local' = in-pod alias
#    (if no alias is configured: `mc alias set local http://localhost:9000 $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD`
#     — do NOT print the creds; they live in the pod env / a secret.)
#
# B. On-node du of the bucket dirs under the MinIO PVC (works even if mc/exec is unavailable).
#    Resolve the MinIO data PVC path from step 3, then du one level into it:
kubectl-node_shell --context <CTX> <node> -- du -xh -d1 /media/data/openebs/openebs/<minio-pvc-uuid> | sort -h | tail
```
`kubectl exec` is **not** a read-only verb → it should be blocked without explicit owner approval.
Method **B (on-node du)** is read-only and needs no approval — prefer it.
Note on erasure coding: MinIO stores each bucket sharded across all `data*` PVCs, so a bucket's
*cluster* footprint ≈ per-node bucket du × number of data drives; `mc du` already reports the logical
cluster total. Record the ranked buckets in your knowledge library.

## 4. How to read it
- **Check the rows sum to the total.** On a lossy link, node-shell can silently drop `du` lines
  (e.g. a large PVC and some buckets missing while the total is still right). Re-read missing PVCs
  with `du -sh <path>`. Node-shell runs no shell, so `*` doesn't expand; use `du -d1 <dir>`.
- **Sanity-check days-to-full.** A raw `deriv()` is skewed by one big backup step in the window. Look
  at `query_range` of `node_filesystem_avail_bytes` and compute the rate either side of any step.
- **`openebs-hostpath` has NO quota** — a PVC's declared size (e.g. "2Gi") is cosmetic. A volume
  grows until the *node's* data filesystem fills. So ranking by declared PVC size is meaningless; only
  on-node `du` tells the truth, and `kubelet_volume_stats_*` is useless (it echoes the shared
  filesystem total for every PVC on the node).
- **Usual heavy hitters:** replicated databases (one full copy per node) and object-store pool
  volumes. Both spread evenly across nodes.
- **Why one node reads a bit higher:** replica sets + erasure pairs spread evenly, so nodes are
  near-balanced; the tightest node is typically just the one that *also* hosts the Prometheus TSDB.
  A large *imbalance* between nodes would instead point at a lopsided PVC or a stuck/orphaned volume.
- **Cheap reclaim to look for:** orphaned/stale PVCs (e.g. leftover restore PVCs in `default`), old
  Prometheus/Loki retention, object-store lifecycle. Deletion is destructive → owner approval + a
  staged command file.
