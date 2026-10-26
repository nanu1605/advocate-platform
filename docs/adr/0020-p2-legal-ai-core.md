# 0020 — Phase 2 `legal_ai` core: Bedrock client, prompts, contracts, cost controls, evals

Status: accepted (26 Oct 2026)

## Context
P2 task 2 (spec §12.1–12.3, §12.13, §12.14): one way to call Claude for every AI feature, with versioned prompts,
validated outputs, cost per run, the shared summary cache, per-organisation caps and credits, and an eval harness.
Track B (the founder's AWS account) is on hold, so nothing here can call a real model yet: `AI_LIVE=0` everywhere,
as `COURTDATA_LIVE=0` is for court data.

## Decision
**Client** (`legal_ai.llm`)
- boto3 **Converse** on `bedrock-runtime` in ap-south-1. Spec §12.2 allows Converse or the Anthropic SDK on the same
  endpoint. Converse takes `effort` natively (`outputConfig.effort`), and botocore's service model lets tests check
  every request's shape offline (Stubber). Mantle and global profiles are never used.
- The India guard runs twice: `LLMClient` refuses any config other than ap-south-1, `bedrock-runtime` and `in.`
  profiles for all three tiers; `BedrockTransport` refuses to start if boto3 would send requests anywhere else. That
  catches an `AWS_ENDPOINT_URL*` override.
- Requests: the tier's profile, `maxTokens` = `output_budget` + `thinking_allowance`, and effort where the tier takes
  it (`effort_supported`: Haiku 4.5 rejects it). No sampling parameter is ever sent. Thinking is left at the models'
  adaptive default.
- Throttling, timeouts, connection and service errors raise `unavailable` (`fallbacks.on_unavailable: degrade`, the
  only value the config accepts); never a re-route. Errors a retry can't fix (no credentials, a bad parameter, access
  denied) raise `failed`.
- **No SDK retries:** a resent call is paid again, so the caller degrades or queues instead. Converse answers only
  when the whole generation is done, so the read timeout is 900 s. Streaming arrives with Ask (task 6).
- **Structured outputs** (§12.3): the reply must be one JSON object matching the task's Pydantic contract. Every
  source id must be one that was sent. An invalid or cut-off reply is retried twice with the error; then
  `invalid_output`. Dates the model resolves can't fall in the past: a next date or due date before the order's date,
  or a voice note's next date before today, goes back to the model (a year-less date is the next such date).
  Bedrock's native JSON-schema output (`outputConfig.textFormat`) isn't used yet; spike 11c can try
  it per tier.
- **Cost** = tokens (thinking included) × USD list price × `usd_inr` × `price_multiplier`, summed over attempts, ₹
  to four decimals. `usd_inr`, the per-tier prices and `effort_supported` are additions to §12.2's YAML. They hold
  placeholders until spike 11c.
- `AI_LIVE=0`: `legal_ai.fake.local_transport` returns a valid, plainly labelled placeholder for every task, so the
  app's flows run end to end without a model.

