-- RLS and trigger matrix for the Phase 2 tables (spec §9.3): five actors × read / insert / update / delete, device
-- writes and API writes, plus every trigger and constraint. Matrix order: owner, advocate, junior, clerk (chamber A),
-- outsider (solo B). Fixture CNRs start with PGTP (see 002). Rows carry a marker ('A …' / 'B …') to count per org.
begin;
\ir _setup.psql

-- ---------------------------------------------------------------- P2 fixture (as postgres)
insert into public.court_cases (cnr, court_id, title) values
  ('PGTP020000012024', 'c0000000-0000-0000-0000-000000000003', 'Tracked by A'),
  ('PGTP020000022024', 'c0000000-0000-0000-0000-000000000003', 'Tracked by B');
insert into public.court_orders (id, cnr, order_date, provider_ref) values
  ('c1000000-0000-0000-0000-000000000001', 'PGTP020000012024', '2026-10-20', 'ord-a'),
  ('c1000000-0000-0000-0000-000000000002', 'PGTP020000022024', '2026-10-20', 'ord-b');
insert into public.matters (id, org_id, cnr, court_id, source) values
  ('aa000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'PGTP020000012024',
   'c0000000-0000-0000-0000-000000000003', 'cnr'),
  ('bb000000-0000-0000-0000-000000000001', '0000000b-0000-0000-0000-000000000000', 'PGTP020000022024',
   'c0000000-0000-0000-0000-000000000003', 'cnr');
insert into public.documents (id, org_id, matter_id, title) values
  ('aa000000-0000-0000-0000-0000000000d1', '0000000a-0000-0000-0000-000000000000',
   'aa000000-0000-0000-0000-000000000001', 'Petition'),
  ('bb000000-0000-0000-0000-0000000000d1', '0000000b-0000-0000-0000-000000000000',
   'bb000000-0000-0000-0000-000000000001', 'Petition');
insert into public.clients (id, org_id, name, phone) values
  ('aa000000-0000-0000-0000-0000000000c1', '0000000a-0000-0000-0000-000000000000', 'Ramesh Sharma', '919000000001'),
  ('bb000000-0000-0000-0000-0000000000c1', '0000000b-0000-0000-0000-000000000000', 'Sita Verma', null);

insert into public.document_chunks (org_id, document_id, court_order_id, page_no, chunk_no, text) values
  ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-0000000000d1', null, 1, 0, 'A petition: जमानत आवेदन'),
  ('0000000b-0000-0000-0000-000000000000', 'bb000000-0000-0000-0000-0000000000d1', null, 1, 0, 'B petition'),
  (null, null, 'c1000000-0000-0000-0000-000000000001', 1, 0, 'A order: reply within four weeks'),
  (null, null, 'c1000000-0000-0000-0000-000000000002', 1, 0, 'B order');

insert into public.voice_notes (id, org_id, created_by, duration_ms) values
  ('aa000000-0000-0000-0000-0000000000b2', '0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a2', 20000),
  ('aa000000-0000-0000-0000-0000000000b3', '0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a3', 20000),
  ('bb000000-0000-0000-0000-0000000000b1', '0000000b-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000b1', 20000);

insert into public.ai_runs (org_id, kind, model_tier, model_id, status) values
  ('0000000a-0000-0000-0000-000000000000', 'ask_case', 'standard', 'fixture', 'ok'),
  ('0000000b-0000-0000-0000-000000000000', 'ask_case', 'standard', 'fixture', 'ok'),
  (null, 'order_summary', 'standard', 'fixture', 'ok');
insert into public.ai_runs (id, org_id, kind, model_tier, model_id, status) values
  ('aa000000-0000-0000-0000-0000000000e9', null, 'client_update', 'fast', 'fixture', 'ok');
insert into public.ai_answers (org_id, kind, question, answer, created_by) values
  ('0000000a-0000-0000-0000-000000000000', 'ask', 'A question', '{}', '00000000-0000-0000-0000-0000000000a2'),
  ('0000000b-0000-0000-0000-000000000000', 'ask', 'B question', '{}', '00000000-0000-0000-0000-0000000000b1');
insert into public.ai_answers (org_id, kind, document_id, language, answer, created_by) values
  ('0000000a-0000-0000-0000-000000000000', 'upload_summary', 'aa000000-0000-0000-0000-0000000000d1', 'en', '{}', null);
