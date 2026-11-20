// md-to-docx.mjs — render an ops report Markdown file to a Word (.docx) document.
// ---------------------------------------------------------------------------------------
// The .md is the SOURCE OF TRUTH (agents keep writing/reading .md). This tool only makes a
// Word COPY on demand — e.g. when the owner says "make that report for my manager".
//
// Usage:
//   node md-to-docx.mjs <input.md> [output.docx]
//   npm --prefix templates/reports run report -- <input.md> [output.docx]
//
// Depth: FULL TECHNICAL — every heading, table, bullet, and fenced log block in the .md is
// rendered inline (nothing is dropped or summarised).
//
// Branding: title page shows "Prepared for: <PREPARED_FOR>" (default below; override with the
// PREPARED_FOR env var, or let the optional company map drive it — see "company attribution").
// Title page is built from the first `# H1` and the `- **Key:** value` metadata bullets that
// immediately follow it (up to the first `---` or `##`). Everything after is the body.
//
// Supported Markdown: #..#### headings, **bold**, *italic*, `code`, [text](url) (renders the
// text), - / * bullet lists (nested by indent), 1. ordered lists, GFM pipe tables, ``` fenced
// code blocks (```chart => a bar chart), > blockquotes, and --- horizontal rules.
// ---------------------------------------------------------------------------------------
import { readFileSync, writeFileSync, unlinkSync } from 'node:fs';
import { resolve, basename, dirname } from 'node:path';
import { execFileSync } from 'node:child_process';
import {
  Document, Packer, Paragraph, TextRun, HeadingLevel, Table, TableRow, TableCell,
  WidthType, AlignmentType, BorderStyle, ShadingType, PageBreak, Footer, PageNumber,
  VerticalAlign, ImageRun,
} from 'docx';

const NAVY = '1F3864', GREY = '595959', CODEBG = 'F2F2F2', BORDER = 'BFBFBF';
// named colours usable in ```chart blocks (severity/RAG palette)
const CHARTCOLORS = {
  red: 'C00000', orange: 'ED7D31', amber: 'FFC000', yellow: 'FFD966',
  green: '70AD47', blue: '4472C4', navy: '1F3864', teal: '2E9599',
  grey: '808080', gray: '808080',
};
// Default "Prepared for:" branding. Override per-render with the PREPARED_FOR env var, or populate
// the company map below to drive it from the report's declared Company.
let PREPARED_FOR = process.env.PREPARED_FOR || 'YOUR ORGANISATION';

// ---- company/tenant attribution (OPTIONAL) — authoritative map + enforcer -----------------
// Leave BOTH tables EMPTY to disable attribution enforcement entirely (any report renders; the
// "Prepared for:" line uses PREPARED_FOR above). To ENFORCE that every report is attributed to the
// right company/tenant (and hard-fail a mismatch), fill these in and keep company-map.md in sync.
//
// Example (uncomment + edit for your org):
//   const COMPANY_BY_PROJECT = { webstore: 'ACME RETAIL', billing: 'ACME RETAIL', clinic: 'ACME HEALTH' };
//   const COMPANY_ALIASES    = { acmeretail: 'ACME RETAIL', acmehealth: 'ACME HEALTH' };
const COMPANY_BY_PROJECT = {};
const COMPANY_ALIASES = {};
const _norm = (s) => String(s).toLowerCase().replace(/[^a-z0-9]/g, '');
const ENFORCE_ATTRIBUTION = Object.keys(COMPANY_BY_PROJECT).length > 0;

// ---- CLI --------------------------------------------------------------------------------
const inArg = process.argv[2];
if (!inArg) { console.error('usage: node md-to-docx.mjs <input.md> [output.docx]'); process.exit(1); }
const inPath = resolve(process.cwd(), inArg);
const outPath = process.argv[3]
  ? resolve(process.cwd(), process.argv[3])
  : resolve(dirname(inPath), basename(inPath).replace(/\.md$/i, '') + '.docx');
const md = readFileSync(inPath, 'utf8').replace(/\r\n/g, '\n').replace(/<!--[\s\S]*?-->/g, '');