**Prompts** (`legal_ai/prompts/`)
- The prompts live inside the package (`src/legal_ai/prompts/`, not §12.3's `packages/legal_ai/prompts/`), so they
  ship with it, like `court_data`'s fixtures.
- Each task file has a `version:` header. `_system.md` holds §12.3's five must-haves; `_hindi.md` holds Appendix C's
  register.
- `versions.json` pins each version's hash over the task file and the shared files. A test fails on any prompt
  change without a new version, because `ai_runs.prompt_version` and the summary cache depend on it.
- Untrusted text never enters the instructions. Only trusted values (dates) fill `$params`. Documents follow as
  numbered `<source>` blocks and other text (a question, a transcript) as `<data>` blocks, escaped so they can't close
  their tags.

**Contracts** (`legal_ai.contracts`), for the six P2 tasks: `order_summary` (§4.4's fields, every bullet sourced),
`order_intel`, `ask_case`, `brief_me`, `voice_parse` and `client_update`.
- `order_intel` gives `due` as the order states it, either a date or "within N days/weeks/months". Code counts the
  date from the order date (weeks are 7 days; months land on the same day, clamped to the month's end); the model
  never counts. Proposals show "verify" (§4.4 F13).
- `ask_case` has `found`; the "I couldn't find this in the case files" text belongs to the app.
- `voice_parse` names its matter by the id of a candidate matter sent as a source.

**Cost controls** (`advocate_shared.ai`, migration `20261026100000`)
- `record_run` writes the `ai_runs` row (no text) and the ledger row. There is a new `usage_ledger` kind,
  `ai_automatic`: automatic AI (order summaries, order intelligence) counts against the cap whatever its outcome.
  `ai_credit` (quantity = credits) is charged only for a run that produced output.
- `automatic(org)` returns:
  - **run**, under the plan's `automatic_ai_cap_inr` this IST month;
  - **on_open**, when the cap is reached (generate when a user opens the order, with credits);
  - **later**, when today's platform AI spend has reached `AI_PLATFORM_DAILY_BUDGET_INR` (§12.14 "queue non-urgent
    jobs"). On-demand AI still runs.
- **Plans before subscriptions (P3):** a solo organisation gets Solo's limits; a chamber gets Chamber's, per active
  member and at least its minimum 3 seats, pooled.
- **Credit prices** are §14.2's estimates. For order summaries, "4–24 by length" is set to 4 per 5 pages, at most 24.
- **Summary cache:** `public_summaries` is read only at the current prompt version, so a new version regenerates it.
  The run that generates a shared summary is costed to the organisation it was made for, so it counts against that
  organisation's automatic cap; organisations that read it later pay nothing. This replaces ADR 0019's "platform
  cost" for those runs; `org_id` is null only for platform runs such as evals.
- **Alerts** (the hourly `ai_cost_watch` worker task):
  - an organisation spending more today than 3× its 30-day daily average, with a ₹10 floor so a new organisation's
    first day stays quiet;
  - platform spend at 80% and 100% of the daily budget.
  Each is logged once a day, like the court-data budget alerts.

**Evals** (`legal_ai.evals`, datasets in `packages/legal_ai/evals/v1/`)
- **Data:** synthetic orders, case-file Q&A and voice transcripts, marked synthetic and for development only. They
  never stand in for the advocate-curated sets at the gate.
- **Metrics and gates follow §4.4 and the P2 exit criteria:**
  - directions and next dates ≥ 90%;
  - actions and deadlines ≥ 90%;
  - Q&A correct with pages ≥ 85%;
  - answers without sources = 0;
  - voice next date ≥ 90%.
  Expected items are paired with outputs by phrase match (case and nukta ignored) as a maximum matching, so the order
  of the model's list doesn't matter, and extra outputs count against the score. A Q&A answer is correct only if
  every page it cites holds the answer; citation precision is reported alongside.
- **Live runs** need `AI_LIVE=1`, which CI never sets. `--record` keeps a run's outputs and `--replies` re-scores them
  without calls. Results go to `docs/evals/YYYY-MM-DD.md`.
- **Q&A coverage:** Q&A sends a case file's every page until retrieval exists (task 4).

The server image now copies `config/ai_models.yaml`.

## Consequences
- **Not possible in Track A:** real scores, prices and profile IDs. Spike 11c (B6) fills in:
  - the `in.` profile IDs per tier;
  - which tiers take `effort`;
  - list prices and `usd_inr`;
  - whether `textFormat` helps;
  - measured p90 cost per action, which replaces the credit estimates.
- **Simplifications accepted:**
  - A call that times out has no token count, so its run records no cost, although Bedrock may bill it.
  - Credits are checked, then charged after the run, so two parallel on-demand actions can overspend by one. The
    automatic cap can be overrun the same way.
  - Task 5 must lock per order and language so concurrent workers don't generate the same summary twice.
- **Wiring left to later tasks:** tasks 5–7 and 11 call `LLMClient.structured` with these contracts and settle each run
  through `record_run`.
