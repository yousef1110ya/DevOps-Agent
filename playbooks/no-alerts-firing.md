# Playbook — "cluster never sends any alerts" (silent alerting pipeline)

**Symptom:** Someone reports a cluster has **never** sent an alert (Discord/Slack/email/PagerDuty)
"since it was created," and/or distrusts the monitoring. Two tempting wrong conclusions to rule out:
"the cluster is just healthy" and "the webhook/secret points at the wrong channel." The **usual real
cause is that alerting was never wired** — a running-but-default Alertmanager that blackholes
everything — so there is nothing to test and nothing ever sent.

All commands below are **read-only** and carry `--context`. Substitute `<CTX>` with your context name
and `<MON_NS>` with the monitoring namespace (kube-prometheus-stack often installs to `monitoring`,
but some stacks use a custom namespace — confirm in step 1).

> **Don't fabricate a target.** If step 3 shows no real receiver, you **cannot** send a "hello" test —
> there is nothing to send to. Report that; never invent a webhook URL.

## Order of checks

### 1. Locate the monitoring stack and confirm it's actually running
```bash
kubectl --context <CTX> get pods -A | grep -iE 'alertmanager|prometheus|grafana'
```
- The `monitoring` namespace can be **empty** even though a stack exists elsewhere — grep **all**
  namespaces. Note the real namespace.
- Alertmanager `Running` proves the *daemon* is up — it says **nothing** about whether it's configured
  to send anywhere. Keep going.

### 2. Confirm alerts are actually being produced (so a silence = dropped, not absent)
```bash
kubectl --context <CTX> get prometheusrule -n <MON_NS> | wc -l
kubectl --context <CTX> get prometheusrule -n <MON_NS> | grep -iE 'general|watchdog'
```
- kube-prometheus-stack ships `Watchdog` (in `*-general.rules`) which **always fires** — a healthy
  pipeline delivers it continuously. If rules exist, alerts are being generated; the question is purely
  routing/receivers.

### 3. Read the effective Alertmanager config — look for the `"null"` default receiver
The operator merges the user config (secret `alertmanager-<name>`) into an effective config
(secret `alertmanager-<name>-generated`). **Decode to a file, not to chat** (the YAML may hold other
secrets), then print only structure with values masked:
```bash
SP=<scratchpad-dir>
kubectl --context <CTX> get secret alertmanager-<name> -n <MON_NS> \
  -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d > "$SP/am.yaml"
sed -E -e 's#(https?://)[^[:space:]"]+#\1<REDACTED-URL>#g' \
       -e 's/((password|token|secret|api_key|url|webhook)[^:]*: *).+/\1<REDACTED>/I' "$SP/am.yaml"
```
- **Smoking gun (default/unconfigured):** the only receiver is `- name: "null"` and the route has
  `receiver: "null"` (plus a `Watchdog → "null"` child). That is the **stock chart placeholder**: it
  routes 100% of alerts into a blackhole. Nothing was ever sent. This is the common root cause.
- If you see real receivers (`discord_configs`, `slack_configs`, `webhook_configs`, `email_configs`,
  `pagerduty_configs`), the pipeline *is* wired — move to step 5 (wrong target / broken delivery).
- Note the Alertmanager **version** (`get alertmanager -n <MON_NS>`): native `discord_configs` needs
  **v0.25+**; older versions need a webhook bridge.

### 4. Prove the receiver secret/target actually exists (or doesn't) — cluster-wide
```bash
kubectl --context <CTX> get secret -A | grep -iE 'discord|slack|webhook|pagerduty'
kubectl --context <CTX> get cm     -A | grep -iE 'discord|slack|webhook'
```
- **Gotcha:** admission-controller TLS secrets are named `*-webhook-*` (cert-manager, cnpg, operators,
  etc.) — those are **not** alerting webhooks. Ignore them.
- Also check **Grafana**-managed alerting isn't the intended path: inspect the grafana datasource CM —
  `handleGrafanaManagedAlerts: false` + no contact-point/notifier provisioning ⇒ Grafana isn't sending
  either.
- If nothing turns up here, **there is no alert target on the cluster** — confirm the step-3 conclusion.

### 5. If a real receiver DOES exist but nothing arrives (wrong channel / broken delivery)
Check what Alertmanager itself thinks — needs API access (port-forward/exec = **owner approval**):
- `/api/v2/status` → is the config loaded, any `uptime`/cluster errors.
- `/api/v2/alerts` → are alerts present but in the wrong route / inhibited / silenced.
- Alertmanager pod logs: `kubectl --context <CTX> logs alertmanager-<name>-0 -n <MON_NS> -c alertmanager`
  → look for `notify` errors (e.g. Discord `401/404`, DNS failure) = wrong/expired webhook = "another
  channel or dead channel." Only here does a `HELLO` test message make sense (and only with owner OK).

## Fix (destructive — owner approval + real webhook URL required)
Add a real receiver and point the default route at it; keep `Watchdog` on a heartbeat (or `null`).
This edits the Alertmanager secret / adds an `AlertmanagerConfig` → **not read-only**; stage it in a
command file and get approval. Re-verify with `Watchdog` after applying.
