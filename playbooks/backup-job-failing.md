# Playbook: backup CronJob failing

**Symptom:** backup pods in `Error` / `ImagePullBackOff`, or jobs stuck `Running` for days.
Replace `<CTX>`/`<NS>`. All steps read-only. First check your knowledge library — a cluster may
have a known recurring cause for this.

## 1. Which backups, and when did they last succeed?
```bash
kubectl --context <CTX> get cronjobs -A                     # schedules, SUSPEND, last schedule
kubectl --context <CTX> -n <NS> get jobs                    # STATUS + last "Complete" = last good backup
```
A job stuck `Running` for days usually = its pod can't start (ImagePull) — it never completes.

## 2. Why is the pod unhappy?
```bash
# pod states in one line (reuse the triage scan)
bash tools/scans/cluster-triage.sh <CTX>
# ImagePullBackOff -> the exact reason (delete a pod first to force a fresh pull if events aged out)
kubectl --context <CTX> -n <NS> describe pod <pod> | sed -n '/Events/,$p'
# Running-but-failing -> grep the logs for the real error
bash tools/scans/pod-logs-scan.sh <CTX> <NS> <pod>
```

## 3. Common causes (check in this order)
1. **Image pull failing** — anonymous Docker Hub `:latest` + `pullPolicy: Always` + no
   `imagePullSecrets` → rate-limit (`toomanyrequests`). Fix: pin a tag, add pull auth, or mirror.
   ```bash
   kubectl --context <CTX> -n <NS> get cronjob <cj> -o jsonpath='{..containers[0].image} pull={..imagePullPolicy} secrets={..imagePullSecrets}{"\n"}'
   ```
2. **Runtime download of a tool broke** — job `curl`s a binary (e.g. an object-store `mc` client) at
   run time and the URL now 404/410s → `<tool>: not found`. Inspect the actual script:
   ```bash
   kubectl --context <CTX> -n <NS> get cronjob <cj> -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].command}{"\n"}'
   ```
   Durable fix: bake the tool into an image in a registry you control; don't fetch at run time.
   Also add `set -e` so a failed download aborts the job instead of silently producing no backup.
3. **Credentials / endpoint** — object-store creds rotated or bucket/endpoint changed (auth/403).
4. **Destination full / quota** — e.g. `QuotaExceeded 403`; the downstream error message can be
   misleading ("corruption"/"not found").

## 4. Record + hand off
- Put the last-good-backup dates + root cause (with proof) into your knowledge library.
- Fixes edit/patch/delete → **destructive**: stage them in a command file for the owner (per the
  operating rules, AGENTS.md), never run them without approval.
