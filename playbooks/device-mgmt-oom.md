# Version-correlated OOMKilled / memory leak in an app deployment

**Symptom:** a deployment OOMKills "every once in a while", or its pods sit far above their memory
request and climb over time. You suspect a **memory leak tied to a specific image tag** — the same
app on a newer tag sits flat.

**The pattern:** memory creeps up over hours/days until it hits the container limit
(`limits.memory`) and the kernel OOMKills the container. The **node itself is usually not short on
RAM** — it's the **container cgroup limit** that's hit. The fix is almost always a newer image tag
that caps memory in-code, not a bigger limit (a bigger limit only delays the OOM).

> This playbook is the generic **method** — reuse it whenever an app is suspected of a
> version-correlated leak. Substitute your context name for `<CTX>`, the namespace for `<ns>`, and
> the deployment/label for `<app>`.

## Diagnose (all read-only, all carry `--context`)

1. **Find the app everywhere + its OOM/restart signal (fleet-wide):**
   ```bash
   kubectl --context <CTX> get pods -A -o json | jq -r '
     .items[] | select(.metadata.name|test("<app>";"i")) | . as $p
     | (.status.containerStatuses // [{}])[]
     | "\($p.metadata.namespace)/\($p.metadata.name) restarts=\(.restartCount) lastReason=\(.lastState.terminated.reason // "-") lastFinished=\(.lastState.terminated.finishedAt // "-")"'
   ```
   `lastReason=OOMKilled` = it hit the limit. NOTE: `lastState` only shows the **most recent**
   termination — a slow leak may show a low restart count (it OOMs only every few weeks), so also
   check live memory (step 3) and pod age.

2. **Get the image tag + the real limit (this is the key discriminator):**
   ```bash
   kubectl --context <CTX> -n <ns> get deploy <app> \
     -o jsonpath='image={.spec.template.spec.containers[0].image} req={.spec.template.spec.containers[0].resources.requests} lim={.spec.template.spec.containers[0].resources.limits}{"\n"}'
   ```
   - The known-leaky tag → **will OOM** — this is the one to fix.
   - The fixed tag onward → look elsewhere.
   - ⚠️ **Do NOT read the limit from `containerStatuses[].resources`** — that field is not reliably
     populated on all k8s versions and can falsely read "none". Always read `.spec...resources`.

3. **Live memory vs limit (is it creeping toward the limit?):**
   ```bash
   kubectl --context <CTX> -n <ns> top pods -l app=<app>
   ```
   - Flat and well under the limit → fixed image, healthy.
   - Several hundred Mi and rising, or near the limit → leaking. Near the limit now + a prior OOM ≈
     will re-OOM within days.

4. **(Optional) confirm the trend** with Prometheus `container_memory_working_set_bytes` for the
   pods over 2–3 weeks (needs port-forward/API access = owner approval). A steady upward ramp that
   resets at each restart = leak; a flat plateau = not.

## Fix
Roll the deployment to the fixed image tag (the release with the in-code memory cap). This is a
`set image` / `rollout` = **destructive, needs owner approval** per the operating rules (AGENTS.md);
stage the exact command in a command file. Bumping the memory limit only delays the OOM — the real
fix is the image.

## Keep a fleet status table
When you sweep the fleet, record a small table per cluster (image tag, live mem/pod, limit, verdict)
in your knowledge library so the next check is a glance, not a re-investigation.
