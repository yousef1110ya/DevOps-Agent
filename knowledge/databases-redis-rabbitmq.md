# Redis & RabbitMQ

Generalized, reusable operational lessons for Redis AOF and RabbitMQ WAL corruption after a disk-full (ENOSPC) event on Kubernetes.

## Redis & RabbitMQ (AOF/WAL corruption after disk-full)

### After an ENOSPC disk-full, most DB pods self-heal but a torn Redis AOF / RabbitMQ WAL stays corrupt
**Symptom:** A node's data drive fills to 100% (ENOSPC); every stateful pod with a PV there crash-loops with `No space left on device` (mongod `WT_PANIC`, rabbitmq `{badmatch,{error,enospc}}`, etc.). Freeing space fixes **most** of them (Mongo, Postgres/CNPG, RabbitMQ, EMQX recover on their next backoff retry).
**Cause:** A log/AOF/WAL that was torn mid-write does **not** self-heal once space is free.
**Fix (Redis):** `redis-check-aof --fix <appendonlydir>/appendonly.aof.manifest` (it truncates only the torn tail; replicas usually have no corruption and re-sync once the master is up). On bitnami the binary is at `/opt/bitnami/redis/bin/redis-check-aof` — **not on PATH**, so a "command not found" is a red herring, not a missing binary.
**Repair pattern (OpenEBS-hostpath, node-local RWO PV):** scale the owning STS to 0 to release the PV → launch a throwaway pod pinned to that node (`nodeSelector kubernetes.io/hostname: <node>`) mounting the PVC → back up the corrupt file → repair → delete pod → scale STS back to 1 → poll `get` until `1/1` (don't rely on `kubectl wait` if a guard blocks it).

### A repointed `bitnamilegacy` Redis crashing on `RDB format version 15` is image version skew, not data loss
**Symptom:** After repointing `bitnami/redis:latest` → `bitnamilegacy/redis:latest`, Redis CrashLoops: `Reading RDB base file on AOF loading… Can't handle RDB format version 15 … appendonly.aof.*.base.rdb, AOF loading aborted` (replicas then crash only because the master is down).
**Cause:** `:latest` version skew, **not** corruption. The old manifest's `bitnami/redis:latest` is a newer Redis (Redis Stack 8.x) that booted once on the fresh empty PVC and wrote an **RDB v15** AOF; `bitnamilegacy/*:latest` is a frozen older snapshot that can't read v15. In a config-only migration the "data" is just the target's own disposable first-boot scratch.
**Fix:** For an empty-but-running instance, **wipe** the master's volume — `scale sts redis-master 0` → `delete pvc redis-data-redis-master-0` → `scale … 1`, then delete the crashlooping `redis-replicas-*` pods (emptyDir, they re-sync from the fresh master). To prevent it, pin an explicit `bitnamilegacy/redis:<major>-…` tag matching the source's running **major** version rather than `:latest`.
