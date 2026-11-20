# AGENTS.md — operating rules for this cluster-ops workspace

This is a portable, **agent-agnostic** operating manual for a DevSecOps team that inspects and
operates many Kubernetes clusters through `kubectl` contexts. Any agent (or human) working here
**must** follow the rules below. It is written for *any* assistant/harness — not one product — so
the mechanisms are plain `bash` hooks and plain Markdown.

> **New here?** Read [`onboarding.md`](onboarding.md) first — it installs the tools/MCP servers you
> need and (optionally) wires the hooks.

Rules 1–3 are also enforced automatically by the hooks in [`tools/hooks/`](tools/hooks/) (see
**How enforcement works**); the rest are your responsibility on every session.

> **Sharing this with a teammate whose context names differ?** The clusters are the same — only the
> local `kubectl` context names differ. Nothing is keyed to a specific name: see **rule 11**.

---

## The rules

### 1. Log every command (two tiers: full local + shared audit)
Every shell command is recorded automatically by the `logger.sh` hook, **per-user** (keyed on your
git `user.name`, else your OS username), in **two** files. Do not disable either.
- **Full log — `logs/commands-<user>.log`:** the command **plus its complete output**. Output can
  contain secrets (`kubectl get secret -o yaml`, env dumps, tokens), so this file is **LOCAL ONLY**
  (gitignored). Use it for deep local debugging.
- **Audit trail — `audit/commands-<user>.audit.log`:** timestamp, user, session, cluster context,
  and the command (secret-bearing **args** redacted) — **never any output**. This is the **shared**
  accountability record ("who ran what, when, on which cluster") and is safe to sync to a team repo
  (rule 14). The guard hook also records its verdicts here (BLOCKED / APPROVED-DESTRUCTIVE /
  NODE-SHELL-ALLOWED), so policy events are attributable too.
- Per-user files mean a shared repo never merge-conflicts on the trail. Still avoid gratuitous secret
  dumps — they land in the local full log, readable by anyone on that machine.

### 2. Never change the active context — always use `--context`
- **Do not** run `kubectl config use-context` (blocked by the guard).
- Pass `--context <name>` explicitly on **every** cluster-talking `kubectl` command.
- Commands missing `--context` are blocked. Example: `kubectl --context <your-ctx> get pods -A`.
- `<name>` is **your own device's** context name for that cluster; teammates will have different
  names for the same cluster — that is expected. The guard only checks that `--context` is *present*,
  never *which* name it is.

### 3. No destructive commands without the owner's approval
- Only **read-only** kubectl verbs run freely:
  `get, describe, logs, top, explain, version, api-resources, api-versions, cluster-info, events,
  auth, config (view/get-contexts/current-context), kustomize, diff`.
- Everything else — `apply, create, delete, edit, patch, replace, scale, rollout, drain, cordon,
  uncordon, taint, label, annotate, set, exec, cp, attach, run, port-forward, expose, autoscale`,
  etc. — is **blocked by default**.
- To run one you must (a) get the **session owner's explicit approval in chat for that specific
  command**, then (b) create the single-use approval token, then run it:
  ```bash
  # only after the owner has said yes to THIS command:
  : > state/APPROVE_NEXT      # single-use; the guard deletes it after one command
  ```
  Never self-approve. The approval and the command are both recorded.
- **node-shell exception (read-only host access):** `kubectl node-shell <node> -- <cmd>` (and the
  plugin form `kubectl-node_shell`) is allowed **without** a token *iff* it is non-interactive
  (`-- <cmd>` present), carries `--context`, and the host command is strictly read-only (allowlisted
  primary binary + denylist of any mutating/redirect/substitution/privilege/network/interpreter
  command). Use it for on-node `du`/`df`/`cat` etc.; anything that writes on the node still needs
  owner approval.
