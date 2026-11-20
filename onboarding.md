# Onboarding — set up this workspace for any agent

This workspace is **agent-agnostic**. It works with any AI coding/ops assistant or harness — the
enforcement is plain `bash` hooks and the knowledge is plain Markdown. Follow the steps below to get
a new machine (and a new agent) productive and safe.

Read [`AGENTS.md`](AGENTS.md) for the operating rules. This file is about **installing the tools and
MCP servers**, **wiring the guard/logging hooks**, and **(optionally) activating git auto-sync**.

---

## 1. Install the CLI tools (by name)

Install these on the operator's device (names are the common package names; use your OS package
manager — `apt`, `dnf`, `brew`, `winget`/`choco`, or the official installer):

**Required**
- **kubectl** — the Kubernetes CLI (everything here talks to clusters through it).
- **bash** — the hooks and scans are bash. On Windows use **Git Bash** (ships with *Git for Windows*).
- **jq** — the hooks parse JSON with it; they refuse to run cleanly without it.
- **git** — version control + the optional auto-sync.
- **velero** — the Velero **client/CLI**, installed **on your device**. You need it locally to drive
  backups/restores/migrations. ⚠️ **Only install the Velero *server* into a cluster when a migration
  actually needs it** — do not deploy Velero into clusters by default (it's not part of steady-state;
  install it per-migration and remove/leave-dormant after). See
  [`templates/velero-migration/`](templates/velero-migration/).

**Required for reports** (rule 12)
- **node** + **npm** — the Markdown→`.docx` renderer (`templates/reports/md-to-docx.mjs`) runs on
  Node. After cloning, run `npm --prefix templates/reports install` once.
- **python3** *(optional)* — only to turn report bar-charts into *native editable* Word charts
  (`inject-charts.py`); without it charts render as static tables.

**Install when needed (not upfront)**
- **kubectl-node_shell** (plugin, a.k.a. `kubectl node-shell`) — read-only on-node access for `du`/
  `df`/`cat`. Install via **krew** (`kubectl krew install node-shell`) or the upstream script. The
  guard explicitly permits read-only node-shell. Install it the first time you need on-node disk
  attribution.
- **openssl** — only for `tools/scans/cert-expiry-decode.sh`.
- **aws** CLI and/or **mc** (MinIO client) — only if you operate S3/MinIO object stores or run the
  backup templates from your device. (The backup *CronJobs* carry their own tools in-cluster; you
  don't need these locally just to apply them.)
- **helm** — if your platform is Helm-managed.

Quick check after install:
```bash
kubectl version --client
jq --version
velero version --client-only
node --version && npm --version
bash --version
```

## 2. Install the MCP servers (by name)

Add these to **your agent/harness's MCP configuration** (every harness has its own way — e.g. an
`mcp add <name> ...` command or an MCP config file). They are referenced by **server name**, not tied
to any one assistant:

- **filesystem** — lets the agent read/write files in this workspace reliably.
- **git** — repo status/diff/commit/log operations.
- **fetch** (or a **web-search**/web-fetch server) — pull upstream docs and release notes during
  diagnosis (version gotchas, CVE notes, operator support matrices).

**We do NOT use a Kubernetes MCP server here — on purpose.** This workspace drives `kubectl` through
the **shell/Bash tool**, which is exactly what the `guard.sh` hook intercepts (read-only allowlist,
`--context` requirement, `APPROVE_NEXT`, CNI hard-guard). A Kubernetes MCP server would call the API
*around* the shell, **bypassing the guard** — so don't add one unless you also reimplement the guard
at the MCP layer.

**Adding any other MCP server:** pick the server by name, add it to your harness's MCP config with the
command/URL and any required credentials, restart the agent, and confirm the tools appear. Useful
optional ones for a DevSecOps team:
- A **secrets-manager** MCP (e.g. a vault/Passbolt-style server) so the agent can *use* credentials
  **without ever seeing them** — it fills secrets into approved sinks and never prints them to chat.
  This matches the "never paste secret values" rule; point it at your own vault.
