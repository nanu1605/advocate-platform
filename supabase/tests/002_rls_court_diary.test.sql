-- RLS and trigger matrix for Phase 1 tables (spec §9.3): five actors × read / insert / update / delete, plus every
-- trigger. Fixture CNRs are synthetic and start with PGTP, not TEST: the court_data stand-in's CNRs start with TEST,
-- and a local end-to-end run leaves those in the database.
-- Ids: chamber A 0000000a…, solo B 0000000b…; A's matters aa…01 (auto), aa…02 (manual), aa…03 (auto, deleted);
-- B's matters bb…01 (same CNR as aa…01), bb…02. Per-org rows use aa…/bb… with c1 client, d1 document, e1 order.
begin;
\ir _setup.psql

-- ---------------------------------------------------------------- P1 fixture (as postgres)
insert into public.court_cases (cnr, court_id, title, status) values
  ('PGTP010000012024', 'c0000000-0000-0000-0000-000000000003', 'Tracked by A and B', 'pending'),
  ('PGTP010000022024', 'c0000000-0000-0000-0000-000000000003', 'Deleted in A', 'pending'),
  ('PGTP010000032024', 'c0000000-0000-0000-0000-000000000005', 'Tracked by B', 'pending');
insert into public.court_hearings (cnr, hearing_date, purpose)
  select cnr, '2026-10-20', 'Admission' from public.court_cases where cnr like 'PGTP%';
insert into public.court_orders (cnr, order_date, provider_ref)
  select cnr, '2026-10-20', 'ord-' || cnr from public.court_cases where cnr like 'PGTP%';
insert into public.cause_list_entries (court_id, list_date, cnr, court_no, item_no)
  select court_id, '2026-10-26', cnr, '12', '23' from public.court_cases where cnr like 'PGTP%';
insert into public.court_holidays (court_id, date, kind, note) values
  ('c0000000-0000-0000-0000-000000000003', '2026-11-14', 'holiday', 'fixture');

insert into public.matters (id, org_id, cnr, court_id, source, tracking, deleted_at) values
  ('aa000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'PGTP010000012024',
   'c0000000-0000-0000-0000-000000000003', 'cnr', 'auto', null),
  ('aa000000-0000-0000-0000-000000000002', '0000000a-0000-0000-0000-000000000000', null,
   'c0000000-0000-0000-0000-000000000005', 'manual', 'manual', null),
  ('aa000000-0000-0000-0000-000000000003', '0000000a-0000-0000-0000-000000000000', 'PGTP010000022024',
   'c0000000-0000-0000-0000-000000000003', 'cnr', 'auto', now()),
  ('bb000000-0000-0000-0000-000000000001', '0000000b-0000-0000-0000-000000000000', 'PGTP010000012024',
   'c0000000-0000-0000-0000-000000000003', 'cnr', 'auto', null),
  ('bb000000-0000-0000-0000-000000000002', '0000000b-0000-0000-0000-000000000000', 'PGTP010000032024',
   'c0000000-0000-0000-0000-000000000005', 'cnr', 'auto', null);

insert into public.hearings (org_id, matter_id, date, source, purpose) values
  ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-000000000001', '2026-10-20', 'court', 'Admission'),
  ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-000000000002', '2026-10-21', 'manual', 'Evidence'),
  ('0000000b-0000-0000-0000-000000000000', 'bb000000-0000-0000-0000-000000000001', '2026-10-20', 'court', 'Admission');

insert into public.documents (id, org_id, matter_id, title, storage_path) values
  ('aa000000-0000-0000-0000-0000000000d1', '0000000a-0000-0000-0000-000000000000',
   'aa000000-0000-0000-0000-000000000001', 'Petition', 'a/petition.pdf'),
  ('bb000000-0000-0000-0000-0000000000d1', '0000000b-0000-0000-0000-000000000000',
   'bb000000-0000-0000-0000-000000000001', 'Petition', 'b/petition.pdf');

insert into public.orders (id, org_id, matter_id, order_date, title) values
  ('aa000000-0000-0000-0000-0000000000e1', '0000000a-0000-0000-0000-000000000000',
   'aa000000-0000-0000-0000-000000000001', '2026-10-20', 'Order'),
  ('bb000000-0000-0000-0000-0000000000e1', '0000000b-0000-0000-0000-000000000000',
   'bb000000-0000-0000-0000-000000000001', '2026-10-20', 'Order');
insert into public.order_reads (org_id, user_id, order_id) values
  ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a2', 'aa000000-0000-0000-0000-0000000000e1'),
  ('0000000b-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000b1', 'bb000000-0000-0000-0000-0000000000e1');

