# Kubernetes upgrades — kubeadm & etcd

Generalized, reusable lessons for upgrading kubeadm-managed clusters and handling etcd during upgrades.

### kubeadm refuses to skip minor versions — one minor per hop
**Symptom:** `kubeadm upgrade apply` rejects a multi-minor jump; a big upgrade (e.g. 1.30→1.37) requires 7 separate hops.
**Cause:** kubeadm only supports upgrading one minor version at a time; the control plane restarts on each hop.
**Fix:** Repeat the full cycle per minor (`1.30→1.31→…`). Per hop: repoint apt repo to `v1.<minor>` + refresh its `Release.key` → `apt-get install kubeadm=<patch>` → `kubeadm upgrade apply vX.Y.Z` → install matching `kubelet`/`kubectl` → `systemctl daemon-reload && restart kubelet` → wait node Ready at new version. On a single node each hop is a brief API/app outage; warn the owner.

### `CreateJob` preflight false-fails on modest nodes (kubeadm ≥1.33)
**Symptom:** `kubeadm upgrade apply` aborts with `CreateJob … did not complete in 15s` though pods actually run fine.
**Cause:** kubeadm ≥1.33 added a health-check Job with a tight 15s gate that times out on slower/smaller nodes.
**Fix:** Verify pod-run health independently (a test pod schedules in <10s), then bypass: `kubeadm upgrade apply … --ignore-preflight-errors=CreateJob`.
**Version note:** Introduced in kubeadm 1.33+.

### etcd restart races the co-located apiserver on a single control-plane node
**Symptom:** During upgrade, kubeadm reports `failed to obtain static Pod hash for component etcd … context deadline exceeded` and then **rolls etcd back**.
**Cause:** On a single (stacked) control-plane node, restarting etcd drops the co-located apiserver, which resets kubeadm's connection mid-operation.
**Fix:** Decompose the hop — run the control-plane upgrade without touching etcd: `kubeadm upgrade apply vX.Y.Z --etcd-upgrade=false`. On an HA cluster this race is far milder (other members keep quorum).

### apiserver crashloops after any etcd restart — kick its static pod
**Symptom:** apiserver stuck in crashloop backoff with `:6443 connection refused` after etcd restarted.
**Cause:** The restart threw the apiserver into backoff; it won't retry fast enough on its own.
**Fix:** Move its static manifest out and back to reset the backoff: `mv /etc/kubernetes/manifests/kube-apiserver.yaml` out ~10s, then move it back. Transient high restart counts on CNI controllers / cert-manager / CSI provisioner during this window are collateral (they log `connection refused to <apiserver-clusterIP>`, i.e. API down) and self-heal — not version incompatibilities.

### etcd 3.6→3.7 panics on an existing data store
**Symptom:** After upgrade, the new etcd member crashloops, **panicking in `applyEntries`**.
**Cause:** `etcd:3.7.0-0` cannot apply entries against a live 3.6 store; 3.6.8 runs clean against the same data. A *fresh* `kubeadm init` gets 3.7.0 fine on an **empty** datadir — the panic is upgrade/existing-data specific.
**Fix:** Keep etcd at **3.6.8** (a supported datastore for k8s 1.37) — do **not** force the image swap. The k8s component versions (apiserver/kubelet/etc.) are what matter.
**Version note:** etcd 3.7.0-0 vs an existing 3.6 store. On HA, STOP immediately if the first upgraded member crashloops — the other members hold quorum, so you have time to decide (stay on current etcd, or snapshot-restore). Never push the remaining members onto the broken version.

### Back up etcd before upgrading — the distroless etcd image has no `tar`
**Symptom:** `kubectl cp` of an etcd snapshot fails because `tar` is missing in the etcd container.
**Cause:** The etcd image is distroless; `kubectl cp` relies on in-container `tar`.
**Fix:** Save the snapshot to the **host-mounted** `/var/lib/etcd` path *inside* the etcd pod (`etcdctl snapshot save /var/lib/etcd/snap.db`), then copy it on the host. For HA stacked etcd, one member's snapshot suffices (replicated). Also archive `/etc/kubernetes` on every control-plane node.

### HA upgrade golden order (never deviate)
**Symptom:** Full API outage or broken quorum during a multi-node upgrade.
**Cause:** Wrong node order or upgrading multiple nodes at once.
**Fix:** Per minor: (1) FIRST control-plane node = `kubeadm upgrade apply` (does cluster-wide + etcd); (2) EACH other control-plane node = `kubeadm upgrade node`, one at a time; (3) EACH worker = `kubeadm upgrade node`, one at a time, drain→upgrade→uncordon. Never run `apply` on more than the first CP node; never upgrade two nodes concurrently on a small cluster (starves capacity / risks quorum). HA etcd keeps quorum so there's no full API outage. A mixed-minor cluster (apiserver newer, some kubelets older) is a supported skew state, so mid-upgrade abort between nodes is safe. kubeadm does **not** support minor downgrades — fix-forward or restore from backup.

### A bad `kubeadm upgrade apply` auto-restores manifests
**Symptom:** You need to recover from a failed apply.
**Cause/Fix:** kubeadm auto-restores the previous static-pod manifests from `/etc/kubernetes/tmp/kubeadm-backup-manifests-*` — this is the built-in rollback. For an etcd data disaster (last resort), restore the pre-upgrade snapshot with `etcdctl snapshot restore` into a fresh data dir on each member.

### Check component compatibility before each big jump
**Symptom:** Operators/webhooks wedge on removed APIs after an upgrade.
**Cause:** Across many minors, APIs are removed and support windows matter. CoreDNS/kube-proxy upgrade automatically with `apply`; everything else does not.
**Fix:** Before each target minor, confirm the CNI (e.g. Calico/tigera-operator), CSI/storage provisioner, cert-manager (removed APIs break its webhook), ingress-nginx (Ingress API + admission webhook), and each operator (DB operators have their own k8s support matrix) support the target; upgrade them in the same window. CNI is kubeadm-independent — upgrade separately and watch its status after each minor.
**Version note (one validated fleet profile):** Calico v3.28.1 (via tigera-operator), cert-manager v1.15.0, ingress-nginx v1.11.2, OpenEBS localpv 3.4.0 all ran on k8s v1.37.2 (OpenEBS only logged a harmless `v1 Endpoints deprecated in 1.33+` warning).
