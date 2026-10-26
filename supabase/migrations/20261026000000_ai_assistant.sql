-- Phase 2 daily AI assistant (spec §9.2–9.3, §12, §17 P2): case-file text for search and Ask, voice notes, AI runs
-- and answers, the shared summary cache, client messages, the team-shared item tracker and calendar feeds.
-- Same write paths as P1 (ADR 0003): a device changes only what §9.3 lists, the API (`via_api()`) and workers
-- (service_role) write the rest. Prompt and answer text lives only in `ai_answers`, which users can delete (§15.6).

create extension if not exists vector with schema extensions;
create extension if not exists pg_trgm with schema extensions;

-- Chunks carry their document's org, so a chunk can never point at another organisation's file.
alter table public.documents add constraint documents_id_org_key unique (id, org_id);

-- A court order's text is shared like the order itself: readable by users whose organisation tracks its CNR.
create or replace function public.tracks_court_order(order_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.court_orders o where o.id = order_id and public.tracks_cnr(o.cnr))
$$;

-- ---------------------------------------------------------------- case-file text (server only, never synced)

-- Page text from the text layer or OCR, in ~400-token chunks (§12.4). An uploaded document's chunks belong to its
-- organisation; a court order's are shared, one copy for every organisation tracking the case.
create table public.document_chunks (
  id uuid primary key default gen_random_uuid(),
  org_id uuid,
  document_id uuid,
  court_order_id uuid references public.court_orders (id) on delete cascade,
  page_no int not null check (page_no >= 1),
  chunk_no int not null check (chunk_no >= 0),
  paras text[] not null default '{}',     -- paragraph numbers detected in the chunk, e.g. {12, 12.1}
  text text not null,
  embedding extensions.vector(1024),      -- BGE-M3 dense; null until the embedder has run
  tsv tsvector generated always as (to_tsvector('simple', text)) stored,  -- no Hindi stemmer: words as written
  created_at timestamptz not null default now(),
  check ((document_id is not null and org_id is not null and court_order_id is null)
      or (court_order_id is not null and org_id is null and document_id is null)),
  foreign key (org_id) references public.organizations (id) on delete cascade,
  foreign key (document_id, org_id) references public.documents (id, org_id) on delete cascade
);
create unique index document_chunks_document_key on public.document_chunks (document_id, page_no, chunk_no)
  where document_id is not null;
create unique index document_chunks_court_order_key on public.document_chunks (court_order_id, page_no, chunk_no)
  where court_order_id is not null;
create index document_chunks_org_idx on public.document_chunks (org_id);
create index document_chunks_embedding_idx on public.document_chunks
  using hnsw (embedding extensions.vector_cosine_ops);
create index document_chunks_tsv_idx on public.document_chunks using gin (tsv);
create index document_chunks_trgm_idx on public.document_chunks using gin (text extensions.gin_trgm_ops);

-- ---------------------------------------------------------------- voice notes (author only, synced to the author)

create table public.voice_notes (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  matter_id uuid,
  created_by uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  audio_path text,                        -- set by the upload-url call
  duration_ms int check (duration_ms between 0 and 120000),  -- at most 2 minutes (§4.4)
  transcript text,
  language text,
  parsed jsonb,                           -- voice_parse output; saved as fact only on confirm
  status text not null default 'queued' check (status in ('queued', 'transcribed', 'parsed', 'confirmed', 'failed')),
  error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (matter_id, org_id) references public.matters (id, org_id) on delete cascade
);
create index voice_notes_author_idx on public.voice_notes (created_by);

-- ---------------------------------------------------------------- AI runs, answers and the shared summary cache

-- One row per model call, for cost and quality: never the prompt or the answer (§9.2).
create table public.ai_runs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid references public.organizations (id) on delete cascade,  -- null: a shared summary (platform cost)
  user_id uuid references public.profiles (id) on delete set null,
  matter_id uuid references public.matters (id) on delete set null,
  kind text not null,                     -- the task in config/ai_models.yaml
  prompt_version text,
  model_tier text not null,
  model_id text not null,
  input_tokens int not null default 0,
  output_tokens int not null default 0,   -- thinking included (§12.2)
  cost_inr numeric(12, 4) not null default 0,
  latency_ms int,
  status text not null check (status in ('ok', 'failed', 'invalid_output', 'unavailable')),
  error_code text,
  created_at timestamptz not null default now()
);
create index ai_runs_org_idx on public.ai_runs (org_id, created_at);

