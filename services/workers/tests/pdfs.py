"""Small PDFs written by hand for the text tests: each page a list of (font, lines), where the font is a PDF base
font name. A font named KrutiDev010 is drawn with a stand-in, but its name and character codes are what a real
Kruti Dev PDF carries, so the text layer reads as Kruti Dev text does."""

import io
import zipfile

Page = list[tuple[str, list[str]]]


def _string(line: str) -> bytes:
    raw = line.encode("cp1252")
    return b"(" + raw.replace(b"\\", b"\\\\").replace(b"(", b"\\(").replace(b")", b"\\)") + b")"


def make_pdf(pages: list[Page]) -> bytes:
    fonts = sorted({font for page in pages for font, _ in page})
    objects: list[bytes] = []  # object n is objects[n - 1]

    def add(body: bytes) -> int:
        objects.append(body)
        return len(objects)

    catalog = add(b"")  # filled in below
    tree = add(b"")
    font_ids = {
        f: add(b"<< /Type /Font /Subtype /Type1 /BaseFont /%s /Encoding /WinAnsiEncoding >>" % f.encode())
        for f in fonts
    }
    resources = b"<< /Font << %s >> >>" % b" ".join(b"/F%d %d 0 R" % (i, font_ids[f]) for i, f in enumerate(fonts))
    kids = []
    for page in pages:
        ops = [b"BT 72 780 Td 18 TL"]
        for font, lines in page:
            ops.append(b"/F%d 12 Tf" % fonts.index(font))
            ops += [_string(line) + b" Tj T*" for line in lines]
        ops.append(b"ET")
        stream = b"\n".join(ops)
        content = add(b"<< /Length %d >>\nstream\n%s\nendstream" % (len(stream), stream))
        kids.append(
            add(
                b"<< /Type /Page /Parent %d 0 R /MediaBox [0 0 595 842] /Resources %s /Contents %d 0 R >>"
                % (tree, resources, content)
            )
        )
    objects[catalog - 1] = b"<< /Type /Catalog /Pages %d 0 R >>" % tree
    objects[tree - 1] = b"<< /Type /Pages /Kids [%s] /Count %d >>" % (
        b" ".join(b"%d 0 R" % k for k in kids),
        len(kids),
    )
    out = io.BytesIO()
    out.write(b"%PDF-1.4\n")
    offsets = []
    for n, body in enumerate(objects, 1):
        offsets.append(out.tell())
        out.write(b"%d 0 obj\n%s\nendobj\n" % (n, body))
    xref = out.tell()
    out.write(b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1))
    out.write(b"".join(b"%010d 00000 n \n" % o for o in offsets))
    out.write(b"trailer << /Size %d /Root %d 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, catalog, xref))
    return out.getvalue()


def make_docx(paragraphs: list[str]) -> bytes:
    w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    body = "".join(f"<w:p><w:r><w:t>{p}</w:t></w:r></w:p>" for p in paragraphs)
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w") as z:
        z.writestr("word/document.xml", f'<w:document xmlns:w="{w}"><w:body>{body}</w:body></w:document>')
    return out.getvalue()
