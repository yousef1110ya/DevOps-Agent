<!--
  REPORT TEMPLATE — copy this file to start a new report.

  WHERE TO SAVE:
    - Markdown SOURCE stays in templates/reports/<name>.md   (source of truth + your re-readable copy)
    - Rendered .docx goes to the ROOT reports/<name>.docx     (human deliverable, outside config)
    - <name> = YYYY-MM-DD-<short-descriptive-name> (name it for the finding, not "incident-report")

  RENDER (human deliverable):
    node templates/reports/md-to-docx.mjs templates/reports/<name>.md reports/<name>.docx
    Re-render on every edit so the Word copy never drifts.

  RULES FOR THIS REPORT:
    - Three sections only, in this order: Summary -> Technical details -> Recommended remediation.
    - Every claim in Technical details must be backed by the EXACT command that produced it and that
      command's ACTUAL output. No paraphrasing, no invented output. (The "Proof" rule.)
    - Use read-only commands for evidence. If a change was made, say so explicitly.
    - Do not paste secret values (tokens, secret -o yaml, credential env dumps).
    - OPTIONAL company/tenant attribution: if your team populated the company map
      (templates/reports/company-map.md + COMPANY_BY_PROJECT in md-to-docx.mjs), the `Project` and
      `Company` bullets below are REQUIRED and must agree, or the renderer hard-fails. If the map is
      empty, attribution is not enforced and you can delete those two bullets.
  Delete this comment block in the finished report.
-->

# <Title> — <Cluster friendly name> (`<cluster-context>`)

**Date:** <YYYY-MM-DD>
**Project:** <project name — only required if attribution is enforced>
**Company:** <company/tenant — only required if attribution is enforced>
**Cluster / context:** `<cluster-context>` (<prod | stage | dev>)
**Prepared by:** Cluster Ops
**Status:** <Active | Mitigated | Resolved> — <one clause on whether changes were applied>
**Evidence method:** read-only `kubectl` only; no cluster state was modified.

---

## 1. Summary

*What happened, and how much it affects the cluster. A few sentences a non-engineer can follow.
State the environment (prod/dev) and the real impact (customer-facing? data loss? noise only?).*

- **What happened:** <plain-language description of the symptom / the incident>
- **Impact:** <who/what is affected, and how badly>
- **Current state:** <firing / resolved / mitigated; what is at risk if untouched>

---

## 2. Technical details

### 2.1 Root cause
*One or two paragraphs: the actual mechanism, not just the symptom.*

### 2.2 Evidence (command → output, as run)
*Each block is the exact command and its actual output. They must match.*

**<What this proves>**
```bash
<exact command, including --context>
```
```
<actual output>
```

*(Repeat one command→output pair per fact.)*

---

## 3. Recommended remediation

*Ordered, most impactful first. Mark clearly what is not yet applied and what needs approval.
Link any owner-run script under `commands-to-run/`.*

1. <action> — <why / expected effect>
2. <action>
3. <underlying fix to prevent recurrence>

_All diagnostic commands above were read-only; no cluster state was modified._
