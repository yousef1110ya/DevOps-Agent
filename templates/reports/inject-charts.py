#!/usr/bin/env python3
# inject-charts.py — post-process a .docx produced by md-to-docx.mjs, replacing each
# "@@CHART:n@@" placeholder paragraph with a NATIVE, editable Word bar chart (DrawingML).
# Native charts => the owner can right-click the chart in Word to change colours, type, and values.
#
# Usage:  python inject-charts.py <docx> <charts.json>
#   charts.json = [{ "title": str, "rows": [{ "label": str, "val": number, "hex": "RRGGBB" }, ...] }, ...]
# Invoked automatically by md-to-docx.mjs when the report contains ```chart blocks.
import sys, json, zipfile, shutil, re

docx_path, spec_path = sys.argv[1], sys.argv[2]
charts = json.load(open(spec_path, encoding='utf-8'))
CHART_CT = 'application/vnd.openxmlformats-officedocument.drawingml.chart+xml'
C_NS = 'http://schemas.openxmlformats.org/drawingml/2006/chart'
A_NS = 'http://schemas.openxmlformats.org/drawingml/2006/main'
R_NS = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'


def esc(s):
    return str(s).replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def chart_xml(spec):
    rows = spec['rows']; n = len(rows); title = spec.get('title', '')
    cats = ''.join('<c:pt idx="%d"><c:v>%s</c:v></c:pt>' % (i, esc(r['label'])) for i, r in enumerate(rows))
    vals = ''.join('<c:pt idx="%d"><c:v>%s</c:v></c:pt>' % (i, r['val']) for i, r in enumerate(rows))
    dpts = ''.join(
        '<c:dPt><c:idx val="%d"/><c:invertIfNegative val="0"/><c:bubble3D val="0"/>'
        '<c:spPr><a:solidFill><a:srgbClr val="%s"/></a:solidFill>'
        '<a:ln><a:noFill/></a:ln></c:spPr></c:dPt>' % (i, r.get('hex', '1F3864')) for i, r in enumerate(rows))
    title_xml = ''
    if title:
        title_xml = ('<c:title><c:tx><c:rich><a:bodyPr/><a:lstStyle/><a:p><a:pPr><a:defRPr b="1" sz="1100">'
                     '<a:solidFill><a:srgbClr val="1F3864"/></a:solidFill></a:defRPr></a:pPr>'
                     '<a:r><a:rPr lang="en-US" b="1" sz="1100"><a:solidFill><a:srgbClr val="1F3864"/></a:solidFill></a:rPr>'
                     '<a:t>%s</a:t></a:r></a:p></c:rich></c:tx><c:overlay val="0"/></c:title>' % esc(title))
    return ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<c:chartSpace xmlns:c="%s" xmlns:a="%s" xmlns:r="%s">' % (C_NS, A_NS, R_NS) +
            '<c:roundedCorners val="0"/><c:chart>' + title_xml +
            '<c:autoTitleDeleted val="%d"/>' % (0 if title else 1) +
            '<c:plotArea><c:layout/>'
            '<c:barChart><c:barDir val="bar"/><c:grouping val="clustered"/><c:varyColors val="1"/>'
            '<c:ser><c:idx val="0"/><c:order val="0"/>'
            '<c:tx><c:strRef><c:f>Sheet1!$B$1</c:f><c:strCache><c:ptCount val="1"/>'
            '<c:pt idx="0"><c:v>Value</c:v></c:pt></c:strCache></c:strRef></c:tx>' + dpts +
            '<c:cat><c:strRef><c:f>Sheet1!$A$2:$A$%d</c:f><c:strCache><c:ptCount val="%d"/>%s</c:strCache></c:strRef></c:cat>' % (n + 1, n, cats) +
            '<c:val><c:numRef><c:f>Sheet1!$B$2:$B$%d</c:f><c:numCache><c:formatCode>General</c:formatCode>'
            '<c:ptCount val="%d"/>%s</c:numCache></c:numRef></c:val>' % (n + 1, n, vals) +
            '</c:ser>'
            '<c:gapWidth val="60"/><c:axId val="111111111"/><c:axId val="222222222"/></c:barChart>'
            '<c:catAx><c:axId val="111111111"/><c:scaling><c:orientation val="maxMin"/></c:scaling>'
            '<c:delete val="0"/><c:axPos val="l"/><c:crossAx val="222222222"/></c:catAx>'
            '<c:valAx><c:axId val="222222222"/><c:scaling><c:orientation val="minMax"/></c:scaling>'
            '<c:delete val="0"/><c:axPos val="b"/><c:crossAx val="111111111"/></c:valAx>'
            '</c:plotArea><c:plotVisOnly val="1"/><c:dispBlanksAs val="gap"/></c:chart></c:chartSpace>')


def drawing_xml(n, rid, rows):
    cx = 5486400
    cy = max(1600000, len(rows) * 420000 + 700000)
    return ('<w:p><w:r><w:drawing>'
            '<wp:inline distT="0" distB="0" distL="0" distR="0">'
            '<wp:extent cx="%d" cy="%d"/><wp:effectExtent l="0" t="0" r="0" b="0"/>'
            '<wp:docPr id="%d" name="Chart %d"/><wp:cNvGraphicFramePr/>'
            '<a:graphic xmlns:a="%s"><a:graphicData uri="%s">'
            '<c:chart xmlns:c="%s" xmlns:r="%s" r:id="%s"/>'
            '</a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>'
            % (cx, cy, 1000 + n, n, A_NS, C_NS, C_NS, R_NS, rid))


z = zipfile.ZipFile(docx_path)
names = z.namelist()
data = {nm: z.read(nm) for nm in names}
z.close()

doc = data['word/document.xml'].decode('utf-8')
ct = data['[Content_Types].xml'].decode('utf-8')
rels = data['word/_rels/document.xml.rels'].decode('utf-8')

injected = 0
for i, spec in enumerate(charts, start=1):
    rid = 'rIdChart%d' % i
    data['word/charts/chart%d.xml' % i] = chart_xml(spec).encode('utf-8')
    ct = ct.replace('</Types>', '<Override PartName="/word/charts/chart%d.xml" ContentType="%s"/></Types>' % (i, CHART_CT))
    rels = rels.replace('</Relationships>',
                        '<Relationship Id="%s" Type="%s/chart" Target="charts/chart%d.xml"/></Relationships>' % (rid, R_NS, i))
    token = '@@CHART:%d@@' % i
    pat = re.compile(r'<w:p\b[^>]*>(?:(?!</w:p>).)*?' + re.escape(token) + r'(?:(?!</w:p>).)*?</w:p>', re.S)
    doc, cnt = pat.subn(lambda m: drawing_xml(i, rid, spec['rows']), doc, count=1)
    if cnt == 0:
        sys.stderr.write('WARN: placeholder %s not found\n' % token)
    else:
        injected += 1

data['word/document.xml'] = doc.encode('utf-8')
data['[Content_Types].xml'] = ct.encode('utf-8')
data['word/_rels/document.xml.rels'] = rels.encode('utf-8')

tmp = docx_path + '.tmp'
zo = zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED)
for nm in names:
    zo.writestr(nm, data[nm])
for nm in data:
    if nm not in names:
        zo.writestr(nm, data[nm])
zo.close()
shutil.move(tmp, docx_path)
print('INJECTED %d native chart(s) into %s' % (injected, docx_path))
