-- Phase 1 court diary (spec §9.2–9.3, §17 P1): reference data, shared court data, org-scoped practice data,
-- notifications, provider costs and feedback.
-- Write paths (ADR 0003): a device upload may change only the columns §9.3 lists (`device_columns` triggers);
-- the API (`via_api()`) and workers (service_role) write the rest. User content is soft-deleted (`deleted_at`),
-- so devices get no DELETE except on link and per-user preference rows.

-- ---------------------------------------------------------------- helpers

-- Workers connect as service_role; postgres runs migrations, seeds and tests.
create or replace function public.is_worker() returns boolean
language sql stable as $$
  select current_user in ('service_role', 'postgres', 'supabase_admin')
$$;

create or replace function public.changed_columns(o jsonb, n jsonb) returns text[]
language sql immutable as $$
  select coalesce(array_agg(k), '{}') from jsonb_object_keys(n) k where n -> k is distinct from o -> k
$$;

-- BEFORE UPDATE; TG_ARGV = the only columns a device upload may change.
create or replace function public.device_columns() returns trigger
language plpgsql as $$
declare bad text[];
begin
  if not public.is_worker() and not public.via_api() then
    select array_agg(c) into bad
    from unnest(public.changed_columns(to_jsonb(old), to_jsonb(new))) c
    where c <> 'updated_at' and c <> all (tg_argv);
    if bad is not null then
      raise exception '%.% cannot change from a device', tg_table_name, bad using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

-- BEFORE UPDATE; TG_ARGV = columns only workers may change.
create or replace function public.guard_columns() returns trigger
language plpgsql as $$
declare bad text[];
begin
  if not public.is_worker() then
    select array_agg(c) into bad
    from unnest(public.changed_columns(to_jsonb(old), to_jsonb(new))) c
    where c = any (tg_argv);
    if bad is not null then
      raise exception '%.% is read-only', tg_table_name, bad using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------- reference data (synced to every device)

