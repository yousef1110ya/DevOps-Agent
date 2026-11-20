# Playbook — storm of `KubernetesPodCrashLooping` alerts on unrelated pods (leader-election storm → usually slow etcd)

**Symptom:** several *unrelated* controllers alert `KubernetesPodCrashLooping` at once — e.g.
`kube-scheduler`, `kube-controller-manager`, a CloudNativePG/psmdb/minio operator, `openebs-localpv-provisioner`,
`cert-manager`, `tigera-operator`. They often look recovered (`1/1 Running`) by the time you check.

**Key idea:** all these components hold a **leader-election lease** via the apiserver. If the
apiserver/etcd blips, they all fail lease renewal within the same second and **self-terminate by
design** (`"Leaderelection lost"`, exit 1), then restart. One control-plane event → many crashloop
alerts. **Don't debug each pod — find the shared cause.**

All commands read-only; replace `<CTX>` with your context.

### 1. Confirm it's ONE event — check restart timing
```bash
kubectl --context <CTX> get pods -A -o wide | grep -Ei 'scheduler|controller-manager|operator|provisioner'
```
If the alerted pods all show their **last restart at ~the same age** ("2m5x ago") → single correlated
event, not N bugs. Note which node each is on (the CP pods pin the affected control-plane node).

### 2. Confirm the mechanism — a controller's previous log says "Leaderelection lost"
```bash
kubectl --context <CTX> -n kube-system logs kube-scheduler-<cp-node> --previous --tail=20 \
  | grep -iE 'renew lease|Leaderelection lost|context deadline|Client.Timeout'
```
`failed to renew lease ...: timed out` → `"Leaderelection lost"` confirms lease-loss, not an app bug.

### 3. Find the shared cause — etcd slow disk (most common)
```bash
# Is etcd blaming its disk? (this is the smoking gun)
kubectl --context <CTX> -n kube-system logs etcd-<cp-node> --tail=3000 \
  | grep -c "overloaded likely from slow disk"

# How bad / when — apply latency bursts (expected 100ms; multi-second = bad)
kubectl --context <CTX> -n kube-system logs etcd-<cp-node> --tail=3000 \
  | grep "took too long" | grep -oE '[0-9]{4}-[0-9-]+T[0-9]{2}:[0-9]{2}' | sort | uniq -c

# Isolate WHICH member — run the slow-disk grep on every etcd pod; only the bad one has hits
for p in $(kubectl --context <CTX> get po -n kube-system -l component=etcd -o name); do
  echo "$p: $(kubectl --context <CTX> -n kube-system logs ${p#pod/} --tail=1500 | grep -c 'slow disk')"
done
```
Only the **leader's** disk gates cluster-wide commits, so a single bad member (if it's leader) stalls
everything. `apply request took too long` of several seconds lines up exactly with the crashloop time.

### 4. Rule OUT node resource pressure (so you don't misattribute to CPU/RAM)
```bash
kubectl --context <CTX> top node <cp-node>              # low CPU/mem here => it's disk I/O, not node pressure
kubectl --context <CTX> top pod -A --sort-by=cpu | head # is a noisy neighbor on the CP node? usually not
```

### 5. Blast radius (optional, for the writeup)
```bash
kubectl --context <CTX> -n kube-system logs etcd-<cp-node> --tail=3000 \
  | grep '<HH:MM of the burst>' | grep -oE '/registry/leases/[a-z0-9-]+/[a-z0-9-]+' | sort -u
```

### Interpreting
- etcd "slow disk" + multi-second `apply took too long` on the **leader**, node not CPU/RAM-bound →
  **etcd disk latency**. Fix = move leadership off the bad member (mitigation) + faster/dedicated
  etcd disk (real fix); defrag if DB bloated. Owner-side, non-read-only → stage in a command file.
- No etcd disk warnings? Widen: apiserver overload/OOM, etcd member down (lost quorum margin),
  network blips between apiserver↔etcd, or cert/clock issues. Check `kube-apiserver-<node>` logs and
  `etcdctl endpoint status` (needs exec + approval).

### Other causes of a crashloop *storm* (if leader-election is NOT the link)
- Shared dependency down (a common backend/DB, a webhook admission service timing out).
- Node-level: DiskPressure/MemoryPressure evicting many pods on one node (`describe node`).
