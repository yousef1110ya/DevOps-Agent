# projects/ — objective-driven, cross-cluster work

A **project** (a.k.a. operation) is a bounded goal that spans clusters — e.g. "fix every failing
Postgres backup job", "roll out an off-site MongoDB backup to all prod clusters", "migrate cluster X
to a new provider". It lives in `projects/<slug>/` and holds **everything for that project in that
one folder** (AGENTS.md rule 15).

## Start a new project
```bash
cp -r templates/projects/_TEMPLATE projects/<slug>
```
Then fill in the three core files:
- **`README.md`** — objective, scope, inputs, the **Approved operations** list, per-cluster progress.
- **`kb.md`** — learnings: ✅ what worked / ⛔ what failed, dated + proof-cited.
- **`log.md`** — dated execution timeline.

Owner-run scripts and any other artifacts (manifests, evidence) go in
`projects/<slug>/commands-to-run/`.

## Rules that still apply (a project does NOT loosen the guard)
- Every command logged + audited; `--context` mandatory; CNI/cluster-infra hard-guard never
  overridable.
- **"More authorization" = a standing, *enumerated* approval** in the project's Approved operations
  list — each pre-approved op still runs under a single-use `APPROVE_NEXT` token so it's audited.
  Anything not on the list needs explicit owner approval. Never self-approve.
- After every step, write the outcome to `kb.md` (✅/⛔) and append to `log.md` before finishing.
- Keep a live, editable TODO list for project tasks (project work only) and follow it to completion
  through tangents — but never persist the checklist; only its effects go to `log.md`/`kb.md`.
