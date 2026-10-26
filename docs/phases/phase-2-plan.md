# Phase 2 — Daily AI assistant: plan

Goal (spec §17): the app reads orders, understands voice notes and keeps clients informed, in Hindi or English, with
sources. Features F07, F09, F13, F14 (dictation), F15, F21, F22, F23, F28 (Kruti Dev), F29, F32; F04 (WhatsApp +
email), F03 (ICS feed), F06 (OCR search), scan-to-case; iOS on TestFlight.

**Start condition.** The founder started Phase 2 on 26 Oct 2026 with the Phase 0 and Phase 1 gates still open: Track B
(accounts) is on hold. Phase 2 is split the same way. **Track A** builds everything locally: the LLM, speech-to-text,
OCR and messaging run against fakes and recorded fixtures behind the real adapters, and CI never calls a live
provider. **Track B** needs accounts and keys and waits for the hold to lift. The gate can't close on Track A alone:
the evals on real datasets, the cost check, TestFlight and usability round 3 need Track B.

## Track A — local only, in order

Each row is one or more PRs; CI stays green after each.

| # | Task | Main files |
|---|---|---|
| 1 | **Schema + RLS + pgTAP** for the P2 tables (§9.2): `document_chunks` (pgvector 1024-d HNSW, `tsv`, trigram; server-only), `voice_notes`, `ai_runs`, `ai_answers`, `public_summaries`, `client_messages`, `display_board_snapshots`; an ICS feed token per member; write paths and triggers (§9.3); sync streams for `voice_notes` (own) and `display_board_snapshots` (`is_live`); 5 actors × CRUD | `supabase/migrations/*_ai_assistant.sql`, `supabase/tests/*`, `infra/powersync/*` |
| 2 | **`legal_ai` core** (§12.1–12.3, 12.14): `LLMClient` on Bedrock Runtime (Converse, India profiles only, no sampling parameters, effort and token budgets from `config/ai_models.yaml`) with a fake transport for local and CI; prompt registry (`prompts/<task>.md`, versioned); structured outputs (Pydantic, two retries); numbered `<source>` context and source-id checks; untrusted-text delimiters; `ai_runs` with cost (thinking included × `price_multiplier`); `public_summaries` cache; per-organisation automatic-AI cap and credits in `usage_ledger`; eval harness with synthetic v1 datasets | `packages/legal_ai/*`, `config/ai_models.yaml` |
| 3 | **Kit components deferred from P0** (ADR 0001): AIAnswerCard, SourceChip/CitationChip, MicButton, VoiceConfirmSheet, ItemTracker; kitchen sink and goldens | `apps/client/lib/ui/*`, `features/dev_kitchen_sink/*` |
| 4 | **Document pipeline** (F15, F28, F06): text-layer detection (pypdfium2); OCR adapter (Sarvam Document Digitization when keyed, Tesseract `hin+eng` locally and as fallback); Kruti Dev / DevLys detection and conversion in Python and Dart with shared vectors (`POST /v1/text/krutidev-to-unicode`); per-page text → ~400-token chunks with page and paragraph numbers; `services/embedder` (BGE-M3 dense, bge-reranker-v2-m3, CPU) with a fake for CI; hybrid retrieval (vector ∪ full text → RRF → rerank → top 8, org and matter filters); search inside scans from the app | `services/workers/*`, `services/embedder/*`, `packages/legal_ai/retrieval*`, `apps/client/lib/core/krutidev.dart` |
| 5 | **Order pipeline** (F07, F13): `order_summary` in each tracking user's language, cached in `public_summaries`, fanned out to `orders.summary_*`; `order_intel` → proposed tasks and deadlines (`dedupe_key`) → "New order — 2 actions found"; summaries of private uploads in `ai_answers`; automatic cap, then on open with credits; `POST /v1/orders/{id}/summary`, `/v1/documents/{id}/summary`, `/v1/ai/order-intel`. App: summary card with Hindi/English toggle and page chips, "As cited in this order — not verified", Confirm / Confirm all | `services/workers/*`, `services/api/*`, `features/case_page/*` |
| 6 | **Ask your case and Brief me** (F09, F29): `POST /v1/ai/ask` (SSE) over the organisation's files, "I couldn't find this in the case files"; `POST /v1/ai/brief` (≤ 8 s, every line sourced); answer history in `ai_answers`, deletable. App: Ask tab and case-page AI tab (flag `ask`), Brief me on Today and the board (flag `brief_me`) | `services/api/*`, `features/ask/*`, `features/today/*` |
| 7 | **Voice → diary** (F14, F22): record ≤ 2 min (16 kHz mono), offline queue, upload, speech-to-text adapter (Sarvam when keyed, ≤ 30 s pieces or batch; fake locally), `voice_parse` with today's and tomorrow's matters, VoiceConfirmSheet with low-confidence fields, save only on confirm (`hearings.user_next_date`, tasks, note). The centre button becomes the mic: tap for quick add, hold to record (flag `voice`) | `features/voice/*`, `services/api/*`, `services/workers/*` |
| 8 | **Limitation** (F23): engine (exclusions, certified-copy time, court closed on the last day, VERIFIED holidays and vacations only, "not verified — check manually"), `config/limitation_rules.yaml` with every rule `DRAFT – VERIFY` (listed in `docs/legal-verification.md`, hidden in production builds), `POST /v1/limitation/calculate`, calculator UI with the step-by-step basis, save as a deadline with reminders | `packages/shared/*` or `services/api/*`, `features/limitation/*` |
| 9 | **Live item tracker** (F21): `POST /v1/tracker/{courtId}/{courtNo}`, team-shared current item synced to the chamber, fades after 20 min, cleared after 2 h; "You're 5 items away" from the cause-list item; optional alert at N away (`item_tracker`); ≤ 5 s to other members online (sync test). No scraping: a permitted source later plugs into the same model | `services/api/*`, `features/tracker/*` |
| 10 | **Messaging adapter** (F04, §13.3): `Messaging` interface; WhatsApp Cloud API (utility templates, opt-in, signature-verified webhook, delivery status, cost per message) against recorded fixtures; SES email; WhatsApp and email for `tomorrow_board`, `deadline_due`, `listed_unexpectedly`, `new_device_signin`; channel preferences per kind with minimum content and quiet hours | `packages/shared/messaging/*` or `services/workers/*`, `features/notifications/*` |
| 11 | **Client updates** (F32): `client_update` draft in the client's language after a next date or a new order (`client_update_ready`); a junior's draft waits as `pending_approval`; approve (owner, advocate); send by "Share via my WhatsApp" (default, free) or the WhatsApp API; preview shows exactly what is sent; every send logged; automated test that nothing sends without approval | `services/api/*`, `features/clients/*`, `features/case_page/*` |
| 12 | **ICS calendar feed** (F03): per-member secret URL, rotate, public `GET /ics/{token}.ics` with hearings, deadlines and tasks at minimum content (titles only with "Include case titles") | `services/api/*`, `features/settings/*` |
| 13 | **Scan-to-case**: capture a page → OCR → detect CNR or case number → search and add (flag `scan_to_case`) | `features/scan/*` |
| 14 | **Phase checks**: goldens, accessibility and 200% text for every new screen; pseudo-locale; offline; evals on the synthetic sets; iOS usage strings (camera, microphone, Face ID) and `hi.lproj` registration; `phase-2-report.md` | `apps/client/test/*`, `apps/client/ios/*`, `docs/phases/phase-2-report.md` |

