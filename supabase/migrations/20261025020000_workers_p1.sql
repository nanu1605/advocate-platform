-- Phase 1 workers (spec §11.5–11.6, §13, P1 task 6): keys that make re-run jobs idempotent, and the court-day rule.

-- Event keys (cnr, event, value) per user, so a retried fan-out never notifies twice (§11.6). Rows without a key
-- never conflict (null). The evening board uses one key per organisation and date, so a later attempt rewrites the
-- same message instead of adding one (§13.2 batching).
create unique index notifications_event_key_idx on public.notifications (user_id, (data->>'event_key'));

-- One listing per case per day: the 20:30 and 22:00 cause-list attempts update the 18:30 rows.
-- ponytail: a second listing the same day (supplementary list) replaces the first; add list_type to the key if the
-- board ever needs both.
drop index public.cause_list_entries_cnr_idx;
alter table public.cause_list_entries add constraint cause_list_entries_cnr_list_date_key unique (cnr, list_date);

-- One sitting per case and date (§11.6): a corrected purpose updates the sitting in place, so the diary hearings
-- copied from it (and their user notes) stay attached instead of a second hearing appearing on that date.
alter table public.court_hearings drop constraint court_hearings_cnr_hearing_date_purpose_key,
  add constraint court_hearings_cnr_hearing_date_key unique (cnr, hearing_date);

-- Any day but Sunday that the court's verified calendar doesn't close. Holidays count only once VERIFIED: none are
-- invented (hard rule 2).
create or replace function public.is_court_day(court uuid, d date) returns boolean
language sql stable as $$
  select extract(isodow from d) <> 7 and not exists (
    select 1 from public.court_holidays h where h.court_id = court and h.date = d and h.status = 'VERIFIED'
  )
$$;
