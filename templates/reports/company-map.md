# Company / tenant attribution map (OPTIONAL)

Use this **only if** your team needs every report attributed to a specific company, tenant, or
business unit — e.g. an agency or MSP that reports under more than one brand. If you don't need that,
ignore this file: leave the map empty and reports render freely with a neutral `Prepared for:` line
(set `PREPARED_FOR=...` or edit the default in `md-to-docx.mjs`).

**To enable enforcement:** fill in BOTH tables below AND the matching `COMPANY_BY_PROJECT` /
`COMPANY_ALIASES` objects in [`md-to-docx.mjs`](md-to-docx.mjs). Keep the two in sync — the
human-readable source of truth is here; the **enforcer** is the code.

## Project → Company

| Project | Company / tenant |
|---------|------------------|
| _(example)_ webstore | **ACME RETAIL** |
| _(example)_ billing  | **ACME RETAIL** |
| _(example)_ clinic   | **ACME HEALTH** |

## Company aliases (what a report may write in the `Company:` bullet → canonical name)

| Written as | Canonical |
|------------|-----------|
| _(example)_ acme retail, acmeretail | **ACME RETAIL** |
| _(example)_ acme health            | **ACME HEALTH** |

## How enforcement works (when enabled)

Every report `.md` must carry two metadata bullets right under the `# title`:

```markdown
- **Project:** webstore            (or a comma list: webstore, billing)
- **Company:** ACME RETAIL
```

On every `md-to-docx.mjs` render the enforcer:
1. **Requires** both `Project` and `Company` bullets — missing → hard abort, no `.docx`.
2. Maps each declared project → its company via `COMPANY_BY_PROJECT`.
3. **Cross-checks** the declared `Company` against the mapped company — any mismatch → hard abort.
4. Rejects an **unknown** project (not in the map) → hard abort.
5. On pass, drives the title-page `Prepared for:` branding from the verified company (unless
   `PREPARED_FOR` env var overrides it).

A failed check exits non-zero and writes **no** `.docx`, so a mis-attributed report can't ship.

## Adding or moving a project

1. Add/adjust the row in the tables above.
2. Add/adjust the key in `COMPANY_BY_PROJECT` in `md-to-docx.mjs` (keys are lowercased,
   alphanumeric-only).
3. If a new company name appears, add its alias to `COMPANY_ALIASES` in the same file.
