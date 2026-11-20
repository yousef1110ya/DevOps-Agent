# Database off-site backup templates (vendor-neutral)

Reusable, provider-agnostic Kubernetes CronJob templates that stream a database dump straight
to S3-compatible object storage for **off-site disaster recovery**. Distilled from real
production CronJobs. Every specific value (namespace, image, host, bucket, region, secret) is a
`<PLACEHOLDER>` — nothing company/cluster/host-specific is baked in.

## What's here

| Template | Engine | Shape | Use when |
|----------|--------|-------|----------|
| `mongodb-offsite-s3/cronjob.yaml` | MongoDB (mongodump) | 3 containers: dump → upload → notify, via an in-pod FIFO | You run MongoDB (plain or operator-managed, e.g. Percona psmdb) and want a **self-contained off-site copy** that streams with nothing staged on disk, plus success/failure notification. |
| `postgres-offsite-s3/cronjob-apt.yaml` | PostgreSQL (pg_dump) | 1 container: `apt-get install awscli` then `pg_dump | aws s3 cp -` | Postgres cluster where the pod **can reach the apt mirror** (egress open). Simplest shape. |
| `postgres-offsite-s3/cronjob-two-image.yaml` | PostgreSQL (pg_dump) | 2 images: `postgres` initContainer dumps to an `emptyDir`, `amazon/aws-cli` uploads | Postgres cluster where **apt egress is blocked** (the stock image can't install awscli). Also the more robust default. |

Each template carries a header comment listing every placeholder. `mongodb-offsite-s3/` also
ships an `apply.sh` wrapper; see each folder's `README.md` for engine-specific guidance.

## Design principles (why every template looks like this)

1. **Stream, don't stage.** Pipe the dump straight to the uploader (Mongo: through an in-pod
   FIFO; Postgres apt shape: `pg_dump | aws s3 cp -`). The two-image Postgres shape stages to a
   small `emptyDir` only because apt is blocked — not because staging is desirable. Never write
   the dump to the node's real disk; a big dump can fill `/` and take the node down.
2. **Self-verify the object exists and is non-empty.** A green pod is **not** proof of a good
   backup. After uploading, re-list the object (`aws s3 ls`) and confirm the dump tool's own
   exit code was `0` before declaring success. Never call a truncated stream a success.
3. **Abort on an empty / missing source.** If the dump produced nothing (DB gone, auth failed,
   dump tool errored), fail loudly — never upload a 0-byte "backup" that looks fine until a real
   restore.
4. **Retention / prune to N.** Keep only the newest N copies (timestamped prefixes) and prune the
   rest in the same run, so the bucket doesn't grow without bound. Prune **after** the new copy is
   verified present, never before.
5. **Notify on success AND failure.** Send a message on both outcomes (the Mongo template posts a
   colored embed to a chat webhook). A backup system that's silent on failure is worse than none —
   you learn it was broken only during a real DR.
6. **Bake tools into an image — never `curl` a binary at runtime.** Use an image that already has
   the tool (`amazon/aws-cli`, `public.ecr.aws/aws-cli/aws-cli`, the stock `postgres`/`mongo`
   image), or `apt-get install` from a distro mirror. **Do not** `curl https://.../somebinary` at
   runtime: upstream URLs die (a dead URL returns an HTML error page that gets saved *as* the
   "binary", and the upload then silently no-ops). Pin the dump-tool image to the **live server
   version** so the dump restores cleanly.
7. **`set -e` (fail fast) + guard rails on the Job.** Every script starts with `set -e`
   (`set -euo pipefail` where the shell supports it). On the CronJob: `concurrencyPolicy: Forbid`
   (never two dumps at once), `startingDeadlineSeconds` (a missed run still fires), an
   `activeDeadlineSeconds` hard cap, and a small `backoffLimit` (1–2) so a broken run doesn't pile
   up pods and starve the node.

## Known version gotchas

- **Old MinIO (and some S3-compatible stores) reject aws-cli's newer multipart checksum.** A
  recent aws-cli sends a default checksum on `CreateMultipartUpload` that older MinIO builds
  reject (`invalid/unknown checksum`), so the upload fails. Fix, present in every Postgres
  template: force single-part + disable the new checksum —
  ```sh
  export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
  aws configure set default.s3.multipart_threshold 4GB
  ```
  Real AWS S3 doesn't need this, but it's harmless there, so the templates set it unconditionally.
  (The Mongo template streams one object with an `--expected-size` hint rather than many parts; if
  you point it at an old MinIO and hit the checksum error, add the same two lines to its upload
  container.)
- **`curl`-a-binary-at-runtime is a trap (see principle 6).** The original real-world job this was
  distilled from `curl`ed a client binary from a URL that had gone HTTP 410; the error page got
  saved as the binary and backups silently no-op'd for weeks. Use a tool-bearing image instead.
- **Operator single-storage limitation is WHY the standalone Mongo job exists.** Database operators
  that drive backups (e.g. the Percona psmdb operator on PBM ≤ 2.5.0) can point at only **one**
  storage at a time. When the most-frequent operator task re-pins that one storage to an in-cluster
  bucket, a lower-frequency "off-site" task silently lands in the **wrong** store while its status
  still shows `ready`. A green operator backup CR is **not** proof of an off-site copy. This
  standalone CronJob takes off-site DR out of the operator's hands — it dumps and uploads itself, so
  the off-site copy is independent of whatever the operator's single storage pointer currently is.
- **`mongodump` host: mongos for sharded, an rs member for a replica set.**
  - **Sharded** cluster → dump through a **mongos** router
    (`<release>-mongos-0.<ns>.svc.cluster.local:27017`); it captures every shard.
  - **Replica-set-only** (no mongos) → dump against an **rs member**
    (`<release>-rs0-0.<release>-rs0.<ns>.svc.cluster.local:27017`), ideally a secondary
    (`--readPreference=secondaryPreferred`) to spare the primary.
  Using an rs member on a sharded cluster captures only that shard — a partial, silently-wrong
  backup.
- **Pin the dump-tool image to the live server version** (Mongo: `.spec.image` of the DB; Postgres:
  the running server major). A dump taken with a mismatched major may not restore into the target.

## Security + operational notes

- **Secrets only via `secretKeyRef` / `envFrom` → secretRef.** Never inline an access key, DB
  password, or webhook URL into the YAML (these templates reference secrets by name only). Create
  the referenced secrets out of band.
- **Applying a CronJob is a mutating action.** In a guarded workspace it needs the owner's explicit
  approval and a single-use approval token (`APPROVE_NEXT`), and must be applied **from a file**
  (`kubectl --context <CTX> apply -f file.yaml`) — the heredoc form (`apply -f - <<EOF`) is blocked
  by the guard. Every `kubectl` in the helper scripts carries `--context <CTX>` explicitly.
- **Verify with a test run.** After applying, trigger one immediate run
  (`kubectl --context <CTX> -n <NS> create job --from=cronjob/<name> <name>-test-<ts>`), watch it,
  and confirm the object landed — don't wait for the first scheduled fire to discover it's broken.