- **Protected CNI / cluster-infra HARD guard (NOT overridable by `APPROVE_NEXT`):** mutating a
  cluster's networking or API-aggregation layer is blocked **outright — even with an approval
  token**. This covers any mutating verb against: the CNI/system namespaces (`kube-system`,
  `calico-system`, `calico-apiserver`, `tigera-operator`, `kube-flannel`) or objects inside them;
  any `APIService`; and any Calico/Tigera resource (`Installation`, `ippools`,
  `felixconfigurations`, `*.projectcalico.org`, `*.tigera.io`, `calico-node`/`calico-typha`/…).
  Deleting these breaks the **whole** cluster (pods lose networking, stick `Terminating`). Read-only
  `get/describe` is still fine. If a change here is ever truly required, the **owner runs it
  manually, outside the agent**. Never delete a namespace/APIService to "free resources" without
  first confirming it is not the CNI/infra.

### 4. Build the knowledge base as you go (a habit, not a task)
After **every message** in which you learn something reusable about the infrastructure, record it
before you finish your reply — this is a standing habit, not a one-off.
- **Reusable, cross-cluster lessons** (version gotchas, command recipes, failure patterns) →
  [`knowledge/`](knowledge/). Keep it vendor-neutral: strip cluster/host/secret specifics so the
  lesson travels.
- **Cluster-specific facts** (nodes, workloads, storage layout, quirks, incidents, ownership) → a
  per-cluster file you create under a `cluster-kb/` folder (not shipped here — it's yours and may
  contain internal detail). One file **per cluster**, keyed by identity (rule 11), with context-name
  aliases in the header.
- Keep entries **dated** and **cite the command/proof** for every fact (see **Proof**).
- Do **not** paste secret values — reference where they live instead.

### 5. Shareable — minimal `.gitignore`
Keep everything in plain Markdown / shell / JSON so it can be shared with the team directly. The
minimal `.gitignore` excludes only what must not sync: regenerable deps (`node_modules/`), transient
runtime state (`state/` — the `APPROVE_NEXT` token must **never** propagate to a teammate's machine),
and the **full** command logs (`logs/` — output can contain secrets). The metadata-only **audit
trail** (`audit/`) **is** shared. Do not add anything else; do not withhold knowledge content.

### 6. Never hand the owner raw commands in chat — put them in a file
If you produce commands for the **owner** to run themselves (an interactive login, or a destructive
action they will execute), write them to a file (`YYYY-MM-DD-<short-desc>.sh`) with a comment
explaining each command, and point the owner to that file.
- **Project work →** the file lives inside that project's folder, under
  `projects/<slug>/commands-to-run/` (rule 15).
- **Non-project one-offs →** a shared `commands-to-run/` folder.
- Destructive commands still need explicit owner approval (rule 3) before execution.
- (Teams who prefer node/rollback commands pasted directly in chat can set that as a local exception
  — but the default is: write them to a file.)

### 7. Capture reusable diagnostics (playbooks) — a standing habit
When a command or short sequence made diagnosis faster, save it so the next agent benefits.
- **Generic, symptom-based runbooks** → [`playbooks/<symptom>.md`](playbooks/): an ordered,
  copy-pasteable list of **read-only** commands (each with `--context <CTX>`), what each reveals, and
  gotchas. Use `<CTX>` as the context placeholder so the runbook stays reusable.
- **Cluster-specific "check this first here" notes** → that cluster's own KB file under a
  **Check-first hints** heading, cross-linked from the playbook.
- Keep the "check first" order honest and every command backed by proof.

### 8. Consult the knowledge first (saves time and tokens)
Before a broad investigation, **read the relevant [`knowledge/`](knowledge/) file** (and any
symptom→cause map you keep). If the symptom is a known pattern, verify that cause first before
fanning out. "Check first" means **order, not exclusion** — still weigh every other cause if it
doesn't fit.

### 9. Scan before you read (triage-first, to save tokens)
When checking a cluster's health, run the scan scripts instead of dumping raw `kubectl` output into
context:
- `bash tools/scans/cluster-triage.sh <CTX>` → compact `[OK]/[!]/[i]` verdict; drill only into `[!]`.
  Exit `0` = all clear, so stop there.
- `bash tools/scans/pod-logs-scan.sh <CTX> <ns> <pod> [container] [tail]` → greps logs for error
  keywords; open the full log only if it reports `[!]`.
- A clean scan is *evidence of* health, not proof every workload is correct.

### 10. Disk-usage answers must attribute to the top consumers
Whenever the owner asks about disk usage, a bare "X% full" is **not an acceptable answer**. Always
tell them **which pods/applications (and their PVCs) are consuming the storage the most** — a ranked
list of the biggest consumers with their actual on-disk sizes, backed by proof.
- On hostpath/local-path clusters this means per-PVC attribution via on-node `du` (kubelet volume
  metrics are useless — they echo the shared filesystem total for every PVC), then mapping the big
  PV UIDs back to `<namespace>/<pvc>` and the owning app with `kubectl get pv`.
- **If an object store (MinIO/S3-compatible) is a top consumer, break it down per bucket** — which
  buckets are biggest, not just the total. See [`knowledge/storage-and-disk.md`](knowledge/storage-and-disk.md)
  and [`knowledge/object-stores.md`](knowledge/object-stores.md).

### 11. Identify clusters by identity, not by context name (portable across devices)
The same cluster can carry **different context names on different machines**. Two contexts are the
**same cluster** when they have the **same API server URL** (and the same shared admin user). Key
your knowledge to the **cluster** (its API server URL), never to the local context name.
- `bash tools/scans/cluster-identities.sh [CTX]` prints each local context's API server URL (reads
  kubeconfig only — no cluster contact, no secrets) and flags contexts that share a URL as the same
  cluster.
