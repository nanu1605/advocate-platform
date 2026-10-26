-- Document text search (P2 task 4): words match whichever way OCR or a typist wrote them (search_text).
begin;
\ir _setup.psql

select is(public.search_text('ज़मानत'), 'जमानत', 'the nukta is dropped');
select is(public.search_text(U&'\095Bमानत'), 'जमानत', 'a precomposed nukta letter is its base letter');
select is(public.search_text('दुःख अतः'), 'दुख अत', 'the visarga is dropped');
select is(public.search_text('हाँ'), 'हां', 'chandrabindu is anusvara');
select is(public.search_text('धारा ३०२ WP'), 'धारा 302 wp', 'Devanagari digits are Western, and case folds');

insert into public.court_orders (id, cnr, provider_ref) values
  ('c1000000-0000-0000-0000-0000000000f1', 'PGTP050000012024', 'ord-text');
insert into public.document_chunks (court_order_id, page_no, chunk_no, text) values
  ('c1000000-0000-0000-0000-0000000000f1', 1, 0, 'आवेदक को ज़मानत पर रिहा किया जाए। दुःख। धारा ३०२');
select is(
  (select count(*)::int from public.document_chunks
   where tsv @@ plainto_tsquery('simple', public.search_text('जमानत धारा 302 दुख'))),
  1, 'the full-text column folds the same way as the query');
select is(
  (select count(*)::int from public.document_chunks
   where court_order_id = 'c1000000-0000-0000-0000-0000000000f1' and embedding is null),
  1, 'a new chunk waits for its embedding');
select ok(
  exists (select 1 from pg_indexes where indexname = 'document_chunks_unembedded_idx'),
  'the embedder finds unembedded chunks by index');

select * from finish();
rollback;