create table public.courts (
  id uuid primary key default gen_random_uuid(),
  level text not null check (level in ('SC', 'HC', 'DC', 'TRIBUNAL')),
  name text not null,
  name_hi text not null,                  -- court names are data, so both languages live here (hard rule 5)
  short_name text not null,
  short_name_hi text not null,
  state text,                             -- null for the Supreme Court
  district text,
  bench text,
  provider_codes jsonb not null default '{}',  -- per provider; filled from spike 11e
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.court_holidays (
  id uuid primary key default gen_random_uuid(),
  court_id uuid not null references public.courts (id) on delete cascade,
  date date not null,
  kind text not null check (kind in ('holiday', 'vacation', 'closed')),
  note text,
  source text,
  status text not null default 'DRAFT' check (status in ('DRAFT', 'VERIFIED')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (court_id, date)
);

-- ---------------------------------------------------------------- public court data (workers only; never synced)

create table public.court_cases (
  id uuid primary key default gen_random_uuid(),
  cnr text not null unique,
  court_id uuid references public.courts (id),
  case_type text,
  case_number text,
  case_year int,
  filing_no text,
  registration_no text,
  title text,
  petitioners jsonb not null default '[]',
  respondents jsonb not null default '[]',
  advocates jsonb not null default '[]',
  judge text,
  court_no text,
  stage text,
  status text not null default 'unknown' check (status in ('pending', 'disposed', 'transferred', 'unknown')),
  next_hearing_date date,
  last_hearing_date date,
  decision_date date,
  acts jsonb not null default '[]',
  provider text,
  fetched_at timestamptz,
  content_hash text,
  raw jsonb,                              -- provider payload, for debugging only (§11.2)
  search_key text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.court_hearings (
  id uuid primary key default gen_random_uuid(),
  cnr text not null,
  hearing_date date not null,
  purpose text,
  judge text,
  business text,
  next_date date,
  source text,
  created_at timestamptz not null default now(),
  unique nulls not distinct (cnr, hearing_date, purpose)
);

create table public.court_orders (
  id uuid primary key default gen_random_uuid(),
  cnr text not null,
  order_date date,
  order_type text not null default 'order' check (order_type in ('order', 'judgment', 'interim')),
  judge text,
  provider_ref text not null,
  storage_path text,
  sha256 text,
  pages int,
  text_status text not null default 'none' check (text_status in ('none', 'text', 'ocr_pending', 'ocr_done', 'failed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (cnr, provider_ref)
);

create table public.cause_list_entries (
  id uuid primary key default gen_random_uuid(),
  court_id uuid references public.courts (id),
  list_date date not null,
  cnr text,
  case_ref text,
  court_no text,
  item_no text,                           -- text: supplementary lists use items like "S-12"
  bench text,
  list_type text,
  source text,
  fetched_at timestamptz not null default now()
);
create index cause_list_entries_cnr_idx on public.cause_list_entries (cnr, list_date);

-- ---------------------------------------------------------------- matters and practice data (org-scoped)

create table public.matters (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  cnr text,
  court_id uuid references public.courts (id),
  case_type text,
  case_number text,
  case_year int,
  title text,
  our_side text,
  file_no text,
  status text not null default 'active' check (status in ('active', 'archived')),
  tracking text not null default 'auto' check (tracking in ('auto', 'manual', 'off')),
  assigned_to uuid,
  source text not null check (source in ('import', 'cnr', 'search', 'manual', 'found')),
  tags text[] not null default '{}',
  -- court fields, copied by workers during fan-out (§11.6)
  court_status text check (court_status in ('pending', 'disposed', 'transferred', 'unknown')),
  next_hearing_date date,
  stage text,
  judge text,
  court_no text,
  last_order_date date,
  court_fetched_at timestamptz,
  deleted_at timestamptz,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, cnr),
  unique (id, org_id),                    -- target of the (matter_id, org_id) keys below: no cross-org links
  foreign key (org_id, assigned_to) references public.memberships (org_id, user_id)
);
create index matters_cnr_idx on public.matters (cnr) where deleted_at is null;

create table public.clients (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  name text not null,
  search_key text,
  phone text,
  whatsapp_opt_in boolean not null default false,
  whatsapp_opt_in_at timestamptz,
  email text,
  address text,
  language text check (language in ('hi', 'en')),
  notes text,
  deleted_at timestamptz,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, org_id)
);
create index clients_org_idx on public.clients (org_id);

create table public.matter_clients (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  matter_id uuid not null,
  client_id uuid not null,
  role text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (matter_id, client_id),
  foreign key (matter_id, org_id) references public.matters (id, org_id) on delete cascade,
  foreign key (client_id, org_id) references public.clients (id, org_id) on delete cascade
);

create table public.hearings (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  matter_id uuid not null,
  court_hearing_id uuid references public.court_hearings (id) on delete set null,  -- fan-out upsert key
  date date not null,
  court_no text,
  item_no text,
  purpose text,
  outcome text,
  next_date date,
  source text not null default 'manual' check (source in ('court', 'manual', 'voice')),
  -- user fields: editable on every row
  user_next_date date,
  user_purpose text,
  user_outcome text,
  user_note text,
  confirmed boolean not null default false,
  deleted_at timestamptz,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (matter_id, court_hearing_id),
  foreign key (matter_id, org_id) references public.matters (id, org_id) on delete cascade
);
create index hearings_matter_idx on public.hearings (matter_id);

create table public.documents (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  matter_id uuid,
  title text not null,
  kind text not null default 'other'
    check (kind in ('pleading', 'order', 'evidence', 'annexure', 'correspondence', 'other')),
  storage_path text,
  mime text,
  size_bytes bigint check (size_bytes <= 52428800),  -- 50 MB per file (§4.3)
  pages int,
  sha256 text,
  upload_status text not null default 'pending' check (upload_status in ('pending', 'ready', 'quarantined')),
  text_status text not null default 'none' check (text_status in ('none', 'text', 'ocr_pending', 'ocr_done', 'failed')),
  language text,
  legacy_font_detected boolean not null default false,
  uploaded_by uuid default auth.uid(),
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (org_id) references public.organizations (id) on delete cascade,
  foreign key (matter_id, org_id) references public.matters (id, org_id) on delete cascade
);
create index documents_matter_idx on public.documents (matter_id);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  matter_id uuid not null,
  court_order_id uuid references public.court_orders (id) on delete set null,
  document_id uuid references public.documents (id) on delete set null,
  order_date date,
  title text,
  summary_en jsonb,                       -- copied from public_summaries by workers (P2)
  summary_hi jsonb,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (matter_id, court_order_id),
  foreign key (matter_id, org_id) references public.matters (id, org_id) on delete cascade
);
create index orders_matter_idx on public.orders (matter_id);

create table public.order_reads (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  order_id uuid not null references public.orders (id) on delete cascade,
  read_at timestamptz not null default now(),
  unique (user_id, order_id)
);

create table public.org_cause_list_entries (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  matter_id uuid not null,
  cause_list_entry_id uuid references public.cause_list_entries (id) on delete set null,
  list_date date not null,
  court_id uuid references public.courts (id),
  court_no text,
  item_no text,
  bench text,
  list_type text,
  is_current boolean not null default true,  -- today and tomorrow; a scheduled job clears it
  created_at timestamptz not null default now(),
  unique (matter_id, cause_list_entry_id),
  foreign key (matter_id, org_id) references public.matters (id, org_id) on delete cascade
);
create index org_cause_list_entries_current_idx on public.org_cause_list_entries (org_id) where is_current;

create table public.board_entries (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  board_date date not null,
  matter_id uuid not null,
  court_id uuid references public.courts (id),
  court_no text,
  item_no text,
  expected_slot time,                     -- estimated start (IST) from the item number; heuristic in its ADR
  clash_group int,
  assignee_id uuid,
  proxy_arranged boolean not null default false,  -- "Mark proxy arranged" (§4.2)
  is_current boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (matter_id, board_date),
  foreign key (matter_id, org_id) references public.matters (id, org_id) on delete cascade,
  foreign key (org_id, assignee_id) references public.memberships (org_id, user_id)
);
create index board_entries_current_idx on public.board_entries (org_id) where is_current;

create table public.found_cases (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,  -- who it was found for
  job_id uuid references public.jobs (id) on delete set null,
  cnr text not null,
  court_id uuid references public.courts (id),
  case_type text,
  case_number text,
  case_year int,
  court_no text,
  title text,
  next_date date,
  case_status text check (case_status in ('pending', 'disposed', 'transferred', 'unknown')),
  confidence text not null check (confidence in ('high', 'low')),
  match_reason text not null check (match_reason in
    ('exact_name_practice_court', 'enrolment', 'partial_name', 'outside_practice_courts')),
  source text not null check (source in ('onboarding', 'auto_match', 'advocate_watch')),
  decision text not null default 'pending' check (decision in ('pending', 'added', 'skipped', 'not_mine')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, cnr)                    -- a `not_mine` row is the exclusion auto-match respects
);

create table public.notes (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  matter_id uuid not null,
  author_id uuid not null default auth.uid() references public.profiles (id),
  body text not null,
  visibility text not null default 'team' check (visibility in ('team', 'private')),
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (matter_id, org_id) references public.matters (id, org_id) on delete cascade
);
create index notes_matter_idx on public.notes (matter_id);

create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  matter_id uuid,
  title text not null,
  due_at timestamptz,
  assignee_id uuid,
  status text not null default 'open' check (status in ('proposed', 'open', 'done', 'dismissed')),
  source text not null default 'manual' check (source in ('manual', 'order', 'voice', 'ai')),
  source_ref text,
  dedupe_key text,
  deleted_at timestamptz,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, dedupe_key),            -- stops duplicate proposals (§9.3)
  foreign key (matter_id, org_id) references public.matters (id, org_id) on delete cascade,
  foreign key (org_id, assignee_id) references public.memberships (org_id, user_id)
);
create index tasks_org_idx on public.tasks (org_id);

