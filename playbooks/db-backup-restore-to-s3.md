# Playbook — one-off DB backup & restore to/from S3 (MongoDB, generalizable)

Reusable recipe for "dump a specific database to S3" and "restore it back". The pattern below is the
template; adapt the engine-specific dump/restore tool as noted.

## The pattern (why it looks like this)
- **Sharded Percona Mongo → connect through `mongos`**, not `rs0`. Image pinned to the server
  version so `mongodump`/`mongorestore` match.
- **Two-container Job:** init container does the heavy step (dump / fetch), main container does the
  other (upload / restore), sharing an `emptyDir`.
- **AWS access+secret keys via `secretKeyRef`** from an existing cluster secret — **never inline
  keys in the YAML** (inlined keys leak into a shared repo). Bucket + region are set as **literals**
  (the secret's own `S3_BUCKET` may be stale/different).
- **Self-verifying:** backup prints `listDatabases` and aborts on missing DB / empty archive;
  restore aborts on a missing/empty S3 object. No silent empty backup or no-op restore.
- **Backup** uses the **BACKUP** Mongo user (read). **Restore** needs **write** → use the
  **DATABASE_ADMIN** user (`MONGODB_DATABASE_ADMIN_USER/PASSWORD`).
- **Restore defaults are SAFE:** no `--drop` (insert-only), original DB names. Knobs: `DROP=true`
  (clean replace, destructive), `RESTORE_SUFFIX=-restore` (restore into `<db>-restore` to verify
  first — do this before any real DR), `ARCHIVE_KEY`/`ONLY` overrides.

## Guardrails (always)
- Every `kubectl` carries `--context`. **Verify read-only first** (`get`/`describe` only).
- Stage files as `YYYY-MM-DD-<desc>.{yaml,sh}` in a command folder — never loose in chat.
- Applying a Job is non-read-only: owner approval + single-use token, OR the owner runs the `.sh` in
  their own shell. Restore writes to **live prod** → prefer `RESTORE_SUFFIX=-restore` first.
- Record what you learn + the outcome in your knowledge library.

## For PostgreSQL / other engines
Same skeleton, swap the dump/restore tool: `pg_dump -Fc | aws s3 cp -` and `aws s3 cp - - | pg_restore`
(a reliable Postgres→S3 path is **awscli → MinIO/S3**). Ask for the CNPG cluster / credentials the
same way.

---

## Prompt to generate a BACKUP (copy, fill the `<...>`, send to an agent)

```
Create a one-off backup of the database(s) below to S3, following the two-container-Job pattern:
mongodump via mongos -> aws s3 cp; self-verifying listDatabases + empty-archive guard;
AWS creds via secretKeyRef, NEVER inlined; bucket+region as literals.

Target:
- My kubectl context name for the cluster: <CONTEXT>
- Namespace where the DB + its creds live: <NAMESPACE>
- Engine: MongoDB (Percona psmdb)  |  PostgreSQL (CNPG)  |  other: <...>
- Exact database name(s) to back up: <DB1>[, <DB2> ...]   (case-sensitive!)
- (Mongo) Mongo creds secret + keys: <secret name> / user=<key> / pass=<key>
         (default psmdb: mongodb-psmdb-db-secrets / MONGODB_BACKUP_USER / MONGODB_BACKUP_PASSWORD)

S3 destination:
- Provider: real AWS S3  |  S3-compatible endpoint <URL> (MinIO/R2/other)
- Bucket: <bucket>   Region: <region>   Optional key prefix: <prefix or none>
- Use the access key + secret key from cluster secret <secret name>
  (keys <ACCESS_KEY_ID key> / <SECRET_ACCESS_KEY key>). Use ONLY those two; set bucket/region literally.

Frequency: one-off snapshot   |   recurring CronJob on schedule <cron>

Do this:
1. Verify everything READ-ONLY first (get/describe only, --context on every command): cluster reachable,
   namespace(s) exist, the Mongo cluster + server image, and the key names inside BOTH secrets.
   Surface any mismatch (e.g. the bucket baked into the secret differs from the one I gave).
2. Write a dated manifest + runner .sh into a command folder (no loose commands in chat).
3. Make the Job self-verify (prove the DB exists and the archive is non-empty before/after dumping).
4. Record findings + outcome in the cluster's knowledge-library entry.
5. Do NOT apply it yourself unless I approve; otherwise I'll run the .sh.
```

## Prompt to generate a RESTORE (copy, fill the `<...>`, send to an agent)

```
Prepare a ready-to-fire (but DO NOT run) restore of the database(s) below from S3, following the
pattern: fetch archive from S3 -> mongorestore via mongos; DATABASE_ADMIN write user; SAFE defaults;
DROP + RESTORE_SUFFIX + ARCHIVE_KEY/ONLY knobs; abort on missing/empty archive.

Target:
- My kubectl context name for the cluster: <CONTEXT>
- Namespace: <NAMESPACE>
- Engine: <MongoDB psmdb | PostgreSQL CNPG | other>
- Database name(s) to restore: <DB1>[, <DB2> ...]
- Mongo WRITE user secret + keys: <secret>/<user key>/<pass key>
         (default psmdb: mongodb-psmdb-db-secrets / MONGODB_DATABASE_ADMIN_USER / MONGODB_DATABASE_ADMIN_PASSWORD)

S3 source:
- Bucket: <bucket>   Region: <region>
- Archive key(s): <exact key> OR "latest — list the bucket first and default to the newest"
- Use access+secret keys from cluster secret <secret name> (keys <...>/<...>).

Behaviour:
- Keep defaults SAFE: no --drop, original DB names.
- Expose knobs: DROP=true (clean replace, destructive), RESTORE_SUFFIX=-restore (verify into
  "<db>-restore" without touching live), ONLY=<db>, and per-db KEY overrides for a newer archive.

Do this:
1. READ-ONLY verify first (--context everywhere): cluster, namespace, the WRITE user's secret keys.
2. Write dated manifest + runner .sh into a command folder. Validate the YAML parses.
3. Record it in the cluster's knowledge-library entry.
4. DO NOT run it. Remind me to run RESTORE_SUFFIX=-restore first, verify, then the real restore.
```
