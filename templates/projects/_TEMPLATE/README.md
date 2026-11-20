# Project: <slug> — <one-line objective>

- **Status:** proposed | in progress | blocked | done
- **Started:** YYYY-MM-DD   **Owner:** <owner>
- **Slug:** `<slug>` (folder name)

## Objective
<What outcome this project commits to. One paragraph. What "done" looks like, measurably.>

## Scope
- **In scope:** <clusters / resources / namespaces this touches>
- **Out of scope:** <explicitly excluded, so no one over-reaches>

## Inputs (knowledge this project consumes)
- Knowledge: `knowledge/<file>.md` … (which lessons and why)
- Cluster KBs: `<canonical-context>` … (which clusters and why)
- External sources: <repo path / doc / ticket>

## Approved operations (the STANDING owner approval — AGENTS.md rule 15)
> These are the ONLY destructive operations pre-approved for this project. Each still runs under a
> single-use `APPROVE_NEXT` token (so it's audited). Anything not listed here needs a fresh chat
> approval. The CNI/cluster-infra HARD guard always applies and is never overridable.
- [ ] `<exact operation class, e.g. kubectl apply -f <file> of CronJob X in namespace Y>` — approved by <owner> on <date>

## Progress (per cluster)
| Cluster (context) | Reachable | Action | Result | Verified | Notes |
|-------------------|-----------|--------|--------|----------|-------|

## Learnings
See [`kb.md`](kb.md) (✅ reuse / ⛔ never repeat) and the timeline in [`log.md`](log.md).

## Commands & artifacts
All owner-run scripts and any other artifacts for this project (YAML manifests, captured evidence,
guides) live in [`commands-to-run/`](commands-to-run/) — **in this project folder, not the shared
`commands-to-run/`** (AGENTS.md rules 6 + 15). Naming: `YYYY-MM-DD-<short-desc>.sh`, one comment per
command, destructive steps still need owner approval + an `APPROVE_NEXT` token.
