# CNI & networking

Generalized, reusable lessons for CNI (Calico/Tigera/flannel) and cluster networking operations.

### Never mutate the CNI / cluster-infra layer to "free resources"
**Symptom:** After deleting a namespace/APIService/CNI object, pods lose networking and get stuck `Terminating`; the whole cluster breaks.
**Cause:** Deleting or patching the networking/API-aggregation layer (CNI system namespaces, any `APIService`, Calico/Tigera resources like `Installation`/`ippools`/`felixconfigurations`/`*.projectcalico.org`/`*.tigera.io`) takes down cluster-wide networking.
**Fix:** Treat all CNI/infra mutation as off-limits even under broad approval — if truly required, the owner runs it manually, outside automation. Read-only `get/describe` is fine. Before deleting any namespace to free space, confirm it is not the CNI/infra (check the `Installation` CR / `/etc/cni/net.d`); a stray `kube-flannel` DaemonSet can be vestigial — don't trust it as proof flannel is in use.

### Operator-managed CNI reverts hand-patched Deployments
**Symptom:** You `set resources` on a CNI component Deployment (e.g. `calico-apiserver`) and the operator reverts it within seconds.
**Cause:** With tigera-operator, the Deployment is owned by the operator CR (`APIServer/default`, `Installation/default`), which is the source of truth.
**Fix:** Patch the **operator CR**, not the Deployment (e.g. `spec.apiServerDeployment.spec.template.spec.containers[name=…].resources`). Also confirm whether the install is Helm-managed, or a `helm upgrade` could wipe a kubectl patch.

### calico-apiserver memory leak crushes small control-plane nodes
**Symptom:** "Lots of memory alerts"; control-plane nodes at 94–97% while workers are fine.
**Cause:** `calico-apiserver` replicas running with `resources:{}` (no mem limit) leak to 1.4–1.9 GiB each (normal <150 Mi), pinned to the (often small, ~4 GiB) control-plane nodes.
**Fix:** Temporary relief: `kubectl delete pod -n <cni-ns> -l k8s-app=calico-apiserver` (operator recreates, frees memory). Permanent fix: set a memory limit via the operator CR (see above).

### Config-only migration repoints need every container incl. initContainers
**Symptom:** After `set image`, a pod shows `Init:ImagePullBackOff`.
**Cause:** `set image <main>=…` leaves initContainers on the old/purged image.
**Fix:** Name every container **and** initContainer in `set image`. Sweep before declaring done: `get sts -o jsonpath` over `.spec.template.spec.initContainers[*].image` + `.containers[*].image`, grep for the stale registry.
