# templates/ — reusable scaffolding and build kits

Copy-and-fill starting points for the recurring work. Everything here is vendor-neutral; replace the
`<placeholders>` with your specifics. Destructive steps always need owner approval + an `APPROVE_NEXT`
token (AGENTS.md rule 3), and manifests are applied from a **file** (never a heredoc — the guard
blocks `apply -f -`).

| Folder | What it gives you |
|--------|-------------------|
| [`backup/`](backup/) | Off-site database backup CronJobs: MongoDB→S3 (3-container dump→FIFO→upload→notify) and PostgreSQL→S3 (apt / two-image shapes). Self-verifying, prune-to-N, notify on success+failure. |
| [`velero-migration/`](velero-migration/) | A from-scratch Velero cluster-migration kit: the 3-plane model, target prerequisites, backup/restore scripts, the resource-modifiers ConfigMap, post-restore fixes, and a "what we did wrong, don't repeat" guide. |
| [`projects/`](projects/) | The project (operation) scaffold — `_TEMPLATE/` with README/kb/log + `commands-to-run/`. |
| [`reports/`](reports/) | Markdown→Word `.docx` report rendering (source of truth stays `.md`), with optional company/tenant attribution. |

Pair these with the lessons in [`knowledge/`](../knowledge/) and the runbooks in
[`playbooks/`](../playbooks/) — the templates are the "how to build it", the knowledge is the "what
goes wrong and why".
