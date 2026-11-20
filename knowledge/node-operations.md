# Node operations & saturation

Generalized, reusable lessons for node drains, saturation triage, and node-local stateful recovery.

### Compute vs disk-I/O is the fork that decides everything
**Symptom:** `NodeSystemSaturation` ("load per core > 2") or "High CPU 90%" on one node.
**Cause:** High load can be real on-CPU compute **or** iowait (run-queue full of D-state tasks) — different root causes and fixes.
**Fix:** metrics-server `top nodes`/`top pod` `CPU(cores)` is genuine on-CPU time and **excludes iowait** — so 80%+ there is real compute, not an iowait artifact. The iowait tell is **load ≫ CPU(cores)**. With node access, read PSI: `cat /proc/pressure/cpu /proc/pressure/io` — high `cpu some avg10` = compute-bound; high `io` = disk-I/O-bound (also check `node_procs_blocked` ≈ 0 for compute). Then name the top consumers with numbers (`top pod -A --sort-by=cpu`) — "the node is at 83%" is not an answer. Warning ≠ emergency: load just above 2 with no Memory/Disk/PID pressure and a healthy data plane is "real but not urgent."

### Stateful singletons piled on one worker pin that node
**Symptom:** One worker is far hotter than the others; CPU requests near 100% there.
**Cause:** The stateful tier (DB / object store / Prometheus / analytics shards) is co-located on one node; a workload burst saturates it.
**Fix:** Spread the singletons with anti-affinity / topology-spread constraints. For an intended load-generator being #1, dial down its rate/replicas if the saturation is unwanted (raising the app's own CPU limit won't help an alert that measures run-queue, not need).

### Node-saturation stall ≠ OOM, ≠ control-plane etcd pattern
**Symptom:** A batch of app pods — all on the **same worker** — crashloop together, restarting **gracefully** (lastState `exitCode 0/143`, never 137), alongside HighMemory on that node.
**Cause:** A short (~1–2 min) single-node saturation stall: a memory-tight node (high anon usage, **no swap**, overcommitted limits) hits a workload burst → direct reclaim → kubelet traces (volume-metrics, `ExecSync DeadlineExceeded`) blow liveness thresholds → kubelet SIGTERM-restarts the pods. It self-recovers. It is **not** OOM (no 137, `MemoryPressure=False`, no dmesg OOM) and **not** the control-plane leader-election pattern (that hits leader-elected controllers, cluster-wide; this is worker-local).
**Fix:** Tell them apart fast: `get pods -A -o wide | grep` the alerted pods — all on one worker? Check `lastState.terminated.exitCode` (0/143 = graceful). On-node: `cat /proc/meminfo` (high AnonPages, Swap 0), `dmesg | grep -i oom` (clean), `journalctl -u kubelet` (node journald is **UTC**) to see the ExecSync/volume-metrics stall. Real fix: add swap / raise headroom, spread stateful singletons off the node, and/or raise tight exec-probe timeouts. Not urgent.

### A hot reconcile loop (operator spinning on a stuck object) wastes a core
**Symptom:** A controller/operator/sidecar burns hundreds of millicores and shows up as node "waste."
**Cause:** A stuck object makes the reconcile loop hot-loop (e.g. a backup CR stuck `requested` holds a lock so N queued CRs spin). A pod with `resources:{}` can spin unbounded *and* is invisible to the scheduler.
**Fix:** Confirm with its logs (the same line repeating sub-second) and `get <workload> -o jsonpath='{…containers[0].resources}'` = `{}`. Clear the stuck object to recover the core; cap it with requests/limits so it can't spin unbounded again.

### OpenEBS hostpath PVs are node-pinned — draining = downtime for that app
**Symptom:** You drain a node and a DB/object-store pod goes `Pending` forever.
**Cause:** `openebs-hostpath` (and similar local-path) PVs have node affinity to their original node; the pod can't reschedule elsewhere.
**Fix:** Expected, not a fault — uncordon the node and the pod returns. Plan upgrades/drains around it: keep the per-node window short, or temporarily scale the app to 0 and back around the drain. Inventory affected workloads first: `get pv -o json | jq` filtering on the local storageClass, reading `spec.nodeAffinity…values[0]`.