- Before creating a new cluster-KB file, resolve your context to an existing cluster **by identity**.
  If the server URL already appears, add your context name as an **alias**; only create a new file
  when no identity matches. Never rename/fork/duplicate a KB file just because your local context
  name differs — add an alias.

### 12. Reports: `.docx` for humans, `.md` for you — always keep the `.md`
Applies **only when the owner explicitly asks for a report** (an RCA, incident writeup, status
summary, or document deliverable). Normal chat answers and knowledge/playbook updates are not reports.
- **For a human** → render a **Word `.docx`** from the Markdown source with the bundled tool, writing
  the `.docx` to the **root `reports/`** folder (outside config — rule 13):
  `node templates/reports/md-to-docx.mjs templates/reports/<name>.md reports/<name>.docx`
- **For you (the agent)** → a plain **`.md`** is enough; don't render a `.docx`.
- **Always keep the `.md` source** — it's the source of truth and your re-readable copy. Re-render the
  `.docx` on every `.md` edit so the Word copy never drifts.
- **If the audience is unclear, ask** (pick-one): "A human (`.docx`)" / "You, the agent (`.md`)".
- **Optional company/tenant attribution:** the renderer can hard-fail a report whose `Project`/
  `Company` metadata is missing or mismatched — but **only if your team populates the map** in
  `templates/reports/company-map.md` + the `COMPANY_BY_PROJECT` table. Left empty, attribution is not
  enforced and `Prepared for:` falls back to a neutral default (set `PREPARED_FOR=...`). See
  `templates/reports/README.md`.

### 13. `.docx` reports live OUTSIDE the config dir — in `reports/` at the repo root
Generated `.docx` reports are **human deliverables, not workspace config**. Every `.docx` goes in the
**`reports/` folder at the repo root**, flat, using the same basename as its Markdown source. The
Markdown **source stays in `templates/reports/`** (source of truth + your re-readable copy) alongside
the renderer. Never leave a `.docx` under `templates/`.

### 14. (Optional) Shared git repo — auto-sync with the team
If you make this a shared git repo, the hooks keep everyone on the latest knowledge:
- **On session start**, `git-sync.sh pull` runs `git pull --rebase --autostash` (best-effort).
- **After every reply**, `git-sync.sh push` commits any changes and pushes (best-effort; no-ops when
  nothing changed).
- Both are **best-effort and non-blocking**: offline or an auth failure just leaves work committed
  locally; the hook never hangs (`GIT_TERMINAL_PROMPT=0`) and **never force-pushes**.
- **Conflict policy — never lose either side's data:** knowledge/data files (`*.md`, `*.log`,
  `*.txt`) use the git **`union`** merge driver (`.gitattributes`), auto-keeping **both** versions of
  a conflicting hunk. Code/config (`*.sh`, `*.mjs`, `*.json`) is **not** union-merged (that would
  corrupt a script/JSON) — such a conflict pauses and warns; resolve keeping both sides.
- **Until you add a remote, the hooks do nothing** (they exit quietly). See `onboarding.md` for how
  to add your repo URL and activate the sync.

