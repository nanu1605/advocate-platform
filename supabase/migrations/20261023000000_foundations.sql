-- Phase 0 foundations: identity, tenancy, platform tables (spec §9.1–9.3).
-- Write paths (§9.1): device uploads and API calls both arrive as role `authenticated`.
-- The API marks its transactions with `app.write_path = 'api'`; policies for API-only writes check `via_api()`.
-- PostgREST clients cannot set that setting. Workers use service_role, which bypasses RLS.

-- ---------------------------------------------------------------- helpers

create or replace function public.via_api() returns boolean
language sql stable as $$
  select coalesce(current_setting('app.write_path', true), '') = 'api'
$$;

create or replace function public.set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ---------------------------------------------------------------- identity and tenancy

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text,
  phone text,
  email text,
  preferred_language text not null default 'hi' check (preferred_language in ('hi', 'en')),
  enrolment_no text,
  bar_council_state text,
  practice_court_ids uuid[] not null default '{}',  -- empty = every court in the Bar Council's state
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  kind text not null check (kind in ('solo', 'chamber')),
  owner_id uuid not null references public.profiles (id),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.memberships (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  role text not null check (role in ('owner', 'advocate', 'junior', 'clerk')),
  display_name text,
  status text not null default 'active' check (status in ('invited', 'active', 'removed')),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, user_id)
);
create index memberships_user_idx on public.memberships (user_id) where status = 'active';

create table public.invites (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  phone text,
  role text not null check (role in ('advocate', 'junior', 'clerk')),
  code text not null unique,
  expires_at timestamptz not null,
  accepted_at timestamptz,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);

create table public.devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  platform text not null check (platform in ('android', 'ios', 'windows')),
  push_token text,
  app_version text,
  last_seen_at timestamptz not null default now(),
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);
create index devices_user_idx on public.devices (user_id);

create table public.platform_admins (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references public.profiles (id) on delete cascade,
  role text not null check (role in ('super_admin', 'support')),
  mfa_enrolled_at timestamptz
);

-- ---------------------------------------------------------------- membership checks (security definer: avoids RLS recursion)

create or replace function public.is_member(target_org uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.memberships m
    where m.org_id = target_org and m.user_id = auth.uid() and m.status = 'active'
  )
$$;

create or replace function public.has_role(target_org uuid, roles text[]) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.memberships m
    where m.org_id = target_org and m.user_id = auth.uid() and m.status = 'active' and m.role = any (roles)
  )
$$;

-- New auth user → profile row.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, phone, email) values (new.id, new.phone, new.email);
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- New organisation → owner membership (spec §9.2 onboarding role mapping).
create or replace function public.handle_new_org() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.memberships (org_id, user_id, role, display_name, status, created_by)
  select new.id, new.owner_id, 'owner', p.full_name, 'active', new.owner_id
  from public.profiles p where p.id = new.owner_id;
  return new;
end $$;

create trigger on_org_created after insert on public.organizations
  for each row execute function public.handle_new_org();

-- ---------------------------------------------------------------- platform tables

create table public.consents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  purpose text not null,          -- e.g. account_processing, whatsapp_alerts, analytics
  version text not null,          -- notice version shown
  granted boolean not null,
  created_at timestamptz not null default now()
);
create index consents_user_idx on public.consents (user_id, purpose, created_at desc);

-- No foreign keys: the log outlives the org and user rows it mentions (and FK actions would rewrite it).
create table public.audit_log (
  id uuid primary key default gen_random_uuid(),
  org_id uuid,
  user_id uuid,
  action text not null,
  entity text,
  entity_id uuid,
  meta jsonb not null default '{}',
  ip_hash text,
  user_agent text,
  created_at timestamptz not null default now()
);
create index audit_log_org_idx on public.audit_log (org_id, created_at desc);

-- Append-only: no updates ever; deletes only by retention jobs (service_role).
create or replace function public.audit_log_append_only() returns trigger
language plpgsql as $$
begin
  if tg_op = 'UPDATE' or current_user not in ('service_role', 'postgres', 'supabase_admin') then
    raise exception 'audit_log is append-only' using errcode = '42501';
  end if;
  return old;
end $$;

create trigger audit_log_no_change before update or delete on public.audit_log
  for each row execute function public.audit_log_append_only();

create table public.feature_flags (
  id uuid primary key default gen_random_uuid(),
  key text not null unique,
  value jsonb not null default 'false',
  updated_at timestamptz not null default now()
);

