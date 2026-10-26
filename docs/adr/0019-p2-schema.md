# 0019 — Phase 2 schema: additions to §9.2 and the client-message guard

Status: accepted (26 Oct 2026)

## Context
Phase 2 adds the tables spec §17 P2 names: `document_chunks`, `voice_notes`, `ai_runs`, `ai_answers`,
`public_summaries`, `client_messages`, `display_board_snapshots`. §9.2 gives their columns and §9.3 their access
rules, but a few P2 features need more than the listed columns, the ICS feed (§10.2) has no table, and "never sent
without approval" (§17 P2 exit criterion) should hold for every writer, not only the API.

## Decision
Migration `20261026000000_ai_assistant.sql`, with the same write paths as Phase 1 (ADR 0003, 0009).

**Case-file text** (`document_chunks`, server only, never synced)
- A chunk belongs to an uploaded document (with its `org_id`) or to a court order (`court_order_id`, `org_id` null):
  a court order's text is shared like the order itself, one copy for every organisation tracking the case, and is
  readable by users whose organisation tracks its CNR (`tracks_court_order`). So Ask and search cover orders without
  copying them per organisation. A check makes it exactly one of the two.
- `paras text[]` keeps the paragraph numbers detected in a chunk (§12.4); `embedding vector(1024)` stays null until the
  embedder has run (HNSW, cosine). `tsv` uses the `simple` configuration: Postgres has no Hindi stemmer, and words as
  written are what search needs; a trigram index helps partial and misspelt words.
- `documents` gains `unique (id, org_id)`, so a chunk can't carry another organisation's document.

**Voice notes.** `error_code` added. A device inserts only a `queued` note with no server fields, may then change
only `matter_id`, and may delete its own note (§9.2 gives voice notes no `deleted_at`). Transcripts and parses come
from workers, the confirm from the API.

**AI runs and answers**
- `ai_runs` adds `prompt_version` (§12.3: runs record it); `org_id` is null for a platform run. No prompt or answer
  text. (A shared summary's run is costed to the organisation it was made for: ADR 0020.)
- `ai_answers` adds `language`, `document_id` and `updated_at`; kinds are `ask`, `brief` and `upload_summary`, with one
  upload summary per document and language (an upload summary must name both). Answers are deleted softly through the API by the asker or the owner.
  They are readable by every member (§9.3), so Ask and Brief me must never draw on private notes (task 6).
- `public_summaries` adds `prompt_version`, so a prompt change can regenerate the cache. A court order's `doc_ref` must
  be its id: the read policy casts it, and one malformed row would otherwise break every read.

**Client messages.** `language`, `recipient`, `run_id` (the AI draft), `provider_msg_id`, `error_code` and
`deleted_at` added. A trigger and two checks hold for every writer, workers included:
- a message starts as `draft` or `pending_approval`, with no approval, recipient or send time;
- approval needs an active owner or advocate as `approved_by`, and through the API that must be the caller;
- approval copies the destination from the client (phone, or email for email) into `recipient`, whatever the caller
  sent, so a later edit to the client (any member may edit clients) can't redirect an approved message. Email and the
  WhatsApp API need one; "Share via my WhatsApp" may leave the contact to the advocate's own WhatsApp;
- `approved`, `sent` and `failed` need `approved_at`, and `sent` needs `sent_at`;
- only an approved (or failed) message becomes `sent`; approving and sending are two steps;
- once approved, the text, channel, client, recipient, case, language, template and approver can't change, and the
  message can't go back to a draft;
- deleting the author, the approver or the AI run clears that key (`on delete set null`) and nothing else.
Clerks can read messages but not write them (§10.2: drafting is for owners, advocates and juniors).

**Item tracker.** `current_item` is text like cause-list items ("S-12"). Team rows go through the API as the caller;
`official` rows are for workers only, once a permitted source exists (§11.10).

**Calendar feeds** (new, for §10.2's ICS URLs). One feed per member: `calendar_feeds (org_id, user_id, token_hash)`,
keyed to the membership. The app removes members by status, so a trigger drops the feed when a membership stops
being active. Only the SHA-256 of the secret in the URL is stored.

**Sync** (§9.4). Devices receive their own voice notes (`created_by`, in their organisations) and the chamber's live
tracker rows (`is_live`). The other P2 tables are never synced. Sync tests check that no member gets another's voice
notes.

## Consequences
- 329 new pgTAP assertions (1348 in all); 27 deliberate breaks of the new policies, triggers and checks each fail them.
- **Task 11** must bind an approval to the text the approver saw (the approve call carries it, or the row's
  `updated_at`, and fails on a mismatch): otherwise a junior's edit between opening and approving would be approved
  unseen.
- **Task 4**: one HNSW index serves every organisation and RLS filters after the index scan, so a small organisation
  could get few candidates. Retrieval sets pgvector's iterative scan (`hnsw.iterative_scan`), or searches exactly
  within one case's documents.
- The "never sent without approval" exit criterion is enforced in the database; the API test (task 11) still covers
  the endpoints.
- A soft-deleted document's chunks stay until the data-deletion flow; retrieval must join `documents` and skip deleted
  ones (task 4).
