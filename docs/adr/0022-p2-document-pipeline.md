# 0022 — Phase 2 document pipeline: text, OCR, Kruti Dev, chunks, embedder, search

Status: accepted (27 Oct 2026)

## Context
P2 task 4 (spec §12.4, §12.11, F06, F15, F28): every document and court order gets searchable text, in Hindi and
English, as chunks the AI tasks will retrieve (Ask, Brief me, order summaries). Track B is on hold: no Sarvam key, and
§15.6 lets case content go to Sarvam only once its data location and retention are recorded in `docs/vendors.md`.

## Decision
**Kruti Dev and DevLys** (`advocate_shared.krutidev`, `apps/client/lib/core/krutidev.dart`)
- A deterministic table taken from the fonts' own glyphs (Kruti Dev 010 and DevLys 010 rendered code point by code
  point), cross-checked against SIL's TECkit map (MIT) and the common converters; no converter code was copied. DevLys
  differs in five quote slots.
- One longest-match pass, clean-up rules, then the two reorderings Kruti Dev needs: the i-matra typed before its whole
  cluster (`fLFkfr` = स्थिति) and the reph typed after it (`lkeF;Z` = सामर्थ्य).
- Python and Dart share 100 vectors (`config/fixtures/krutidev.json`), legal words among them. The Dart table and rules
  were generated from the Python module's.
- Detection uses letter shares (about a fifth of Kruti Dev Hindi's letters are `k`, the ā sign), common words and the
  font's punctuation. It needs a paragraph, and no repository text, English or romanised Hindi tested trips it.
- Conversion runs in linear time (every rule is anchored at the start of its run), so a crafted 20,000-character text
  converts in milliseconds; speed tests in both languages guard each rewritten rule.
- Uses: PDFs convert only the text drawn in a font named Kruti Dev or DevLys (the page number in Times stays); a page
  with unnamed fonts converts when it reads as Kruti Dev. DOCX converts the runs whose font, set on the run or inherited
  from its style or the document default, is Kruti Dev or DevLys; when none is named but the text reads as Kruti Dev,
  only runs without a named font convert. Case and client notes offer to convert pasted Kruti Dev: only the pasted
  part converts (English already in the note stays), and the change can be undone. `POST /v1/text/krutidev-to-unicode`
  converts up to 20,000 characters, off the event loop.

**Reading text** (`advocate_workers.doctext`, `text`)
- pypdfium2 reads the text layer page by page. A page with fewer than 30 letters is a scan: it is rendered at 300 dpi
  greyscale and read by Tesseract `hin+eng` (stdin to stdout, no temporary files). Images are read by Tesseract; DOCX
  from its XML (one page; tabs and line breaks kept, so the words beside them stay apart).
- A page pdfium cannot load or render, or one Tesseract fails on or times out on, is left empty and the rest of the
  file is read. A file that claims more pages than it has stops after a run of pages that fail to load.
- **OCR is Tesseract only for now.** The Sarvam Document Digitization client waits for B7: it needs the key, and the
  §15.6 data-terms record before any scan goes to Sarvam. The reader takes any OCR function, so Sarvam slots in.
- Extraction runs when a document's malware scan passes and when a court order's PDF is stored (by the order pipeline
  or the API's fetch-on-open). An hourly sweep picks up what is left: files from before P2, lost tasks, and scans that
  waited because no OCR engine was there (`text_status = ocr_pending`). Unreadable or missing files are `failed`.
- It runs on its own `text` queue and worker, one file at a time, so a long scan delays neither user jobs nor the
  evening board. The API routes it there too (the routes live in `advocate_shared.tasks`).
- A run reads only sources still at `none` or `ocr_pending`, so a redelivered or swept duplicate costs one query. A
  run may take 3 hours (soft limit; hard limit 5 minutes later). The broker's visibility timeout is 4 hours, above the
  hard limit, so a long scan is not redelivered while it runs; this also delays redelivery of a task lost in a crash.
  Any unexpected error, the soft limit included, marks the source `failed`; a source whose runs are killed three times
  is marked `failed` too, so the sweep never retries a file forever.
- Statuses: `text` (all from the text layer), `ocr_done`, `ocr_pending` (Tesseract or its Hindi data missing),
  `failed`. `pages`, `language` (`hi`, `en` or `mixed`) and `legacy_font_detected` are filled in.

**Chunks** (spec §12.4): about 400 tokens with 50 overlapping, never across pages, counted as one token per four
characters. Runs of spaces collapse and an over-long word is cut, so a chunk stays near 2,000 characters, well inside the
embedder's limit. Each chunk lists the numbered paragraph it starts in (carried across pages) and those that start inside it
("12.", "12.1", "(4)", "para 5"; not "302 IPC" or dates). A document's chunks are its organisation's; a court order's are
shared (ADR 0019).

**Embedder** (`services/embedder`): a FastAPI service with BGE-M3 dense vectors (1024-d, unit length) and
bge-reranker-v2-m3 scores, on CPU, one request at a time. The image downloads only the files the models load at build
time and runs offline. PyTorch comes from the CPU index, so no CUDA is installed. Tests and CI use deterministic fake
models behind the same HTTP API. The workers embed new chunks in batches of 16 (after each extraction, and every 15
minutes for leftovers). A batch the embedder refuses (400, 413, 422) is retried one chunk at a time, and a chunk still
refused is remembered in Redis and skipped, so one bad chunk cannot stop embedding for everyone; an outage stops the
run until the next one. Without `EMBEDDER_URL` nothing is embedded and search uses full text alone.

**Search** (`advocate_shared.retrieval`, `POST /v1/documents/search`)
- Full-text top 40 and vector top 40, fused by reciprocal rank (k = 60), reranked, top 8.
- A page only the vector branch found is kept only when the reranker scores it 0.2 or more (to be tuned on real
  files); without the reranker it is dropped, so a search for words in no page shows none.
- The embedder and the reranker share one 10-second deadline per search, under the app's 20-second timeout; past it
  the search answers from what it has.
- It runs on the user's connection, so row-level security applies on top of the explicit organisation filter and the
  optional case filter. Deleted and unscanned documents are skipped, and court orders are reached through the
  organisation's own `orders` rows.
- Full text matches any of the words. Pages with all of them come first; the rest are ranked without common function
  words (की, के, को, the, of, to …), so a page is not lifted by how often it says की.
- `public.search_text` folds the nukta, the visarga, chandrabindu and Devanagari digits on both sides, so जमानत finds
  ज़मानत and `दुख` finds दुःख (and Kruti Dev's `:` for ः). The Python `fold` mirrors it for the snippets.
- Vectors are compared exactly over the organisation's chunks (thousands), so filters never starve the result; an HNSW
  scan with `hnsw.iterative_scan` is the step up if an organisation reaches hundreds of thousands.
- The app searches inside documents online, on a tap or Enter, even when the organisation has uploaded nothing (its
  court orders are searchable); the results come above the title matches and are announced. A hit's source chip opens
  the document or order at that page (`?page=`).

## Consequences
- The worker image now carries Tesseract with Hindi and English. CI installs it, so the OCR test reads real Hindi there.
- Local development without the embedder searches full text only. `docker compose --profile embedder` adds it, with a
  large image (the models are about 4.6 GB).
- Search quality on real scans, the Sarvam client and its cost (₹0.5 per page) wait for B7 and B12.
- New Hindi strings wait for the native-speaker review: the inside-search texts and the Kruti Dev offer
  (`krutidevFound`: "यह कृतिदेव फ़ॉन्ट में टाइप की गई हिंदी लगती है।").
