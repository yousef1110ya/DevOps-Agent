# Playbook: disk usage high (node / cluster)

**Symptom:** a node is low on disk, `DiskPressure`, image GC churn, pods evicted, or PVC full.
Replace `<CTX>` with your context name. All steps below are **read-only**. Steps marked 🔒 need
node access and are destructive-by-policy → get owner approval before running (see the operating
rules, AGENTS.md).

> Cluster-specific "usually the cause here" notes belong in your knowledge library (`knowledge/`)
> under a **Check-first hints** heading — read those first.

## 0. Is there actually pressure? (fast triage)
```bash
# DiskPressure per node (False = below kubelet eviction threshold)
kubectl --context <CTX> get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="DiskPressure")]}{.status}{end}{"\n"}{end}'
# Recent disk/eviction events
kubectl --context <CTX> get events -A --field-selector reason=EvictionThresholdMet 2>/dev/null
kubectl --context <CTX> get events -A | grep -iE 'evict|disk|NodeHasDiskPressure|ImageGC' | tail -20
```

## 1. Get REAL used% per node (not just capacity)
`kubectl top nodes` shows CPU/mem only — **no disk**. Node objects show capacity, not usage.
Best source of live filesystem usage is node-exporter via Prometheus, if present:
```bash
# Confirm the monitoring stack + find the Prometheus pod/port
kubectl --context <CTX> get pods -A | grep -iE 'prometheus|node-exporter'
# PromQL: size & available bytes for root and any data mount (URL-encoded query)
PROM="<ns>/pods/<prometheus-pod>:9090"
kubectl --context <CTX> get --raw "/api/v1/namespaces/$PROM/proxy/api/v1/query?query=node_filesystem_size_bytes%7Bmountpoint%3D~%22%2F%7C%2Fmedia%2Fdata%22%7D"
kubectl --context <CTX> get --raw "/api/v1/namespaces/$PROM/proxy/api/v1/query?query=node_filesystem_avail_bytes%7Bmountpoint%3D~%22%2F%7C%2Fmedia%2Fdata%22%7D"
# used% = (size - avail) / size. Broadest one-liner (all mounts >70% full):
kubectl --context <CTX> get --raw "/api/v1/namespaces/$PROM/proxy/api/v1/query?query=(1-node_filesystem_avail_bytes/node_filesystem_size_bytes)*100%3E70"
```
**Is it *alarming*? Get days-to-full from the trend** (a high % that's flat is fine; a rising one
is not). Days to full per mount = avail / daily fill rate over the last 7 days
(`avail / -deriv(avail[7d]) / 86400`; negative result = shrinking/flat, i.e. safe):
```bash
Q='node_filesystem_avail_bytes{mountpoint="/media/data",fstype=~"ext4|xfs"} / (-deriv(node_filesystem_avail_bytes{mountpoint="/media/data",fstype=~"ext4|xfs"}[7d])) / 86400'
ENC=$(printf '%s' "$Q" | jq -sRr @uri)
kubectl --context <CTX> get --raw "/api/v1/namespaces/$PROM/proxy/api/v1/query?query=$ENC" \
  | jq -r '.data.result[]|[.metric.instance,((.value[1]|tonumber)|round|tostring)+"d"]|@tsv'
```
> **`/media/data`** is used here as the shared data filesystem mount on OpenEBS-hostpath clusters
> (the hostpath data drive where **every pod PVC** is stored; SC `openebs-hostpath`, BasePath
> `/media/data/openebs/openebs`). **Adjust to your own mount.** Root `/` is usually fine — check
> the data mount first.
⚠️ **Gotcha:** some clusters disable the kubelet stats API —
`kubectl get --raw /api/v1/nodes/<node>/proxy/stats/summary` returns `NotFound`. When that
happens, use the Prometheus path above.