create table public.app_config (
  id uuid primary key default gen_random_uuid(),
  key text not null unique,
  value jsonb not null,
  updated_at timestamptz not null default now()
);

create table public.jobs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid references public.organizations (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null,
  status text not null default 'queued' check (status in ('queued', 'running', 'done', 'failed', 'cancelled')),
  progress jsonb not null default '{}',
  result jsonb,
  error text,
  is_recent boolean not null default true,  -- running, or finished in the last 24 h (kept current by a job)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index jobs_user_recent_idx on public.jobs (user_id) where is_recent;

create table public.plans (
  id text primary key,            -- free / solo / chamber … (spec §9.2)
  name text not null,
  price_paise bigint not null,
  interval text not null check (interval in ('month', 'year')),
  limits jsonb not null,
  active boolean not null default true
);

-- updated_at bookkeeping
create trigger set_updated_at before update on public.profiles for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.organizations for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.memberships for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.feature_flags for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.app_config for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.jobs for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------- row-level security (spec §9.3)

alter table public.profiles enable row level security;
alter table public.organizations enable row level security;
alter table public.memberships enable row level security;
alter table public.invites enable row level security;
alter table public.devices enable row level security;
alter table public.platform_admins enable row level security;
alter table public.consents enable row level security;
alter table public.audit_log enable row level security;
alter table public.feature_flags enable row level security;
alter table public.app_config enable row level security;
alter table public.jobs enable row level security;
alter table public.plans enable row level security;

-- profiles: own row; edits through PATCH /v1/me
create policy profiles_select on public.profiles for select to authenticated using (id = auth.uid());
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid() and via_api()) with check (id = auth.uid());

-- organizations: members read; anyone creates their own through the API; owner edits through the API
create policy organizations_select on public.organizations for select to authenticated using (is_member(id));
create policy organizations_insert on public.organizations for insert to authenticated
  with check (owner_id = auth.uid() and via_api());
create policy organizations_update on public.organizations for update to authenticated
  using (has_role(id, array['owner']) and via_api());

-- memberships / invites: members read; owner manages through the API
create policy memberships_select on public.memberships for select to authenticated using (is_member(org_id));
create policy memberships_insert on public.memberships for insert to authenticated
  with check (has_role(org_id, array['owner']) and via_api());
create policy memberships_update on public.memberships for update to authenticated
  using (has_role(org_id, array['owner']) and via_api());

create policy invites_select on public.invites for select to authenticated using (is_member(org_id));
create policy invites_insert on public.invites for insert to authenticated
  with check (has_role(org_id, array['owner']) and via_api());
create policy invites_update on public.invites for update to authenticated
  using (has_role(org_id, array['owner']) and via_api());

-- devices: own rows, through the API
create policy devices_select on public.devices for select to authenticated using (user_id = auth.uid());
create policy devices_insert on public.devices for insert to authenticated
  with check (user_id = auth.uid() and via_api());
create policy devices_update on public.devices for update to authenticated
  using (user_id = auth.uid() and via_api());

-- platform_admins: service role only (no policies)

-- consents: own rows; recorded through the API, never edited (withdrawal = new row)
create policy consents_select on public.consents for select to authenticated using (user_id = auth.uid());
create policy consents_insert on public.consents for insert to authenticated
  with check (user_id = auth.uid() and via_api());

-- audit_log: org owner reads; the API appends as the acting user
create policy audit_log_select on public.audit_log for select to authenticated
  using (org_id is not null and has_role(org_id, array['owner']));
create policy audit_log_insert on public.audit_log for insert to authenticated
  with check (user_id = auth.uid() and via_api() and (org_id is null or is_member(org_id)));

-- reference/config: any signed-in user reads; admins write as service role
create policy feature_flags_select on public.feature_flags for select to authenticated using (true);
create policy app_config_select on public.app_config for select to authenticated using (true);
create policy plans_select on public.plans for select to authenticated using (active);

-- jobs: own rows; the owner sees the organisation's; created and cancelled through the API
create policy jobs_select on public.jobs for select to authenticated
  using (user_id = auth.uid() or (org_id is not null and has_role(org_id, array['owner'])));
create policy jobs_insert on public.jobs for insert to authenticated
  with check (user_id = auth.uid() and via_api() and (org_id is null or is_member(org_id)));
create policy jobs_update on public.jobs for update to authenticated
  using (user_id = auth.uid() and via_api());

-- Defence in depth: anon gets nothing; nobody but the server rewrites history.
revoke all on all tables in schema public from anon;
revoke update, delete on public.audit_log, public.consents from authenticated;
