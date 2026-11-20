# Daily check: are MongoDB (psmdb) backups healthy across the fleet?

A standing **daily** verification that every reachable cluster running Percona Server for MongoDB
(psmdb) has a **recent successful backup** — so a silent stall (an operator that stops reconciling
for days before anyone notices) is caught within a day, not weeks later.

- **Scope:** all reachable contexts that run psmdb (auto-discovered).
- **Cadence:** once a day (see "Automation" below). Also runnable by hand any time.
- **Everything here is read-only.** Any *fix* (restart operator, clear a stuck CR, add creds/buckets)
  is destructive → owner approval per the operating rules (AGENTS.md), and uses the companion playbook
  [`psmdb-backup-error.md`](psmdb-backup-error.md).

## 1. Run the scan (the whole check, in one command)

```bash
bash tools/scans/mongodb-backups.sh            # all reachable clusters (auto-discover)
bash tools/scans/mongodb-backups.sh <CTX> ...  # just these contexts (spot check)
```

What it reports per MongoDB cluster (decisive signal = *did a `ready` backup complete recently?*):

- **`[OK]`** — newest `ready` backup is within the threshold (default **36h**; daily cadence + grace).
  Errored/stuck CRs sitting next to a fresh `ready` one are shown as `[i]` only — that pattern is
  usually the operator false-positive documented in [`psmdb-backup-error.md`](psmdb-backup-error.md).
- **`[!]`** — a real gap: **no `ready` backup at all**, newest `ready` **older than the threshold**,
  backups **disabled** in `.spec.backup.enabled`, **no scheduled task**, or the cluster isn't `ready`.
- **`[i]`** — context unreachable from this machine, or no psmdb operator / no clusters (nothing to check).

Exit `0` = every cluster `[OK]` (stop here). Exit `1` = at least one `[!]` — drill only into those.

Tuning:
- `MAX_AGE_HOURS=72 bash tools/scans/mongodb-backups.sh <CTX>` for a cluster that only backs up
  **weekly** (otherwise a weekly-only cluster false-flags every day). Record the right threshold in
  that cluster's knowledge-library entry so the daily judgment stays honest.
- `REQ_TIMEOUT=25s …` on a slow link.

## 2. For each `[!]`, confirm before alarming (don't cry wolf)

Follow [`psmdb-backup-error.md`](psmdb-backup-error.md) — in particular:
1. Read the latest CRs: `kubectl --context <CTX> -n <NS> get psmdb-backup --sort-by=.metadata.creationTimestamp`
2. Is the cluster itself healthy? `kubectl --context <CTX> -n <NS> get psmdb <cluster> -o jsonpath='{.status.state}'` (expect `ready`).
3. Did a dump actually finish? Check `backup-agent` logs (step 2 of that playbook) — an `error` CR next
   to a finished dump is a false positive, **not** a backup gap.
4. Stuck `requested`/`waiting`/empty CRs → the SmartUpdate⇄backup deadlock (step 1b there).
5. No recent `ready` + empty `.status` + no error → operator stopped reconciling: the fix is to restart
   the psmdb operator.

Always weigh the cluster's own **Check-first hints** first (e.g. a cluster that only backs up weekly,
or one with a known nightly file-descriptor crash near backup time).

## 3. Record + alert (what the daily run does)

- **Always:** overwrite the latest status to a `mongodb-backups-latest.md` and append one dated summary
  line to a history log.
- **Only on `[!]`:** write a clearly-named alert file (what's wrong, which cluster, the confirming
  command + output), update that cluster's **Check-first hints**, and surface it to the owner.
- Never paste secret values; cite the command + output as proof.

## Automation (how the daily run is wired)

- Mechanism: **headless agent on a scheduled job** (runs on a machine with the kubeconfig + the guard
  active — a cloud routine can't reach the clusters).
- A wrapper the scheduled task runs: cd repo → run the agent with the daily prompt → capture a local
  transcript → notify on problems.
- The kubectl-guard still runs in headless mode, so destructive cluster ops stay blocked even though
  the job runs unattended; the daily job only ever runs the read-only scan + read-only drill-downs.

## Gotchas

- A clean scan is *evidence of* healthy backups, not proof a restore works. Confirming a snapshot is
  **restorable** needs `pbm status`/`pbm list` via `exec` = destructive-by-policy — do it deliberately,
  not daily.
- `error`-state CRs are often operator false-positives; **don't delete them to "clean up"** — they can
  carry a finalizer that removes real S3 data (see psmdb-backup-error.md gotchas).
- Weekly/monthly-only clusters need a higher `MAX_AGE_HOURS` or they false-flag daily — note the
  per-cluster threshold in that cluster's entry.
