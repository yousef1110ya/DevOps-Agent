# Security headers / weak CSP — find the emitting layer, then harden safely

**Symptom / request:** a scanner or pentest flags a weak `Content-Security-Policy` (or missing
security headers) on a web app, e.g. `script-src 'unsafe-inline' 'unsafe-eval'` / overly broad
wildcards. You must say **definitively which layer emits it**, whether an upstream CDN overrides
it, and give a **report-only-first** remediation split by owner (infra vs frontend).

All commands are **read-only** and carry `--context <CTX>`. Substitute your context name.
Do **not** edit/patch anything — propose diffs for the owner.

## 1. Find the Ingress that routes the host
```bash
kubectl --context <CTX> get ingress -A -o wide        # match the HOST column to the app FQDN
kubectl --context <CTX> get ingress <ing> -n <ns> -o yaml
```
In the ingress YAML look for the CSP in annotations (nginx-ingress):
- `nginx.ingress.kubernetes.io/configuration-snippet` / `server-snippet` → `more_set_headers "Content-Security-Policy: …"`
- `nginx.ingress.kubernetes.io/add-headers` → a referenced ConfigMap of headers
Note the **backend service → deployment → container image** (you need it for step 3).
Note if it's **Helm-managed** (`meta.helm.sh/release-name`): a live edit will be reverted by the
next `helm upgrade` — the durable fix belongs in the **chart**, not the live object.

## 2. Rule out the controller-wide ConfigMap (a second possible source)
```bash
kubectl --context <CTX> get cm -n ingress-nginx ingress-nginx-controller -o yaml \
  | grep -iE 'add-headers|proxy-set-headers|content-security|header'
```
If CSP is here, it applies cluster-wide (every ingress). If only the per-ingress annotation has it,
that annotation is the **sole** emitter.

## 3. Determine STATIC SPA vs SERVER-RENDERED (decides nonce vs hash)
```bash
kubectl --context <CTX> get deploy <app> -n <ns> -o jsonpath='{.spec.template.spec.containers[*].image}{"\n"}'
# static-server image (nginx/caddy serving a dist) vs a node/SSR process?
curl -s https://<host> | sha256sum ; sleep 1 ; curl -s https://<host> | sha256sum   # identical twice => static
curl -sI https://<host> | grep -iE 'cache-control|last-modified|etag|x-powered-by'
curl -s https://<host> | grep -oiE '<script[^>]*>' | head                           # any INLINE <script> blocks?
```
- **Byte-identical HTML + a single hashed `/assets/index-*.js` module + no inline `<script>`** ⇒ **static**
  ⇒ **per-request nonces are NOT viable** (no server to stamp a fresh nonce). Harden by **removing
  `'unsafe-inline'`/`'unsafe-eval'`** and, for any legitimately-inline script, **SHA-256 hashes**
  (static & cacheable) or move it to an external file.
- **HTML varies per request / `x-powered-by` / SSR** ⇒ a server layer exists ⇒ **nonces are viable**
  (preferred over hashes for dynamic inline).

## 4. Compare cluster config vs the LIVE wire header (detect CDN/WAF override)
```bash
curl -sI https://<host> | grep -iE 'content-security-policy|server|cf-ray|cf-cache-status'
```
- If `Server: cloudflare` / `CF-RAY` present → **a CDN is in front**.
- **Diff the live CSP against the ingress annotation CSP:**
  - **Identical** ⇒ the CDN passes the origin header through; the **whole fix is in-cluster/chart** —
    nothing to change at the CDN.
  - **Different** ⇒ the delta is injected/overridden by the CDN (e.g. a Transform Rule/Worker),
    which lives **outside kubectl** — that part of the fix is a CDN dashboard change.
- A CDN beacon origin in the policy (e.g. a RUM/insights script host) usually means the **origin**
  added it so the CDN's auto-injected script isn't blocked — not that the CDN edited the header.

## 5. Confirm which allowlisted origins are ACTUALLY used (don't prune blind)
Load the real page in a browser and capture network + console (a read-only browser-automation tool):
navigate → capture network requests (filter to `\.js` and 3p origins) → capture console warnings.
- Network capture tells you **which `script-src` origins actually fire**; everything else in the
  allowlist is a candidate to remove.
- ⚠️ A login/landing page exercises only a subset — maps/recaptcha/payment/analytics scripts often
  load only on **authenticated/deep routes**. Have the frontend confirm per-route before deleting an
  origin; note explicitly that your capture covered only the pages you visited.
- Console CSP errors here also surface **pre-existing** violations (e.g. `connect-src` missing `data:`)
  worth flagging separately.

## 6. Remediate report-only FIRST (never flip enforce blind)
- Add a **`Content-Security-Policy-Report-Only`** header carrying the *tightened* policy **alongside**
  the current enforced CSP. The browser reports what *would* break (console + optional `report-to`
  collector) while nothing is actually blocked.
- Keep it in RO across a full QA pass of every route. When RO is clean, move the tightened policy into
  the **enforced** `Content-Security-Policy` and remove the RO copy.
- Put the owner-run edit/patch commands in a command file; if Helm-managed, the real change goes in the
  chart (a live patch is only for the RO experiment / emergency).

## Owner split (typical)
- **DevOps/infra (ingress annotation or Helm chart):** roll out RO, then enforce — drop
  `'unsafe-inline'`/`'unsafe-eval'`, narrow wildcards (`*.domain` → `'self'` for scripts), prune
  unused 3p origins.
- **Frontend:** confirm no runtime-injected inline scripts (else provide SHA-256 hashes / externalize),
  confirm/remove `eval`/`new Function` usage (to drop `'unsafe-eval'`), confirm which 3p script
  origins are genuinely used, and ideally self-host small libs to shrink the allowlist.
