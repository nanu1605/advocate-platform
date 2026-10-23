# 0006 — Devanagari in generated PDFs — spike 11g

Status: accepted.

## Context
Spike 11g: WeasyPrint and LibreOffice (DOCX → PDF) with Mukta and Noto Sans Devanagari, checking conjuncts and vowel
signs, plus a Tesseract `hin+eng` text layer merged with pikepdf (spec §4.4 F34, §7.2). Reproducible:
`docs/spikes/11g-devanagari-pdf/` (`docker build -t spike-11g . && docker run -v ./out:/spike/out spike-11g`).

## Findings (24 Oct 2026)
- **WeasyPrint + Mukta:** correct shaping of क्ष त्र ज्ञ श्र द्ध प्र, reph (र्), pre-base ि, nukta (ज़), chandrabindu,
  and mixed Hindi/English lines with ₹ and Indian grouping.
- **LibreOffice + Mukta:** correct shaping, but Devanagari renders at LibreOffice's default size unless the DOCX sets
  the complex-script size (`w:szCs`) and font (`w:rFonts w:cs`). With both set, sizes match.
- **Noto Sans Devanagari** has no Latin glyphs, so English falls back to another face (visible serif in LibreOffice).
  Mukta covers both scripts and keeps lines even.
- **Text extraction** from shaped PDFs (pypdfium2) reorders some pre-base matras; fine for our own documents, where
  we keep the source text.
- **Tesseract `hin+eng` text-only PDF + pikepdf overlay:** produces a searchable layer; 4 of 6 probe words found
  (missed a nukta word and `1234/2024`). Adequate as the fallback search layer; Sarvam stays primary for OCR text.
- No AGPL tools needed (no OCRmyPDF/Ghostscript).

## Decision
- Generated PDFs (invoices, boards, drafts) use **Mukta** for both scripts; Noto Sans Devanagari is installed only as
  a fallback font in the worker image.
- Every DOCX template sets `w:rFonts` (ascii, hAnsi, cs) and both `w:sz` and `w:szCs` at style level.
- Worker image packages: `libreoffice-writer-nogui`, `tesseract-ocr` + `-hin` + `-eng`, Pango/HarfBuzz, Mukta, Noto.
- P3/P4 PDF tests rasterise page 1 with pypdfium2 and compare against committed golden PNGs.
