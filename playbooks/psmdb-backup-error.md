# Symptom: Percona MongoDB (psmdb) backup CR shows `STATUS=error`

For `PerconaServerMongoDBBackup` (psmdb-backup) objects stuck/failed in `error`.
A large share of these are **operator false-positives**: the pbm-agent completes the dump
but the operator's own status-tracking connection failed and marked the CR `error`.
**Confirm the data path before treating it as a real failure.** All commands read-only.
Replace `<CTX>`, `<NS>`, `<BACKUP>`.

## 1. Read the failure reason + timing
```bash
kubectl --context <CTX> -n <NS> get psmdb-backup <BACKUP> -o yaml | sed -n '/^status:/,$p'
```
Look at `status.error`, `status.start`, `status.lastTransition`, `status.pbmPods`.
- **Tell:** if `lastTransition` is only seconds after `start`, and the error is a *connection*
  message (`create pbm object` / `create PBM connection` / `create mongo connection to
  configsvr` / `the specified CA file does not contain any valid certificates`), it's almost
  certainly the **operator's** poll connection, not the backup itself → go to step 2.

## 2. Did the dump actually finish? (the decisive check)
`status.pbmPods` lists the pod per replset (e.g. `rs0: ...-rs0-0`, `cfg: ...-cfg-1`).
```bash
kubectl --context <CTX> -n <NS> logs <pbmPod> -c backup-agent --tail=50 | grep -iE 'backup finished|mongodump finished|error'
```
Do this for **each** replset pod. `backup finished` for the matching `[backup/<pbmName>]` job
means the data was dumped/uploaded — the `error` on the CR is a false positive.

## 3. Is it the operator that errored (not the agent)?
```bash
kubectl --context <CTX> -n <NS> get pods | grep -i operator
kubectl --context <CTX> -n <NS> logs <operator-pod> --tail=20000 \
  | grep -iE 'failed to make backup|CA file does not contain|valid certificate' | grep <BACKUP>
```
Same error text under `psmdbbackup-controller` = operator-side connection race.

## 4. Rule out a *real* cert problem (so you don't chase ghosts)
```bash
kubectl --context <CTX> -n <NS> get certificate                 # expect READY=True
# ca.crt must be non-empty; prints only a byte count, never the cert material:
for s in mongodb-psmdb-db-ssl mongodb-psmdb-db-ssl-internal; do
  echo -n "$s ca.crt bytes: "
  kubectl --context <CTX> -n <NS> get secret $s -o "jsonpath={.data.ca\.crt}" | base64 -d | wc -c
done
```
Non-zero bytes + `READY=True` ⇒ certs are fine; the "no valid certificates" error is the
operator's transient file race, **not** the stored secret. (Do **not** `get secret -o yaml`
— it dumps `tls.key` into the log; the byte-count above is safe.)

## 5. Rule out storage / cluster health
```bash
kubectl --context <CTX> -n <NS> get psmdb-backup --sort-by=.metadata.creationTimestamp   # sporadic vs total outage?
kubectl --context <CTX> -n <NS> get psmdb <cluster> -o jsonpath='{.status.state}'          # expect ready
```
If **only some** backups error and neighbors are `ready`, that supports the transient-race
diagnosis over a storage outage or expired cert.

## 1b. Backups stuck `waiting` / `requested` / blank (never `error`, never start)
Different failure mode from `error`: the backup **never starts**. Usually the operator is
refusing to run backups because the **cluster isn't `ready`**.
```bash
kubectl --context <CTX> -n <NS> get psmdb <cluster> -o jsonpath='{.status.state}{"\n"}'   # ready? or initializing/error?
kubectl --context <CTX> -n <NS> get psmdb-backup -o jsonpath='{range .items[*]}{.status.state}{"\n"}{end}' | sed 's/^$/(empty)/' | sort | uniq -c
kubectl --context <CTX> -n <NS> logs deploy/<operator> --tail=4000 \
  | grep -iE 'Cluster is not ready for backup|waiting for running backups|SmartUpdate|StatefulSet is (changed|not up to date)' | tail -20
```
**Deadlock signature** (`Cluster is not ready for backup` **and** `can't start 'SmartUpdate':
waiting for running backups to be finished` together): a pending SmartUpdate can't start
because non-terminal backups exist, and those backups can't run because the cluster stays
`initializing` while SmartUpdate is pending. Confirm the data plane is actually healthy
(members PRIMARY/SECONDARY, pods Ready) — it usually is.
- **Break it** by deleting the non-terminal (waiting/requested/empty) backup CRs so SmartUpdate
  can finish → cluster returns to `ready` → backups resume. Those CRs have no `status.start`/
  `destination`, so no data is lost. This is a `delete` (destructive) → owner approval; stage the
  steps in a command file. Note `unsafeFlags.backupIfUnhealthy` — if `false`, any not-ready state
  fully halts backups (no grace), so one stuck backup can cascade.

## 1c. `error` = "corruption found in archive" / "upload multipart failed"
Do **not** take "corruption found in archive" at face value — PBM streams `mongodump`
straight to S3, so if the S3 upload aborts mid-stream the archive pipe truncates and the parser
reports "corruption". **Read to the END of `status.error` for the real `caused by:`.**
```bash
kubectl --context <CTX> -n <NS> get psmdb-backup <BACKUP> -o jsonpath='{.status.error}{"\n"}'
```
Common real causes after `caused by:`:
- `QuotaExceeded` / `status code: 403` → the target bucket/account is **full**.
  Fix on the storage side: abort orphaned incomplete multipart uploads (each failed run leaves
  one, compounding the problem), delete old backups, or raise the quota. Add a lifecycle rule to
  auto-abort incomplete multipart uploads.
- `no space left` → storage backend disk full.
- `AccessDenied` / `SignatureDoesNotMatch` → wrong/expired creds for that storage.
**Tip:** if one storage fails and another succeeds, compare their `spec.backup.storages`
endpoints — the failing provider is the culprit, not Mongo/PBM:
```bash
kubectl --context <CTX> -n <NS> get psmdb <cluster> -o json \
  | jq -r '.spec.backup.storages | to_entries[] | "\(.key): \(.value.s3.endpointUrl // "AWS") bucket=\(.value.s3.bucket)"'
```

## Interpreting
- Dump `backup finished` + valid certs + operator-side error ⇒ **false-positive**; the data
  likely exists in the bucket. Real remediation is operator-side (align crVersion to the
  operator version, reduce reconcile churn, upgrade operator).
- No `backup finished` in agent logs ⇒ investigate as a **real** failure (storage creds,
  bucket reachability, PBM lock, resources).

## Gotchas
- **Don't delete an errored backup CR to "clean up"** — it may carry finalizer
  `percona.com/delete-backup`; deletion can remove the S3 data of a snapshot that actually
  succeeded.
- Confirming a snapshot is **restorable** needs `pbm list` / `pbm status` via `kubectl exec`
  — that's **destructive-by-policy**; get owner approval first.
