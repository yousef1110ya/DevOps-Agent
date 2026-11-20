# Control-plane & etcd health

Generalized, reusable lessons for diagnosing control-plane, etcd, and leader-election issues.

### Crashloop storm of unrelated controllers = one leader-election event, usually slow etcd
**Symptom:** Several unrelated controllers (`kube-scheduler`, `kube-controller-manager`, CSI provisioner, DB operators, cert-manager, CNI operator) all alert `KubernetesPodCrashLooping` at once, often already `1/1 Running` by the time you look, all restarted at the same age.
**Cause:** They all hold a leader-election lease via the apiserver. One apiserver/etcd blip → all fail lease renewal in the same second and self-terminate by design (`"Leaderelection lost"`, exit 1) → restart. The most common root blip is **etcd slow disk** (only the leader's disk gates cluster-wide raft commits).
**Fix:** Don't debug each pod — find the shared cause. Confirm the mechanism: `logs <controller> --previous | grep -iE 'renew lease|Leaderelection lost'`. Then find the leader's slow disk: `logs etcd-<node> --tail=3000 | grep -c "overloaded likely from slow disk"` (only the bad member has hits) and `grep "took too long"` (multi-second apply latency lines up with the crashloop time). Rule out node CPU/RAM pressure (`top node`) so you don't misattribute. Real fix = faster/dedicated etcd disk + move leadership off the bad member (mitigation); defrag if the DB is bloated.

### "Control plane down" on an HA cluster is usually ONE node down, quorum intact
**Symptom:** Owner reports "control plane is down"; `kubectl` fails *intermittently* with `TLS handshake timeout` (some calls succeed, some time out).
**Cause:** On a 3+ control-plane cluster, one node is down but quorum holds; the apiserver VIP/LB still routes a share of requests to the dead backend → ~1/N failures.
**Fix:** `get nodes -o wide` — 1-of-3 (or 2-of-5) NotReady = degraded, quorum OK. (Majority NotReady = real quorum loss, escalate.) Pulling the dead apiserver from the LB pool stops the timeouts immediately, before the node is fixed. The actual repair is host recovery (SSH, check disk/mem/`dmesg`, `systemctl restart kubelet containerd`, or reboot the VM); static control-plane pods are recreated by the kubelet automatically once it's healthy. Do **not** `etcdctl member remove` for a transient outage — that's only for permanent replacement.

### Dead node's static-pod status is a "lie of staleness"
**Symptom:** A down control-plane node's `etcd`/`kube-apiserver` static pods still show `Running`.
**Cause:** The API shows last-reported status for a dead kubelet (stale mirror-pod state).
**Fix:** Don't trust it. Verify quorum via a **surviving** member's etcd log instead — expect warnings about the dead peer only (`TLS handshake timeout`, `peer became inactive`, `i/o timeout` to its `:2380`). That the apiserver answers reads/writes at all is itself proof quorum holds.

### DB/platform operator crashloop under etcd churn is benign
**Symptom:** A controller/operator pod is `1/1 Running` with a high restart count; `--previous` log ends in `fatal error: concurrent map read and map write` (a Go data race) → panic → exit 2 → restart, preceded by `etcdserver: leader changed` / `request timed out`.
**Cause:** The reconcile loop hits a controller-runtime data race under lease/leader churn; it co-occurs with the etcd-slow-disk signal. The data plane (e.g. DB StatefulSets, backups) keeps running throughout.
**Fix:** Don't treat it as a data-plane outage. Confirm the data pods are Running and backups current; watch the **underlying etcd slow-disk latency**, not the operator restarts. Optional permanent fix: bump the operator image to a version with the data-race fix.

### Enabling apiserver flags (OIDC/audit) without SSH via a privileged Job
**Symptom:** You need to edit `kube-apiserver.yaml` (add flags/volumes) but want to avoid SSH, and the edit causes an API blip.
**Cause:** Editing the static-pod manifest restarts the apiserver.
**Fix:** Schedule a one-shot **privileged Job pinned to the control-plane node** (`hostPID` + `hostNetwork`, tolerating the control-plane taint, mounting `/etc/kubernetes` + the audit dir under `/host`) that does the edit locally: preconditions → byte-exact backup → **additive-only** parser edit (assert no pre-existing flag/mount is dropped) → kubelet restart → health-gate on local `curl -sk https://localhost:6443/livez` → **auto-rollback** to the byte-exact backup if unhealthy. Single-CP = one ~30–60s blip. For HA, run the Job per CP node **one at a time**, verifying that node's apiserver healthy with the new flags live before the next — the other members keep serving, so there's no full-API blip (~40–46s per node). Pre-stage read-only `--check` Jobs on all nodes in parallel, but enable strictly serially. Edit the manifest with a real YAML parser (full `safe_load`→`safe_dump`, `sort_keys=False`, `width=4096` to stop flag folding), never text munging.

### Alert-count floods are usually control-plane scrape misconfig, not an outage
**Symptom:** A cluster shows a large number of critical alerts — `etcdInsufficientMembers(0)`, `etcdMembersDown`, `KubeSchedulerDown`, `KubeControllerManagerDown`, `KubeProxyDown`, `TargetDown` — firing continuously for months.
**Cause:** Prometheus can't scrape the control-plane metrics endpoints (classic kubeadm `127.0.0.1` bind) → scrapes 0 members → permanent false criticals. (An apiserver that responds at all makes `etcd 0 members` impossible.)
**Fix:** Verify the named pods are `1/1 Running` with live endpoints — it's noise. Repair/relax the control-plane ServiceMonitors or silence the stock HA rules. Caution: these often route to a `null` blackhole receiver, so **real** problems can go un-alerted behind the noise — fix the routing too.
