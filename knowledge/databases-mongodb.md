# MongoDB / Percona psmdb

Generalized, reusable operational lessons for running Percona Server for MongoDB (psmdb) — operator, sharding, TLS, and users — on Kubernetes.

## MongoDB / Percona psmdb (operator, sharding, TLS, users)

### Create app users through mongos on a sharded cluster, never direct to a shard
**Symptom:** A Mongo user works when you port-forward straight to an `rs0` shard member, but fails with `Authentication failed` through the `mongos` endpoint. `usersInfo forAllDBs` via mongos shows only the ~5 psmdb system users (backup, clusterAdmin, clusterMonitor, databaseAdmin, userAdmin).
**Cause:** `mongos` authenticates against the **config servers**. A user created directly on a shard exists only on that shard, so mongos (reading the config-server copy) never sees it.
**Fix:** Create app users through mongos: `db.getSiblingDB("admin").createUser(...)` connected to the mongos endpoint. A stray shard-local copy is harmless — mongos uses the config-server copy.

### psmdb TLS is mutual TLS — a plain `--tls` with no client cert is silently dropped
**Symptom:** A TLS connection to an exposed psmdb endpoint "hangs"/drops with nothing logged by the LB/nginx, even though `openssl s_client` handshakes fine and prints the cert (misleading).
**Cause:** mongos is `preferTLS` (plaintext also works) but **requires a client certificate** for any TLS connection. mongod drops a certless TLS connection (`connection ... closed`). The self-signed server cert's SANs are internal only, so external clients also fail hostname validation.
**Fix:** Supply the client cert + key + CA (in psmdb these live in secret `<cr>-ssl`: `tls.crt`/`tls.key`/`ca.crt`) and add `--tlsAllowInvalidHostnames` for external clients. These endpoints serve the self-signed cert even when exposed — there is no public/LE cert on Mongo.
**Version note:** Observed with the Percona psmdb operator exposing mongos via NodePort behind an nginx `stream` passthrough.

### psmdb-operator `KubernetesPodCrashLooping` is a benign Go data race, not a Mongo fault
**Symptom:** `KubernetesPodCrashLooping` alert for the `*-psmdb-operator-*` pod; pod is `1/1 Running` with a modest restart count (~1 / few days). `--previous` log ends in `fatal error: concurrent map read and map write` → panic → exit 2 → auto-restart.
**Cause:** A data race in the operator's controller-runtime reconcile loop, triggered by **etcd latency** (bursts of `etcdserver: leader changed` / `request timed out` / `Failed to update lock optimistically` right before the crash). The MongoDB StatefulSets (`rs0`/`cfg`/`mongos`) keep running and backups stay current throughout.
**Fix:** Don't treat it as a Mongo outage. Confirm: `describe pod` (LastState Terminated/Error exit 2) + `logs ...operator --previous | grep -i 'fatal\|leader changed'`, then verify data pods Running and backups `ready`. The real thing to watch is the underlying **etcd slow-disk latency**, not the operator restarts. Optional permanent fix: bump the operator image to a version with the data-race fix.
**Version note:** Seen with controller-runtime v0.18.4 inside the psmdb operator.

### Backup-night `KubernetesPodCrashLooping` at a fixed time can be mongod file-descriptor exhaustion
**Symptom:** A daily `KubernetesPodCrashLooping` for `rs0-N` members that fires→resolves at the same clock minute each night (rotating between members), with the RS briefly going `initializing` and that night's backup CR erroring as a side effect.
**Cause:** The nightly PBM logical backup floods connections → mongod logs `Too many open files` (tens of thousands of times) → WiredTiger panic (`__wt_panic_func → abort`), `exitCode 14`. Backup failure is a **consequence**, not a second bug. Once the connection ceiling is low, *any* connection spike (nightly dump **or** morning traffic ramp) trips it.
**Cause detail:** The 1024 soft `nofile` is the **containerd/OCI per-container default**. Go binaries auto-raise soft→hard (so they mask it); **C++ mongod does not self-raise** and its entrypoint has no `ulimit`, so mongod stays at soft 1024 (idle ~425 FDs → ~600 new conns crashes it). Host/kernel is not the limit (`fs.file-max` unlimited). mongod prints no "soft rlimit too low" warning, so read `/proc/<pid>/limits` before prescribing.
**Fix:** Raise the mongod container's **soft** `nofile` (hard is already large, e.g. 524288 → set soft ≥64000). The operator owns the STS and reverts a `command` wrapper, the CR has no ulimit field, and k8s/containerd have no clean per-container ulimit knob — so the proven non-destructive fix is `prlimit` on the live mongod PID (1024→64000, zero restart) plus a privileged hostPID enforcer DaemonSet to persist it across restarts. Fixing the crash also unblocks the nightly backups.

### Co-locating mongod `/data/db` on the same disk the backup dump fills causes a self-inflicted ENOSPC crash loop
**Symptom:** On backup nights (especially when weekly + daily/monthly fire together) mongod members crash `exitCode 14` with `FileStreamFailed: Failed to write … /data/db/diagnostic.data/...`; cluster goes `status=initializing`; the operator then refuses both tasks (`allowUnsafeConfigurations must be true … status initializing`). Self-recovers once the disk drains.
**Cause:** mongod's data PV is `openebs-hostpath` with `.spec.local.path` on the same shared drive the nightly dump writes to (e.g. a ~23G dump on a shared drive). The dump peaks the filesystem to ~100% → mongod ENOSPC → exit 14 → cluster not-ready → backups refused. A classic self-inflicted loop.
**Fix:** Move mongod `/data/db` **off** the backup/shared drive (separate openebs basePath/disk) so a full backup drive can't ENOSPC the DB. Also shrink the nightly footprint (lower `keep`, reduce replica dump fan-out) and/or grow the drive. This is distinct from the FD-exhaustion crash above despite both being exit-14 backup-night crashes — verify which by reading the `--previous` log (`FileStreamFailed`/ENOSPC vs `Too many open files`).