-- What users see again: Ask history, briefs, summaries of private uploads (one per document and language).
create table public.ai_answers (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  run_id uuid references public.ai_runs (id) on delete set null,
  matter_id uuid,
  document_id uuid,
  kind text not null check (kind in ('ask', 'brief', 'upload_summary')),
  language text check (language in ('hi', 'en')),
  question text,
  answer jsonb not null,
  sources jsonb not null default '[]',
  created_by uuid default auth.uid() references public.profiles (id) on delete set null,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (kind <> 'upload_summary' or (document_id is not null and language is not null)),
  foreign key (matter_id, org_id) references public.matters (id, org_id) on delete cascade,
  foreign key (document_id, org_id) references public.documents (id, org_id) on delete cascade
);
create index ai_answers_matter_idx on public.ai_answers (matter_id) where deleted_at is null;
create unique index ai_answers_upload_summary_key on public.ai_answers (document_id, language)
  where kind = 'upload_summary' and deleted_at is null;

-- Summaries of public orders and judgments, generated once per document and language for everyone (§4.4 F07).
create table public.public_summaries (
  id uuid primary key default gen_random_uuid(),
  doc_kind text not null check (doc_kind in ('court_order', 'judgment')),
  doc_ref text not null,                  -- court_orders.id; the judgment's id from P5
  language text not null check (language in ('hi', 'en')),
  summary jsonb not null,
  model_id text not null,
  prompt_version text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (doc_kind, doc_ref, language),
  -- the read policy casts a court order's ref to uuid: a malformed one would break every read
  check (doc_kind <> 'court_order'
         or doc_ref ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
);

-- ---------------------------------------------------------------- client messages (F32)

-- Nothing reaches a client without an owner's or advocate's approval: the checks below hold for every writer.
create table public.client_messages (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  client_id uuid not null,
  matter_id uuid,
  channel text not null default 'whatsapp_share' check (channel in ('whatsapp_api', 'whatsapp_share', 'email')),
  language text check (language in ('hi', 'en')),
  body text not null check (length(body) between 1 and 4000),
  recipient text,                         -- the client's phone or email, copied when the message is approved
  template_name text,
  status text not null default 'draft' check (status in ('draft', 'pending_approval', 'approved', 'sent', 'failed')),
  run_id uuid references public.ai_runs (id) on delete set null,  -- the AI draft it started from
  provider_msg_id text,
  error_code text,
  created_by uuid default auth.uid() references public.profiles (id) on delete set null,
  approved_by uuid references public.profiles (id) on delete set null,
  approved_at timestamptz,
  sent_at timestamptz,
  cost_inr numeric(12, 4),
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (status in ('draft', 'pending_approval') or approved_at is not null),
  check (status <> 'sent' or sent_at is not null),
  foreign key (client_id, org_id) references public.clients (id, org_id) on delete cascade,
  foreign key (matter_id, org_id) references public.matters (id, org_id) on delete cascade
);
create index client_messages_client_idx on public.client_messages (client_id);

-- ---------------------------------------------------------------- live item tracker (F21)

-- "Court 12 now at item 18", shared with the chamber. No scraping: an official source writes `official` rows only
-- once one is permitted (§11.10).
create table public.display_board_snapshots (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  court_id uuid not null references public.courts (id),
  court_no text not null,
  current_item text not null,             -- text, like cause-list items ("S-12")
  captured_at timestamptz not null default now(),
  captured_by uuid default auth.uid() references public.profiles (id) on delete set null,
  source text not null default 'team' check (source in ('team', 'official')),
  is_live boolean not null default true,  -- a job clears it after 2 h; the app fades it after 20 min (§4.4)
  created_at timestamptz not null default now()
);
create index display_board_snapshots_live_idx on public.display_board_snapshots (org_id) where is_live;

-- ---------------------------------------------------------------- calendar feeds (F03 ICS)

-- One secret feed URL per member; only its hash is kept. Removing the member removes the feed (trigger below).
create table public.calendar_feeds (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  user_id uuid not null,
  token_hash text not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, user_id),
  foreign key (org_id, user_id) references public.memberships (org_id, user_id) on delete cascade
);

-- ---------------------------------------------------------------- triggers