insert into public.org_cause_list_entries (org_id, matter_id, list_date, court_no, item_no) values
  ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-000000000001', '2026-10-26', '12', '23'),
  ('0000000b-0000-0000-0000-000000000000', 'bb000000-0000-0000-0000-000000000001', '2026-10-26', '12', '23');
insert into public.board_entries (org_id, board_date, matter_id, court_no, item_no) values
  ('0000000a-0000-0000-0000-000000000000', '2026-10-26', 'aa000000-0000-0000-0000-000000000001', '12', '23'),
  ('0000000b-0000-0000-0000-000000000000', '2026-10-26', 'bb000000-0000-0000-0000-000000000001', '12', '23');
insert into public.found_cases (org_id, user_id, cnr, confidence, match_reason, source) values
  ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a1', 'PGTP010000042024', 'high',
   'exact_name_practice_court', 'onboarding'),
  ('0000000b-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000b1', 'PGTP010000042024', 'high',
   'exact_name_practice_court', 'onboarding');

insert into public.clients (id, org_id, name) values
  ('aa000000-0000-0000-0000-0000000000c1', '0000000a-0000-0000-0000-000000000000', 'Ramesh Sharma'),
  ('bb000000-0000-0000-0000-0000000000c1', '0000000b-0000-0000-0000-000000000000', 'Sita Verma');
insert into public.matter_clients (org_id, matter_id, client_id) values
  ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-000000000001', 'aa000000-0000-0000-0000-0000000000c1'),
  ('0000000b-0000-0000-0000-000000000000', 'bb000000-0000-0000-0000-000000000001', 'bb000000-0000-0000-0000-0000000000c1');

insert into public.notes (org_id, matter_id, author_id, body, visibility) values
  ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a2', 'team', 'team'),
  ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a1', 'owner', 'private'),
  ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a4', 'clerk', 'private'),
  ('0000000b-0000-0000-0000-000000000000', 'bb000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000b1', 'team', 'team');

insert into public.tasks (org_id, matter_id, title, dedupe_key) values
  ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-000000000001', 'File reply', 'fixture-task'),
  ('0000000b-0000-0000-0000-000000000000', 'bb000000-0000-0000-0000-000000000001', 'File reply', null);
insert into public.deadlines (org_id, matter_id, kind, due_date, dedupe_key) values
  ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-000000000001', 'filing', '2026-11-01', 'fixture-deadline'),
  ('0000000b-0000-0000-0000-000000000000', 'bb000000-0000-0000-0000-000000000001', 'filing', '2026-11-01', null);

insert into public.document_offline_prefs (org_id, user_id, document_id) values
  ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a2', 'aa000000-0000-0000-0000-0000000000d1'),
  ('0000000b-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000b1', 'bb000000-0000-0000-0000-0000000000d1');

insert into public.notifications (id, org_id, user_id, kind, title) values
  ('aa000000-0000-0000-0000-0000000000f1', '0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a1', 'tomorrow_board', 'Tomorrow'),
  ('aa000000-0000-0000-0000-0000000000f2', '0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a2', 'tomorrow_board', 'Tomorrow'),
  ('bb000000-0000-0000-0000-0000000000f1', '0000000b-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000b1', 'tomorrow_board', 'Tomorrow');
insert into public.notification_deliveries (notification_id, channel, status) values
  ('aa000000-0000-0000-0000-0000000000f1', 'push', 'sent');
insert into public.notification_prefs (user_id, kind) values
  ('00000000-0000-0000-0000-0000000000a1', 'tomorrow_board'), ('00000000-0000-0000-0000-0000000000b1', 'tomorrow_board');

insert into public.provider_calls (provider, operation, org_id, status) values
  ('fixture', 'get_case', '0000000a-0000-0000-0000-000000000000', 'ok'),
  ('fixture', 'get_case', '0000000b-0000-0000-0000-000000000000', 'ok'),
  ('fixture', 'get_case', null, 'ok');
insert into public.usage_ledger (org_id, kind) values
  ('0000000a-0000-0000-0000-000000000000', 'provider_call'), ('0000000b-0000-0000-0000-000000000000', 'provider_call'),
  (null, 'provider_call');
insert into public.feedback (org_id, user_id, note) values
  ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a1', 'fixture'),
  ('0000000b-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000b1', 'fixture');

-- ---------------------------------------------------------------- reference data
select is((select count(*)::int from public.courts where id::text like 'c0000000-%'), 5, 'reference courts seeded');
select is((select value from public.app_config where key = 'beta_tracked_case_allowance'), '100'::jsonb,
  'beta tracked-case allowance seeded');