insert into public.public_summaries (doc_kind, doc_ref, language, summary, model_id, prompt_version) values
  ('court_order', 'c1000000-0000-0000-0000-000000000001', 'en', '{}', 'fixture', 'v1'),
  ('court_order', 'c1000000-0000-0000-0000-000000000002', 'en', '{}', 'fixture', 'v1'),
  ('judgment', 'J-fixture', 'en', '{}', 'fixture', 'v1');

insert into public.client_messages (id, org_id, client_id, body, status, created_by, run_id) values
  ('aa000000-0000-0000-0000-0000000000a5', '0000000a-0000-0000-0000-000000000000',
   'aa000000-0000-0000-0000-0000000000c1', 'A draft', 'pending_approval', '00000000-0000-0000-0000-0000000000a3',
   'aa000000-0000-0000-0000-0000000000e9'),
  ('bb000000-0000-0000-0000-0000000000a5', '0000000b-0000-0000-0000-000000000000',
   'bb000000-0000-0000-0000-0000000000c1', 'B draft', 'draft', '00000000-0000-0000-0000-0000000000b1', null),
  ('aa000000-0000-0000-0000-0000000000a6', '0000000a-0000-0000-0000-000000000000',
   'aa000000-0000-0000-0000-0000000000c1', 'A approved', 'draft', '00000000-0000-0000-0000-0000000000a3', null);
update public.client_messages set status = 'approved', approved_by = '00000000-0000-0000-0000-0000000000a2',
  approved_at = now() where id = 'aa000000-0000-0000-0000-0000000000a6';

insert into public.display_board_snapshots (org_id, court_id, court_no, current_item, captured_by) values
  ('0000000a-0000-0000-0000-000000000000', 'c0000000-0000-0000-0000-000000000003', '12', 'A 18', '00000000-0000-0000-0000-0000000000a2'),
  ('0000000b-0000-0000-0000-000000000000', 'c0000000-0000-0000-0000-000000000003', '12', 'B 18', '00000000-0000-0000-0000-0000000000b1');

insert into public.calendar_feeds (org_id, user_id, token_hash) values
  ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a2', 'hash-a2'),
  ('0000000b-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000b1', 'hash-b1');

