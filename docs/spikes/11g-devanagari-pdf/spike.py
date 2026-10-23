"""Spike 11g: do Devanagari conjuncts and vowel signs survive WeasyPrint, LibreOffice (DOCX → PDF) and a
Tesseract hin+eng text layer merged with pikepdf? Writes PDFs + PNG renders to out/ and prints a report."""

import subprocess
from pathlib import Path

import pikepdf
import pypdfium2 as pdfium
from docx import Document
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Pt
from weasyprint import HTML

OUT = Path("out")
OUT.mkdir(exist_ok=True)

# Conjuncts (क्ष त्र ज्ञ श्र द्ध प्र र्), vowel signs (ि ी ु ू ृ े ै ो ौ), nukta (ज़ फ़), anusvara/chandrabindu.
SAMPLE = [
    "माननीय उच्च न्यायालय मध्यप्रदेश, खंडपीठ इंदौर",
    "याचिकाकर्ता की ओर से श्री राम शर्मा, अधिवक्ता उपस्थित।",
    "क्षतिपूर्ति, त्रुटि, ज्ञापन, श्रीमती, सिद्धांत, प्रार्थना, कर्तव्य, धर्मार्थ",
    "ज़मानत आवेदन क्रमांक 1234/2024 — अगली तारीख 05-11-2026",
    "हस्ताक्षर, ऋण, कृषि, पूर्वोक्त, सौंपें, कौन, चाँद, संविधान",
    "Ramesh Sharma v. State of M.P. — WP 1234/2024 · ₹1,25,000",
]
FONTS = ["Mukta", "Noto Sans Devanagari"]


def render(pdf: Path) -> list[str]:
    """PNG of page 1 at 2x for eyeballing, and the extracted text of every page."""
    doc = pdfium.PdfDocument(pdf)
    doc[0].render(scale=2).to_pil().save(pdf.with_suffix(".png"))
    return [doc[i].get_textpage().get_text_range() for i in range(len(doc))]


def check(name: str, pdf: Path) -> bool:
    text = " ".join(render(pdf))
    missing = [line for line in SAMPLE if line.split(",")[0].split("—")[0].strip() not in text]
    print(f"{name:34} pages={len(pdfium.PdfDocument(pdf))} text-extract={'OK' if not missing else 'MISSING ' + str(missing)}")
    return not missing


def weasy(font: str) -> Path:
    body = "".join(f"<p>{line}</p>" for line in SAMPLE)
    html = f"<html><body style='font-family:\"{font}\";font-size:14pt;line-height:1.6'>{body}</body></html>"
    pdf = OUT / f"weasy-{font.split()[0].lower()}.pdf"
    HTML(string=html).write_pdf(pdf)
    return pdf


def libreoffice(font: str) -> Path:
    doc = Document()
    style = doc.styles["Normal"]
    style.font.name, style.font.size = font, Pt(14)
    style.element.rPr.rFonts.set(qn("w:cs"), font)  # complex-script font slot used for Devanagari
    style.element.rPr.rFonts.set(qn("w:eastAsia"), font)
    # Devanagari uses the complex-script size (w:szCs); without it LibreOffice falls back to its default.
    size_cs = OxmlElement("w:szCs")
    size_cs.set(qn("w:val"), "28")  # half-points
    style.element.rPr.append(size_cs)
    for line in SAMPLE:
        doc.add_paragraph().add_run(line)
    docx = OUT / f"lo-{font.split()[0].lower()}.docx"
    doc.save(docx)
    subprocess.run(["soffice", "--headless", "--convert-to", "pdf", "--outdir", str(OUT), str(docx)],
                   check=True, capture_output=True)
    return docx.with_suffix(".pdf")


def tesseract_layer(source_pdf: Path) -> Path:
    """Scan-like PDF (image only) + Tesseract hin+eng text-only PDF, merged with pikepdf (spec §4.4 F34)."""
    img = OUT / "scan.png"
    pdfium.PdfDocument(source_pdf)[0].render(scale=300 / 72).to_pil().convert("L").save(img, dpi=(300, 300))
    image_pdf = OUT / "scan-image.pdf"
    from PIL import Image
    Image.open(img).save(image_pdf, resolution=300)
    subprocess.run(["tesseract", str(img), str(OUT / "scan-text"), "-l", "hin+eng", "-c", "textonly_pdf=1", "pdf"],
                   check=True, capture_output=True)
    merged = OUT / "scan-searchable.pdf"
    with pikepdf.open(image_pdf) as base, pikepdf.open(OUT / "scan-text.pdf") as layer:
        base.pages[0].add_overlay(layer.pages[0])  # invisible text drawn over the scan
        base.save(merged)
    return merged


if __name__ == "__main__":
    results = {}
    for font in FONTS:
        results[f"WeasyPrint · {font}"] = check(f"WeasyPrint · {font}", weasy(font))
        results[f"LibreOffice · {font}"] = check(f"LibreOffice · {font}", libreoffice(font))
    merged = tesseract_layer(OUT / "weasy-mukta.pdf")
    text = render(merged)[0]
    words = ["न्यायालय", "याचिकाकर्ता", "अधिवक्ता", "ज़मानत", "1234/2024", "Sharma"]
    found = [w for w in words if w in text]
    print(f"Tesseract hin+eng + pikepdf          searchable words found: {len(found)}/{len(words)} {found}")
    print("ALL OK" if all(results.values()) and len(found) >= 4 else "CHECK REPORT")
