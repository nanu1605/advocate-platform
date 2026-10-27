-- The order pipeline (P2 task 5): order intelligence is cached in public_summaries, read like a court order's
-- summary (whoever tracks the order) and never written by users. Matrix order: owner, advocate, junior, clerk
-- (chamber A), outsider (solo B).
begin;
\ir _setup.psql

insert into public.court_orders (id, cnr, order_date, provider_ref) values
  ('c1000000-0000-0000-0000-000000000061', 'PGTP060000012024', '2026-10-20', 'ord-a');
insert into public.matters (org_id, cnr, court_id, source, tracking) values
  ('0000000a-0000-0000-0000-000000000000', 'PGTP060000012024', 'c0000000-0000-0000-0000-000000000003', 'cnr', 'manual');
insert into public.public_summaries (doc_kind, doc_ref, language, summary, model_id, prompt_version) values
  ('order_intel', 'c1000000-0000-0000-0000-000000000061', 'hi', '{"actions": []}', 'fixture', 'v1');

select tests.matrix('order_intel read', $$select 1 from public.public_summaries where doc_kind = 'order_intel'$$,
  true, '{1,1,1,1,0}');
select tests.matrix('order_intel insert', $$insert into public.public_summaries (doc_kind, doc_ref, language, summary, model_id, prompt_version) values ('order_intel', 'c1000000-0000-0000-0000-000000000061', 'en', '{}', 'x', 'v1')$$,
  true, '{-1,-1,-1,-1,-1}');
select tests.matrix('order_intel update', $$update public.public_summaries set summary = '{}' where doc_kind = 'order_intel'$$,
  true, '{0,0,0,0,0}');
select tests.matrix('order_intel delete', $$delete from public.public_summaries where doc_kind = 'order_intel'$$,
  true, '{0,0,0,0,0}');
select throws_ok($$insert into public.public_summaries (doc_kind, doc_ref, language, summary, model_id, prompt_version) values ('order_intel', 'ord-a', 'en', '{}', 'x', 'v1')$$,
  '23514', null, 'order_intel: a court order is referred to by its id');
select throws_ok($$insert into public.public_summaries (doc_kind, doc_ref, language, summary, model_id, prompt_version) values ('order_intel', 'c1000000-0000-0000-0000-000000000061', 'hi', '{}', 'x', 'v1')$$,
  '23505', null, 'order_intel: one per court order and language');
select throws_ok($$insert into public.public_summaries (doc_kind, doc_ref, language, summary, model_id, prompt_version) values ('order_tasks', 'c1000000-0000-0000-0000-000000000061', 'en', '{}', 'x', 'v1')$$,
  '23514', null, 'public_summaries: only known kinds');
select lives_ok($$insert into public.public_summaries (doc_kind, doc_ref, language, summary, model_id, prompt_version) values ('judgment', 'J-006', 'en', '{}', 'x', 'v1')$$,
  'a judgment keeps its own ref');

select * from finish();
rollback;