-- ---------------------------------------------------------------- document chunks: read through the API, workers write
select tests.matrix('document_chunks read own org and tracked orders', $$select 1 from public.document_chunks where text like 'A %'$$, true, '{2,2,2,2,0}');
select tests.matrix('document_chunks read other org', $$select 1 from public.document_chunks where text like 'B %'$$, true, '{0,0,0,0,2}');
select tests.matrix('document_chunks insert', $$insert into public.document_chunks (org_id, document_id, page_no, chunk_no, text) values ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-0000000000d1', 2, 0, 'x')$$, true, '{-1,-1,-1,-1,-1}');
select tests.matrix('document_chunks update', $$update public.document_chunks set text = 'x'$$, true, '{0,0,0,0,0}');
select tests.matrix('document_chunks delete', 'delete from public.document_chunks', true, '{0,0,0,0,0}');

select is((select count(*)::int from public.document_chunks where tsv @@ to_tsquery('simple', 'जमानत')), 1,
  'document_chunks full-text search finds a Hindi word');
select is((select count(*)::int from pg_indexes where tablename = 'document_chunks' and indexname in
  ('document_chunks_embedding_idx', 'document_chunks_tsv_idx', 'document_chunks_trgm_idx')), 3,
  'document_chunks have vector, full-text and trigram indexes');
select throws_ok($$insert into public.document_chunks (org_id, document_id, court_order_id, page_no, chunk_no, text) values ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-0000000000d1', 'c1000000-0000-0000-0000-000000000001', 1, 1, 'x')$$,
  '23514', null, 'document_chunks belong to a document or a court order, not both');
select throws_ok($$insert into public.document_chunks (org_id, page_no, chunk_no, text) values ('0000000a-0000-0000-0000-000000000000', 1, 1, 'x')$$,
  '23514', null, 'document_chunks need a document or a court order');
select throws_ok($$insert into public.document_chunks (org_id, document_id, page_no, chunk_no, text) values ('0000000a-0000-0000-0000-000000000000', 'bb000000-0000-0000-0000-0000000000d1', 1, 1, 'x')$$,
  '23503', null, 'document_chunks cannot carry another organisation''s document');
select throws_ok($$insert into public.document_chunks (org_id, document_id, page_no, chunk_no, text) values ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-0000000000d1', 1, 0, 'x')$$,
  '23505', null, 'document_chunks: one chunk per document, page and number');
select throws_ok($$insert into public.document_chunks (court_order_id, page_no, chunk_no, text) values ('c1000000-0000-0000-0000-000000000001', 1, 0, 'x')$$,
  '23505', null, 'document_chunks: one chunk per court order, page and number');
select lives_ok($$update public.document_chunks set embedding = array_fill(0.01, array[1024])::extensions.vector where page_no = 1$$,
  'document_chunks take a 1024-d embedding');

-- ---------------------------------------------------------------- voice notes: the author only
select tests.matrix('voice_notes read', 'select 1 from public.voice_notes', false, '{0,1,1,0,1}');
select tests.matrix('voice_notes insert queued', $$insert into public.voice_notes (org_id, duration_ms) values ('0000000a-0000-0000-0000-000000000000', 15000)$$, false, '{1,1,1,1,-1}');
select tests.matrix('voice_notes insert for someone else', $$insert into public.voice_notes (org_id, created_by) values ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a2')$$, false, '{-1,1,-1,-1,-1}');
select tests.matrix('voice_notes insert with a transcript', $$insert into public.voice_notes (org_id, transcript) values ('0000000a-0000-0000-0000-000000000000', 'x')$$, false, '{-1,-1,-1,-1,-1}');
select tests.matrix('voice_notes insert with a transcript (api)', $$insert into public.voice_notes (org_id, transcript, status) values ('0000000a-0000-0000-0000-000000000000', 'x', 'transcribed')$$, true, '{1,1,1,1,-1}');
select tests.matrix('voice_notes update matter', 'update public.voice_notes set matter_id = null', false, '{0,1,1,0,1}');
select tests.matrix('voice_notes update transcript', $$update public.voice_notes set transcript = 'x'$$, false, '{0,-1,-1,0,-1}');
select tests.matrix('voice_notes update transcript (api)', $$update public.voice_notes set transcript = 'x', status = 'transcribed'$$, true, '{0,1,1,0,1}');
select tests.matrix('voice_notes update author (api)', $$update public.voice_notes set created_by = '00000000-0000-0000-0000-0000000000a1'$$, true, '{0,-1,-1,0,-1}');
select tests.matrix('voice_notes delete', 'delete from public.voice_notes', false, '{0,1,1,0,1}');
select throws_ok($$insert into public.voice_notes (org_id, created_by, duration_ms) values ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a2', 120001)$$,
  '23514', null, 'voice_notes are at most 2 minutes');

-- ---------------------------------------------------------------- AI runs: the owner reads costs
select tests.matrix('ai_runs read', 'select 1 from public.ai_runs', true, '{1,0,0,0,1}');
select tests.matrix('ai_runs insert', $$insert into public.ai_runs (org_id, kind, model_tier, model_id, status) values ('0000000a-0000-0000-0000-000000000000', 'x', 'fast', 'x', 'ok')$$, true, '{-1,-1,-1,-1,-1}');
select tests.matrix('ai_runs update', 'update public.ai_runs set cost_inr = 0', true, '{0,0,0,0,0}');
select tests.matrix('ai_runs delete', 'delete from public.ai_runs', true, '{0,0,0,0,0}');

-- ---------------------------------------------------------------- AI answers: members read; the API writes
select tests.matrix('ai_answers read', $$select 1 from public.ai_answers where question like 'A %'$$, false, '{1,1,1,1,0}');
select tests.matrix('ai_answers insert', $$insert into public.ai_answers (org_id, kind, answer) values ('0000000a-0000-0000-0000-000000000000', 'ask', '{}')$$, false, '{-1,-1,-1,-1,-1}');
select tests.matrix('ai_answers insert (api)', $$insert into public.ai_answers (org_id, kind, answer) values ('0000000a-0000-0000-0000-000000000000', 'ask', '{}')$$, true, '{1,1,1,1,-1}');
select tests.matrix('ai_answers insert as someone else (api)', $$insert into public.ai_answers (org_id, kind, answer, created_by) values ('0000000a-0000-0000-0000-000000000000', 'ask', '{}', '00000000-0000-0000-0000-0000000000a2')$$, true, '{-1,1,-1,-1,-1}');
select tests.matrix('ai_answers delete (api, soft)', $$update public.ai_answers set deleted_at = now() where kind = 'ask'$$, true, '{1,1,0,0,1}');
select tests.matrix('ai_answers delete (device, soft)', $$update public.ai_answers set deleted_at = now()$$, false, '{0,0,0,0,0}');
select tests.matrix('ai_answers update answer (api)', $$update public.ai_answers set answer = '{"x": 1}' where kind = 'ask'$$, true, '{-1,-1,0,0,-1}');
select tests.matrix('ai_answers delete', 'delete from public.ai_answers', true, '{0,0,0,0,0}');
select throws_ok($$insert into public.ai_answers (org_id, kind, document_id, language, answer) values ('0000000a-0000-0000-0000-000000000000', 'upload_summary', 'aa000000-0000-0000-0000-0000000000d1', 'en', '{}')$$,
  '23505', null, 'ai_answers: one upload summary per document and language');
select throws_ok($$insert into public.ai_answers (org_id, kind, document_id, answer) values ('0000000a-0000-0000-0000-000000000000', 'upload_summary', 'aa000000-0000-0000-0000-0000000000d1', '{}')$$,
  '23514', null, 'ai_answers: an upload summary names its document and language');
select lives_ok($$insert into public.ai_answers (org_id, kind, document_id, language, answer) values ('0000000a-0000-0000-0000-000000000000', 'upload_summary', 'aa000000-0000-0000-0000-0000000000d1', 'hi', '{}')$$,
  'ai_answers: the other language is its own summary');

-- ---------------------------------------------------------------- public summaries: tracked court orders, any judgment
select tests.matrix('public_summaries read tracked order', $$select 1 from public.public_summaries where doc_ref = 'c1000000-0000-0000-0000-000000000001'$$, true, '{1,1,1,1,0}');
select tests.matrix('public_summaries read judgment', $$select 1 from public.public_summaries where doc_kind = 'judgment'$$, true, '{1,1,1,1,1}');
select tests.matrix('public_summaries read all', 'select 1 from public.public_summaries', true, '{2,2,2,2,2}');
select tests.matrix('public_summaries insert', $$insert into public.public_summaries (doc_kind, doc_ref, language, summary, model_id, prompt_version) values ('judgment', 'J2', 'en', '{}', 'x', 'v1')$$, true, '{-1,-1,-1,-1,-1}');
select tests.matrix('public_summaries update', $$update public.public_summaries set summary = '{}'$$, true, '{0,0,0,0,0}');
select tests.matrix('public_summaries delete', 'delete from public.public_summaries', true, '{0,0,0,0,0}');
select throws_ok($$insert into public.public_summaries (doc_kind, doc_ref, language, summary, model_id, prompt_version) values ('court_order', 'c1000000-0000-0000-0000-000000000001', 'en', '{}', 'x', 'v1')$$,
  '23505', null, 'public_summaries: one per document and language');
select throws_ok($$insert into public.public_summaries (doc_kind, doc_ref, language, summary, model_id, prompt_version) values ('court_order', 'ord-a', 'en', '{}', 'x', 'v1')$$,
  '23514', null, 'public_summaries: a court order is referred to by its id');

-- ---------------------------------------------------------------- client messages: approval before anything is sent
select tests.matrix('client_messages read', $$select 1 from public.client_messages where body like 'A %'$$, false, '{2,2,2,2,0}');
select tests.matrix('client_messages insert', $$insert into public.client_messages (org_id, client_id, body) values ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-0000000000c1', 'x')$$, false, '{-1,-1,-1,-1,-1}');
select tests.matrix('client_messages insert (api)', $$insert into public.client_messages (org_id, client_id, body) values ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-0000000000c1', 'x')$$, true, '{1,1,1,-1,-1}');
select tests.matrix('client_messages insert with a recipient (api)', $$insert into public.client_messages (org_id, client_id, body, recipient) values ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-0000000000c1', 'x', '910000000000')$$, true, '{-1,-1,-1,-1,-1}');
select tests.matrix('client_messages insert approved (api)', $$insert into public.client_messages (org_id, client_id, body, status, approved_by, approved_at) values ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-0000000000c1', 'x', 'approved', auth.uid(), now())$$, true, '{-1,-1,-1,-1,-1}');
select tests.matrix('client_messages edit draft (api)', $$update public.client_messages set body = 'x' where status <> 'approved'$$, true, '{1,1,1,0,1}');
select tests.matrix('client_messages edit draft (device)', $$update public.client_messages set body = 'x'$$, false, '{0,0,0,0,0}');
select tests.matrix('client_messages send approved (api)', $$update public.client_messages set status = 'sent', sent_at = now() where id = 'aa000000-0000-0000-0000-0000000000a6'$$, true, '{1,1,1,0,0}');
select tests.matrix('client_messages delete', 'delete from public.client_messages', true, '{0,0,0,0,0}');
select is((select recipient from public.client_messages where id = 'aa000000-0000-0000-0000-0000000000a6'), '919000000001',
  'client_messages: approval fixes the client''s phone as the recipient');

select is(tests.state('00000000-0000-0000-0000-0000000000a3', true,
  $$update public.client_messages set status = 'approved', approved_by = auth.uid(), approved_at = now() where id = 'aa000000-0000-0000-0000-0000000000a5'$$),
  '42501', 'client_messages: a junior cannot approve');
select is(tests.state('00000000-0000-0000-0000-0000000000a2', true,
  $$update public.client_messages set status = 'approved', approved_by = auth.uid(), approved_at = now() where id = 'aa000000-0000-0000-0000-0000000000a5'$$),
  '00000', 'client_messages: an advocate approves');
select is(tests.state('00000000-0000-0000-0000-0000000000a1', true,
  $$update public.client_messages set status = 'approved', approved_by = auth.uid(), approved_at = now() where id = 'aa000000-0000-0000-0000-0000000000a5'$$),
  '00000', 'client_messages: an owner approves');
select is(tests.state('00000000-0000-0000-0000-0000000000a2', true,
  $$update public.client_messages set status = 'approved', approved_by = '00000000-0000-0000-0000-0000000000a1', approved_at = now() where id = 'aa000000-0000-0000-0000-0000000000a5'$$),
  '42501', 'client_messages: an approval is in the approver''s own name');
select is(tests.state('00000000-0000-0000-0000-0000000000a2', true,
  $$update public.client_messages set status = 'sent', sent_at = now() where id = 'aa000000-0000-0000-0000-0000000000a5'$$),
  '42501', 'client_messages: an unapproved message is never sent');
select is(tests.state('00000000-0000-0000-0000-0000000000a2', true,
  $$update public.client_messages set approved_by = auth.uid(), approved_at = now(), sent_at = now(), status = 'sent' where id = 'aa000000-0000-0000-0000-0000000000a5'$$),
  '42501', 'client_messages: approving and sending are two steps');
select is(tests.state('00000000-0000-0000-0000-0000000000a1', true,
  $$update public.client_messages set body = 'changed' where id = 'aa000000-0000-0000-0000-0000000000a6'$$),
  '42501', 'client_messages: an approved message cannot change');
select is(tests.state('00000000-0000-0000-0000-0000000000a1', true,
  $$update public.client_messages set status = 'draft' where id = 'aa000000-0000-0000-0000-0000000000a6'$$),
  '42501', 'client_messages: an approval cannot be taken back into a draft');
select is(tests.state('00000000-0000-0000-0000-0000000000a1', true,
  $$update public.client_messages set approved_by = '00000000-0000-0000-0000-0000000000a1' where id = 'aa000000-0000-0000-0000-0000000000a6'$$),
  '42501', 'client_messages: the approver cannot change');
select is(tests.state('00000000-0000-0000-0000-0000000000a1', true,
  $$update public.client_messages set recipient = '910000000000' where id = 'aa000000-0000-0000-0000-0000000000a6'$$),
  '42501', 'client_messages: an approved message''s recipient cannot change');
select throws_ok($$update public.client_messages set status = 'approved', approved_by = '00000000-0000-0000-0000-0000000000a3', approved_at = now() where id = 'aa000000-0000-0000-0000-0000000000a5'$$,
  '42501', null, 'client_messages: not even a worker approves in a junior''s name');
select throws_ok($$update public.client_messages set status = 'approved' where id = 'aa000000-0000-0000-0000-0000000000a5'$$,
  '23514', null, 'client_messages: approved needs an approval time');
select throws_ok($$update public.client_messages set status = 'sent', sent_at = now() where id = 'aa000000-0000-0000-0000-0000000000a5'$$,
  '42501', null, 'client_messages: not even a worker sends an unapproved message');
select throws_ok($$insert into public.client_messages (org_id, client_id, body) values ('0000000a-0000-0000-0000-000000000000', 'bb000000-0000-0000-0000-0000000000c1', 'x')$$,
  '23503', null, 'client_messages cannot go to another organisation''s client');
select throws_ok($$insert into public.client_messages (org_id, client_id, body) values ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-0000000000c1', '')$$,
  '23514', null, 'client_messages need a body');

-- The destination is the client's at approval: a caller can't supply one, and a later edit doesn't redirect.
insert into public.client_messages (id, org_id, client_id, body, channel) values
  ('aa000000-0000-0000-0000-0000000000a7', '0000000a-0000-0000-0000-000000000000',
   'aa000000-0000-0000-0000-0000000000c1', 'api', 'whatsapp_api'),
  ('aa000000-0000-0000-0000-0000000000a8', '0000000a-0000-0000-0000-000000000000',
   'aa000000-0000-0000-0000-0000000000c1', 'email', 'email'),
  ('bb000000-0000-0000-0000-0000000000a7', '0000000b-0000-0000-0000-000000000000',
   'bb000000-0000-0000-0000-0000000000c1', 'share', 'whatsapp_share');
update public.client_messages set status = 'approved', approved_by = '00000000-0000-0000-0000-0000000000a2',
  approved_at = now(), recipient = '910000000000' where id = 'aa000000-0000-0000-0000-0000000000a7';
select is((select recipient from public.client_messages where id = 'aa000000-0000-0000-0000-0000000000a7'), '919000000001',
  'client_messages: the recipient comes from the client, not the caller');
update public.clients set phone = '910000000000' where id = 'aa000000-0000-0000-0000-0000000000c1';
select is((select recipient from public.client_messages where id = 'aa000000-0000-0000-0000-0000000000a7'), '919000000001',
  'client_messages: editing the client later doesn''t redirect an approved message');
select throws_ok($$update public.client_messages set status = 'approved', approved_by = '00000000-0000-0000-0000-0000000000a2', approved_at = now() where id = 'aa000000-0000-0000-0000-0000000000a8'$$,
  '23514', null, 'client_messages: an email needs the client''s email address');
select lives_ok($$update public.client_messages set status = 'approved', approved_by = '00000000-0000-0000-0000-0000000000b1', approved_at = now() where id = 'bb000000-0000-0000-0000-0000000000a7'$$,
  'client_messages: "Share via my WhatsApp" works without a phone number');

-- ---------------------------------------------------------------- item tracker: team updates through the API
select tests.matrix('display_board_snapshots read', $$select 1 from public.display_board_snapshots where current_item like 'A %'$$, false, '{1,1,1,1,0}');
select tests.matrix('display_board_snapshots insert', $$insert into public.display_board_snapshots (org_id, court_id, court_no, current_item) values ('0000000a-0000-0000-0000-000000000000', 'c0000000-0000-0000-0000-000000000003', '12', '19')$$, false, '{-1,-1,-1,-1,-1}');
select tests.matrix('display_board_snapshots insert (api)', $$insert into public.display_board_snapshots (org_id, court_id, court_no, current_item) values ('0000000a-0000-0000-0000-000000000000', 'c0000000-0000-0000-0000-000000000003', '12', '19')$$, true, '{1,1,1,1,-1}');
select tests.matrix('display_board_snapshots insert official (api)', $$insert into public.display_board_snapshots (org_id, court_id, court_no, current_item, source) values ('0000000a-0000-0000-0000-000000000000', 'c0000000-0000-0000-0000-000000000003', '12', '19', 'official')$$, true, '{-1,-1,-1,-1,-1}');
select tests.matrix('display_board_snapshots update', $$update public.display_board_snapshots set current_item = '20'$$, true, '{0,0,0,0,0}');
select tests.matrix('display_board_snapshots delete', 'delete from public.display_board_snapshots', true, '{0,0,0,0,0}');

-- ---------------------------------------------------------------- calendar feeds: own feed through the API
select tests.matrix('calendar_feeds read', 'select 1 from public.calendar_feeds', false, '{0,1,0,0,1}');
select tests.matrix('calendar_feeds insert', $$insert into public.calendar_feeds (org_id, user_id, token_hash) values ('0000000a-0000-0000-0000-000000000000', auth.uid(), 'h' || auth.uid())$$, false, '{-1,-1,-1,-1,-1}');
select tests.matrix('calendar_feeds insert (api)', $$insert into public.calendar_feeds (org_id, user_id, token_hash) values ('0000000a-0000-0000-0000-000000000000', auth.uid(), 'h' || auth.uid()) on conflict (org_id, user_id) do nothing$$, true, '{1,0,1,1,-1}');
select tests.matrix('calendar_feeds insert for someone else (api)', $$insert into public.calendar_feeds (org_id, user_id, token_hash) values ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a3', 'hx')$$, true, '{-1,-1,1,-1,-1}');
select tests.matrix('calendar_feeds rotate (api)', $$update public.calendar_feeds set token_hash = 'rotated' || auth.uid()$$, true, '{0,1,0,0,1}');
select tests.matrix('calendar_feeds rotate (device)', $$update public.calendar_feeds set token_hash = 'rotated' || auth.uid()$$, false, '{0,0,0,0,0}');
select tests.matrix('calendar_feeds move (api)', $$update public.calendar_feeds set user_id = '00000000-0000-0000-0000-0000000000a1'$$, true, '{0,-1,0,0,-1}');
select tests.matrix('calendar_feeds delete (api)', 'delete from public.calendar_feeds', true, '{0,1,0,0,1}');
select tests.matrix('calendar_feeds delete (device)', 'delete from public.calendar_feeds', false, '{0,0,0,0,0}');

-- ---------------------------------------------------------------- sync and RLS coverage
select is((select count(*)::int from pg_publication_tables where pubname = 'powersync'
           and tablename in ('voice_notes', 'display_board_snapshots')), 2, 'voice notes and the tracker are synced');
select is((select count(*)::int from pg_publication_tables where pubname = 'powersync'
           and tablename in ('document_chunks', 'ai_runs', 'ai_answers', 'public_summaries', 'client_messages',
                             'calendar_feeds')), 0, 'server-only P2 tables are never synced');

-- Last: removing a member (by status, as the app does) removes their calendar feed; another member's stays.
update public.memberships set status = 'removed' where user_id = '00000000-0000-0000-0000-0000000000a2';
select is((select count(*)::int from public.calendar_feeds where user_id = '00000000-0000-0000-0000-0000000000a2'), 0,
  'calendar_feeds go when the member is removed');
select is((select count(*)::int from public.calendar_feeds where user_id = '00000000-0000-0000-0000-0000000000b1'), 1,
  'calendar_feeds of other members stay');

-- Deleting a run, an author or an approver keeps their messages, with the key cleared.
select lives_ok($$delete from public.ai_runs where id = 'aa000000-0000-0000-0000-0000000000e9'$$,
  'client_messages: deleting the AI run behind a draft');
select lives_ok($$delete from auth.users where id = '00000000-0000-0000-0000-0000000000a3'$$,
  'client_messages: deleting the junior who drafted them');
select lives_ok($$delete from auth.users where id = '00000000-0000-0000-0000-0000000000a2'$$,
  'client_messages: deleting the advocate who approved them');
select is((select (run_id, created_by, approved_by, status, recipient)::text from public.client_messages
           where id = 'aa000000-0000-0000-0000-0000000000a6'), '(,,,approved,919000000001)',
  'client_messages: … and the approved message is otherwise unchanged');

-- ---------------------------------------------------------------- AI cost controls (ADR 0020)
select lives_ok($$insert into public.usage_ledger (org_id, kind, quantity, cost_inr) values
  ('0000000a-0000-0000-0000-000000000000', 'ai_automatic', 1, 0.5),
  ('0000000a-0000-0000-0000-000000000000', 'ai_credit', 20, 0.5)$$, 'usage_ledger takes automatic AI and credits');
select throws_ok($$insert into public.usage_ledger (org_id, kind) values ('0000000a-0000-0000-0000-000000000000', 'ai')$$,
  '23514', null, 'usage_ledger refuses an unknown kind');
select tests.matrix('usage_ledger insert ai_automatic (api)', $$insert into public.usage_ledger (org_id, kind) values ('0000000a-0000-0000-0000-000000000000', 'ai_automatic')$$, true, '{-1,-1,-1,-1,-1}');
select has_index('public', 'ai_runs', 'ai_runs_created_idx', 'ai_runs is indexed for the daily platform spend');

-- ---------------------------------------------------------------- anon gets nothing
set local role anon;
select is(tests.try('select 1 from public.document_chunks'), -1, 'anon cannot read document_chunks');
select is(tests.try('select 1 from public.public_summaries'), -1, 'anon cannot read public_summaries');
reset role;

select * from finish();
rollback;
