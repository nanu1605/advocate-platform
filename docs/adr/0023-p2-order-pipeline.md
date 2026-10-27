# 0023 — Phase 2 order pipeline: summaries, order intelligence, proposals

Status: accepted (28 Oct 2026)

## Context
P2 task 5 (spec F07, F13, §11.5, §12.8, §12.14, §14.2, §13.1): a new court order is summarised in Hindi or English
with every point tied to its page, its directions become proposed tasks and deadlines, and the new-order message says
how many actions were found. The spec leaves several points open: which language is automatic, who pays for a summary
several organisations share, how order intelligence is cached, how a proposal maps to a task or a deadline, and how an
on-demand summary is priced. The core (LLMClient, prompts, contracts, the summary cache, the automatic cap and credits)
is ADR 0020; the text and chunks are ADR 0022.

## Decision
**Languages.** The pipeline summarises a new order in every preferred language of the active members of the
organisations that auto-track its case (§4.4 F07 and §17 are the specific rule; §12.8's "Hindi on request" is read as
"the language nobody there prefers, on request"). Changing the app language in Settings now also updates
`profiles.preferred_language`, which the pipeline reads.

**Automatic versus on demand.**
- Automatic means the pipeline, billed to the automatic-AI cap of one paying organisation per task and language: the
  oldest organisation that needs that language and is under its cap. The others reuse the result free (ADR 0020). When
  the platform's daily budget is spent, the pipeline retries every 30 minutes, six times in all; when every organisation
  is over its cap, it skips that language and members can ask for it.
- On demand (the app's Summarise and Find actions) costs credits unless the result is already stored (§14.2: "on demand,
  when not cached or over the automatic cap"). The app asks first: "Summarising uses N credits. M left." The price is
  checked when the request arrives and again just before the model runs, so queued requests cannot spend far past the
  month's credits. Order summary: 4 credits per 5 pages, at most 24; order intelligence: 2 (a placeholder until spike
  11c, like the other prices).
- On-demand work runs as a job on a new `ai` queue (`worker-ai`, four at a time), so no request waits on the model and
  the app follows the synced job. A job retries a busy model for about 15 minutes, then fails with `AI_BUSY`.

**Order intelligence** runs once per order and language and is cached like summaries (`public_summaries.doc_kind =
'order_intel'`, read by whoever tracks the order). It reads the order's pages with the order date from the court
record, else from the summary. The pipeline runs it only for orders dated in the last 30 days, so importing a case never
proposes work from its old orders.

**Proposals** are per organisation, in one language: the owner's.
- A direction with a time becomes a proposed `compliance` deadline counted from the order date (`Due.resolve`); its
  title, the time as written, the order date and the pages go in `basis`, marked "verify". Anything else becomes a
  proposed task (`source = 'order'`), dated at IST midnight when the order gives a time.
- An organisation gets proposals from an order once: if it already has any row from that order (confirmed, dismissed or
  deleted), nothing is proposed again. `dedupe_key` (`order:<court order>:<hash of kind, title and date>`) stops
  repeats within a run, and an action matching an existing task or deadline of the case by title and date is skipped.
- Nothing is added as fact: the worker writes only `proposed` rows. Any member confirms (tasks `open`, deadlines
  `active`), dismisses, or confirms all, each with Undo. Proposals show the order they came from.

**Sources and stored shapes.** The model gets one source per page, rebuilt from the order's chunks (their overlap
merged; blank pages keep their numbers). Stored summaries and intel carry `source_pages` (`S2 → page 3`), so every point
in the app has a page chip that opens the order at that page. Paragraph chips wait.

**Sharing and fan-out.** A court order's summary is stored once per language (`public_summaries`) and copied into
every organisation's `orders.summary_en` / `summary_hi`, including organisations that start tracking the case later.
Summaries of uploaded orders (`documents.kind = 'order'`) stay in that organisation's `ai_answers`. A Redis lock per
order, task and language stops two workers making the same thing twice.

**Notification.** When proposals were added, the organisation's existing new-order message is rewritten: "New order in
WP 1234/2024 — 2 actions found." / "WP 1234/2024 में नया आदेश — 2 काम मिले।" (minimum content, §13.2). No message is
created for an order that never had one.

**App.** Each order on the timeline has Summary and, when there are any, "N actions to review". The summary sheet has
the Hindi/English switch, the F07 sections with page chips, authorities labelled "As cited in this order — not
verified", the order's proposals with Confirm, Dismiss and Confirm all, and Find actions for owners, advocates and
juniors. The Notes tab lists "Suggested from orders". Uploaded orders get Summary in their menu.

**API.** `POST /v1/orders/{id}/summary` and `POST /v1/documents/{id}/summary` (`{language, credits}`, every role) and
`POST /v1/ai/order-intel` (`{order_id, credits}`, owner, advocate, junior) return 200 with a stored result, 202 with a
job, or 409/402 with `ORDER_TEXT_PENDING` (the order's PDF is fetched first if needed), `ORDER_TEXT_UNREADABLE`,
`ORDER_DATE_UNKNOWN`, `ORDER_SUMMARY_UNAVAILABLE`, `DOCUMENT_NOT_AN_ORDER`, `AI_CREDITS_NEEDED` or
`AI_CREDITS_EXHAUSTED`. Each needs an `Idempotency-Key`.

## Consequences
- The API now loads the AI configuration for prices, so in production it needs the `BEDROCK_PROFILE_*` settings the
  workers have.
- A lost automatic task is not re-sent (it is not a job); that order waits until someone asks for its summary.
- Credits are checked, not reserved: requests running at the same moment can each spend one price past the month's
  credits.
- Evaluation on real orders (30 MP orders, ≥ 90 % directions and dates) waits for Track B; the synthetic set has 10.
- New Hindi strings wait for the native-speaker review: the summary sheet, the proposals, the credits dialog, the new
  error messages and the new-order message.
