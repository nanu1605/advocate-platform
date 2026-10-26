-- Document text search (P2 task 4, spec §12.4, F06, F15): words match whichever way they are written. OCR and typists
-- disagree on the nukta (ज़मानत, जमानत), on the visarga (दुःख, दुख; Kruti Dev's ':' for ः), on chandrabindu and
-- anusvara (हाँ, हां) and on digits (१२, 12), so the full-text column and every query fold these the same way.

-- Lower case; Devanagari digits as Western; the precomposed nukta letters as their base letters; the nukta, the visarga
-- and zero-width (non-)joiners dropped; chandrabindu as anusvara. Escapes, so no editor recomposes the letters.
create or replace function public.search_text(t text) returns text
language sql immutable parallel safe set search_path = '' as $$
  select translate(lower(t),
    U&'\0966\0967\0968\0969\096A\096B\096C\096D\096E\096F'          -- Devanagari 0-9
      || U&'\0958\0959\095A\095B\095C\095D\095E\095F\0929\0931\0934' -- precomposed nukta letters
      || U&'\0901'                                                   -- chandrabindu
      || U&'\093C\0903\200C\200D',                                   -- nukta, visarga, ZWNJ, ZWJ: dropped
    '0123456789'
      || U&'\0915\0916\0917\091C\0921\0922\092B\092F\0928\0930\0933'
      || U&'\0902')
$$;

drop index public.document_chunks_tsv_idx;
alter table public.document_chunks drop column tsv;
alter table public.document_chunks
  add column tsv tsvector generated always as (to_tsvector('simple', public.search_text(text))) stored;
create index document_chunks_tsv_idx on public.document_chunks using gin (tsv);

-- The embedder works through the chunks that have no vector yet, oldest first.
create index document_chunks_unembedded_idx on public.document_chunks (created_at) where embedding is null;