select tests.matrix('courts read', $$select 1 from public.courts where id::text like 'c0000000-%'$$, false, '{5,5,5,5,5}');
select tests.matrix('courts insert', $$insert into public.courts (level, name, name_hi, short_name, short_name_hi) values ('DC', 'x', 'x', 'x', 'x')$$, true, '{-1,-1,-1,-1,-1}');
select tests.matrix('courts update', $$update public.courts set name = 'x'$$, true, '{0,0,0,0,0}');
select tests.matrix('courts delete', 'delete from public.courts', true, '{0,0,0,0,0}');
select tests.matrix('court_holidays read', $$select 1 from public.court_holidays where note = 'fixture'$$, false, '{1,1,1,1,1}');
select tests.matrix('court_holidays insert', $$insert into public.court_holidays (court_id, date, kind) values ('c0000000-0000-0000-0000-000000000003', '2026-12-25', 'holiday')$$, true, '{-1,-1,-1,-1,-1}');
select tests.matrix('court_holidays update', $$update public.court_holidays set status = 'VERIFIED'$$, true, '{0,0,0,0,0}');
select tests.matrix('court_holidays delete', 'delete from public.court_holidays', true, '{0,0,0,0,0}');

-- ---------------------------------------------------------------- shared court data: only CNRs your organisation tracks
select tests.matrix('court_cases read', 'select 1 from public.court_cases', false, '{1,1,1,1,2}');
select tests.matrix('court_cases insert', $$insert into public.court_cases (cnr) values ('PGTP010000092024')$$, true, '{-1,-1,-1,-1,-1}');
select tests.matrix('court_cases update', $$update public.court_cases set title = 'x'$$, true, '{0,0,0,0,0}');
select tests.matrix('court_cases delete', 'delete from public.court_cases', true, '{0,0,0,0,0}');
select tests.matrix('court_hearings read', 'select 1 from public.court_hearings', false, '{1,1,1,1,2}');
select tests.matrix('court_hearings insert', $$insert into public.court_hearings (cnr, hearing_date) values ('PGTP010000012024', '2026-10-30')$$, true, '{-1,-1,-1,-1,-1}');
select tests.matrix('court_hearings update', $$update public.court_hearings set purpose = 'x'$$, true, '{0,0,0,0,0}');
select tests.matrix('court_hearings delete', 'delete from public.court_hearings', true, '{0,0,0,0,0}');
select tests.matrix('court_orders read', 'select 1 from public.court_orders', false, '{1,1,1,1,2}');
select tests.matrix('court_orders insert', $$insert into public.court_orders (cnr, provider_ref) values ('PGTP010000012024', 'x')$$, true, '{-1,-1,-1,-1,-1}');
select tests.matrix('court_orders update', $$update public.court_orders set pages = 1$$, true, '{0,0,0,0,0}');
select tests.matrix('court_orders delete', 'delete from public.court_orders', true, '{0,0,0,0,0}');
select tests.matrix('cause_list_entries read', 'select 1 from public.cause_list_entries', false, '{1,1,1,1,2}');
select tests.matrix('cause_list_entries insert', $$insert into public.cause_list_entries (list_date, cnr) values ('2026-10-27', 'PGTP010000012024')$$, true, '{-1,-1,-1,-1,-1}');
select tests.matrix('cause_list_entries update', $$update public.cause_list_entries set item_no = '1'$$, true, '{0,0,0,0,0}');
select tests.matrix('cause_list_entries delete', 'delete from public.cause_list_entries', true, '{0,0,0,0,0}');

