# Backups & DR

Generalized, reusable operational lessons for MongoDB/psmdb backups (PBM, multi-storage, off-site to S3) and the backup-verification / DR discipline on Kubernetes.

## MongoDB & psmdb backups (PBM, multi-storage, off-site to S3)

### psmdb collapses multiple backup storages to ONE PBM "main" storage → backups silently land in the wrong bucket
**Symptom:** The off-site/AWS bucket a daily task names stops receiving objects, yet `psmdb-backup` CRs for that task keep going `state=ready, error=null` with a cosmetically-correct `status.destination`. On-disk, a dump physically lands in a *different* task's bucket (e.g. a monthly dump inside the weekly bucket), leaving the named bucket empty — plus an un-prunable orphan in the wrong bucket (no CR there for `keep` to act on).
**Cause:** The operator + PBM keep a **single "main" storage** and the **most-frequent task re-pins it**. When tasks point at different storages (daily→AWS, 2h/weekly→MinIO), the lower-frequency task dumps to whatever the high-frequency task last pinned. The `ready` CR renders `destination` from the task's *declared* storage, not where the object actually went — a silent fail.
**Tells (read-only):** `pbm status` lists only ONE storage and shows the "other" task's snapshots inside it; operator prune logs `nothing to delete` for the mis-routed task (object isn't on the declared storage); agent log shows `backup finished` (the dump DID run — just to the wrong place).
**Fix:** For any psmdb cluster with multiple backup storages, verify the off-site copy with `pbm status` or by listing the actual bucket — **never** trust the CR. Durable fix = a **standalone `mongodump | aws s3 cp` CronJob** for off-site DR (decouples from the operator's single-storage limit) + alert on its failure. Proper fix = an operator/PBM version with real multi-storage profiles.
**Version note:** Seen with pbm-agent **v2.5.0** — no `pbm profile`/`config-profile` subcommand, i.e. no real multi-storage support.

### Standalone off-site MongoDB→S3 CronJob (the durable DR workaround to the single-storage limit)
**Symptom:** You need a guaranteed off-site/AWS copy independent of the operator's single-storage PBM behaviour.
**Fix:** Deploy an **additive** CronJob (never touch the operator's own backups) using stock containers, no custom image: `mongodump --archive --gzip` → FIFO → `aws s3 cp -` → notify. Read bucket/region/creds straight off the cluster's existing psmdb S3 storage secret. For rs-only clusters the dump host is `rs0/<member>:27017` (non-TLS); add a TLS block only if the cluster requires it. Size the job generously — a large logical dump can run ~1.5h, so set `activeDeadlineSeconds` to ~4h. A green run should be verified by the actual S3 object appearing.
**Discriminator — who needs it:** only clusters whose psmdb `spec.backup.storages` has a storage whose S3 `endpointUrl` is AWS-default (empty) or an **external** host — not an in-cluster `minio.*`/`rustfs.*` URL. Clusters that back up only to in-cluster object storage have no off-site bucket to reuse.

### Reclaim orphaned PBM backup objects with `mc` inside the object-store pod — `pbm delete-backup` no-ops under the operator
**Symptom:** `kubectl get psmdb-backup` under-reports disk (shows a few CRs while the bucket holds many dumps). Orphans accumulate after any ENOSPC/failed-prune window: dumps whose CR was pruned while the S3 delete failed, plus failed/partial dumps, which `keep=N` never reclaims (it prunes only the **K8s CR**, not always the physical S3 data).
**Cause:** `pbm delete-backup --force <name>` reports `[done]` + the right size but frees nothing — the operator reconfigures PBM's single main-storage pointer per task, so the ad-hoc delete acts on the wrong storage. Never use `pbm delete-backup --older-than` either: `pbm list` is a merged view across buckets so it can nuke keepers that live in other buckets.
**Fix:** Delete directly with `mc` from **inside** an object-store pod. Root creds aren't in the container env and mc can't write `/.mc`, so source them from the mounted secret file and point `HOME` at a writable dir:
```
kubectl exec <minio-pod> -c minio -- sh -c \
 'export HOME=/tmp; set -a; . /tmp/minio/config.env; set +a; \
  mc alias set loc http://minio.<namespace>.svc.cluster.local "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"; \
  mc rm --recursive --force loc/<bucket>/<timestamp>/'
```
Delete the dump dir **and** its `<timestamp>.pbm.json`; keep `.pbm.init`. Verify with an independent on-node `du`/`df`, not mc's own "Removed" lines. Durable fix = lower `keep` + TTL the source data.

### `mc rm` traps: trailing slash, false-zero, async trash, minimal image
**Symptom:** A storage reclaim appears to succeed ("after = 0 B / 0 objects", or "Removed") but the bucket is untouched, or `df` looks flat/worse right after.
**Causes & fixes:**
- A bucket-**root** recursive remove needs a **trailing slash**: `<alias>/<bucket>/`. Without it, `mc rm --recursive --force` errors `Requested path not found` and deletes nothing (while `mc ls`/`mc find` work without the slash, so the dry-run looks fine).
- **Never trust the deleting tool's own "after=0/empty" line.** Independently re-list (object-count delta from a separate read) before claiming a wipe worked.
- `mc rm` frees disk **asynchronously**: objects move to `.minio.sys/tmp/.trash` and a background janitor purges blocks over **minutes**. Immediately after a delete the bucket `du` drops but `.trash` balloons and `df` is unchanged or momentarily worse. Watch `.trash` drain, then re-check `df` — don't call the reclaim failed from an immediate `df`. (RustFS behaves the same under `.rustfs.sys/`.)
- The minimal object-store server image ships `mc`/`sh` but **no `grep`/`awk`/`tar`** — in-pod verification built on grep prints "command not found" and can emit a false "deletion failed". Emit raw `mc` output and parse counts in the **outer** shell.
- Incomplete multipart orphans live in `.minio.sys/multipart` (not cleared by deleting the snapshot dir) — abort with `mc rm --incomplete --recursive --force <alias>/<bucket>/`; add a lifecycle rule to auto-abort them.

### A silently-stalled psmdb operator is a multi-day backup gap — restart the operator, then watch for a *downstream* fault
**Symptom:** Backup cron keeps creating CRs but they have a completely empty/null `.status` (no state, no error); no new `ready` daily for days. The operator pod is `Running` with **0 restarts** but its reconcile loop is **frozen**.
**Cause:** The reconciler stopped — the diagnostic tell is "operator pod up + zero recent log lines": `logs deploy/<operator> --tail=1 --timestamps` shows a stale timestamp (hours/days old). It does not self-heal.
**Fix:** `rollout restart deploy/<psmdb-operator>` (destructive → owner approval). Then **don't stop there** — a stall is often stacked faults: after the operator is healthy, check the PBM `backup-agent` + object-store logs. Downstream blockers seen: the S3 target returning HTTP 503 (wedged object store → rolling-restart its StatefulSet), or a degraded erasure set reporting `InternalError: Faulty disk` (HTTP 500) on PUTs, which a restart **cannot** repair → needs an admin heal (`mc admin heal -r --dry-run`), last-resort rebuild one member's data dir from parity only if the other members are healthy. Always confirm a fresh `ready` daily actually lands afterward, watching **minutes not seconds**.

### Migrated/restored clusters often have a `ready` Mongo but ZERO working backups — make it a cutover checklist item
**Symptom:** After a config-only (e.g. Velero) migration, the target has a `ready` psmdb with scheduled tasks but no `ready` backup on any storage.
**Cause:** The config restore doesn't carry a working PBM backup path. Three signatures: (a) missing S3 cred secret → all CRs `error`; (b) stuck `requested`/`waiting` with `create pbm object: ... must have at least 1 host`; (c) `SCRAM-SHA-1 (AuthenticationFailed)` because the PBM backup user wasn't restored. Often `backup.enabled=false` at spec too.
**Fix (per target):** recreate the PBM S3 cred secret(s), restore/create the PBM backup user, set `backup.enabled=true`, then confirm a fresh `ready` daily. Treat it as a Phase-3 cutover checklist item — a *live* cluster in this state has no backups at all.

### Daily automated backup-health scan — and its false-flag traps under fleet load
**Symptom:** You need to catch silent backup stalls within a day (stalls have gone ~6 days unnoticed = a data-loss risk).
**Fix:** A read-only scan that flags `[!]` when the newest `ready` backup is older than a threshold (default 36h = daily cadence + grace), or backups are disabled / no task / stuck CRs / cluster not ready. An errored CR next to a fresh `ready` one is `[i]` (operator false-positive), not a gap.
**Gotchas:** (1) Weekly-only clusters need a higher threshold (e.g. `MAX_AGE_HOURS=72`) or they false-flag daily — record the per-cluster threshold. (2) Under fleet load, slow clusters time out and get **misclassified** two ways: the backup list returns empty → false `[!] total=0`, and the operator-discovery probe errors → false `[i] "no operator"` = a **silent SKIP** that drops a healthy cluster from coverage (the dangerous one). Mitigate with a longer request timeout (≥60s) and a retry on **both** the probe and the list; always re-confirm any `[!]`/skip with a scoped re-run before alarming.

## Backup verification & DR (the "a green CR is not proof" discipline)

### A `ready`/`Complete` backup status is NOT proof the object exists in the named bucket
**Symptom:** CRs/Jobs look green but the DR copy is missing, stale, or in the wrong bucket.
**Cause:** Multiple ways a green status lies: the psmdb single-storage re-pin writes the dump to a *different* bucket while rendering `destination` from the declared storage; a backup job that no-ops (dead tool download) still "succeeds"; a `ready` CR can render cosmetically from spec rather than from a confirmed upload.
**Fix (the discipline):** Verify the actual object, not the status. For psmdb off-site DR, use `pbm status` or list the real bucket. For job-based backups, confirm the S3 object appeared (list the key, check size > 0). Make the backup job **self-verifying** — abort on a missing/empty source DB (`listDatabases`) and on an empty archive after dump, so there's no silent empty backup or no-op restore.

### Don't delete an errored psmdb backup CR to "clean up" — the finalizer can delete real S3 data
**Symptom:** You want to tidy away `error`-state CRs.
**Cause:** A psmdb-backup CR may carry finalizer `percona.com/delete-backup`; deleting the CR can remove the S3 data of a snapshot that **actually succeeded** (many `error` CRs are operator false-positives whose dump finished).
**Fix:** Before calling an `error` CR a real failure, confirm the **data path**: check `status.error`/timing (a connection-type error only seconds after `start` is usually the operator's own poll connection, not the dump) and grep each replset's `backup-agent` logs for `backup finished` / `mongodump finished`. "corruption found in archive" / "upload multipart failed" is often a truncated S3 upload — read to the end of `status.error` for the real `caused by:` (`QuotaExceeded`/`403` = bucket full, `no space left` = backend full, `AccessDenied`/`SignatureDoesNotMatch` = bad creds). Only treat as a real failure when no `backup finished` appears. Deleting non-terminal `waiting`/`requested`/empty CRs (no `status.start`/`destination`, no data to lose) is the correct way to break the SmartUpdate⇄backup deadlock.

### A clean backup scan proves recency, not restorability — test restores deliberately
**Symptom:** You rely on a green daily scan as DR assurance.
**Cause:** A clean scan is *evidence of* recent successful backups, not proof a restore works.
**Fix:** Periodically test a real restore (deliberately, not daily, since `pbm status`/`pbm list` via `exec` and a restore Job are destructive-by-policy). Restore **safely first**: into a suffixed DB (`RESTORE_SUFFIX=-restore`) or a temp recovery cluster, verify row/table/object parity against the source, *then* do the real restore. Backup uses the read/**backup** user; restore needs the **database-admin** (write) user. Keep restore defaults safe (no `--drop`, original names) and expose `DROP`/`RESTORE_SUFFIX`/`ARCHIVE_KEY` as knobs.
