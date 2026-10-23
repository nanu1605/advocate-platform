# 0005 — PDF viewing with pdfrx — spike 11f (host part done, devices pending)

Status: accepted for P1; device numbers pending.

## Context
Spike 11f: pdfrx (PDFium) with 100+ page scanned orders on the low-end Android and on Windows (spec §17 P0).

## Findings (24 Oct 2026, Flutter 3.47.7, pdfrx 2.10.1)
- Builds against Flutter 3.47 (`PdfViewer`, `PdfDocument` APIs unchanged from 2.x docs).
- PDFium engine on the Windows host: a 120-page Devanagari PDF (from spike 11g) opened in **162 ms**; page 60 text
  extracted (375 chars) and rendered at 1080 × 1527 in **15 ms**.
- `pdfrxFlutterInitialize()` needs `path_provider`, which is absent in plain `flutter test`; app code calls it at
  startup, tests use the engine directly.
- Licences: pdfrx MIT, PDFium BSD-3-Clause.

## Decision
Use pdfrx for the P1 document viewer (`PdfViewer` wrapper, kit component #17).

## Still open (before the P1 beta)
- Scroll fps and memory on a 4 GB-RAM Android phone with real 100+ page scanned orders (founder's samples).
- Same on a Windows laptop build (needs Windows Developer Mode for plugin symlinks).
