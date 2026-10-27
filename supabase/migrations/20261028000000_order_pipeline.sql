-- The order pipeline (P2 task 5, spec §4.4 F07, F13, §12.8, ADR 0023).

-- Order intelligence is cached like summaries: once per court order and language (doc_ref = court_orders.id),
-- read by whoever tracks the order (the read policy's `else` branch) and written only by workers.
alter table public.public_summaries
  drop constraint public_summaries_doc_kind_check,
  add constraint public_summaries_doc_kind_check check (doc_kind in ('court_order', 'order_intel', 'judgment')),
  -- the read policy casts every ref but a judgment's to uuid: a malformed one would break every read
  drop constraint public_summaries_check,
  add constraint public_summaries_check check (doc_kind = 'judgment'
    or doc_ref ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