## Track B — on hold with the founder's accounts

| # | Task | Blocked on |
|---|---|---|
| B6 | Spike 11c: India profile IDs and prefix, models per tier, `effort`/thinking support, prices → `config/ai_models.yaml`, credit prices; live `LLMClient` smoke test | AWS account, Bedrock India access |
| B7 | Spike 11d: Sarvam speech-to-text on 10 voice notes, Document Digitization on scans; data location and retention in `docs/vendors.md` | Sarvam key, 10 voice notes |
| B8 | WhatsApp Cloud API live: utility templates (§13.4) approved, webhook, Cloud API local storage in India (ADR) | Meta Business verification, number |
| B9 | SES in Mumbai: domain verification, production access | AWS account, domain |
| B10 | iOS TestFlight with ≥ 10 testers, push (APNs via FCM), VisionKit scanning | Apple account, Codemagic, Firebase |
| B11 | Embedder and workers on ECS; evals nightly on staging with a spend cap | AWS, staging |
| B12 | Evals on the real datasets (30 orders, 50 Q&A, 30 voice notes); P2 cost check (≤ 40% of the Solo price per median user); usability round 3 | Datasets with an advocate, beta, live providers |

## Defaults taken (change any of them by telling me)
- **No live AI, speech or messaging in Track A or CI.** `AI_LIVE=0`, `STT_LIVE=0`, `MESSAGING_LIVE=0` (like
  `COURTDATA_LIVE`): the adapters are real, the transports are fakes with recorded shapes from the providers' docs.
- **Bhashini is not used** until the founder approves its data terms (§15.6); speech-to-text retries Sarvam.
- **Item tracker:** team-shared manual updates only; no display-board source (Appendix D, optional).
- **Eval datasets:** synthetic, clearly marked, for development only; they never stand in for the real sets at the gate.
- **Limitation rules and court holidays:** every rule ships `DRAFT – VERIFY` and is hidden in production builds;
  holidays come only from verified calendars (the table stays empty until the founder supplies them).
- **Embeddings run on the CPU** in `services/embedder`; models are downloaded at image build, never committed.
- **"Share via my WhatsApp" is the default** send route for client updates; the API route needs B8.

## Founder inputs (spec §17 P2)
Eval datasets with an advocate; advocate verification of the limitation rules and holiday calendars; WhatsApp utility
template approvals; the Bhashini decision; the Apple account. All wait on the hold except where the founder says.

## Exit criteria (spec §17 P2) and where each is checked
| Criterion | Track A | Needs Track B |
|---|---|---|
| Summary directions and next dates ≥ 90%; Q&A ≥ 85% with correct pages; voice next date ≥ 90%; 0 answers without sources | Eval harness, metrics and gates on synthetic sets; "0 answers without sources" enforced in code and tested | Real datasets, live models |
| Limitation tests pass; production shows only VERIFIED rules and holidays | Engine tests; a build test that DRAFT rules are hidden | Advocate verification |
| Client messages never sent without approval | Automated test | — |
| Median active beta user's variable cost ≤ 40% of the Solo price | Cost ledger (court data + AI + messaging) tested | Live rates, beta usage |
| TestFlight with ≥ 10 testers | iOS strings and project prep | Apple account, Codemagic |
| Usability round 3: voice note → next date → client update unaided; SUS ≥ 70 | Flow built end to end locally | Beta users |
