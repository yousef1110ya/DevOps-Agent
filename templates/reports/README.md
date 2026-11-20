# reports/ — human-readable report rendering

Turn an ops report written in Markdown into a polished Word `.docx` for a human audience, while the
Markdown stays the source of truth (and your re-readable copy).

## When to use
Only when the owner **explicitly asks for a report** (RCA, incident writeup, status/manager summary,
or any document deliverable). Normal chat answers and knowledge/playbook updates are not reports.
- **For a human →** render a `.docx` (keep the `.md` too).
- **For you (the agent) →** a plain `.md` is enough; don't render a `.docx`.
- If the audience is unclear, **ask** (pick-one): "A human (`.docx`)" / "You, the agent (`.md`)".

## Setup (once)
```bash
npm --prefix templates/reports install     # installs the 'docx' library
# optional, for native editable Word charts:
#   ensure python3 is on PATH (inject-charts.py runs automatically)
```

## Write + render
1. Copy `_TEMPLATE.md` → `templates/reports/YYYY-MM-DD-<short-desc>.md` and fill it in.
2. Render to the **root** `reports/` folder (outside config):
   ```bash
   node templates/reports/md-to-docx.mjs templates/reports/YYYY-MM-DD-<short-desc>.md reports/YYYY-MM-DD-<short-desc>.docx
   ```
3. Re-render on **every** `.md` edit so the Word copy never drifts. Keep the `.md` — it's the source.

## Files
| File | Purpose |
|------|---------|
| `_TEMPLATE.md` | Start here. Summary → Technical details → Recommended remediation. |
| `md-to-docx.mjs` | The renderer. Full-fidelity: headings, tables, bullets, code/log blocks, `​```chart` bar charts. |
| `inject-charts.py` | Turns `​```chart` placeholders into native, editable Word charts (optional, needs python). |
| `company-map.md` | **Optional** company/tenant attribution — leave empty to disable. |
| `package.json` | Pins the `docx` dependency. |

## Charts
Inside the report, a fenced ` ```chart ` block renders a horizontal bar chart (no image deps):
```
title: Open criticals by quarter
This quarter | 81 | red
Last quarter | 114 | orange
```
Colours: red/orange/amber/yellow/green/blue/navy/teal/grey.

## Branding
The title page shows `Prepared for: <PREPARED_FOR>`. Default is a neutral placeholder; override per
render with `PREPARED_FOR="Your Org"` or let the optional company map drive it. Other env knobs:
`REPORT_EYEBROW`, `REPORT_LOGO` (+ `REPORT_LOGO_W`/`REPORT_LOGO_H`).
