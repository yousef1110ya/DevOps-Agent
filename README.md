# DevOps — a portable, agent-agnostic cluster-ops workspace

A self-contained toolkit that lets **any** AI agent (or human) safely inspect and operate many
Kubernetes clusters through `kubectl` — with a read-only-by-default guard, full audit logging, a
library of hard-won operational lessons, symptom-based playbooks, and build kits for backups,
migrations, projects, and reports.

It is **not tied to any one assistant**: enforcement is plain `bash` hooks, knowledge is plain
Markdown, and tools/MCP servers are referenced by name. Point your agent at this folder and go.

## Start here
1. **[onboarding.md](onboarding.md)** — install the CLI tools + MCP servers (by name), wire the
   hooks into your harness, and (optionally) add a git remote to turn on team auto-sync.
2. **[AGENTS.md](AGENTS.md)** — the operating rules every agent must follow (the guard, read-only
   policy, `APPROVE_NEXT`, the CNI hard-guard, proof discipline, projects, reports).

## What's inside
```
AGENTS.md            operating rules (guards, read-only, APPROVE_NEXT, proof)
onboarding.md        install tools + MCP, wire hooks, activate git sync
tools/
  hooks/             guard.sh · logger.sh · git-sync.sh   (the enforcement)
  scans/             token-cheap read-only triage scripts
  settings/          example hook wiring (Claude Code + any harness)
knowledge/           reusable, vendor-neutral lessons (version gotchas, failure patterns, fixes)
playbooks/           symptom-based read-only diagnostic runbooks
templates/
  backup/            MongoDB/Postgres off-site backup CronJobs
  velero-migration/  from-scratch cluster-migration kit (+ what not to repeat)
  projects/          the project/operation scaffold (README/kb/log)
  reports/           Markdown → Word .docx rendering
cluster-kb/          (yours) per-cluster facts, keyed by API-server identity
commands-to-run/     (yours) owner-run one-off scripts
reports/             (generated) human .docx deliverables
logs/ audit/ state/  runtime: local full logs · shared audit trail · APPROVE_NEXT token
```

## Coverage — what this workspace knows

Every item below is backed by a file in here (a lesson in `knowledge/`, a runbook in `playbooks/`,
or a build kit in `templates/`) distilled from real production work — not a wish-list. Each lesson is
written **Symptom → Cause → Fix (with command) → Version note**.

### Kubernetes (core)
- **Cluster upgrades** — kubeadm one-minor-per-hop, the `CreateJob` preflight bypass, HA upgrade
  order, mid-upgrade version skew. `knowledge/kubernetes-upgrades.md`, `playbooks/upgrade-multi-node-cluster.md`
- **etcd** — slow-disk latency as the hidden root cause, `3.6→3.7` panic-on-existing-data, snapshot
  backup/restore (distroless image has no `tar`), quorum math on HA. `knowledge/control-plane-etcd.md`
- **Control plane** — leader-election crashloop storms (many unrelated controllers = one blip),
  "control plane down" triage, editing apiserver flags via a privileged Job (OIDC/audit).
  `playbooks/control-plane-node-down.md`, `playbooks/leader-election-crashloop-storm.md`
- **CNI / networking** — Calico/Tigera/flannel, operator-owned Deployments that revert hand-patches,
  the calico-apiserver memory leak, and the **hard rule never to mutate the CNI/infra layer**.
  `knowledge/cni-networking.md`
- **Workloads** — StatefulSet rollout stalls, `OnDelete` strategy, PodDisruptionBudgets, drains,
  node-pinned hostpath PVs, image version-skew crashes, `set image` incl. initContainers.
  `knowledge/node-operations.md`
- Single-node and multi-node cluster **builds from scratch**. `playbooks/create-single-node-cluster.md`

### Databases
- **MongoDB / Percona psmdb** — sharding + `mongos`, creating users through mongos, mutual-TLS
  client certs, the benign operator crashloop, backup-night file-descriptor / ENOSPC crashes.
  `knowledge/databases-mongodb.md`, `playbooks/psmdb-backup-error.md`
- **PostgreSQL / CloudNativePG** — barman-cloud backups, PITR recovery, the `serverName` empty-check
  gotcha, backup CronJob fixes (awscli, not the dead `mc`). `knowledge/databases-postgres.md`
- **Redis** — torn AOF after a disk-full, `redis-check-aof --fix`, `:latest` RDB-version skew.
- **RabbitMQ** — WAL corruption after ENOSPC. `knowledge/databases-redis-rabbitmq.md`
- Also encountered in migrations: **ClickHouse, MySQL/MariaDB, EMQX**. `knowledge/cluster-migration.md`