-- ---------------------------------------------------------------- matters
select tests.matrix('matters read', 'select 1 from public.matters', false, '{3,3,3,3,2}');
select tests.matrix('matters insert (device)', $$insert into public.matters (org_id, cnr, source) values ('0000000a-0000-0000-0000-000000000000', 'PGTP010000092024', 'cnr')$$, false, '{-1,-1,-1,-1,-1}');
select tests.matrix('matters insert in A', $$insert into public.matters (org_id, cnr, source) values ('0000000a-0000-0000-0000-000000000000', 'PGTP010000092024', 'cnr')$$, true, '{1,1,1,1,-1}');
select tests.matrix('matters tags (device)', $$update public.matters set tags = '{urgent}', file_no = 'F-1', our_side = 'petitioner', status = 'archived' where id = 'aa000000-0000-0000-0000-000000000001'$$, false, '{1,1,1,1,0}');
select tests.matrix('matters assign (device)', $$update public.matters set assigned_to = '00000000-0000-0000-0000-0000000000a3' where id = 'aa000000-0000-0000-0000-000000000001'$$, false, '{1,1,1,1,0}');
select tests.matrix('matters tracking (device)', $$update public.matters set tracking = 'manual' where id = 'aa000000-0000-0000-0000-000000000001'$$, false, '{-1,-1,-1,-1,0}');
select tests.matrix('matters tracking', $$update public.matters set tracking = 'manual' where id = 'aa000000-0000-0000-0000-000000000001'$$, true, '{1,1,1,1,0}');
select tests.matrix('matters soft delete (device)', $$update public.matters set deleted_at = now() where id = 'aa000000-0000-0000-0000-000000000001'$$, false, '{-1,-1,-1,-1,0}');
select tests.matrix('matters soft delete', $$update public.matters set deleted_at = now() where id = 'aa000000-0000-0000-0000-000000000001'$$, true, '{1,1,1,1,0}');
select tests.matrix('matters court field', $$update public.matters set next_hearing_date = '2026-11-05' where id = 'aa000000-0000-0000-0000-000000000001'$$, true, '{-1,-1,-1,-1,0}');
select tests.matrix('matters cnr', $$update public.matters set cnr = 'PGTP010000092024' where id = 'aa000000-0000-0000-0000-000000000001'$$, true, '{-1,-1,-1,-1,0}');
select tests.matrix('matters move org', $$update public.matters set org_id = '0000000b-0000-0000-0000-000000000000' where id = 'aa000000-0000-0000-0000-000000000001'$$, true, '{-1,-1,-1,-1,0}');
select tests.matrix('matters delete', 'delete from public.matters', true, '{0,0,0,0,0}');
select is(tests.state('00000000-0000-0000-0000-0000000000a1', false,
  $$update public.matters set assigned_to = '00000000-0000-0000-0000-0000000000b1' where id = 'aa000000-0000-0000-0000-000000000001'$$),
  '23503', 'matters can only be assigned to members');

update public.app_config set value = '1' where key = 'beta_tracked_case_allowance';
select is(tests.state('00000000-0000-0000-0000-0000000000a1', true,
  $$insert into public.matters (org_id, cnr, source) values ('0000000a-0000-0000-0000-000000000000', 'PGTP010000092024', 'cnr')$$),
  'P0001', 'allowance blocks a new auto-tracked case');
select is(tests.state('00000000-0000-0000-0000-0000000000a1', true,
  $$insert into public.matters (org_id, source, tracking) values ('0000000a-0000-0000-0000-000000000000', 'manual', 'manual')$$),
  '00000', 'allowance ignores manual cases');
select is(tests.state('00000000-0000-0000-0000-0000000000a1', true,
  $$update public.matters set tracking = 'auto' where id = 'aa000000-0000-0000-0000-000000000002'$$),
  'P0001', 'allowance blocks switching a case to auto');
select is(tests.state('00000000-0000-0000-0000-0000000000a1', true,
  $$update public.matters set deleted_at = null where id = 'aa000000-0000-0000-0000-000000000003'$$),
  'P0001', 'allowance blocks restoring a deleted auto case');
select is(tests.state('00000000-0000-0000-0000-0000000000b1', true,
  $$insert into public.matters (org_id, cnr, source) values ('0000000b-0000-0000-0000-000000000000', 'PGTP010000092024', 'cnr')$$),
  'P0001', 'allowance counts per organisation');
update public.app_config set value = '100' where key = 'beta_tracked_case_allowance';

