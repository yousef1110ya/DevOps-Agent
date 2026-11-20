# Node saturation / high CPU / `NodeSystemSaturation` alert

Symptom: an alert like `NodeSystemSaturation` ("system load per core > 2") or "High CPU 90%"
on a specific node (the alert names an IP:9100 = node-exporter). Goal: decide **compute vs
disk-I/O**, then name the **top consumers** — legit load vs waste.

All commands are **read-only** and carry `--context <CTX>`. Replace `<CTX>` and `<NODE>`.

## 0. Map the alert IP to a node
```
kubectl --context <CTX> get nodes -o wide     # match INTERNAL-IP to the alert's a.b.c.d:9100
```

## 1. Is it actually this node, and how hot?
```
kubectl --context <CTX> top nodes             # CPU% / MEM% per node; is <NODE> an outlier?
kubectl --context <CTX> describe node <NODE> | sed -n '/Conditions:/,/Addresses:/p;/Allocated resources:/,/Events:/p'
```
- Conditions `MemoryPressure/DiskPressure/PIDPressure=False` + `Ready=True` → no kubelet-level
  pressure; the alert is about load, not eviction risk.
- `Allocated resources` CPU **requests %** near/over 100% → the node is packed at the *scheduler*
  level (oversubscribed), independent of live usage.

## 2. Compute or disk-I/O? (this is the fork that decides everything)
**Shortcut:** metrics-server `top nodes`/`top pod` `CPU(cores)` is **genuine on-CPU time and
EXCLUDES iowait.** So if `top nodes` shows the node at 80%+ CPU, that is *real compute* — it is
**not** an iowait artifact. (The contrasting case is where high load is iowait: there the tell is
load ≫ CPU(cores), i.e. a run-queue full of D-state tasks while CPU(cores) stays modest.)

If you have node access (and node-shell is permitted for read-only host commands):
```
kubectl node-shell <NODE> --context <CTX> -- cat /proc/loadavg /proc/pressure/cpu /proc/pressure/io
```
- PSI `cpu` `some avg10` high → **compute** bound. PSI `io` high → **disk-I/O** bound.
- ⚠️ node-shell gotchas: it's a **plugin**, so `--context` must come **after** the node name
  (`kubectl node-shell <NODE> --context <CTX> -- …`), not before. A guard that denylists the
  literal `node` (Node.js) can block it — if so, step 1's metrics-server reading is usually enough.

## 3. Name the top consumers (legit load vs waste)
```
kubectl --context <CTX> top pod -A --sort-by=cpu | head -25
kubectl --context <CTX> get pods -A --field-selector spec.nodeName=<NODE> -o wide   # what lives here
```
Classify each big consumer:
- **Legit application load** (app servers, DBs doing real queries, an intended load generator on
  a stage/test cluster) — expected; the lever is scaling the app or the load, not "a bug".
- **Waste** — a controller/operator/sidecar burning hundreds of millicores is almost always a
  **hot reconcile loop**. Confirm with its logs (look for the same line repeating sub-second):
  ```
  kubectl --context <CTX> -n <NS> logs deploy/<operator> --tail=30
  ```
  A pod with `resources:{}` (no requests/limits) can spin unbounded *and* is invisible to the
  scheduler — check `get deploy <op> -o jsonpath='{.spec.template.spec.containers[0].resources}'`.

## 4. Common causes & levers
| Finding | Meaning | Lever (destructive → owner approval) |
|---|---|---|
| One node ≫ others, CPU requests near 100% | Stateful singletons piled on one worker | Spread with anti-affinity / topology-spread |
| An operator/controller at 100s of millicores, logs looping | Hot reconcile loop (e.g. stuck lock/backlog) | Clear the stuck object; cap it with requests/limits |
| A load-generator pod is #1 | Intended test/stage load | Dial down its rate/replicas if saturation is unwanted |
| Load ≫ CPU(cores), PSI `io` high | Disk-I/O (iowait), NOT compute | Faster disk tier / reduce the I/O source |

## Gotchas
- **Warning ≠ emergency.** load/core just above 2 with no Memory/Disk/PID pressure and a healthy
  data plane (DBs `ready`, pods Running) is "real but not urgent."
- Always report **which pods/apps** own the CPU with numbers (cite proof). "The node is at 83%"
  is not an answer; "simulator 788m + operator 628m (spinning) + db replica ~700m" is.
- A common benign pattern: compute-bound analytics shards (e.g. ClickHouse) pinning the 2 nodes
  that host the actively-ingesting replicas while an idle replica's node stays quiet — iowait≈0,
  ~1 core idle. If there's **no metrics-server + no node-shell**, use the in-cluster Prometheus
  proxy for `node_load1` / CPU-by-mode / top-pod CPU.
