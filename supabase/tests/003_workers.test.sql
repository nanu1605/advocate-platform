-- Worker support (P1 task 6): the court-day rule and the keys that make re-run jobs idempotent.
begin;
\ir _setup.psql

-- ---------------------------------------------------------------- court days
insert into public.court_holidays (court_id, date, kind, status) values
  ('c0000000-0000-0000-0000-000000000003', '2031-01-06', 'holiday', 'VERIFIED'),
  ('c0000000-0000-0000-0000-000000000003', '2031-01-07', 'holiday', 'DRAFT');
select is(public.is_court_day('c0000000-0000-0000-0000-000000000003', '2031-01-05'), false, 'Sunday is no court day');
select is(public.is_court_day('c0000000-0000-0000-0000-000000000003', '2031-01-06'), false, 'a VERIFIED holiday closes the court');
select is(public.is_court_day('c0000000-0000-0000-0000-000000000003', '2031-01-07'), true, 'a DRAFT holiday does not');
select is(public.is_court_day('c0000000-0000-0000-0000-000000000005', '2031-01-06'), true, 'another court stays open');
select is(public.is_court_day(null, '2031-01-06'), true, 'a case without a known court sits on weekdays');

-- ---------------------------------------------------------------- cause-list reruns
insert into public.cause_list_entries (list_date, cnr, item_no) values ('2031-01-06', 'TEST099999999999', '4');
select throws_ok(
  $$insert into public.cause_list_entries (list_date, cnr, item_no) values ('2031-01-06', 'TEST099999999999', '9')$$,
  '23505', null, 'one listing per case per day');
select lives_ok(
  $$insert into public.cause_list_entries (list_date, cnr) values ('2031-01-07', 'TEST099999999999'),
    ('2031-01-06', null), ('2031-01-06', null)$$,
  'another day, or rows without a CNR, are separate');

-- ---------------------------------------------------------------- court sittings
insert into public.court_hearings (cnr, hearing_date, purpose) values ('TEST099999999999', '2031-01-06', null);
select throws_ok(
  $$insert into public.court_hearings (cnr, hearing_date, purpose) values ('TEST099999999999', '2031-01-06', 'Admission')$$,
  '23505', null, 'one sitting per case and date: a corrected purpose updates it');

-- ---------------------------------------------------------------- notification event keys
insert into public.notifications (user_id, kind, data) values
  ('00000000-0000-0000-0000-0000000000a1', 'next_date_set', '{"event_key": "TEST099999999999:next_date_set:2031-01-06"}');
select throws_ok(
  $$insert into public.notifications (user_id, kind, data) values ('00000000-0000-0000-0000-0000000000a1',
    'next_date_set', '{"event_key": "TEST099999999999:next_date_set:2031-01-06"}')$$,
  '23505', null, 'an event notifies a user once');
select lives_ok(
  $$insert into public.notifications (user_id, kind, data) values ('00000000-0000-0000-0000-0000000000a2',
    'next_date_set', '{"event_key": "TEST099999999999:next_date_set:2031-01-06"}'),
    ('00000000-0000-0000-0000-0000000000a1', 'sync_issue', '{}'), ('00000000-0000-0000-0000-0000000000a1', 'sync_issue', '{}')$$,
  'other users, and rows without a key, are not limited');

select * from finish();
rollback;