### Backups & disaster recovery
- Off-site **MongoDB→S3** (streaming `mongodump | aws s3 cp`, self-verifying, prune-to-N, notify) and
  **PostgreSQL→S3** CronJobs. `templates/backup/`
- PBM single-storage silent-fail (a green CR ≠ an object in the bucket), orphan reclaim with `mc`,
  the **"a status is not proof"** discipline, DR test method. `knowledge/backups-and-dr.md`,
  `playbooks/backup-job-failing.md`, `playbooks/db-backup-restore-to-s3.md`

### Velero & cluster migration
- A complete **from-scratch migration kit**: the 3-plane model (Velero = config only, app-native
  replication = DBs, object-store mirror = blobs, DNS flips last), target prerequisites,
  backup/restore scripts, the resource-modifiers ConfigMap, post-restore fixes, and a **14-item
  "what we did wrong, don't repeat"** guide. `templates/velero-migration/`, `knowledge/cluster-migration.md`

### Storage & object stores
- hostpath/local-path (no per-PVC quota), **per-PVC disk attribution with on-node `du`** (kubelet
  metrics lie on shared disks), ENOSPC aftermath. `knowledge/storage-and-disk.md`
- **MinIO / RustFS / S3-compatible** — `mc` reclaim traps (trailing slash, false-zero, async
  `.trash`), per-bucket sizing, erasure-set heal. `knowledge/object-stores.md`

### Observability & alerting
- **Prometheus** — corrupt-WAL vs `retention.size`, OOM-during-WAL-replay (raise memory, don't delete
  data), TSDB internals. `knowledge/prometheus.md`
- **Alertmanager** — the Discord 4096-char group-drop, control-plane scrape alert floods,
  `matcherStrategy` + blackhole routing, hostpath PV-filling noise. `knowledge/alerting.md`,
  `playbooks/no-alerts-firing.md`
- Also worked with: **Grafana, Loki, node-exporter**.

### Linux / node operations
- `df`/`du`, **PSI (`/proc/pressure`)** to separate compute- from I/O-bound saturation, `ulimit`/
  `nofile` and live `prlimit`, `systemd`/`journalctl` (UTC), `dmesg` OOM checks, kubelet/containerd,
  cert decoding with `openssl`. Read-only on-node access via `node-shell`. `knowledge/node-operations.md`,
  `tools/scans/disk-usage-all-nodes.sh`, `tools/scans/cert-expiry-decode.sh`

### Cloud & infra
- **AWS S3** (awscli, SigV4 reads, the old-MinIO multipart-checksum workaround), S3-compatible
  endpoints (MinIO / Ceph / R2), provider-to-provider cluster migration (why lift-and-shift VM clones
  corrupt k8s nodes → rebuild + data-migrate). `knowledge/cluster-migration.md`, `templates/backup/`

### Edge, ingress & TLS
- **nginx** load-balancer connection/worker exhaustion (both `worker_rlimit_nofile` and
  `worker_connections`), **ingress-nginx** `externalTrafficPolicy`, cert-manager / ingress TLS after
  a restore. `knowledge/load-balancers.md`, `playbooks/ingress-tls-expired-after-restore.md`,
  `playbooks/cert-expiration.md`

### Security & SIEM (the "Sec" in DevSecOps)
- The read-only guard, audit trail, and `APPROVE_NEXT` model itself. **Wazuh / MISP** IOC
  false-positives (the empty-file-hash trap), exposed **dev servers** in prod (Vite CVEs, safe
  file-read fingerprinting), **CSP / security-header** remediation, secrets-manager MCP usage (use a
  credential without ever seeing it). `knowledge/security-siem.md`, `knowledge/tooling-gotchas.md`,
  `playbooks/security-headers-csp.md`, `playbooks/misp-ioc-false-positive.md`

### Ways of working
- Triage-first scanning, projects/operations with a standing enumerated approval, Markdown→Word
  report rendering, and portable cross-device cluster identity (same cluster, different context
  names). `tools/scans/`, `templates/projects/`, `templates/reports/`

## The safety model in one paragraph
Every `kubectl` goes through `guard.sh`: only read-only verbs run freely, every cluster-talking call
must carry `--context`, and anything mutating is blocked unless the owner drops a single-use
`state/APPROVE_NEXT` token — except CNI/cluster-infra mutations, which are blocked **outright, even
with a token**. Read-only on-node access via `node-shell` is allowed. `logger.sh` records every
command: full output locally (gitignored, may contain secrets) and a metadata-only audit line that's
safe to share. Nothing here fabricates evidence — every finding carries the exact command and output.

## Requirements
`bash` + `jq` (hooks), `kubectl`, `git`, `velero` CLI (client), `node`+`npm` (reports). See
[onboarding.md](onboarding.md) for the full list and the install-when-needed extras.
