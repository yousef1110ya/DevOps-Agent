# PostgreSQL off-site backup → S3

Two shapes of the same idea — `pg_dump` to an S3-compatible bucket on a schedule, for
off-site disaster recovery. Pick by whether the pod can reach the apt mirror.

| File | Shape | Images | Pick when |
|------|-------|--------|-----------|
| `cronjob-apt.yaml` | **A — apt, single container** | `postgres:<major>` only | The pod **can reach the apt mirror** (egress open). Simplest; streams `pg_dump | aws s3 cp -`, nothing staged. |
| `cronjob-two-image.yaml` | **B — two-image, no apt** | `postgres:<major>` initContainer + `amazon/aws-cli` | **apt egress is blocked** (e.g. `deb.debian.org 403`). Also the more robust default — both images already carry their tool. Stages to a small `emptyDir`. |

## How to pick A vs B

- **Start with B if you're unsure.** Nothing is installed or downloaded at runtime (both images
  ship their tool), so it can't be broken by a blocked or flaky package mirror. The only cost is a
  small `emptyDir` to stage the dump — size `<EMPTYDIR_LIMIT>` above the uncompressed dump.
- **Use A when apt egress is known-good and you want the leanest manifest.** It's one container and
  streams the dump straight through (`pg_dump | gzip | aws s3 cp -`), staging nothing. But if the
  cluster blocks the Debian mirror, the `apt-get install -y awscli` step fails and the whole job
  fails — that's the exact situation that forces B.

## `pg_dump` vs `pg_dumpall`

- Both templates dump a **single database** (`pg_dump <DB_NAME>`). That's the common case and what
  restores cleanly into one DB.
- Use **`pg_dumpall`** only if you need the **entire cluster including globals** (roles,
  tablespaces, grants). It takes no DB name and must run as a superuser. If you switch to it, drop
  the `<DB_NAME>` argument and name the object something cluster-wide (e.g.
  `out-cluster-${TS}.sql.gz`). For most off-site DR of one app DB, stick with `pg_dump`.

## Pin the Postgres major to the LIVE server

`<PG_MAJOR>` **must** match the running server's major version. A dump taken with a mismatched
`pg_dump` major may fail to restore into the target. Postgres majors drift across a fleet (16 / 17
/ 18 are all common) and many managed-Postgres CRs don't pin a version — so check the live server
and set the image per cluster. Don't assume a single uniform major fleet-wide.

## The mc-is-dead / awscli-works lesson

These templates **deliberately use awscli**, not the MinIO `mc` client. The real-world job this was
distilled from `curl`ed the `mc` binary from an upstream URL at runtime — and that URL went **HTTP
410 (gone)**. The 410 error *page* got saved **as** the `mc` binary, so the upload silently no-op'd
and backups were broken for weeks while the pod looked green. The common `mc` container image is
also not reliably anonymously pullable (gated/pruned registries → `ImagePullBackOff` / `401`). So:

- **Never `curl` a client binary at runtime.** Use an image that already ships the tool
  (`amazon/aws-cli`, `public.ecr.aws/aws-cli/aws-cli`) or `apt-get install awscli` from a distro
  mirror (shape A).
- **awscli talks to MinIO / any S3-compatible store fine** — just pass `--endpoint-url`
  (`<S3_ENDPOINT_URL>`). Delete that flag + env var for real AWS S3.
- **Old MinIO needs the checksum workaround** (already in both templates): set
  `AWS_REQUEST_CHECKSUM_CALCULATION=when_required` and
  `aws configure set default.s3.multipart_threshold 4GB`, or multipart uploads fail with an
  `invalid/unknown checksum` error. Harmless on real AWS S3.

## Before you apply

1. **Verify read-only first** (`--context` on every command): the cluster is reachable, the
   namespace exists, the live server **major**, the real **host/service**, and that the referenced
   secrets carry the expected keys.
2. **List ALL backup CronJobs, not just one** — a cluster may run several schedules (e.g. 2h +
   weekly + monthly), each to its own bucket. Fixing/adding only one leaves the others broken.
3. Applying is **mutating** → owner approval + single-use `APPROVE_NEXT`, applied **from a file**
   (heredoc apply is blocked). Then fire one test run and confirm the object landed:
   ```sh
   kubectl --context <CTX> -n <NS> create job --from=cronjob/postgres-offsite-backup pg-offsite-test-$(date -u +%Y%m%d-%H%M%S)
   kubectl --context <CTX> -n <NS> logs -l job-name=<test-job> --all-containers --tail=40
   ```
4. **Clean up throwaway test Job objects** (success or fail) — a leftover `Failed` Job keeps
   tripping "job failed" alerts long after backups are healthy.
