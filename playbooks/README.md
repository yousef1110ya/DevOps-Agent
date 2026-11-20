# Playbooks — reusable Kubernetes diagnostics

A portable, vendor-neutral library of symptom-based runbooks so the **next** operator (human or
agent) diagnoses faster. Each file = one symptom → an ordered list of proven, **read-only**
commands (with `--context <CTX>`), what each reveals, and known gotchas.

## The symptom → playbook index idea

The goal is **triage-first, token-cheap** diagnosis. When you hit a symptom:

1. **Match the symptom to a playbook** in the table below (the "symptom → playbook" index).
2. **Run the ordered, read-only checks** in that playbook. They start with the cheapest, most
   decisive check (often a scan script) and fan out only if needed.
3. **Keep cluster-specific "usually the cause here" notes separate.** The playbooks here are
   *generic* — they work on any cluster. Anything specific to one of your clusters (its recurring
   symptom→cause, its quirks) belongs in your own **knowledge library** (`knowledge/`) under a
   **Check-first hints** heading, cross-linked from the relevant playbook. That keeps the runbooks
   reusable while the quirks stay per-cluster.

**Conventions**
- `<CTX>` = your own device's kubectl context name for the cluster (names differ per device;
  clusters are identified by **API server URL**, not context name). Other placeholders:
  `<namespace>`, `<pod>`, `<node>`, `<pvc>`, `<ns>`, `<HOST>`.
- Scan scripts live under `tools/scans/`; the operating rules live in `AGENTS.md`.
- `/media/data` appears as the example **shared data filesystem** mount on OpenEBS-hostpath clusters
  — **adjust it to your own mount**.

**Rules that still apply on every command**
- Every command must be **read-only** and carry `--context`. Steps that need node access (SSH,
  `debug node`, `exec`, node-shell writes) are destructive-by-policy — they're marked, and need owner
  approval before running (see the operating rules, `AGENTS.md`).
- When you improve a runbook, add the command that helped, note what it revealed, and keep the
  "check first" order accurate. Update the index below.

## Index

| Symptom | Playbook |
|---------|----------|
| Node/cluster disk usage high | [disk-usage-high.md](disk-usage-high.md) |
| Disk usage across ALL nodes (+ per-PVC breakdown) | [disk-usage-all-nodes.md](disk-usage-all-nodes.md) → `tools/scans/disk-usage-all-nodes.sh` |
| Percona MongoDB backup CR shows `error` | [psmdb-backup-error.md](psmdb-backup-error.md) |
| **Daily** check: are MongoDB (psmdb) backups healthy fleet-wide? | [mongodb-backups-daily-check.md](mongodb-backups-daily-check.md) → `tools/scans/mongodb-backups.sh` |
| Scan a cluster cheaply (triage-first) | [cluster-scan.md](cluster-scan.md) → scripts in `tools/scans/` |
| Backup CronJob failing (Error / ImagePullBackOff / stuck) | [backup-job-failing.md](backup-job-failing.md) |
| Cluster URL "not working" (ingress reachability, outside-in) | [url-not-reachable.md](url-not-reachable.md) |
| "Control plane down" / intermittent `TLS handshake timeout` (HA cluster, one cp node down) | [control-plane-node-down.md](control-plane-node-down.md) |
| Storm of `KubernetesPodCrashLooping` on unrelated pods (leader-election loss → usually slow etcd) | [leader-election-crashloop-storm.md](leader-election-crashloop-storm.md) |
| `NodeSystemSaturation` / high CPU on a node (compute vs disk-I/O; name top consumers) | [node-saturation.md](node-saturation.md) |
| "Cluster never sends any alerts" / distrust monitoring (usually a default `"null"` Alertmanager) | [no-alerts-firing.md](no-alerts-firing.md) |
| App deployment OOMKilled / memory leak (version-correlated — leaky tag vs fixed tag) | [device-mgmt-oom.md](device-mgmt-oom.md) |
| **Migrate a cluster to new infra** (config-first, no data; Velero + fixes; MUTATING ops) | [config-first-cluster-migration.md](config-first-cluster-migration.md) |
| **Create a single-node cluster** (reference profile: k8s v1.37 + Calico v3.28.1 + OpenEBS + ingress-nginx hostNetwork + cert-manager; all commands+manifests inline; MUTATING install) + **upgrading an existing single-node cluster** | [create-single-node-cluster.md](create-single-node-cluster.md) |
| **Upgrade a MULTI-NODE cluster** (HA-aware kubeadm: first-cp `apply` → other cp/workers `upgrade node`, drain/uncordon, version-skew, hostpath node-pinning downtime, etcd-quorum safety; MUTATING maintenance) | [upgrade-multi-node-cluster.md](upgrade-multi-node-cluster.md) |
| Weak CSP / missing security headers (find emitting layer, CDN override?, static-vs-SSR, report-only-first) | [security-headers-csp.md](security-headers-csp.md) |
| **Back up / restore a specific DB to/from S3** (mongodump→S3 + mongorestore; self-verifying; ready-to-fill prompts) | [db-backup-restore-to-s3.md](db-backup-restore-to-s3.md) |
| **Cert expiry / `kubeadm certs check-expiration`** (read-only: decode public certs off the CP node via node-shell) | [cert-expiration.md](cert-expiration.md) |
| Browser cert expired on a restored cluster; cert-manager renewals stuck | [ingress-tls-expired-after-restore.md](ingress-tls-expired-after-restore.md) |
| Wazuh "MISP IOC match (to_ids)" alert (rule 100702, level 14) — real vs false positive; empty-file-hash & FIM-symlink FP is the #1 cause | [misp-ioc-false-positive.md](misp-ioc-false-positive.md) |

_Add a row when you create a new playbook (e.g. pod-crashloop, node-notready, pvc-pending, oom-kills)._