// ---- inline tokenizer -> TextRun[] ------------------------------------------------------
function leaves(text, base = {}) {
  const out = []; let buf = ''; let s = text;
  const flush = () => { if (buf) { out.push({ ...base, text: buf }); buf = ''; } };
  while (s.length) {
    let m;
    if ((m = /^`([^`]+)`/.exec(s)))                    { flush(); out.push({ ...base, mono: true, text: m[1] }); s = s.slice(m[0].length); continue; }
    if ((m = /^\*\*(\S[\s\S]*?\S|\S)\*\*/.exec(s)))     { flush(); out.push(...leaves(m[1], { ...base, bold: true })); s = s.slice(m[0].length); continue; }
    if ((m = /^\*(\S[\s\S]*?\S|\S)\*/.exec(s)))         { flush(); out.push(...leaves(m[1], { ...base, italics: true })); s = s.slice(m[0].length); continue; }
    if ((m = /^\[([^\]]+)\]\(([^)]+)\)/.exec(s)))       { flush(); out.push(...leaves(m[1], { ...base })); s = s.slice(m[0].length); continue; }
    buf += s[0]; s = s.slice(1);
  }
  flush();
  return out;
}
const runs = (text, base = {}) => leaves(text, base).map((l) => new TextRun({
  text: l.text, bold: l.bold, italics: l.italics, color: l.color,
  size: l.size ?? base.size ?? 22, font: l.mono ? 'Consolas' : 'Calibri',
}));

// ---- table helpers ----------------------------------------------------------------------
const b = { style: BorderStyle.SINGLE, size: 4, color: BORDER };
const isSep = (ln) => /\|/.test(ln) && /^[\s|:-]+$/.test(ln) && /-/.test(ln);
const splitRow = (ln) => ln.replace(/^\s*\|/, '').replace(/\|\s*$/, '').split('|').map((s) => s.trim());
function cell(text, { header, width } = {}) {
  return new TableCell({
    width: width ? { size: width, type: WidthType.PERCENTAGE } : undefined,
    shading: header ? { type: ShadingType.CLEAR, fill: NAVY } : undefined,
    margins: { top: 60, bottom: 60, left: 80, right: 80 },
    children: [new Paragraph({ children: runs(text, header ? { bold: true, color: 'FFFFFF', size: 20 } : { size: 20 }) })],
  });
}
function makeTable(rows) {
  const n = rows[0].length; const w = Math.floor(100 / n);
  return new Table({
    width: { size: 100, type: WidthType.PERCENTAGE },
    borders: { top: b, bottom: b, left: b, right: b, insideHorizontal: b, insideVertical: b },
    rows: rows.map((r, ri) => new TableRow({
      tableHeader: ri === 0,
      children: r.map((cText) => cell(cText, { header: ri === 0, width: w })),
    })),
  });
}

// ---- block helpers ----------------------------------------------------------------------
const HMAP = { 1: HeadingLevel.HEADING_1, 2: HeadingLevel.HEADING_1, 3: HeadingLevel.HEADING_2, 4: HeadingLevel.HEADING_3 };
const codeLines = (lines) => lines.map((ln, i) => new Paragraph({
  spacing: { after: i === lines.length - 1 ? 120 : 0 },
  shading: { type: ShadingType.CLEAR, fill: CODEBG },
  children: [new TextRun({ text: ln === '' ? ' ' : ln, font: 'Consolas', size: 18 })],
}));
const rule = () => new Paragraph({ spacing: { before: 60, after: 120 }, border: { bottom: { style: BorderStyle.SINGLE, size: 6, color: BORDER, space: 1 } } });

// ---- native bar chart (no image deps): horizontal bars built from shaded table cells --------
// Source syntax inside a ```chart fenced block:
//   title: <chart title>
//   <label> | <number> | <colour>
function parseChart(buf) {
  let title = ''; const rows = [];
  for (const ln of buf) {
    const t = ln.trim(); if (!t) continue;
    let m; if ((m = /^title:\s*(.+)$/i.exec(t))) { title = m[1].trim(); continue; }
    const p = t.split('|').map((s) => s.trim());
    if (p.length >= 2) {
      const val = parseFloat((p[1] || '').replace(/[^0-9.\-]/g, '')) || 0;
      rows.push({ label: p[0], val, color: (p[2] || 'navy').toLowerCase() });
    }
  }
  return { title, rows };
}
const noB = { style: BorderStyle.NONE, size: 0, color: 'FFFFFF' };
const NOBORDERS = { top: noB, bottom: noB, left: noB, right: noB, insideHorizontal: noB, insideVertical: noB };
function makeBarChart(buf) {
  const { title, rows } = parseChart(buf);
  const out = [];
  if (title) out.push(new Paragraph({ spacing: { before: 200, after: 100 }, children: runs(title, { bold: true, color: NAVY, size: 22 }) }));
  const max = Math.max(1, ...rows.map((r) => r.val));
  const LABELW = 2900, VALW = 760, BARMAX = 5200; // twips
  const trows = rows.map((r) => {
    const fill = Math.max(0, Math.round((r.val / max) * BARMAX));
    const rest = Math.max(1, BARMAX - fill);
    const hex = CHARTCOLORS[r.color] || NAVY;
    const barCells = [];
    if (fill > 0) barCells.push(new TableCell({ width: { size: fill, type: WidthType.DXA }, shading: { type: ShadingType.CLEAR, fill: hex }, borders: NOBORDERS, children: [new Paragraph({ spacing: { before: 0, after: 0 }, children: [new TextRun({ text: ' ', size: 16 })] })] }));
    barCells.push(new TableCell({ width: { size: rest, type: WidthType.DXA }, borders: NOBORDERS, children: [new Paragraph({ spacing: { before: 0, after: 0 }, children: [new TextRun({ text: ' ', size: 16 })] })] }));
    const barTable = new Table({ width: { size: BARMAX, type: WidthType.DXA }, columnWidths: fill > 0 ? [fill, rest] : [rest], borders: NOBORDERS, rows: [new TableRow({ children: barCells })] });
    return new TableRow({ children: [
      new TableCell({ width: { size: LABELW, type: WidthType.DXA }, borders: NOBORDERS, verticalAlign: VerticalAlign.CENTER, margins: { top: 30, bottom: 30, right: 140 }, children: [new Paragraph({ children: runs(r.label, { size: 20 }) })] }),
      new TableCell({ width: { size: BARMAX, type: WidthType.DXA }, borders: NOBORDERS, verticalAlign: VerticalAlign.CENTER, children: [barTable, new Paragraph({ spacing: { before: 0, after: 0 }, children: [] })] }),
      new TableCell({ width: { size: VALW, type: WidthType.DXA }, borders: NOBORDERS, verticalAlign: VerticalAlign.CENTER, margins: { left: 120 }, children: [new Paragraph({ children: runs(String(r.val), { bold: true, size: 20, color: NAVY }) })] }),
    ] });
  });
  out.push(new Table({ width: { size: 100, type: WidthType.PERCENTAGE }, columnWidths: [LABELW, BARMAX, VALW], borders: NOBORDERS, rows: trows }));
  out.push(new Paragraph({ spacing: { after: 200 }, children: [] }));
  return out;
}

// ---- split off the title page -----------------------------------------------------------
const allLines = md.split('\n');
let title = basename(inPath).replace(/\.md$/i, ''), subtitle = null;
const meta = []; let start = 0;
{
  let i = 0;
  while (i < allLines.length && allLines[i].trim() === '') i++;
  const h1 = /^#\s+(.+)$/.exec(allLines[i] || '');
  if (h1) {
    title = h1[1].trim(); i++;
    for (; i < allLines.length; i++) {
      const ln = allLines[i]; const t = ln.trim();
      if (t === '') continue;
      if (/^---+$/.test(t)) { i++; break; }                 // consume the divider
      if (/^#{2,}\s+/.test(t)) break;                        // body starts (do not consume)
      let mm = /^(?:[-*]\s+)?\*\*(.+?):\*\*\s*(.*)$/.exec(t); // - **Key:** value
      if (mm) { meta.push([mm[1].trim(), mm[2].trim()]); continue; }
      if (!subtitle && meta.length === 0) { subtitle = t; continue; }
      break;
    }
    start = i;
  }
}

// ---- company-attribution enforcement (OPTIONAL — only when COMPANY_BY_PROJECT is populated) --
// When enabled, the report MUST declare `- **Project:** <name>` and `- **Company:** <name>`, and the
// company MUST match the project(s) per COMPANY_BY_PROJECT. Mismatch / missing / unknown => hard
// abort, no .docx. When the map is empty, this block is skipped entirely.
if (ENFORCE_ATTRIBUTION) {
  const getMeta = (key) => { const f = meta.find(([k]) => k.toLowerCase() === key); return f ? f[1] : null; };
  const projField = getMeta('project') || getMeta('projects');
  const compField = getMeta('company');
  const bail = (msg) => {
    console.error('\n✗ COMPANY-ATTRIBUTION CHECK FAILED — no .docx produced.\n  ' + msg +
      '\n  Fix the report metadata. Map/rule: templates/reports/company-map.md.\n');
    process.exit(2);
  };
  if (!projField) bail('Missing `- **Project:** <name>` metadata bullet (right under the # title).');
  if (!compField) bail('Missing `- **Company:** <name>` metadata bullet (right under the # title).');

  const projects = projField.split(/[,·/&]+|\band\b/i).map(_norm).filter(Boolean);
  if (!projects.length) bail('Project field is empty.');
  const unknown = projects.filter((p) => !(p in COMPANY_BY_PROJECT));
  if (unknown.length) bail('Unknown project(s) not in the company map: ' + unknown.join(', ') +
    '. Classify them in COMPANY_BY_PROJECT (md-to-docx.mjs) + company-map.md before rendering.');

  const mapped = [...new Set(projects.map((p) => COMPANY_BY_PROJECT[p]))].sort();
  const declared = [...new Set(compField.split(/[,&]+|\band\b/i).map((c) => COMPANY_ALIASES[_norm(c)]).filter(Boolean))].sort();
  if (!declared.length) bail('Company "' + compField + '" is not recognised (not in COMPANY_ALIASES).');
  if (JSON.stringify(mapped) !== JSON.stringify(declared))
    bail('Declared Company [' + declared.join(' + ') + '] does not match the project(s) ' +
      projects.join(', ') + ' → correct company is [' + mapped.join(' + ') + '].');

  if (!process.env.PREPARED_FOR) PREPARED_FOR = mapped.join(' & ');
}

// ---- render title page ------------------------------------------------------------------
const c = [];
const charts = []; // collected ```chart specs; turned into NATIVE editable Word charts post-render
// optional title-page logo (env REPORT_LOGO=<png path>; REPORT_LOGO_W/H override px size).
const LOGO_PATH = process.env.REPORT_LOGO || '';
let hasLogo = false;
if (LOGO_PATH) {
  try {
    const img = readFileSync(LOGO_PATH);
    const lw = parseInt(process.env.REPORT_LOGO_W || '220', 10);
    const lh = parseInt(process.env.REPORT_LOGO_H || '49', 10);
    c.push(new Paragraph({ alignment: AlignmentType.CENTER, spacing: { before: 1400, after: 140 }, children: [new ImageRun({ data: img, type: 'png', transformation: { width: lw, height: lh } })] }));
    hasLogo = true;
  } catch (e) { console.warn('WARN: REPORT_LOGO not embedded:', e.message); }
}
// eyebrow + navy band for a designed letterhead feel (eyebrow text overridable per report)
const EYEBROW = process.env.REPORT_EYEBROW || 'CONFIDENTIAL · INTERNAL REPORT';
c.push(new Paragraph({ spacing: { before: hasLogo ? 60 : 1800, after: 60 }, alignment: AlignmentType.CENTER, children: [new TextRun({ text: EYEBROW, bold: true, size: 18, color: GREY, font: 'Calibri' })] }));
c.push(new Paragraph({ spacing: { before: 0, after: 160 }, alignment: AlignmentType.CENTER, border: { bottom: { style: BorderStyle.SINGLE, size: 18, color: NAVY, space: 1 } }, children: [] }));
c.push(new Paragraph({ spacing: { before: 120, after: 120 }, alignment: AlignmentType.CENTER, children: runs(title, { bold: true, size: 44, color: NAVY }) }));
if (subtitle) c.push(new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 200 }, children: runs(subtitle, { size: 26, color: GREY }) }));
c.push(new Paragraph({ spacing: { before: 0, after: 300 }, alignment: AlignmentType.CENTER, border: { bottom: { style: BorderStyle.SINGLE, size: 6, color: BORDER, space: 1 } }, children: [] }));
c.push(new Paragraph({ alignment: AlignmentType.CENTER, spacing: { before: subtitle ? 0 : 300, after: 300 }, children: [new TextRun({ text: `Prepared for: ${PREPARED_FOR}`, bold: true, size: 24, font: 'Calibri' })] }));
for (const [k, v] of meta) {
  c.push(new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 60 }, children: [new TextRun({ text: `${k}: `, bold: true, size: 22, font: 'Calibri' }), ...runs(v, { size: 22 })] }));
}
c.push(new Paragraph({ children: [new PageBreak()] }));

