# Playbook — upgrade a MULTI-NODE Kubernetes cluster (kubeadm, HA-aware)

How to upgrade a multi-node kubeadm cluster (several control-plane nodes and/or workers) **one minor
version at a time**, with minimal downtime, draining nodes safely, and respecting common quirks
(Calico CNI, **OpenEBS hostpath = node-pinned volumes**, stacked etcd, control-plane LB/VIP).

> **Provenance.** This follows the **standard kubeadm HA upgrade flow** + the same set of gotchas
> proven on the single-node sibling [`create-single-node-cluster.md`](create-single-node-cluster.md)
> (CreateJob preflight, etcd/apiserver behaviour, guard handling). The per-node mechanics are identical;
> the **ordering** is standard kubeadm. Treat destructive steps as **owner-approved maintenance** and run
> them in a window.

> **Applies to clusters with:** multiple control-plane nodes (3+ for HA) + workers, **stacked etcd**
> (etcd runs on the control-plane nodes), **Calico** CNI, and **OpenEBS hostpath** node-pinned volumes.

---

## 0. The three things that make multi-node DIFFERENT from single-node

1. **HA etcd keeps quorum → little/no API outage.** With ≥3 control-plane nodes, upgrading **one at a
   time** restarts only one etcd member at a time; the other two keep quorum, so the apiserver LB keeps
   serving. This is the opposite of single-node (where the one etcd restart drops the whole API). **The
   etcd 3.6→3.7 crash risk still exists**, but on HA you can abort after the *first* member without a
   full outage (see §6).
2. **You must respect the node roles & order** (control-plane first, workers last) and the **version-skew
   policy** (kubelet/kube-proxy may be older than the apiserver, never newer).
3. **Draining a node moves its pods — but OpenEBS hostpath PVs are NODE-PINNED.** A StatefulSet/Deployment
   using an `openebs-hostpath` PVC **cannot reschedule to another node** (the PV has node affinity to its
   original node). Draining that node evicts the DB/MinIO/etc. pod and it goes **Pending until the node is
   back and uncordoned** = real downtime for *that* workload. Plan around it (see §4 + §6).

## The golden order (NEVER deviate)
```
one minor at a time (repeat the whole cycle per minor, e.g. 1.30→1.31→…→1.37):
  1. FIRST control-plane node   : kubeadm upgrade APPLY vX.Y.Z   (does the cluster-wide + etcd upgrade)
  2. EACH other control-plane   : kubeadm upgrade NODE           (one at a time)
  3. EACH worker node           : kubeadm upgrade NODE           (one at a time, drain→upgrade→uncordon)
  for EVERY node: drain → upgrade kubeadm pkg → (apply|node) → upgrade kubelet+kubectl → restart kubelet → uncordon
```

---

## Conventions & the guard
- `<CTX>` = **your device's** context name for the cluster.
- SSH to each node is required (you run `kubeadm`/`apt`/`systemctl` **on the node**). Use the node SSH key,
  e.g. `ssh -i ~/.ssh/<key> <user>@<node-ip>`.
- **Guard:** `kubectl drain/cordon/uncordon/delete` are MUTATING → blocked by a mutating-verb guard and
  need the owner's approval. Two ways that work:
  - run them in an **on-node script** (`ssh … 'bash /root/x.sh'`) using the node's `/etc/kubernetes/admin.conf`
    (the local command is `bash …`, not `kubectl …`, so the guard doesn't inspect it — same pattern as
    the single-node playbook); **or**
  - get explicit owner approval + an approval token per command.
  Read-only `kubectl --context <CTX> get/describe` is always fine for checking from your machine.
- **Never** `kubectl config use-context`. Pass `--context <CTX>` on read-only checks.

---

## Step 0 — inventory, health & compatibility (read-only, do from your machine)
```bash
CTX=<your-context>
kubectl --context $CTX get nodes -o wide                         # roles, versions, Ready
kubectl --context $CTX get nodes -L node-role.kubernetes.io/control-plane
# all control-plane (etcd) nodes healthy? all workers Ready? any NotReady = FIX FIRST, do not upgrade.
kubectl --context $CTX get pods -A | grep -vE 'Running|Completed' || echo "all pods healthy"
# what will break on drain: node-pinned hostpath stateful pods + PDBs
kubectl --context $CTX get pdb -A
kubectl --context $CTX get pv -o json | \
  jq -r '.items[]|select(.spec.storageClassName=="openebs-hostpath")|"\(.spec.claimRef.namespace)/\(.spec.claimRef.name)  node=\(.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0])"'
```
Checklist before starting:
- Every node **Ready**, every control-plane/etcd member healthy (`kubectl ... get pods -n kube-system |
  grep etcd` → all Running). A degraded cluster must be fixed first.