-- A device records a note and may file it under a case; transcripts, parses and the confirm come from the server.
create or replace function public.voice_notes_insert_guard() returns trigger
language plpgsql as $$
begin
  if not public.is_worker() and not public.via_api()
     and (new.status <> 'queued' or new.audio_path is not null or new.transcript is not null
          or new.language is not null or new.parsed is not null or new.error_code is not null) then
    raise exception 'voice_notes: only a queued note can come from a device' using errcode = '42501';
  end if;
  return new;
end $$;

create trigger voice_notes_insert_guard before insert on public.voice_notes
  for each row execute function public.voice_notes_insert_guard();
create trigger voice_notes_device_columns before update on public.voice_notes
  for each row execute function public.device_columns('matter_id');
create trigger voice_notes_guard before update on public.voice_notes
  for each row execute function public.guard_columns('org_id', 'created_by', 'created_at');

-- What was approved is what is sent: the approver is an active owner or advocate, the API approves only as the
-- caller, and the destination is copied from the client at that moment, so a later edit to the client can't redirect
-- it. Once approved, the text, channel and destination are fixed. Drafts start unapproved.
create or replace function public.client_messages_guard() returns trigger
language plpgsql as $$
declare
  changed text[];
begin
  if tg_op = 'INSERT' then
    if new.status not in ('draft', 'pending_approval') or new.approved_by is not null or new.approved_at is not null
       or new.recipient is not null or new.sent_at is not null then
      raise exception 'client_messages: a message starts as a draft' using errcode = '42501';
    end if;
    return new;
  end if;
  changed := public.changed_columns(to_jsonb(old), to_jsonb(new));
  -- A deleted author, approver or AI run nulls its key (on delete set null, run as the table owner); nothing else moves.
  if public.is_worker() and changed <@ array['created_by', 'approved_by', 'run_id', 'updated_at']
     and (new.created_by is null or new.created_by = old.created_by)
     and (new.approved_by is null or new.approved_by = old.approved_by)
     and (new.run_id is null or new.run_id = old.run_id) then
    return new;
  end if;
  if changed && array['id', 'org_id', 'created_by', 'created_at', 'run_id'] then
    raise exception 'client_messages: these columns cannot change' using errcode = '42501';
  end if;
  if old.approved_at is not null
     and (new.status in ('draft', 'pending_approval')
          or (new.body, new.channel, new.client_id, new.matter_id, new.language, new.template_name, new.recipient,
              new.approved_by, new.approved_at) is distinct from
             (old.body, old.channel, old.client_id, old.matter_id, old.language, old.template_name, old.recipient,
              old.approved_by, old.approved_at)) then
    raise exception 'client_messages: an approved message cannot change' using errcode = '42501';
  end if;
  if old.approved_at is null and new.approved_at is not null then
    if new.approved_by is null
       or (not public.is_worker() and new.approved_by is distinct from auth.uid())
       or not exists (select 1 from public.memberships m
                      where m.org_id = new.org_id and m.user_id = new.approved_by and m.status = 'active'
                        and m.role in ('owner', 'advocate')) then
      raise exception 'client_messages: only an owner or advocate approves' using errcode = '42501';
    end if;
    select case new.channel when 'email' then c.email else c.phone end into new.recipient
    from public.clients c where c.id = new.client_id;
    -- "Share via my WhatsApp" may leave the contact to the advocate's own WhatsApp.
    if new.recipient is null and new.channel <> 'whatsapp_share' then
      raise exception 'client_messages: the client has no % to send to',
        case new.channel when 'email' then 'email' else 'phone' end using errcode = '23514';
    end if;
  end if;
  if new.status = 'sent' and old.status not in ('approved', 'failed', 'sent') then
    raise exception 'client_messages: only an approved message is sent' using errcode = '42501';
  end if;
  return new;
end $$;

create trigger client_messages_guard before insert or update on public.client_messages
  for each row execute function public.client_messages_guard();

-- The app removes a member by status, never by deleting the membership: their feed goes then.
create or replace function public.drop_calendar_feed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  delete from public.calendar_feeds f where f.org_id = new.org_id and f.user_id = new.user_id;
  return null;
end $$;

create trigger memberships_drop_calendar_feed after update of status on public.memberships
  for each row when (new.status <> 'active') execute function public.drop_calendar_feed();