create table public.deadlines (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  matter_id uuid,
  kind text not null check (kind in ('limitation', 'compliance', 'filing', 'other')),
  due_date date not null,
  basis jsonb,
  rule_id text,
  source_order_id uuid references public.orders (id) on delete set null,
  status text not null default 'active' check (status in ('proposed', 'active', 'done', 'dismissed')),
  reminder_offsets int[] not null default '{3,1,0}',  -- days before; §13.1 deadline_due
  dedupe_key text,
  deleted_at timestamptz,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, dedupe_key),
  foreign key (matter_id, org_id) references public.matters (id, org_id) on delete cascade
);
create index deadlines_org_idx on public.deadlines (org_id);

create table public.document_offline_prefs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  document_id uuid not null references public.documents (id) on delete cascade,
  keep_offline boolean not null default true,
  unique (user_id, document_id)
);

-- ---------------------------------------------------------------- notifications (spec §13)

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  org_id uuid references public.organizations (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null check (kind in ('tomorrow_board', 'today_morning', 'listed_unexpectedly', 'new_order',
    'next_date_set', 'status_changed', 'deadline_due', 'task_assigned', 'item_tracker', 'client_update_ready',
    'sync_issue', 'new_device_signin')),
  title text,
  body text,
  data jsonb not null default '{}',       -- deep link, collapse key
  read_at timestamptz,
  in_window boolean not null default true,  -- last 90 days; a nightly job clears it
  created_at timestamptz not null default now()
);
create index notifications_user_idx on public.notifications (user_id) where in_window;

