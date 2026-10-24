-- Phase 1 API support (spec §10.2, ADR 0011): job inputs, invite acceptance, file buckets, beta search cap.

-- What a job was asked to do, so a worker can resume it after redelivery.
alter table public.jobs add column input jsonb not null default '{}';

-- Invite acceptance runs as the invitee, who can't read invites or add memberships under RLS (owners only),
-- so the checks live here. Errors are P0001 with a stable code the API maps (INVITE_INVALID covers missing,
-- used, expired and wrong-phone invites alike, so codes can't be probed).
create or replace function public.accept_invite(invite_code text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  inv public.invites;
  me public.profiles;
begin
  if auth.uid() is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '42501';
  end if;
  select * into inv from public.invites where code = upper(invite_code) for update;
  select * into me from public.profiles where id = auth.uid();
  if inv.id is null or inv.accepted_at is not null or inv.expires_at < now()
     or (inv.phone is not null and inv.phone is distinct from me.phone) then
    raise exception 'INVITE_INVALID' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.memberships
             where org_id = inv.org_id and user_id = auth.uid() and status = 'active') then
    raise exception 'ALREADY_MEMBER' using errcode = 'P0001';
  end if;
  if (select count(*) from public.memberships where org_id = inv.org_id and status = 'active') >= 10 then
    raise exception 'TEAM_LIMIT' using errcode = 'P0001', detail = '10';  -- F16: up to 10 members
  end if;
  insert into public.memberships (org_id, user_id, role, display_name, status, created_by)
  values (inv.org_id, auth.uid(), inv.role, me.full_name, 'active', inv.created_by)
  on conflict (org_id, user_id) do update
    set role = excluded.role, display_name = excluded.display_name, status = 'active';
  update public.invites set accepted_at = now() where id = inv.id;
  insert into public.audit_log (org_id, user_id, action, entity, entity_id, meta)
  values (inv.org_id, auth.uid(), 'invite_accepted', 'invites', inv.id, jsonb_build_object('role', inv.role));
  return inv.org_id;
end $$;
revoke all on function public.accept_invite(text) from public, anon;
grant execute on function public.accept_invite(text) to authenticated;

-- Private buckets; the API signs short-lived URLs after checking access as the user (spec §15.5).
insert into storage.buckets (id, name, public, file_size_limit) values
  ('documents', 'documents', false, 52428800),  -- org files: {org_id}/{document_id}
  ('court-orders', 'court-orders', false, null)  -- public order PDFs, fetched once per CNR and shared
on conflict (id) do nothing;

-- Case searches per organisation per IST day during the beta (plans set this from P3).
insert into public.app_config (key, value) values ('beta_case_search_daily_cap', '100') on conflict (key) do nothing;

-- Manual cases in courts outside the `courts` list keep the court's name as typed (spec §4.1 "Manual case").
alter table public.matters add column court_name text;

-- Deleting a matter through the API soft-deletes its hearings too, court-sourced ones included.
create or replace function public.hearings_guard() returns trigger
language plpgsql as $$
declare
  changed text[];
  user_fields text[] := array['user_next_date', 'user_purpose', 'user_outcome', 'user_note', 'confirmed', 'updated_at'];
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
  if public.via_api() then
    user_fields := user_fields || 'deleted_at'::text;
  end if;
  changed := public.changed_columns(to_jsonb(old), to_jsonb(new));
  if changed && array['id', 'org_id', 'matter_id', 'source', 'court_hearing_id', 'created_by', 'created_at']
     or (old.source = 'court' and not changed <@ user_fields) then
    raise exception 'hearings: % cannot change here', changed using errcode = '42501';
  end if;
  return new;
end $$;

-- Assignees reference memberships; deleting a user or an organisation removes memberships first, which a plain
-- NO ACTION key rejects while an assignment exists. Clear the assignee instead.
alter table public.matters drop constraint matters_org_id_assigned_to_fkey,
  add foreign key (org_id, assigned_to) references public.memberships (org_id, user_id) on delete set null (assigned_to);
alter table public.board_entries drop constraint board_entries_org_id_assignee_id_fkey,
  add foreign key (org_id, assignee_id) references public.memberships (org_id, user_id) on delete set null (assignee_id);
alter table public.tasks drop constraint tasks_org_id_assignee_id_fkey,
  add foreign key (org_id, assignee_id) references public.memberships (org_id, user_id) on delete set null (assignee_id);

-- The allowance count can't see another transaction's uncommitted matters, so concurrent adds could overshoot it.
-- One lock per organisation serialises them; the API takes the same lock before its own pre-check.
create or replace function public.matters_allowance() returns trigger
language plpgsql as $$
declare
  allowance int := (select (value #>> '{}')::int from public.app_config where key = 'beta_tracked_case_allowance');
begin
  if allowance is not null and new.tracking = 'auto' and new.deleted_at is null
     and (tg_op = 'INSERT' or old.tracking <> 'auto' or old.deleted_at is not null) then
    perform pg_advisory_xact_lock(hashtextextended('allowance:' || new.org_id::text, 0));
    if (select count(*) from public.matters m
        where m.org_id = new.org_id and m.tracking = 'auto' and m.deleted_at is null and m.id <> new.id) >= allowance then
      raise exception 'TRACKED_CASE_LIMIT' using errcode = 'P0001', detail = allowance::text;
    end if;
  end if;
  return new;
end $$;

-- Deleting a matter soft-deletes everything hanging off it in one transaction, including rows the caller can't
-- write or even see under RLS (orders, cause-list rows, colleagues' private notes). Owners and advocates only.
create or replace function public.delete_matter(target uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  org uuid := (select org_id from public.matters where id = target and deleted_at is null);
begin
  if org is null or not public.is_member(org) then
    raise exception 'MATTER_NOT_FOUND' using errcode = 'P0001';
  end if;
  if not public.has_role(org, array['owner', 'advocate']) then
    raise exception 'insufficient role' using errcode = '42501';
  end if;
  perform set_config('app.write_path', 'api', true);
  update public.matters set deleted_at = now() where id = target;
  update public.hearings set deleted_at = now() where matter_id = target and deleted_at is null;
  update public.orders set deleted_at = now() where matter_id = target and deleted_at is null;
  update public.notes set deleted_at = now() where matter_id = target and deleted_at is null;
  update public.tasks set deleted_at = now() where matter_id = target and deleted_at is null;
  update public.deadlines set deleted_at = now() where matter_id = target and deleted_at is null;
  update public.documents set deleted_at = now() where matter_id = target and deleted_at is null;
  update public.board_entries set is_current = false where matter_id = target and is_current;
  update public.org_cause_list_entries set is_current = false where matter_id = target and is_current;
  insert into public.audit_log (org_id, user_id, action, entity, entity_id)
  values (org, auth.uid(), 'matter_deleted', 'matters', target);
end $$;
revoke all on function public.delete_matter(uuid) from public, anon;
grant execute on function public.delete_matter(uuid) to authenticated;

-- Uploads must be one of the types the API accepts (spec §4.3); Storage rejects anything else.
update storage.buckets set allowed_mime_types = array[
  'application/pdf', 'image/jpeg', 'image/png',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
] where id = 'documents';