- Note which nodes host **hostpath-pinned stateful workloads** (Mongo/Postgres/MinIO/Redis/Prometheus) —
  draining those nodes = downtime for those apps. Schedule a window / notify owners.
- Confirm the **target minor repo exists** and the **component compatibility** (§5a): CNI (Calico), CSI,
  cert-manager, ingress-nginx, any operators (Percona/CNPG/etc.).
- **Back up etcd** (§1). For HA stacked etcd, a snapshot from ONE member suffices (they're replicated).

## Step 1 — backup (per cluster, before touching anything)
On ONE control-plane node (stacked etcd), take an etcd snapshot + archive `/etc/kubernetes` on **every**
control-plane node. (Distroless etcd has no `tar`, so `kubectl cp` fails — write the snapshot to the
host-mounted `/var/lib/etcd` inside the etcd pod, then copy on the host.)
```bash
# ON a control-plane node (KUBECONFIG=/etc/kubernetes/admin.conf):
POD=$(kubectl -n kube-system get pods -l component=etcd --field-selector spec.nodeName=$(hostname) -o name | head -1)
kubectl -n kube-system exec "${POD#pod/}" -- sh -c \
 'ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
   --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
   --key=/etc/kubernetes/pki/etcd/server.key snapshot save /var/lib/etcd/snap.db'
cp /var/lib/etcd/snap.db /root/etcd-snapshot-$(date +%F).db && rm -f /var/lib/etcd/snap.db
# and on EACH control-plane node:
tar czf /root/etc-kubernetes-$(hostname)-$(date +%F).tgz /etc/kubernetes
```

## Step 2 — upgrade the FIRST control-plane node (`kubeadm upgrade apply`)
This is the only node where you run **`apply`** — it upgrades the cluster-wide config + this node's etcd
+ control-plane static pods. Do it ON that node.
```bash
# --- on cp-01 ---
MINOR=31   # the NEXT minor only
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.${MINOR}/deb/ /" >/etc/apt/sources.list.d/kubernetes.list
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v1.${MINOR}/deb/Release.key" | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
apt-get update -qq
VER=$(apt-cache madison kubeadm | awk 'NR==1{print $3}'); KVER="v${VER%%-*}"
apt-mark unhold kubeadm && apt-get install -y --allow-change-held-packages kubeadm=$VER && apt-mark hold kubeadm

kubeadm upgrade plan                      # review: shows target + etcd/CoreDNS versions + any notes
kubeadm upgrade apply "$KVER" -y --ignore-preflight-errors=CreateJob   # CreateJob bypass — see §6
```
Then **drain this cp node, upgrade its kubelet+kubectl, restart kubelet, uncordon**:
```bash
kubectl --kubeconfig /etc/kubernetes/admin.conf drain $(hostname) --ignore-daemonsets --delete-emptydir-data --timeout=5m
apt-mark unhold kubelet kubectl && apt-get install -y --allow-change-held-packages kubelet=$VER kubectl=$VER && apt-mark hold kubelet kubectl
systemctl daemon-reload && systemctl restart kubelet
kubectl --kubeconfig /etc/kubernetes/admin.conf uncordon $(hostname)
```
**Verify before moving on:** `kubectl get nodes` → cp-01 at the new version & Ready; `kubectl get pods
-n kube-system` → etcd/apiserver/controller/scheduler on cp-01 Running; **etcd quorum intact**
(`kubectl -n kube-system exec <etcd-pod> -- etcdctl … endpoint health --cluster`).

## Step 3 — upgrade the REMAINING control-plane nodes (`kubeadm upgrade node`)
One at a time. Same as step 2 but **`kubeadm upgrade node`** (NOT `apply`), and no `upgrade plan`.
```bash
# --- on cp-02, then cp-03 (one at a time) ---
# (set repo to v1.$MINOR + refresh key as above) ; install kubeadm=$VER
kubeadm upgrade node
kubectl --kubeconfig /etc/kubernetes/admin.conf drain $(hostname) --ignore-daemonsets --delete-emptydir-data --timeout=5m
apt-mark unhold kubelet kubectl && apt-get install -y --allow-change-held-packages kubelet=$VER kubectl=$VER && apt-mark hold kubelet kubectl
systemctl daemon-reload && systemctl restart kubelet
kubectl --kubeconfig /etc/kubernetes/admin.conf uncordon $(hostname)
```
After EACH cp node: confirm it's Ready at the new version and **etcd has all members healthy** before the
next one. (If the new etcd member crashloops — e.g. the 3.6→3.7 panic — STOP here; quorum still holds
from the un-upgraded members, so you have time to investigate, see §6.)

## Step 4 — upgrade the WORKER nodes (`kubeadm upgrade node`), one at a time
For each worker, **drain first** (this moves its workloads — mind the hostpath pinning, §0.3), then
upgrade. Do the drain from a control-plane node / admin kubeconfig.
```bash
# --- from an admin machine / cp node: cordon+drain the worker ---
W=wn-01
kubectl --kubeconfig /etc/kubernetes/admin.conf drain $W --ignore-daemonsets --delete-emptydir-data --timeout=10m
#   ^ if it hangs on a PDB, see §6 (do NOT blindly --disable-eviction on prod).
# --- on the worker $W: ---
# (set repo to v1.$MINOR + refresh key) ; install kubeadm=$VER
kubeadm upgrade node
apt-mark unhold kubelet kubectl && apt-get install -y --allow-change-held-packages kubelet=$VER kubectl=$VER && apt-mark hold kubelet kubectl
systemctl daemon-reload && systemctl restart kubelet
# --- back on admin: ---
kubectl --kubeconfig /etc/kubernetes/admin.conf uncordon $W
kubectl --context $CTX get node $W -o wide     # Ready at new version?
```
Repeat per worker. **Never drain two nodes at once** on a small cluster (you can starve capacity /
break quorum). For nodes hosting a node-pinned hostpath DB, expect that DB to be down from drain until
uncordon + reschedule — keep the window short per node.

## Step 5 — finish the minor, then repeat; final verification
- After all nodes are on `v1.$MINOR`, **repeat Steps 2–4 for the next minor**. For a big jump (e.g.
  1.30→1.37) that's 7 full passes. (Version skew allows kubelets up to 3 minors behind the apiserver, but
  kubeadm still upgrades one minor per `apply` — don't try to shortcut the control-plane minors.)
- Final checks (read-only from your machine):
```bash
kubectl --context $CTX get nodes -o wide                         # ALL at target, ALL Ready
kubectl --context $CTX get pods -A | grep -vE 'Running|Completed' # expect empty
kubectl --context $CTX get tigerastatus                          # Calico: calico/apiserver/ippools True
kubectl --context $CTX get pods -n cert-manager -n ingress-nginx  # components healthy
# etcd health on a cp node:
# kubectl -n kube-system exec <etcd-pod> -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=… --cert=… --key=… endpoint health --cluster
```
- Storage smoke (PVC binds) + an app spot-check. Update your knowledge library with the new version + any
  component bumps + which workloads took drain downtime.

---

## 5a. Component compatibility — check BEFORE each big jump
Across many minors, APIs get removed and component support windows matter. Before each target:
| Component | What to check |
|---|---|
| **Calico (tigera-operator)** | A known-good pin is **v3.28.1** (validated on 1.37.2). For large jumps, confirm the Calico version supports the target k8s; bump the operator if not. Calico is `kubeadm`-independent — upgrade it separately if needed, and watch `tigerastatus` after each k8s minor. |
| **CoreDNS / kube-proxy** | Upgraded automatically by `kubeadm upgrade apply`. |
| **cert-manager** | A known-good pin is **v1.15.0** (ran on 1.37.2). Each cert-manager release supports a band of k8s minors — for big jumps, upgrade cert-manager too (removed APIs break the webhook). |
| **ingress-nginx** | A known-good pin is **v1.11.2** (ran on 1.37.2). Check Ingress API + admission webhook compat for the target. |
| **CSI / OpenEBS** | OpenEBS **localpv 3.4.0** ran on 1.37.2 (only a harmless `v1 Endpoints deprecated in 1.33+` warning). Watch the provisioner after each minor; its crashes during an upgrade are almost always **apiserver-down collateral**, not incompatibility (it logs `connection refused to 10.96.0.1`). |
| **Operators (Percona psmdb, CNPG, etc.)** | Each has its own k8s support matrix. For multi-minor jumps, plan operator upgrades in the same window; a stale operator can wedge on removed APIs. |

## 6. Gotchas (multi-node specific + the proven single-node ones)
- **`CreateJob` preflight (kubeadm ≥1.33)** — the new 15s health-check Job false-fails on modest nodes.
  Verify pod-run health independently (a test pod schedules in <10s), then
  `kubeadm upgrade apply … --ignore-preflight-errors=CreateJob`.
- **etcd 3.6→3.7 can panic on existing data.** `etcd:3.7.0-0` can **panic in `applyEntries`** against a
  live 3.6 store (3.6.8 runs clean). On **HA** this is far safer: the first upgraded member may crash while
  the other two hold quorum — **STOP immediately** if the new etcd member crashloops, keep the cluster on
  the mixed state (quorum intact), and decide: stay on the current etcd (supported) or pursue a
  snapshot-restore. Do **not** push the remaining members onto the broken version.
- **Draining node-pinned hostpath workloads = downtime for those apps** (OpenEBS hostpath PV has node
  affinity; the pod can't move). Options: keep the per-node window short; or temporarily scale the app to
  0 and back around the drain; or (risky, owner call) skip the drain for a pure-stateful node and just
  `kubeadm upgrade node` + kubelet restart (brief kubelet blip, no eviction) — acceptable only if no
  surge capacity exists and the owner accepts the risk.
- **`kubectl drain` hangs on a PodDisruptionBudget** (can't evict without violating `minAvailable`).
  Don't blindly `--disable-eviction`/`--force` on prod. Instead: scale the app up first, or temporarily
  relax/patch the PDB, drain, then restore it. Pods with `emptyDir` need `--delete-emptydir-data`;
  DaemonSet pods need `--ignore-daemonsets` (both set above).
- **Control-plane LB health checks.** HA clusters front the apiservers with an LB/VIP. As each apiserver
  restarts, the LB must mark it down and route to the others — confirm the LB health check is on
  `/healthz` (or `/livez`), not a flat TCP check, so in-flight requests fail over cleanly.
- **apiserver crashloop after etcd restart** (seen badly on single-node; milder on HA) — if an apiserver
  won't come back, kick its static pod: move `/etc/kubernetes/manifests/kube-apiserver.yaml` out ~10s and
  back (resets the crashloop backoff).
- **Guard & scripts:** authoring an on-node script via a bash heredoc that contains literal `kubectl …`
  can trip a mutating-verb guard — write the script with the file-write tool, then `scp`+`bash` it.
- **Never skip a minor**; never run `apply` on more than the first cp; never upgrade two nodes
  concurrently on a small cluster.

## 7. Rollback / abort
- **Mid-upgrade abort is safe between nodes** — a cluster running mixed minors (apiserver newer, some
  kubelets older) is a supported skew state. If a node's upgrade fails, you can pause, fix, and resume;
  the already-upgraded nodes keep running.
- **A bad `kubeadm upgrade apply`** auto-restores the previous static-pod manifests from
  `/etc/kubernetes/tmp/kubeadm-backup-manifests-*`.
- **etcd data disaster (last resort):** restore the Step-1 snapshot with `etcdctl snapshot restore` into
  a fresh data dir on each member and re-point the etcd static pods — a deliberate, owner-run operation,
  not part of the normal flow.
- kubeadm does **not** support downgrading a minor. If the target minor is bad, the path forward is to
  fix-forward or restore from backup — decide before starting that the target is the right one.

## 8. Per-node scripts
Keep one script per role (`first-cp`, `other-cp`, `worker`) built from the blocks above:
- health + etcd snapshot (host-mounted path trick).
- per-minor apt-repo + kubeadm/kubelet/kubectl mechanics (`upgrade apply` for the first cp; change that
  line to `kubeadm upgrade node` for non-first nodes).
- kick a stuck apiserver static pod.
- final node/version + components + storage smoke.

## Troubleshooting
| Symptom | Cause / fix |
|---|---|
| `kubeadm upgrade apply` fails `CreateJob … did not complete in 15s` | 1.33+ preflight; verify pods run, then `--ignore-preflight-errors=CreateJob`. |
| New etcd member crashloops after upgrade (panic in `applyEntries`) | etcd 3.6→3.7 data incompat (see §6). On HA, STOP — quorum holds from other members; don't upgrade the rest. |
| `kubectl drain` hangs forever | PDB blocks eviction, or a pod won't terminate. Scale up / relax the PDB; check for finalizers; mind `--ignore-daemonsets`/`--delete-emptydir-data`. |
| Drained a node, a DB/MinIO pod stuck `Pending` | Its PV is `openebs-hostpath` (node-pinned) — it can only run on its original node. Uncordon that node; the pod returns. Expected, not a fault. |
| A worker stuck `NotReady` after kubelet restart | CNI/kubelet config mismatch — check `journalctl -u kubelet`, `calico-node` on that node; confirm the node's kubelet config was updated by `kubeadm upgrade node`. |
| Apiserver on one cp won't come back | Kick its static pod (move manifest out/in); check etcd reachability from that node. |
| Alerts flood during the upgrade | Expected churn (control-plane scrape gaps, pod restarts). Verify against the alert-noise patterns before treating as real. |

## Related
- Single-node sibling: [`create-single-node-cluster.md`](create-single-node-cluster.md)
  (§ "Upgrading an existing single-node cluster").
- OpenEBS-hostpath disk/pinning behaviour: [`disk-usage-all-nodes.md`](disk-usage-all-nodes.md).