-- ---------------------------------------------------------------- hearings
select tests.matrix('hearings read', 'select 1 from public.hearings', false, '{2,2,2,2,1}');
select tests.matrix('hearings insert court row', $$insert into public.hearings (org_id, matter_id, date, source) values ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-000000000001', '2026-11-05', 'court')$$, true, '{-1,-1,-1,-1,-1}');
select tests.matrix('hearings insert manual on manual matter', $$insert into public.hearings (org_id, matter_id, date, source) values ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-000000000002', '2026-11-05', 'manual')$$, false, '{1,1,1,1,-1}');
select tests.matrix('hearings insert manual on auto matter', $$insert into public.hearings (org_id, matter_id, date, source) values ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-000000000001', '2026-11-05', 'manual')$$, false, '{-1,-1,-1,-1,-1}');
select tests.matrix('hearings insert voice (device)', $$insert into public.hearings (org_id, matter_id, date, source) values ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-000000000002', '2026-11-05', 'voice')$$, false, '{-1,-1,-1,-1,-1}');
select tests.matrix('hearings insert voice', $$insert into public.hearings (org_id, matter_id, date, source) values ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-000000000002', '2026-11-05', 'voice')$$, true, '{1,1,1,1,-1}');
select tests.matrix('hearings user fields on court row', $$update public.hearings set user_note = 'x', user_next_date = '2026-11-07', confirmed = true where matter_id = 'aa000000-0000-0000-0000-000000000001'$$, false, '{1,1,1,1,0}');
select tests.matrix('hearings court field on court row', $$update public.hearings set next_date = '2026-11-05' where matter_id = 'aa000000-0000-0000-0000-000000000001'$$, true, '{-1,-1,-1,-1,0}');
select tests.matrix('hearings edit manual row', $$update public.hearings set next_date = '2026-11-05', purpose = 'Arguments', deleted_at = now() where matter_id = 'aa000000-0000-0000-0000-000000000002'$$, false, '{1,1,1,1,0}');
select tests.matrix('hearings change source', $$update public.hearings set source = 'court' where matter_id = 'aa000000-0000-0000-0000-000000000002'$$, false, '{-1,-1,-1,-1,0}');
select tests.matrix('hearings delete', 'delete from public.hearings', true, '{0,0,0,0,0}');

-- ---------------------------------------------------------------- orders and per-user reads
select tests.matrix('orders read', 'select 1 from public.orders', false, '{1,1,1,1,1}');
select tests.matrix('orders insert', $$insert into public.orders (org_id, matter_id) values ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-000000000001')$$, true, '{-1,-1,-1,-1,-1}');
select tests.matrix('orders update', $$update public.orders set title = 'x'$$, true, '{0,0,0,0,0}');
select tests.matrix('orders delete', 'delete from public.orders', true, '{0,0,0,0,0}');

select tests.matrix('order_reads read', 'select 1 from public.order_reads', false, '{0,1,0,0,1}');
select tests.matrix('order_reads insert own', $$insert into public.order_reads (org_id, user_id, order_id) values ('0000000a-0000-0000-0000-000000000000', auth.uid(), 'aa000000-0000-0000-0000-0000000000e1') on conflict (user_id, order_id) do nothing$$, false, '{1,0,1,1,-1}');
select tests.matrix('order_reads insert for another user', $$insert into public.order_reads (org_id, user_id, order_id) values ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000b1', 'aa000000-0000-0000-0000-0000000000e1')$$, false, '{-1,-1,-1,-1,-1}');
select tests.matrix('order_reads update own', 'update public.order_reads set read_at = now()', false, '{0,1,0,0,1}');
select tests.matrix('order_reads delete own', 'delete from public.order_reads', false, '{0,1,0,0,1}');

-- ---------------------------------------------------------------- cause lists and Tomorrow's Board
select tests.matrix('org_cause_list_entries read', 'select 1 from public.org_cause_list_entries', false, '{1,1,1,1,1}');
select tests.matrix('org_cause_list_entries insert', $$insert into public.org_cause_list_entries (org_id, matter_id, list_date) values ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-000000000001', '2026-10-27')$$, true, '{-1,-1,-1,-1,-1}');
select tests.matrix('org_cause_list_entries update', $$update public.org_cause_list_entries set item_no = '1'$$, true, '{0,0,0,0,0}');
select tests.matrix('org_cause_list_entries delete', 'delete from public.org_cause_list_entries', true, '{0,0,0,0,0}');

select tests.matrix('board_entries read', 'select 1 from public.board_entries', false, '{1,1,1,1,1}');
select tests.matrix('board_entries assign in A', $$update public.board_entries set assignee_id = '00000000-0000-0000-0000-0000000000a3' where org_id = '0000000a-0000-0000-0000-000000000000'$$, false, '{1,1,0,0,0}');
select tests.matrix('board_entries proxy in A', $$update public.board_entries set proxy_arranged = true where org_id = '0000000a-0000-0000-0000-000000000000'$$, false, '{1,1,0,0,0}');
select tests.matrix('board_entries court_no in A', $$update public.board_entries set court_no = '1' where org_id = '0000000a-0000-0000-0000-000000000000'$$, false, '{-1,-1,0,0,0}');
select tests.matrix('board_entries insert', $$insert into public.board_entries (org_id, board_date, matter_id) values ('0000000a-0000-0000-0000-000000000000', '2026-10-27', 'aa000000-0000-0000-0000-000000000001')$$, true, '{-1,-1,-1,-1,-1}');
select tests.matrix('board_entries delete', 'delete from public.board_entries', true, '{0,0,0,0,0}');

-- ---------------------------------------------------------------- found cases: decisions through the API
select tests.matrix('found_cases read', 'select 1 from public.found_cases', false, '{1,1,1,1,1}');
select tests.matrix('found_cases decision (device)', $$update public.found_cases set decision = 'added' where org_id = '0000000a-0000-0000-0000-000000000000'$$, false, '{0,0,0,0,0}');
select tests.matrix('found_cases decision', $$update public.found_cases set decision = 'not_mine' where org_id = '0000000a-0000-0000-0000-000000000000'$$, true, '{1,1,1,1,0}');
select tests.matrix('found_cases cnr', $$update public.found_cases set cnr = 'PGTP010000092024' where org_id = '0000000a-0000-0000-0000-000000000000'$$, true, '{-1,-1,-1,-1,0}');
select tests.matrix('found_cases insert', $$insert into public.found_cases (org_id, user_id, cnr, confidence, match_reason, source) values ('0000000a-0000-0000-0000-000000000000', auth.uid(), 'PGTP010000092024', 'low', 'partial_name', 'auto_match')$$, true, '{-1,-1,-1,-1,-1}');
select tests.matrix('found_cases delete', 'delete from public.found_cases', true, '{0,0,0,0,0}');

-- ---------------------------------------------------------------- clients
select tests.matrix('clients read', 'select 1 from public.clients', false, '{1,1,1,1,1}');
select tests.matrix('clients insert in A', $$insert into public.clients (org_id, name) values ('0000000a-0000-0000-0000-000000000000', 'New client')$$, false, '{1,1,1,1,-1}');
select tests.matrix('clients update in A', $$update public.clients set phone = '919999900000' where org_id = '0000000a-0000-0000-0000-000000000000'$$, false, '{1,1,1,1,0}');
select tests.matrix('clients move org', $$update public.clients set org_id = '0000000b-0000-0000-0000-000000000000' where org_id = '0000000a-0000-0000-0000-000000000000'$$, false, '{-1,-1,-1,-1,0}');
select tests.matrix('clients delete', 'delete from public.clients', false, '{0,0,0,0,0}');

select tests.matrix('matter_clients read', 'select 1 from public.matter_clients', false, '{1,1,1,1,1}');
select tests.matrix('matter_clients link in A', $$insert into public.matter_clients (org_id, matter_id, client_id) values ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-000000000002', 'aa000000-0000-0000-0000-0000000000c1')$$, false, '{1,1,1,1,-1}');
select tests.matrix('matter_clients unlink in A', $$delete from public.matter_clients where org_id = '0000000a-0000-0000-0000-000000000000'$$, false, '{1,1,1,1,0}');
select is(tests.state('00000000-0000-0000-0000-0000000000a1', false,
  $$insert into public.matter_clients (org_id, matter_id, client_id) values ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-000000000001', 'bb000000-0000-0000-0000-0000000000c1')$$),
  '23503', 'matter_clients cannot link another organisation''s client');

-- ---------------------------------------------------------------- notes: team vs private
select tests.matrix('notes read', 'select 1 from public.notes', false, '{2,1,1,2,1}');
select tests.matrix('notes insert team in A', $$insert into public.notes (org_id, matter_id, author_id, body) values ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-000000000001', auth.uid(), 'x')$$, false, '{1,1,1,1,-1}');
select tests.matrix('notes insert as someone else', $$insert into public.notes (org_id, matter_id, author_id, body) values ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-000000000001', case when auth.uid() = '00000000-0000-0000-0000-0000000000a2' then '00000000-0000-0000-0000-0000000000a1'::uuid else '00000000-0000-0000-0000-0000000000a2'::uuid end, 'x')$$, false, '{-1,-1,-1,-1,-1}');
select tests.matrix('notes edit team note in A', $$update public.notes set body = 'x' where org_id = '0000000a-0000-0000-0000-000000000000' and visibility = 'team'$$, false, '{1,1,1,1,0}');
select tests.matrix('notes edit owner''s private note', $$update public.notes set body = 'x' where author_id = '00000000-0000-0000-0000-0000000000a1'$$, false, '{1,0,0,0,0}');
select tests.matrix('notes make team note private', $$update public.notes set visibility = 'private' where org_id = '0000000a-0000-0000-0000-000000000000' and visibility = 'team'$$, false, '{-1,1,-1,-1,0}');
select tests.matrix('notes change author', $$update public.notes set author_id = '00000000-0000-0000-0000-0000000000b1' where org_id = '0000000a-0000-0000-0000-000000000000' and visibility = 'team'$$, false, '{-1,-1,-1,-1,0}');
select tests.matrix('notes delete', 'delete from public.notes', false, '{0,0,0,0,0}');

-- ---------------------------------------------------------------- tasks and deadlines
select tests.matrix('tasks read', 'select 1 from public.tasks', false, '{1,1,1,1,1}');
select tests.matrix('tasks insert in A', $$insert into public.tasks (org_id, matter_id, title) values ('0000000a-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-000000000001', 'x')$$, false, '{1,1,1,1,-1}');
select tests.matrix('tasks update in A', $$update public.tasks set status = 'done', assignee_id = '00000000-0000-0000-0000-0000000000a4' where org_id = '0000000a-0000-0000-0000-000000000000'$$, false, '{1,1,1,1,0}');
select tests.matrix('tasks move org', $$update public.tasks set org_id = '0000000b-0000-0000-0000-000000000000' where org_id = '0000000a-0000-0000-0000-000000000000'$$, false, '{-1,-1,-1,-1,0}');
select tests.matrix('tasks delete', 'delete from public.tasks', false, '{0,0,0,0,0}');
select is(tests.state('00000000-0000-0000-0000-0000000000a1', false,
  $$insert into public.tasks (org_id, title, dedupe_key) values ('0000000a-0000-0000-0000-000000000000', 'x', 'fixture-task')$$),
  '23505', 'tasks dedupe_key stops duplicate proposals');

select tests.matrix('deadlines read', 'select 1 from public.deadlines', false, '{1,1,1,1,1}');
select tests.matrix('deadlines insert in A', $$insert into public.deadlines (org_id, kind, due_date) values ('0000000a-0000-0000-0000-000000000000', 'other', '2026-12-01')$$, false, '{1,1,1,1,-1}');
select tests.matrix('deadlines update in A', $$update public.deadlines set status = 'done' where org_id = '0000000a-0000-0000-0000-000000000000'$$, false, '{1,1,1,1,0}');
select tests.matrix('deadlines move org', $$update public.deadlines set org_id = '0000000b-0000-0000-0000-000000000000' where org_id = '0000000a-0000-0000-0000-000000000000'$$, false, '{-1,-1,-1,-1,0}');
select tests.matrix('deadlines delete', 'delete from public.deadlines', false, '{0,0,0,0,0}');
select is(tests.state('00000000-0000-0000-0000-0000000000a1', false,
  $$insert into public.deadlines (org_id, kind, due_date, dedupe_key) values ('0000000a-0000-0000-0000-000000000000', 'other', '2026-12-01', 'fixture-deadline')$$),
  '23505', 'deadlines dedupe_key stops duplicate proposals');

-- ---------------------------------------------------------------- documents
select tests.matrix('documents read', 'select 1 from public.documents', false, '{1,1,1,1,1}');
select tests.matrix('documents insert (device)', $$insert into public.documents (org_id, title) values ('0000000a-0000-0000-0000-000000000000', 'x')$$, false, '{-1,-1,-1,-1,-1}');
select tests.matrix('documents insert in A', $$insert into public.documents (org_id, title) values ('0000000a-0000-0000-0000-000000000000', 'x')$$, true, '{1,1,1,1,-1}');
select tests.matrix('documents rename (device)', $$update public.documents set title = 'x', kind = 'order', matter_id = null where org_id = '0000000a-0000-0000-0000-000000000000'$$, false, '{1,1,1,1,0}');
select tests.matrix('documents soft delete (device)', $$update public.documents set deleted_at = now() where org_id = '0000000a-0000-0000-0000-000000000000'$$, false, '{1,1,1,1,0}');
select tests.matrix('documents storage_path (device)', $$update public.documents set storage_path = 'x' where org_id = '0000000a-0000-0000-0000-000000000000'$$, false, '{-1,-1,-1,-1,0}');
select tests.matrix('documents storage_path', $$update public.documents set storage_path = 'x', upload_status = 'ready' where org_id = '0000000a-0000-0000-0000-000000000000'$$, true, '{1,1,1,1,0}');
select tests.matrix('documents move org', $$update public.documents set org_id = '0000000b-0000-0000-0000-000000000000', matter_id = null where org_id = '0000000a-0000-0000-0000-000000000000'$$, true, '{-1,-1,-1,-1,0}');
select tests.matrix('documents delete', 'delete from public.documents', true, '{0,0,0,0,0}');
select is(tests.state('00000000-0000-0000-0000-0000000000a1', true,
  $$insert into public.documents (org_id, title, size_bytes) values ('0000000a-0000-0000-0000-000000000000', 'x', 52428801)$$),
  '23514', 'documents larger than 50 MB are rejected');

select tests.matrix('document_offline_prefs read', 'select 1 from public.document_offline_prefs', false, '{0,1,0,0,1}');
select tests.matrix('document_offline_prefs insert own', $$insert into public.document_offline_prefs (org_id, user_id, document_id) values ('0000000a-0000-0000-0000-000000000000', auth.uid(), 'aa000000-0000-0000-0000-0000000000d1') on conflict (user_id, document_id) do nothing$$, false, '{1,0,1,1,-1}');
select tests.matrix('document_offline_prefs update own', 'update public.document_offline_prefs set keep_offline = false', false, '{0,1,0,0,1}');
select tests.matrix('document_offline_prefs delete own', 'delete from public.document_offline_prefs', false, '{0,1,0,0,1}');

-- ---------------------------------------------------------------- notifications
select tests.matrix('notifications read', 'select 1 from public.notifications', false, '{1,1,0,0,1}');
select tests.matrix('notifications mark read', 'update public.notifications set read_at = now()', false, '{1,1,0,0,1}');
select tests.matrix('notifications edit title', $$update public.notifications set title = 'x'$$, false, '{-1,-1,0,0,-1}');
select tests.matrix('notifications insert', $$insert into public.notifications (user_id, kind) values (auth.uid(), 'sync_issue')$$, true, '{-1,-1,-1,-1,-1}');
select tests.matrix('notifications delete', 'delete from public.notifications', true, '{0,0,0,0,0}');

select tests.matrix('notification_deliveries read', 'select 1 from public.notification_deliveries', false, '{0,0,0,0,0}');
select tests.matrix('notification_deliveries insert', $$insert into public.notification_deliveries (notification_id, channel, status) values ('aa000000-0000-0000-0000-0000000000f1', 'push', 'x')$$, true, '{-1,-1,-1,-1,-1}');
select tests.matrix('notification_deliveries update', $$update public.notification_deliveries set status = 'x'$$, true, '{0,0,0,0,0}');
select tests.matrix('notification_deliveries delete', 'delete from public.notification_deliveries', true, '{0,0,0,0,0}');

select tests.matrix('notification_prefs read', 'select 1 from public.notification_prefs', false, '{1,0,0,0,1}');
select tests.matrix('notification_prefs insert own', $$insert into public.notification_prefs (user_id, kind) values (auth.uid(), 'new_order')$$, false, '{1,1,1,1,1}');
select tests.matrix('notification_prefs insert for another user', $$insert into public.notification_prefs (user_id, kind) values (case when auth.uid() = '00000000-0000-0000-0000-0000000000a1' then '00000000-0000-0000-0000-0000000000b1'::uuid else '00000000-0000-0000-0000-0000000000a1'::uuid end, 'new_order')$$, false, '{-1,-1,-1,-1,-1}');
select tests.matrix('notification_prefs update own', 'update public.notification_prefs set include_titles = true', false, '{1,0,0,0,1}');
select tests.matrix('notification_prefs delete own', 'delete from public.notification_prefs', false, '{1,0,0,0,1}');

-- ---------------------------------------------------------------- costs and feedback
select tests.matrix('provider_calls read', 'select 1 from public.provider_calls', false, '{1,0,0,0,1}');
select tests.matrix('provider_calls insert', $$insert into public.provider_calls (provider, operation, status) values ('x', 'x', 'x')$$, true, '{-1,-1,-1,-1,-1}');
select tests.matrix('provider_calls update', $$update public.provider_calls set status = 'x'$$, true, '{0,0,0,0,0}');
select tests.matrix('provider_calls delete', 'delete from public.provider_calls', true, '{0,0,0,0,0}');
select tests.matrix('usage_ledger read', 'select 1 from public.usage_ledger', false, '{1,0,0,0,1}');
select tests.matrix('usage_ledger insert', $$insert into public.usage_ledger (kind) values ('provider_call')$$, true, '{-1,-1,-1,-1,-1}');
select tests.matrix('usage_ledger update', 'update public.usage_ledger set quantity = 2', true, '{0,0,0,0,0}');
select tests.matrix('usage_ledger delete', 'delete from public.usage_ledger', true, '{0,0,0,0,0}');

select tests.matrix('feedback read', 'select 1 from public.feedback', false, '{1,0,0,0,1}');
select tests.matrix('feedback insert own in A', $$insert into public.feedback (org_id, user_id, note) values ('0000000a-0000-0000-0000-000000000000', auth.uid(), 'x')$$, false, '{1,1,1,1,-1}');
select tests.matrix('feedback insert own', $$insert into public.feedback (user_id, note) values (auth.uid(), 'x')$$, false, '{1,1,1,1,1}');
select tests.matrix('feedback update', $$update public.feedback set note = 'x'$$, false, '{0,0,0,0,0}');
select tests.matrix('feedback delete', 'delete from public.feedback', false, '{0,0,0,0,0}');

-- ---------------------------------------------------------------- anon gets nothing
set local role anon;
select is(tests.try('select 1 from public.matters'), -1, 'anon cannot read matters');
select is(tests.try('select 1 from public.courts'), -1, 'anon cannot read courts');
reset role;

select * from finish();
rollback;