### `kubectl drain` hangs on a PodDisruptionBudget
**Symptom:** `kubectl drain` never completes.
**Cause:** A PDB blocks eviction (can't drop below `minAvailable`), or a pod won't terminate (finalizer).
**Fix:** Don't blindly `--disable-eviction`/`--force` on prod. Instead scale the app up first, or temporarily relax/patch the PDB, drain, then restore it. Pods with `emptyDir` need `--delete-emptydir-data`; DaemonSet pods need `--ignore-daemonsets`.

### ENOSPC on a local-path volume leaves Redis AOF / RabbitMQ WAL corrupt after space is freed
**Symptom:** After a node's data filesystem fills to 100%, most stateful pods self-heal when space is freed, but Redis crashloops `Bad file format reading the append only file appendonly.aof.*` (or RabbitMQ WAL stays broken).
**Cause:** A log/AOF torn mid-write during ENOSPC does not self-heal; the engine can't replay it.
**Fix:** Repair the torn tail: `redis-check-aof --fix <appendonlydir>/appendonly.aof.manifest`. On Bitnami the binary is at `/opt/bitnami/redis/bin/redis-check-aof` — **not on PATH** (a "command not found" is a red herring). Repair pattern on node-local RWO storage: scale the owning STS to 0 (release the PV) → launch a throwaway pod pinned to that node (`nodeSelector kubernetes.io/hostname: <node>`) mounting the PVC → back up the corrupt file → repair → delete pod → scale STS back up → poll `get` until Ready.

### Verify fixes over minutes, not a 20-second window
**Symptom:** A restart/reconcile loop looks fixed in a short sample but resumes.
**Cause:** A brief window can land in a quiet gap between rolls (e.g. an operator oscillating two different images into a StatefulSet template → perpetual RollingUpdate).
**Fix:** Watch for several minutes and track a counter that should stop climbing (restart count, STS `generation`). A short "looks fixed" sample is not proof.

### Image version-skew crash after a `:latest` repoint
**Symptom:** A stateful pod that was repointed to a `*legacy:latest` image crashloops on a **format/version** error (e.g. Redis `Can't handle RDB format version 15 … AOF loading aborted`), not an ImagePull error.
**Cause:** The original `:latest` resolved to a newer engine that booted once on a fresh PVC and wrote data in a newer on-disk format; the frozen `legacy:latest` snapshot is **older** and can't read it.
**Fix:** If this is disposable first-boot scratch (config-only migration, no real data), wipe the volume so it starts clean on the older image. Prefer pinning an explicit `legacy:<major>-…` tag matching the source's running MAJOR version over `:latest` — a `:latest`→`legacy:latest` repoint is not version-stable. And check the source's running image first: if source `:latest` already pulls on the target, don't reflexively repoint at all.

### StatefulSet rollout stalls on an already-broken highest-ordinal pod
**Symptom:** After `kubectl set image`, the STS template flips but `updatedReplicas` stays 0 and nothing rolls; the highest-ordinal pod is already broken (ImagePullBackOff / not-Ready).
**Cause:** A StatefulSet RollingUpdate processes highest ordinal first and won't recreate a pod that isn't Ready — so the one pod that most needs replacing is the one it won't touch. (Bitnami Redis also uses `updateStrategy: OnDelete`, so `set image` never recreates the pod by itself.)
**Fix:** `kubectl delete pod <sts>-<highest-ordinal>` → STS recreates it from the new template → it pulls the good image → becomes Ready → the rest of the rollout proceeds automatically. Deleting a 0/1 broken pod is zero-risk. Note: `.status…image` can keep showing the old name when the layer is cached (`IfNotPresent`) — trust `.spec.template…image` + Ready, not `.status…image`.
