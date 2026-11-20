# PostgreSQL / CNPG

Generalized, reusable operational lessons for PostgreSQL and CloudNativePG (CNPG) backups on Kubernetes.

## PostgreSQL / CNPG backups

### Backup jobs that fetch a tool at runtime break silently when the download URL dies
**Symptom:** Postgres backup CronJobs "succeed" but uploads silently no-op / produce no object; or the job logs `<tool>: not found`.
**Cause:** The job `curl`s a client binary at run time (e.g. MinIO `mc` from a download host) and that URL now returns 404/410 — the error page gets saved **as** the binary, so the upload no-ops. The job often lacks `set -e`, so the failed download doesn't abort it.
**Fix:** Don't fetch tools at run time — bake the tool into an image in a registry you control, and add `set -e` so a failed step aborts the job (no silent empty backup). The proven working Postgres→object-store path is **awscli → `aws s3 cp`** (S3-compatible), in one of two shapes:
- **A (apt):** one `postgres:<major>` container, `apt-get install -y awscli` (where apt egress is open).
- **B (two-image, no-apt):** a `postgres` initContainer `pg_dump`s to an emptyDir → an `amazon/aws-cli` container uploads (use where apt is blocked; more robust).
**Version note:** Against older MinIO server builds you **must** disable aws-cli's default multipart checksum or the PUT is rejected: `export AWS_REQUEST_CHECKSUM_CALCULATION=when_required` and `aws configure set default.s3.multipart_threshold 4GB` (force single-part). Also `aws s3 mb "s3://$BUCKET" || true`, pin `postgres:<live CNPG major>`, and harden (`concurrencyPolicy: Forbid`, deadlines, `backoffLimit: 2`). Note: a replacement `mc` init-image (e.g. `quay.io/minio/mc:latest` or `minio/mc`) is **not** a working fix — those images are gone (401/404).

### "Jobs still failing" right after a backup fix is usually STALE failed Job objects, not a regression
**Symptom:** After fixing a backup CronJob, alerts still fire on failed jobs.
**Cause:** A fixed CronJob doesn't delete the `Failed` Job objects from *before* the fix. K8s keeps them and alerts fire on their existence; `failedJobsHistoryLimit:N` only evicts a failed job when a *newer* failure replaces it — so once backups succeed, the last pre-fix failure lingers forever.
**Fix:** Diagnose before reapplying: confirm the live cronjob spec is still the fix (catches GitOps reverts) and the last 3 scheduled runs are `Complete 1/1`; on each lingering failed job, check `creationTimestamp` predates the fix and `.status.failed` is the *old* backoffLimit (e.g. 7 vs the fix's 2) → pre-fix. Remedy = **delete the stale objects**, not another apply. Always `get cronjobs -A` first — weekly/monthly siblings and `default`-namespace jobs are easy to miss, and live jobs are often not where the repo says.

### CNPG barman-cloud to object storage can be the *sole* surviving copy — and restore has a serverName gotcha
**Symptom:** After a source cluster is deleted, the only copy of the Postgres data is the CNPG barman-cloud backup in object storage.
**Fix (verify, read-only):** List the bucket with a SigV4 read (a dependency-free script if no aws/mc/rclone is available). Barman `serverName` = the CNPG cluster name; find the latest **base backup** date and the latest **WAL** timestamp → PITR window is up to the last archived WAL. Retention won't prune once the source is gone (frozen archive) — copy it defensively. Watch for standalone sidecar DBs (e.g. a separate keycloak/temporal Postgres) that are **not** under the same barman prefix and may be uncovered.
**Fix (recover):** Apply a temp CNPG cluster with `bootstrap.recovery` from the ObjectStore (same `serverName`, **no `spec.plugins`** so it never archives back), PITR to latest (omit `recoveryTarget`) → `pg_dump -Fc --no-owner --no-acl` → `pg_restore` into the live cluster. Tear down the recovery cluster after.
**Version note / gotcha:** When **re-enabling** backups on a cluster whose bucket already holds a *different-systemid* history, CNPG's wal-archive empty-check rejects a prefix that already has WALs → use a **fresh `serverName`** (same bucket, new prefix), keeping the old chain as fallback. Adding the barman plugin is a rolling restart (pods 1/1→2/2).
