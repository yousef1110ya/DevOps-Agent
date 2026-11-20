# knowledge/ — reusable, vendor-neutral operations lessons

Hard-won lessons distilled from real production incidents and projects, generalized so any team can
apply them on their own infrastructure. **Read the relevant file before investigating** (AGENTS.md
rule 8) — if your symptom is a known pattern, verify that cause first.

Each lesson follows **Symptom → Cause → Fix (with command) → Version/Note**. Placeholders like
`<context>`, `<namespace>`, `<pod>`, `<node>`, `<pvc>`, `<bucket>` stand in for your specifics.

| File | Covers |
|------|--------|
| [kubernetes-upgrades.md](kubernetes-upgrades.md) | kubeadm one-minor-per-hop, etcd upgrade races & version traps, HA upgrade order, preflight bypass |
| [cni-networking.md](cni-networking.md) | never mutate CNI/infra, operator-owned CNI reverts, calico-apiserver leak, initContainer repoints |
| [control-plane-etcd.md](control-plane-etcd.md) | crashloop storms = leader-election/slow-disk, HA "control plane down" triage, apiserver flag edits |
| [node-operations.md](node-operations.md) | compute vs iowait, saturation stalls vs OOM, drain/PDB traps, hostpath node-pinning, version-skew crashes |
| [storage-and-disk.md](storage-and-disk.md) | disk triage, per-PVC attribution (du not kubelet metrics), ENOSPC aftermath, hostpath no-quota |
| [object-stores.md](object-stores.md) | MinIO/S3 reclaim, `.trash` async delete, trailing-slash + false-zero traps, per-bucket sizing |
| [databases-mongodb.md](databases-mongodb.md) | psmdb sharding/mongos users, mutual TLS, operator crashloop benign, FD/ENOSPC backup-night crashes |
| [databases-postgres.md](databases-postgres.md) | CNPG/Postgres backup jobs (awscli not mc), stale failed-Job cleanup, barman recovery serverName gotcha |
| [databases-redis-rabbitmq.md](databases-redis-rabbitmq.md) | torn AOF/WAL after ENOSPC, `redis-check-aof --fix`, `:latest` RDB version skew |
| [backups-and-dr.md](backups-and-dr.md) | PBM single-storage silent fail, standalone off-site S3 CronJob, "a green CR is not proof", DR test discipline |
| [prometheus.md](prometheus.md) | corrupt WAL vs retention.size, OOM-during-replay → raise mem not delete data |
| [alerting.md](alerting.md) | Discord 4096 drop, control-plane scrape floods, matcherStrategy/blackhole routing, hostpath PV noise |
| [cluster-migration.md](cluster-migration.md) | 3-plane model, rebuild-not-lift-and-shift, Velero config-only traps, cutover gotchas |
| [load-balancers.md](load-balancers.md) | edge nginx connection/worker exhaustion (both knobs), monitor the LB tier |
| [tooling-gotchas.md](tooling-gotchas.md) | guard-bypass via scripts/`--raw`, kubeconfig Windows `;` separator, apply-heredoc block, mc traps |
| [security-siem.md](security-siem.md) | empty-hash IOC false positive, exposed dev servers, weak CSP remediation |

> Keep these **generalized** — strip cluster/host/secret specifics when you add a lesson, so it
> travels. Cluster-specific facts go in your own `cluster-kb/` instead (AGENTS.md rule 4).