create trigger ai_answers_guard before update on public.ai_answers
  for each row execute function public.guard_columns('org_id', 'run_id', 'matter_id', 'document_id', 'kind',
    'language', 'question', 'answer', 'sources', 'created_by', 'created_at');
create trigger calendar_feeds_guard before update on public.calendar_feeds
  for each row execute function public.guard_columns('org_id', 'user_id', 'created_at');

create trigger set_updated_at before update on public.voice_notes for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.ai_answers for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.public_summaries for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.client_messages for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.calendar_feeds for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------- row-level security (spec §9.3)

alter table public.document_chunks enable row level security;
alter table public.voice_notes enable row level security;
alter table public.ai_runs enable row level security;
alter table public.ai_answers enable row level security;
alter table public.public_summaries enable row level security;
alter table public.client_messages enable row level security;
alter table public.display_board_snapshots enable row level security;
alter table public.calendar_feeds enable row level security;

-- chunks: read for Ask and search through the API as the user; written by workers
create policy document_chunks_select on public.document_chunks for select to authenticated
  using ((org_id is not null and is_member(org_id))
      or (court_order_id is not null and tracks_court_order(court_order_id)));

-- voice notes: the author only, on the author's devices
create policy voice_notes_select on public.voice_notes for select to authenticated
  using (created_by = auth.uid() and is_member(org_id));
create policy voice_notes_insert on public.voice_notes for insert to authenticated
  with check (created_by = auth.uid() and is_member(org_id));
create policy voice_notes_update on public.voice_notes for update to authenticated
  using (created_by = auth.uid() and is_member(org_id)) with check (created_by = auth.uid() and is_member(org_id));
create policy voice_notes_delete on public.voice_notes for delete to authenticated
  using (created_by = auth.uid() and is_member(org_id));

-- AI runs: the organisation owner reads costs; the service role writes
create policy ai_runs_select on public.ai_runs for select to authenticated
  using (org_id is not null and has_role(org_id, array['owner']));

-- AI answers: members read; the API writes as the asker and deletes for the asker or the owner
create policy ai_answers_select on public.ai_answers for select to authenticated using (is_member(org_id));
create policy ai_answers_insert on public.ai_answers for insert to authenticated
  with check (is_member(org_id) and via_api() and created_by = auth.uid());
create policy ai_answers_update on public.ai_answers for update to authenticated
  using (is_member(org_id) and via_api() and (created_by = auth.uid() or has_role(org_id, array['owner'])));

-- shared summaries: court orders for those tracking the CNR, judgments for everyone; workers write
create policy public_summaries_select on public.public_summaries for select to authenticated
  using (case doc_kind when 'judgment' then true else tracks_court_order(doc_ref::uuid) end);

-- client messages: members read; drafting, approving and sending through the API, never by a clerk (§10.2)
create policy client_messages_select on public.client_messages for select to authenticated using (is_member(org_id));
create policy client_messages_insert on public.client_messages for insert to authenticated
  with check (has_role(org_id, array['owner', 'advocate', 'junior']) and via_api() and created_by = auth.uid());
create policy client_messages_update on public.client_messages for update to authenticated
  using (has_role(org_id, array['owner', 'advocate', 'junior']) and via_api())
  with check (has_role(org_id, array['owner', 'advocate', 'junior']));

-- item tracker: members read; a team update goes through the API, which also alerts the chamber
create policy display_board_snapshots_select on public.display_board_snapshots for select to authenticated
  using (is_member(org_id));
create policy display_board_snapshots_insert on public.display_board_snapshots for insert to authenticated
  with check (is_member(org_id) and via_api() and source = 'team' and captured_by = auth.uid());

-- calendar feeds: own feed, through the API
create policy calendar_feeds_select on public.calendar_feeds for select to authenticated using (user_id = auth.uid());
create policy calendar_feeds_insert on public.calendar_feeds for insert to authenticated
  with check (user_id = auth.uid() and is_member(org_id) and via_api());
create policy calendar_feeds_update on public.calendar_feeds for update to authenticated
  using (user_id = auth.uid() and via_api());
create policy calendar_feeds_delete on public.calendar_feeds for delete to authenticated
  using (user_id = auth.uid() and via_api());

revoke all on all tables in schema public from anon;

-- Devices receive their own voice notes and the chamber's live tracker (§9.4).
alter publication powersync add table public.voice_notes, public.display_board_snapshots;
