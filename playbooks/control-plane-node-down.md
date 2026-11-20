# Control-plane node down / "control plane down"

**Symptom:** an owner reports "the control plane is down", and/or `kubectl` fails
**intermittently** with `Unable to connect to the server: net/http: TLS handshake timeout`
(some calls succeed, some time out). On an **HA (3+ control-plane node)** cluster this is
almost always **ONE control-plane node down with quorum still intact**, not a real outage —
the apiserver VIP/LB keeps sending a share of requests to the dead node.

> All commands here are **read-only** and carry `--context <CTX>`. The actual *fix* is
> node/host recovery (SSH, systemctl, VM reboot) — that is owner/off-cluster work: stage it in a
> command file, don't run it from here.

Replace `<CTX>` with your context.

## 1. Is it one node or the whole plane? (decides everything)
```bash
bash tools/scans/cluster-triage.sh <CTX>            # look for "[!] ... NotReady control-plane"
kubectl --context <CTX> get nodes -o wide            # how many control-plane nodes NotReady?
```
- **1 of 3 (or 2 of 5) NotReady** → degraded, quorum OK → this playbook. Continue.
- **Majority of control-plane nodes NotReady** → quorum LOST, real outage → STOP and escalate;
  etcd recovery is out of scope for a read-only runbook.
- **`get nodes` itself never succeeds** (all attempts time out) → API endpoint/VIP or etcd
  quorum is gone — escalate.

## 2. Why is that node NotReady?
```bash
kubectl --context <CTX> describe node <cpN> | sed -n '/Conditions:/,/Addresses:/p'
kubectl --context <CTX> get events -A --field-selector involvedObject.name=<cpN> | tail -20
```
- `Ready=Unknown`, reason **`NodeStatusUnknown` / "Kubelet stopped posting node status"** →
  the **kubelet/host went silent** (crash, reboot, full disk, OOM, network) — a host problem,
  not an app problem. Note the `LastHeartbeatTime` = when it died.
- `DiskPressure=True` / `MemoryPressure=True` → see [disk-usage-high.md](disk-usage-high.md).

## 3. Confirm etcd quorum is actually intact
The down node's static pods (`etcd/kube-apiserver/…-<cpN>`) will still show **`Running`** —
that is **stale mirror-pod state** (the API shows last-reported status for a dead kubelet). Don't
trust it. Instead check a **surviving** node's etcd log for peer/quorum status:
```bash
bash tools/scans/pod-logs-scan.sh <CTX> kube-system etcd-<healthy-cpN> etcd 40
```
- Expect: warnings about the **dead** peer only — `TLS handshake timeout`, `tls: bad record MAC`,
  `peer became inactive`, `i/o timeout` to the down node's IP:2380. The surviving members keep
  electing/serving → quorum holds. That the apiserver answers reads/writes at all is itself
  proof quorum is up.

## 4. Quantify client impact (the intermittent timeout)
```bash
for i in $(seq 1 6); do
  kubectl --context <CTX> version --request-timeout=5s | grep -i 'server version' || echo FAIL
done
```
- ~1/N failures on an N-control-plane cluster = the VIP/LB still lists the dead apiserver.
  Pulling that backend from the pool (owner/infra action) stops the timeouts immediately even
  before the node is fixed.

## 5. Fix = recover the host (owner action — NOT from this runbook)
Write the node-recovery steps to a command file: SSH to the node → check disk/mem/`dmesg` →
`systemctl status/restart kubelet containerd`; if the box is unreachable, reboot/recover the VM at
the infra layer. Static control-plane pods (etcd/apiserver/…) are recreated by the kubelet
automatically once it's healthy — don't hand-start them. Verify with step 1 + step 4 (node returns
`Ready`, 6/6 probes succeed).

**Do NOT `etcdctl member remove` a node for a transient outage** — quorum is fine and removal is
only for permanent replacement.

## Gotchas
- "Control plane down" from an owner usually means "kubectl is flaky" → almost always **one**
  node, not the cluster. Check `get nodes` before believing the worst.
- Static-pod `Running` status for the dead node is a **lie of staleness** — verify via a healthy
  peer's logs, not the pod list.
- Don't confuse a control-plane-node outage with an apiserver *app* crashloop: here the pods are
  fine on the survivors; the fault is the host.