## 2. Persistent storage pressure (PV/PVC)
> ⚠️ **OpenEBS-hostpath gotcha — kubelet volume metrics are useless for ranking PVCs.**
> On `openebs-hostpath` clusters, all PVCs share the one data filesystem with no per-volume
> quota, so `kubelet_volume_stats_used_bytes`/`_capacity_bytes` report the **whole filesystem
> total for *every* PVC** (you'll see an identical usedGB and used% on all of them). That is a
> filesystem reading, not per-PVC. To attribute data-drive growth to an actual PVC you must `du`
> on the node under `/media/data/openebs/openebs/<pv-name>` — 🔒 node access, owner approval.
```bash
kubectl --context <CTX> get pv  -o custom-columns='NAME:.metadata.name,SIZE:.spec.capacity.storage,SC:.spec.storageClassName,STATUS:.status.phase,CLAIM:.spec.claimRef.name'
kubectl --context <CTX> get pvc -A
# What storage backend + where it physically lives (hostpath BasePath etc.)
kubectl --context <CTX> get sc -o custom-columns='NAME:.metadata.name,PROV:.provisioner'
kubectl --context <CTX> get sc <sc-name> -o yaml | grep -iA2 'BasePath\|config'
# Live PVC usage % (if kubelet volume metrics are scraped):
kubectl --context <CTX> get --raw "/api/v1/namespaces/$PROM/proxy/api/v1/query?query=(1-kubelet_volume_stats_available_bytes/kubelet_volume_stats_capacity_bytes)*100%3E70"
```

## 3. What's eating the node root disk? (usual suspects)
```bash
# ephemeral-storage requested by pods per node
kubectl --context <CTX> describe node <node> | grep -A8 'Allocated resources' | grep -i ephemeral
# biggest ephemeral-storage requesters cluster-wide
kubectl --context <CTX> get pods -A -o json | grep -c '"ephemeral-storage"'   # quick presence check
```
Common root-disk consumers (verify with 🔒 node access when needed):
- **Container images / containerd** growing (`/var/lib/containerd`) — check image count/GC.
- **Pod & container logs** (`/var/log/pods`, `/var/log/containers`), journald.
- A pod writing large data to **emptyDir / overlay** (ephemeral).
- **OpenEBS hostpath** PV growth if the data path is on the root disk (check `BasePath`).

### Attributing data-drive growth to a real PVC (node-shell `du`) ✅ preferred
Metrics can't do this (see the OpenEBS gotcha above), so read the node directly. If `node-shell`
is permitted for read-only host commands in your setup (interactive shells, redirects, and any
mutating command should stay blocked), use it:
```bash
# 1) biggest PVC dirs on the node's OpenEBS data drive (read-only; safe)
kubectl-node_shell --context <CTX> <node> -- du -xh -d1 /media/data/openebs/openebs | sort -h | tail -30
# 2) translate each pvc-<uuid> dir to its workload
kubectl --context <CTX> get pv -o custom-columns='PV:.metadata.name,PVC:.spec.claimRef.name,NS:.spec.claimRef.namespace,CAP:.spec.capacity.storage'
# quick host filesystem view:
kubectl-node_shell --context <CTX> <node> -- df -h /media/data /
```
> ⚠️ **`openebs-hostpath` has NO quota** — a PVC's declared size (e.g. "2Gi") is cosmetic; the
> volume grows until the *node's* data filesystem fills. Typical heavy consumers are replicated
> databases (one full copy per node) and object stores (erasure-coded pool volumes). Fix = bound
> growth (DB retention/compaction, object-store lifecycle) or add disk.
> Placement of the invocation matters: pass `--context` **after** `node-shell`/to the plugin
> (kubectl eats a global `--context` before the plugin name). On Windows, kubectl can't run the
> bash plugin as a subcommand — call `kubectl-node_shell` directly.

🔒 Anything that *writes* on the node (deleting files, compaction, remounts) is still destructive —
get owner approval and stage the commands in a file for the owner to run.

## 4. Record what you found
- Put cluster-specific findings ("node X root runs hot", "images are the usual cause") into your
  knowledge library under **Check-first hints**, with proof.
- If you found a faster/better command, add it to this playbook.