### 15. Projects (operations) — objective-driven, cross-cluster work with their own KB
A **project** is a bounded goal that spans clusters (e.g. "fix every failing Postgres backup job").
It lives in `projects/<slug>/` and holds **everything for that project in that one folder**. Start
from [`templates/projects/_TEMPLATE/`](templates/projects/_TEMPLATE/). Core files: **`README.md`**
(objective, scope, inputs, the **Approved operations** list, per-cluster progress), **`kb.md`** (✅
what worked / ⛔ what failed, dated + proof-cited), **`log.md`** (dated execution timeline).
- **All owner-run command files for the project go inside `projects/<slug>/commands-to-run/`** — not
  the shared one. Same for any other project artifact (manifests, evidence, notes). Open one folder →
  the whole project.
- **Same security rules apply — a project does NOT loosen the guard.** Every command logged +
  audited, `--context` mandatory, CNI hard-guard never overridable.
- **"More authorization" = a standing, *enumerated* approval, not a bypass.** The owner records a
  specific class of destructive operations in the project's **Approved operations** list. Those don't
  need a fresh chat "yes" each time — **but each one still runs under a single-use `APPROVE_NEXT`
  token** so it's individually audited. Anything not on the list still needs explicit approval. Never
  invent an operation the owner didn't enumerate; never self-approve; never touch protected CNI/infra.
- **Learning is enforced behaviour:** after **every** step, write the outcome to `kb.md` (✅/⛔) and
  append to `log.md` before finishing the reply. Feed cluster-specific facts back into the cluster KB.
- **Keep a live, editable TODO list for project tasks — project work ONLY.** Break the task into a
  TODO list and work it to completion, following it through tangents. Don't persist the checklist
  itself — only its **effects** go to `log.md`/`kb.md`. (Do **not** create a TODO list for ordinary
  health checks or chat answers.)

### Proof
Every finding you report or record **must** carry its evidence: the exact command run and the
relevant output. No guessing. If something cannot be verified, say so explicitly.

---

## How enforcement works (`tools/`)

| Rule | Mechanism | File |
|------|-----------|------|
| 1 | PostToolUse-style hook logs every command + full output (local) and a metadata audit line (shared) | `tools/hooks/logger.sh` → `logs/` + `audit/` |
| 2 | PreToolUse-style hook blocks `use-context` and any cluster-talking kubectl missing `--context` | `tools/hooks/guard.sh` |
| 3 | Same hook blocks non-allowlisted verbs unless `state/APPROVE_NEXT` exists; allows read-only `node-shell`; **hard-blocks CNI/cluster-infra mutation even WITH a token** | `tools/hooks/guard.sh` |
| 4,7,8,10,11 | Agent behaviour (this file) | `knowledge/`, `playbooks/`, `tools/scans/`, your `cluster-kb/` |
| 6,15 | Agent behaviour | `projects/<slug>/commands-to-run/` (project) · shared `commands-to-run/` (one-offs) |
| 12,13 | Agent behaviour + optional renderer-enforced attribution | `templates/reports/` → root `reports/*.docx` |
| 14 | SessionStart pulls; Stop commits + pushes (best-effort, no force, non-blocking) | `tools/hooks/git-sync.sh` |

**Activation:** wire the hooks into your agent harness (see `onboarding.md` and
`tools/settings/`). The hooks require `bash` and `jq` on PATH. They read the command from a hook JSON
payload on stdin **or** from stdin/args directly, so they work with any harness (or as a manual
pre-exec check).

**Testing the guard quickly:**
- `echo 'kubectl --context X get pods'      | bash tools/hooks/guard.sh` → exit 0 (allowed).
- `echo 'kubectl get pods'                  | bash tools/hooks/guard.sh` → exit 2 (no `--context`).
- `echo 'kubectl config use-context X'      | bash tools/hooks/guard.sh` → exit 2 (rule 2).
- `echo 'kubectl --context X delete pod foo'| bash tools/hooks/guard.sh` → exit 2 unless `state/APPROVE_NEXT` exists.
- `echo 'kubectl --context X -n kube-system delete pod foo' | bash tools/hooks/guard.sh` → exit 2 **even with** the token (CNI hard-guard).