create table public.notification_deliveries (
  id uuid primary key default gen_random_uuid(),
  notification_id uuid not null references public.notifications (id) on delete cascade,
  channel text not null check (channel in ('push', 'whatsapp', 'email', 'windows')),
  status text not null,
  provider_msg_id text,
  cost_inr numeric(12, 4),
  error text,
  sent_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.notification_prefs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null,
  channels text[] not null default '{push}',
  quiet_start time not null default '22:00',
  quiet_end time not null default '07:00',
  include_titles boolean not null default false,  -- party names in push only when the user opts in (§13.2)
  updated_at timestamptz not null default now(),
  unique (user_id, kind)
);

-- ---------------------------------------------------------------- costs and feedback

create table public.provider_calls (
  id uuid primary key default gen_random_uuid(),
  provider text not null,
  operation text not null,
  cnr text,
  org_id uuid references public.organizations (id) on delete set null,  -- null: shared fetch
  cost_inr numeric(12, 4) not null default 0,
  status text not null,
  http_status int,
  latency_ms int,
  created_at timestamptz not null default now()
);
create index provider_calls_created_idx on public.provider_calls (created_at);

create table public.usage_ledger (
  id uuid primary key default gen_random_uuid(),
  org_id uuid references public.organizations (id) on delete cascade,  -- null: platform row
  kind text not null check (kind in ('tracked_case_day', 'ai_credit', 'whatsapp', 'ocr_page', 'stt_second', 'provider_call')),
  quantity numeric not null default 1,
  cost_inr numeric(12, 4) not null default 0,
  ref_type text,
  ref_id uuid,
  created_at timestamptz not null default now()
);
create index usage_ledger_org_idx on public.usage_ledger (org_id, created_at);

