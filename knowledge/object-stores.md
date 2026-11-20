# Object stores (MinIO / S3-compatible)

Reusable DevSecOps lessons for sizing, reclaiming, and operating MinIO / RustFS / S3-compatible object stores on Kubernetes, including the `mc` quirks and async-trash reclaim behavior.

## Object stores (MinIO / S3-compatible): reclaim, trash, buckets

### MinIO is a top consumer → report per-BUCKET sizes, not just the total
**Symptom:** "The object store is using 140GB" — but which buckets?
**Cause:** A single total hides the actual driver (usually one backup bucket dwarfs the rest).
**Fix:** Two read-only ways:
```bash
# A. mc from inside the pod (needs exec; uses the pod's local alias/creds — never echo creds)
kubectl --context <context> -n <namespace> exec <minio-pod> -c minio -- mc du local/
# B. on-node du of the bucket dirs under the object-store PVC (read-only, no exec token needed) — prefer this
kubectl-node_shell --context <context> <node> -- du -xh -d1 /<shared-fs>/openebs/openebs/<minio-pvc-uuid> | sort -h | tail
```
**Note:** With erasure coding a bucket is sharded across all `data*` PVCs, so its *cluster* footprint ≈ per-node bucket du × number of data drives; `mc du` already reports the logical cluster total. These backup piles are usually database dumps (per-cluster backup buckets like `<db>-backup-<freq>`).

### Bucket-root `mc rm --recursive` needs a TRAILING SLASH or it deletes nothing
**Symptom:** `mc rm --recursive --force <alias>/<bucket>` errors `Requested path not found` and removes nothing — while the dry-run (`mc ls`/`mc find`) looked fine.
**Cause:** A bucket-root recursive remove requires a trailing slash: `<alias>/<bucket>/`. `mc ls`/`mc find` work without it, so the dry-run silently differs from the destructive run.
**Fix:** Always use `<alias>/<bucket>/` (trailing slash) on bucket-root `mc rm`.
**Note:** Delete both the dump directory **and** its sidecar manifest (e.g. `<timestamp>.pbm.json`); keep init markers like `.pbm.init`.

### NEVER trust a storage tool's own "after = 0 / done / removed" line — independently re-list
**Symptom:** A reclaim script prints "after = 0 B / 0 objects" (a full wipe), but the bucket is actually untouched (re-listed: still 145GiB / 2667 obj).
**Cause:** A `mc du || mc ls --summarize` fallback masked a `du` failure and errored mid-listing, printing a bogus `0`. A destructive op that silently no-ops while reporting success is worse than an error.
**Fix:** Verify every wipe/reclaim with an **object-count (or size) delta from a separate, independent read**, not the deleting tool's self-report.
**Note:** Minimal MinIO server images ship `mc`/`sh`/`head`/`cat`/`wc` but **NO `grep`/`awk`/`sed`/`tar`**. In-pod verification built on grep prints `command not found` and can emit a false "deletion failed" even on success. Emit RAW `mc` output from the pod and parse counts in the OUTER shell. (No `tar` also means `kubectl cp` fails — use `mc pipe` over stdin as the transport, one exec per file.)

### MinIO `mc rm` frees disk ASYNC via `.trash` — an immediate `df` looks flat or worse
**Symptom:** Right after `mc rm`, node `df` is unchanged (or momentarily *worse*), so the reclaim looks like it failed.
**Cause:** Deleted objects are **moved into `.minio.sys/tmp/.trash`** and a background janitor purges the blocks over the next few minutes. The bucket dir shrinks immediately, but `.trash` balloons and `df` doesn't drop until the janitor runs.
**Fix:** Don't conclude failure from an immediate `df`. Watch `.trash` drain, then re-check `df`:
```bash
du -xh -d0 <pvc-path>/data/.minio.sys/tmp/.trash   # balloons at delete, →few MB after purge
```
**Note:** Proven: deleting 3 snapshots → `.trash` 1.9G→24G with `df` flat; ~3 min later `.trash` 21G→3.7M and `df` dropped 98%→81% (~40G/node freed). Watch over *minutes, not seconds*. RustFS behaves the same (`.rustfs.sys/...`). Incomplete multipart orphans live separately in `.minio.sys/multipart` (not cleared by deleting the snapshot dir) — abort with `mc rm --incomplete --recursive --force <alias>/<bucket>/`; MinIO also auto-expires stale uploads ~24h.

### Operator-managed backup `keep=N` prunes only the CR, not orphaned S3 data — reclaim with `mc`, not the backup CLI
**Symptom:** `kubectl get <db>-backup` shows "3" backups but the bucket holds many GB more; retention isn't reclaiming the difference.
**Cause:** `keep=N` prunes only the Kubernetes backup CR, not always the physical S3 objects. Dumps whose CR was pruned while an S3 delete failed (e.g. during an ENOSPC window) + failed/partial dumps become **orphans** that `keep` never reclaims.
**Fix:** Confirm real size with on-node `du` of the bucket dir (not the CR count), then `mc rm` the orphan dirs from inside the object-store pod:
```bash
kubectl exec <minio-pod> -c minio -- sh -c 'export HOME=/tmp; set -a; . /tmp/minio/config.env; set +a; \
  mc alias set loc http://minio.<namespace>.svc.cluster.local "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"; \
  mc rm --recursive --force loc/<bucket>/<timestamp>/'
```
**Note:** The backup CLI's own `delete-backup --force` can silently no-op under an operator that reconfigures the storage pointer per task (reports `[done]` + the right size but frees nothing — it acts on the wrong storage). Never use its `--older-than` either: a merged `list` view spans multiple buckets (weekly/daily) and would nuke keepers. Durable fix = lower `keep` + TTL the source data; orphans recur after each ENOSPC/failed-prune window. (Credentials come from a mounted secret file inside the pod; never echo them.)

### RustFS `existingSecret` key names must be exact or it boots with DEFAULT creds
**Symptom:** Every S3 client (`mc`, DB backup agent, Loki) fails with `The Access Key Id you provided does not exist in our records`.
**Cause:** The RustFS helm chart injects `existingSecret` via `envFrom: secretRef`, so the **secret's key names become env var names verbatim**. RustFS reads its root credential only from `RUSTFS_ACCESS_KEY`/`RUSTFS_SECRET_KEY`; any other key names (e.g. `access_key`/`secret_key`) are silently ignored and it boots with default credentials.
**Fix:** Create the existingSecret with exactly `RUSTFS_ACCESS_KEY` and `RUSTFS_SECRET_KEY`, then restart with `strategy: Recreate` (single RWO `/data` PVC — a RollingUpdate deadlocks).
**Note:** A RustFS "`Faulty disk`"/`ErasureReadQuorum` verdict on PUTs is an *internal* erasure judgment (member corruption/desync), not a physical disk fault, and a restart can't repair it — use `mc admin heal -r` against the service; rebuild one member's data PV from parity only as a last resort and only if the other members are healthy.
