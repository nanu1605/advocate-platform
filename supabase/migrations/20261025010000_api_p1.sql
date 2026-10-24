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