// ---- render body ------------------------------------------------------------------------
for (let i = start; i < allLines.length; i++) {
  const raw = allLines[i]; const t = raw.trim();

  if (t === '') continue;

  // fenced block — ```chart renders a native bar chart; anything else is a code/log block
  let m = /^```(\w*)/.exec(t);
  if (m) {
    const lang = (m[1] || '').toLowerCase();
    const buf = [];
    for (i++; i < allLines.length && !/^```/.test(allLines[i].trim()); i++) buf.push(allLines[i]);
    if (lang === 'chart') {
      const { title, rows } = parseChart(buf);
      const n = charts.length + 1;
      charts.push({ title, rows: rows.map((r) => ({ label: r.label, val: r.val, hex: CHARTCOLORS[r.color] || NAVY })) });
      c.push(new Paragraph({ spacing: { before: 120, after: 120 }, children: [new TextRun({ text: `@@CHART:${n}@@` })] }));
    } else c.push(...codeLines(buf));
    continue;
  }

  // horizontal rule
  if (/^(-{3,}|\*{3,}|_{3,})$/.test(t)) { c.push(rule()); continue; }

  // heading
  if ((m = /^(#{1,6})\s+(.+)$/.exec(t))) {
    const lvl = m[1].length;
    c.push(new Paragraph({ heading: HMAP[lvl] || HeadingLevel.HEADING_4, spacing: { before: 240, after: 120 }, children: runs(m[2], { bold: true, color: NAVY }) }));
    continue;
  }

  // table: a row with '|' immediately followed by a separator line
  if (/\|/.test(t) && i + 1 < allLines.length && isSep(allLines[i + 1])) {
    const rows = [splitRow(t)]; i += 2; // skip header + separator
    for (; i < allLines.length && /\|/.test(allLines[i]) && allLines[i].trim() !== ''; i++) rows.push(splitRow(allLines[i]));
    i--; // step back; loop will i++
    c.push(makeTable(rows));
    c.push(new Paragraph({ spacing: { after: 80 }, children: [] }));
    continue;
  }

  // blockquote
  if ((m = /^>\s?(.*)$/.exec(t))) {
    c.push(new Paragraph({ spacing: { after: 100 }, indent: { left: 360 }, children: runs(m[1], { italics: true, color: GREY }) }));
    continue;
  }

  // unordered list (nested by leading spaces)
  if ((m = /^(\s*)[-*+]\s+(.+)$/.exec(raw))) {
    const level = Math.min(3, Math.floor(m[1].length / 2));
    c.push(new Paragraph({ bullet: { level }, spacing: { after: 60 }, children: runs(m[2]) }));
    continue;
  }

  // ordered list -> explicit number prefix (robust, no docx numbering state)
  if ((m = /^(\s*)(\d+)\.\s+(.+)$/.exec(raw))) {
    c.push(new Paragraph({ spacing: { after: 60 }, indent: { left: 360 }, children: [new TextRun({ text: `${m[2]}. `, bold: true, size: 22, font: 'Calibri' }), ...runs(m[3])] }));
    continue;
  }

  // paragraph: join following plain lines until blank / next block
  const para = [raw];
  while (i + 1 < allLines.length) {
    const nx = allLines[i + 1]; const nt = nx.trim();
    if (nt === '' || /^(#{1,6})\s/.test(nt) || /^```/.test(nt) || /^(-{3,}|\*{3,}|_{3,})$/.test(nt)
      || /^>\s?/.test(nt) || /^(\s*)[-*+]\s+/.test(nx) || /^(\s*)\d+\.\s+/.test(nx)
      || (/\|/.test(nt) && i + 2 < allLines.length && isSep(allLines[i + 2]))) break;
    para.push(nx); i++;
  }
  c.push(new Paragraph({ spacing: { after: 120 }, children: runs(para.join(' ')) }));
}

// ---- assemble & write -------------------------------------------------------------------
const footer = new Footer({ children: [new Paragraph({
  alignment: AlignmentType.CENTER,
  children: [new TextRun({ text: 'Page ', size: 16, color: GREY, font: 'Calibri' }), new TextRun({ children: [PageNumber.CURRENT], size: 16, color: GREY, font: 'Calibri' })],
})] });

const doc = new Document({
  creator: 'cluster-ops', title,
  sections: [{ properties: {}, footers: { default: footer }, children: c }],
});
Packer.toBuffer(doc).then((buf) => {
  writeFileSync(outPath, buf);
  console.log('WROTE', outPath, buf.length, 'bytes');
  // Turn ```chart placeholders into NATIVE, editable Word charts (needs python on PATH).
  if (charts.length) {
    const side = outPath + '.charts.json';
    writeFileSync(side, JSON.stringify(charts));
    const injector = resolve(dirname(process.argv[1]), 'inject-charts.py');
    let done = false;
    for (const py of ['python', 'python3']) {
      try { execFileSync(py, [injector, outPath, side], { stdio: 'inherit' }); done = true; break; }
      catch (e) { /* try next interpreter */ }
    }
    try { unlinkSync(side); } catch { /* ignore */ }
    if (!done) console.warn('WARN: could not run inject-charts.py (python not found) — charts left as placeholders');
  }
});