create table public.feedback (
  id uuid primary key default gen_random_uuid(),
  org_id uuid references public.organizations (id) on delete set null,
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  screen text,
  note text not null,
  screenshot_path text,                   -- only with the user's consent
  app_version text,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------- triggers (spec §9.3)

-- Court rows belong to workers: members change only the user fields. Members add manual rows on manual-tracked
-- matters and may edit those fully; voice rows arrive through the API (P2).
create or replace function public.hearings_guard() returns trigger
language plpgsql as $$
declare
  changed text[];
begin
  if public.is_worker() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.source = 'court' or (new.source = 'voice' and not public.via_api()) then
      raise exception 'hearings: % rows come from the server', new.source using errcode = '42501';
    end if;
    if new.source = 'manual'
       and not exists (select 1 from public.matters m where m.id = new.matter_id and m.tracking = 'manual') then
      raise exception 'hearings: manual rows only on manual-tracked matters' using errcode = '42501';
    end if;
    return new;
  end if;
  changed := public.changed_columns(to_jsonb(old), to_jsonb(new));
  if changed && array['id', 'org_id', 'matter_id', 'source', 'court_hearing_id', 'created_by', 'created_at']
     or (old.source = 'court' and not changed <@ array['user_next_date', 'user_purpose', 'user_outcome', 'user_note',
                                                      'confirmed', 'updated_at']) then
    raise exception 'hearings: % cannot change here', changed using errcode = '42501';
  end if;
  return new;
end $$;

-- Beta allowance on auto-tracked cases (§9.3); plan limits replace it in P3. No allowance row = no limit.
create or replace function public.matters_allowance() returns trigger
language plpgsql as $$
declare
  allowance int := (select (value #>> '{}')::int from public.app_config where key = 'beta_tracked_case_allowance');
begin
  if allowance is not null and new.tracking = 'auto' and new.deleted_at is null
     and (tg_op = 'INSERT' or old.tracking <> 'auto' or old.deleted_at is not null)
     and (select count(*) from public.matters m
          where m.org_id = new.org_id and m.tracking = 'auto' and m.deleted_at is null and m.id <> new.id) >= allowance then
    raise exception 'TRACKED_CASE_LIMIT' using errcode = 'P0001', detail = allowance::text;
  end if;
  return new;
end $$;

create trigger matters_allowance before insert or update of tracking, deleted_at on public.matters
  for each row execute function public.matters_allowance();
create trigger matters_device_columns before update on public.matters
  for each row execute function public.device_columns('assigned_to', 'tags', 'file_no', 'our_side', 'status');
create trigger matters_guard before update on public.matters
  for each row execute function public.guard_columns('org_id', 'cnr', 'source', 'court_status', 'next_hearing_date',
    'stage', 'judge', 'court_no', 'last_order_date', 'court_fetched_at', 'created_by', 'created_at');

create trigger hearings_guard before insert or update on public.hearings
  for each row execute function public.hearings_guard();

create trigger documents_device_columns before update on public.documents
  for each row execute function public.device_columns('title', 'kind', 'matter_id', 'deleted_at');
create trigger board_entries_device_columns before update on public.board_entries
  for each row execute function public.device_columns('assignee_id', 'proxy_arranged');
create trigger notifications_device_columns before update on public.notifications
  for each row execute function public.device_columns('read_at');

create trigger notes_guard before update on public.notes
  for each row execute function public.guard_columns('org_id', 'matter_id', 'author_id', 'created_at');
create trigger clients_guard before update on public.clients
  for each row execute function public.guard_columns('org_id', 'created_by', 'created_at');
create trigger matter_clients_guard before update on public.matter_clients
  for each row execute function public.guard_columns('org_id', 'matter_id', 'client_id');
create trigger tasks_guard before update on public.tasks
  for each row execute function public.guard_columns('org_id', 'created_by', 'created_at');
create trigger deadlines_guard before update on public.deadlines
  for each row execute function public.guard_columns('org_id', 'created_by', 'created_at');
create trigger documents_guard before update on public.documents
  for each row execute function public.guard_columns('org_id', 'uploaded_by', 'created_at');
create trigger found_cases_guard before update on public.found_cases
  for each row execute function public.guard_columns('org_id', 'user_id', 'cnr');
create trigger order_reads_guard before update on public.order_reads
  for each row execute function public.guard_columns('org_id', 'order_id');
create trigger document_offline_prefs_guard before update on public.document_offline_prefs
  for each row execute function public.guard_columns('org_id', 'document_id');

create trigger set_updated_at before update on public.courts for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.court_holidays for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.court_cases for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.court_orders for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.matters for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.clients for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.matter_clients for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.hearings for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.documents for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.orders for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.board_entries for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.found_cases for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.notes for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.tasks for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.deadlines for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.notification_prefs for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------- row-level security (spec §9.3)

-- Shared court rows: readable by users whose organisation tracks that CNR (for API-as-user reads).
create or replace function public.tracks_cnr(target_cnr text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.matters m
    join public.memberships ms on ms.org_id = m.org_id
    where m.cnr = target_cnr and m.deleted_at is null and ms.user_id = auth.uid() and ms.status = 'active'
  )
$$;

alter table public.courts enable row level security;
alter table public.court_holidays enable row level security;
alter table public.court_cases enable row level security;
alter table public.court_hearings enable row level security;
alter table public.court_orders enable row level security;
alter table public.cause_list_entries enable row level security;
alter table public.matters enable row level security;
alter table public.clients enable row level security;
alter table public.matter_clients enable row level security;
alter table public.hearings enable row level security;
alter table public.documents enable row level security;
alter table public.orders enable row level security;
alter table public.order_reads enable row level security;
alter table public.org_cause_list_entries enable row level security;
alter table public.board_entries enable row level security;
alter table public.found_cases enable row level security;
alter table public.notes enable row level security;
alter table public.tasks enable row level security;
alter table public.deadlines enable row level security;
alter table public.document_offline_prefs enable row level security;
alter table public.notifications enable row level security;
alter table public.notification_deliveries enable row level security;
alter table public.notification_prefs enable row level security;
alter table public.provider_calls enable row level security;
alter table public.usage_ledger enable row level security;
alter table public.feedback enable row level security;

create policy courts_select on public.courts for select to authenticated using (true);
create policy court_holidays_select on public.court_holidays for select to authenticated using (true);

create policy court_cases_select on public.court_cases for select to authenticated using (tracks_cnr(cnr));
create policy court_hearings_select on public.court_hearings for select to authenticated using (tracks_cnr(cnr));
create policy court_orders_select on public.court_orders for select to authenticated using (tracks_cnr(cnr));
create policy cause_list_entries_select on public.cause_list_entries for select to authenticated using (tracks_cnr(cnr));

-- matters: created through the API (plan-limit and cost checks); devices edit the §9.3 columns; delete is soft (API)
create policy matters_select on public.matters for select to authenticated using (is_member(org_id));
create policy matters_insert on public.matters for insert to authenticated with check (is_member(org_id) and via_api());
create policy matters_update on public.matters for update to authenticated
  using (is_member(org_id)) with check (is_member(org_id));

create policy hearings_select on public.hearings for select to authenticated using (is_member(org_id));
create policy hearings_insert on public.hearings for insert to authenticated with check (is_member(org_id));
create policy hearings_update on public.hearings for update to authenticated
  using (is_member(org_id)) with check (is_member(org_id));

create policy orders_select on public.orders for select to authenticated using (is_member(org_id));

-- per-user state
create policy order_reads_select on public.order_reads for select to authenticated using (user_id = auth.uid());
create policy order_reads_insert on public.order_reads for insert to authenticated
  with check (user_id = auth.uid() and is_member(org_id));
create policy order_reads_update on public.order_reads for update to authenticated using (user_id = auth.uid());
create policy order_reads_delete on public.order_reads for delete to authenticated using (user_id = auth.uid());

create policy document_offline_prefs_select on public.document_offline_prefs for select to authenticated
  using (user_id = auth.uid());
create policy document_offline_prefs_insert on public.document_offline_prefs for insert to authenticated
  with check (user_id = auth.uid() and is_member(org_id));
create policy document_offline_prefs_update on public.document_offline_prefs for update to authenticated
  using (user_id = auth.uid());
create policy document_offline_prefs_delete on public.document_offline_prefs for delete to authenticated
  using (user_id = auth.uid());

create policy notification_prefs_select on public.notification_prefs for select to authenticated using (user_id = auth.uid());
create policy notification_prefs_insert on public.notification_prefs for insert to authenticated
  with check (user_id = auth.uid());
create policy notification_prefs_update on public.notification_prefs for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy notification_prefs_delete on public.notification_prefs for delete to authenticated
  using (user_id = auth.uid());

-- worker-built rows
create policy org_cause_list_entries_select on public.org_cause_list_entries for select to authenticated
  using (is_member(org_id));
create policy board_entries_select on public.board_entries for select to authenticated using (is_member(org_id));
create policy board_entries_update on public.board_entries for update to authenticated
  using (has_role(org_id, array['owner', 'advocate'])) with check (has_role(org_id, array['owner', 'advocate']));

create policy found_cases_select on public.found_cases for select to authenticated using (is_member(org_id));
create policy found_cases_update on public.found_cases for update to authenticated
  using (is_member(org_id) and via_api());

-- notes: team notes for every member; private notes for their author only (clerks included)
create policy notes_select on public.notes for select to authenticated
  using (is_member(org_id) and (visibility = 'team' or author_id = auth.uid()));
create policy notes_insert on public.notes for insert to authenticated
  with check (is_member(org_id) and author_id = auth.uid());
create policy notes_update on public.notes for update to authenticated
  using (is_member(org_id) and (visibility = 'team' or author_id = auth.uid()))
  with check (is_member(org_id) and (visibility = 'team' or author_id = auth.uid()));

-- device-writable org data
create policy clients_select on public.clients for select to authenticated using (is_member(org_id));
create policy clients_insert on public.clients for insert to authenticated with check (is_member(org_id));
create policy clients_update on public.clients for update to authenticated
  using (is_member(org_id)) with check (is_member(org_id));

create policy matter_clients_select on public.matter_clients for select to authenticated using (is_member(org_id));
create policy matter_clients_insert on public.matter_clients for insert to authenticated with check (is_member(org_id));
create policy matter_clients_update on public.matter_clients for update to authenticated
  using (is_member(org_id)) with check (is_member(org_id));
create policy matter_clients_delete on public.matter_clients for delete to authenticated using (is_member(org_id));

create policy tasks_select on public.tasks for select to authenticated using (is_member(org_id));
create policy tasks_insert on public.tasks for insert to authenticated with check (is_member(org_id));
create policy tasks_update on public.tasks for update to authenticated
  using (is_member(org_id)) with check (is_member(org_id));

create policy deadlines_select on public.deadlines for select to authenticated using (is_member(org_id));
create policy deadlines_insert on public.deadlines for insert to authenticated with check (is_member(org_id));
create policy deadlines_update on public.deadlines for update to authenticated
  using (is_member(org_id)) with check (is_member(org_id));

-- documents: created by the API upload flow; devices rename, re-file or soft-delete
create policy documents_select on public.documents for select to authenticated using (is_member(org_id));
create policy documents_insert on public.documents for insert to authenticated with check (is_member(org_id) and via_api());
create policy documents_update on public.documents for update to authenticated
  using (is_member(org_id)) with check (is_member(org_id));

-- notifications: own rows; devices only mark them read
create policy notifications_select on public.notifications for select to authenticated using (user_id = auth.uid());
create policy notifications_update on public.notifications for update to authenticated using (user_id = auth.uid());

-- costs: organisation owner reads; service role writes. notification_deliveries: service role only (no policies)
create policy provider_calls_select on public.provider_calls for select to authenticated
  using (org_id is not null and has_role(org_id, array['owner']));
create policy usage_ledger_select on public.usage_ledger for select to authenticated
  using (org_id is not null and has_role(org_id, array['owner']));

create policy feedback_select on public.feedback for select to authenticated using (user_id = auth.uid());
create policy feedback_insert on public.feedback for insert to authenticated
  with check (user_id = auth.uid() and (org_id is null or is_member(org_id)));

revoke all on all tables in schema public from anon;

-- ---------------------------------------------------------------- reference rows (every environment)

-- Courts named in spec §4.1 / §17 P1. Provider codes arrive with spike 11e; the founder checks this list (§17 P1).
insert into public.courts (id, level, name, name_hi, short_name, short_name_hi, state, district, bench) values
  ('c0000000-0000-0000-0000-000000000001', 'SC', 'Supreme Court of India', 'भारत का सर्वोच्च न्यायालय',
   'Supreme Court', 'सुप्रीम कोर्ट', null, null, null),
  ('c0000000-0000-0000-0000-000000000002', 'HC', 'High Court of Madhya Pradesh, Jabalpur',
   'मध्यप्रदेश उच्च न्यायालय, जबलपुर', 'MPHC Jabalpur', 'MPHC जबलपुर', 'MP', 'Jabalpur', 'Principal Seat'),
  ('c0000000-0000-0000-0000-000000000003', 'HC', 'High Court of Madhya Pradesh, Bench at Indore',
   'मध्यप्रदेश उच्च न्यायालय, खंडपीठ इंदौर', 'MPHC Indore', 'MPHC इंदौर', 'MP', 'Indore', 'Indore'),
  ('c0000000-0000-0000-0000-000000000004', 'HC', 'High Court of Madhya Pradesh, Bench at Gwalior',
   'मध्यप्रदेश उच्च न्यायालय, खंडपीठ ग्वालियर', 'MPHC Gwalior', 'MPHC ग्वालियर', 'MP', 'Gwalior', 'Gwalior'),
  ('c0000000-0000-0000-0000-000000000005', 'DC', 'District and Sessions Court, Indore', 'जिला एवं सत्र न्यायालय, इंदौर',
   'District Court Indore', 'जिला कोर्ट इंदौर', 'MP', 'Indore', null)
on conflict (id) do nothing;

insert into public.app_config (key, value) values ('beta_tracked_case_allowance', '100') on conflict (key) do nothing;