- Provider MCPs (cloud, DNS, object-store) as your infra requires — keep each read-mostly and never
  let one bypass the kubectl guard for cluster mutations.

## 3. Wire the hooks into your agent/harness

The three hooks in [`tools/hooks/`](tools/hooks/) enforce rules 1–3 and (optionally) rule 14. Wire
them at **four lifecycle points**. Each hook reads the command from a hook-JSON payload on stdin
(`.tool_input.command`) **or** from raw stdin/args, so it fits any harness:

| Lifecycle point | Hook | Purpose |
|-----------------|------|---------|
| Before a shell/Bash tool call | `tools/hooks/guard.sh` | **Blocks** unsafe kubectl (rules 2–3). Exit 2 = deny. |
| After a shell/Bash tool call | `tools/hooks/logger.sh` | Records the command (+output locally, metadata to the shared audit). |
| On session start | `tools/hooks/git-sync.sh pull` | Pulls latest knowledge (no-op until a remote exists). |
| On session stop | `tools/hooks/git-sync.sh push` | Commits + pushes changes (no-op until a remote exists). |

**Claude Code** users: a ready-to-use `settings.json` is in
[`tools/settings/claude-code.settings.json`](tools/settings/claude-code.settings.json) — copy it to
`.claude/settings.json` at the repo root (it references the hooks via `$CLAUDE_PROJECT_DIR`). Then
restart or run `/hooks` to approve them.

**Any other harness:** map the four points above to your harness's equivalent (pre-exec / post-exec /
session-start / session-stop). Point the repo root at the hooks via the `AGENT_PROJECT_DIR`
environment variable so `git-sync.sh` finds the repo (`export AGENT_PROJECT_DIR=/path/to/DevOps`).

**No harness hooks at all?** You can still use the guard as a manual gate:
```bash
echo 'kubectl --context prod delete pod foo' | bash tools/hooks/guard.sh && echo ALLOWED || echo BLOCKED
```

Verify the guard works (see the test cases at the bottom of `AGENTS.md`).

## 4. (Optional) Activate git auto-sync by adding your repo URL

The git-sync hooks **do nothing until this workspace is a git repo with a remote** — so it's safe to
wire them before you have a repo. When you're ready to share the workspace with your team:

```bash
# from the workspace root (.../DevOps)
git init                                  # if not already a repo
git add -A && git commit -m "init: DevSecOps cluster-ops workspace"
git branch -M main
git remote add origin <YOUR-NEW-REPO-URL> # <-- add YOUR repository here to activate auto pull/push
git push -u origin main
```

Once `origin` exists:
- **session start** → `git pull --rebase --autostash` (best-effort, never clobbers).
- **session stop** → commit + `git push` (best-effort, never force-pushes).
- Make sure your machine's **git credential helper / token** is configured, or pushes just fail safe
  and retry next time.

> **For now, there is no remote configured** — the hooks stay dormant. Add `<YOUR-NEW-REPO-URL>` when
> you want the team sync on. The `.gitignore` already excludes the right things (local logs, the
> `state/APPROVE_NEXT` token, `node_modules/`), and `.gitattributes` keeps both sides of any
> knowledge-file conflict.

## 5. First-run sanity check

```bash
# 1) guard allows a read-only call, blocks a mutating one:
echo 'kubectl --context X get pods'        | bash tools/hooks/guard.sh; echo "exit=$?  (expect 0)"
echo 'kubectl --context X delete pod foo'  | bash tools/hooks/guard.sh; echo "exit=$?  (expect 2)"

# 2) triage a reachable cluster (replace <CTX>):
bash tools/scans/cluster-triage.sh <CTX>

# 3) see which local contexts are the same cluster:
bash tools/scans/cluster-identities.sh
```

You're set. Start from [`AGENTS.md`](AGENTS.md); reach for [`knowledge/`](knowledge/) and
[`playbooks/`](playbooks/) before investigating; use [`templates/`](templates/) for backups,
migrations, projects, and reports.
