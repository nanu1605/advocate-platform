-- RLS matrix for Phase 0 tables (spec §9.3): five actors × read / insert / update / delete.
begin;
\ir _setup.psql

-- ---------------------------------------------------------------- P0 fixture (as postgres)
insert into public.invites (org_id, role, code, expires_at) values
  ('0000000a-0000-0000-0000-000000000000', 'clerk', 'FIXTURE1', now() + interval '7 days');
insert into public.devices (user_id, platform) select id, 'android' from public.profiles;
insert into public.consents (user_id, purpose, version, granted) select id, 'account_processing', 'v1', true from public.profiles;
insert into public.platform_admins (user_id, role) values ('00000000-0000-0000-0000-0000000000a1', 'support');
insert into public.audit_log (org_id, user_id, action) values
  ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a1', 'sign_in'),
  ('0000000b-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000b1', 'sign_in');
insert into public.jobs (org_id, user_id, kind) values
  ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a1', 'fixture'),
  ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a2', 'fixture'),
  ('0000000b-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000b1', 'fixture');
insert into public.app_config (key, value) values ('fixture_key', '1');
insert into public.plans (id, name, price_paise, interval, limits) values ('fixture_plan', 'F', 0, 'month', '{}')
  on conflict (id) do nothing;
insert into public.feature_flags (key, value) values ('fixture_flag', 'false') on conflict (key) do nothing;

-- ---------------------------------------------------------------- coverage
select is((select count(*)::int from pg_tables where schemaname = 'public' and not rowsecurity), 0,
  'every public table has RLS enabled');
select is((select count(*)::int from public.memberships where org_id = '0000000a-0000-0000-0000-000000000000'
  and user_id = '00000000-0000-0000-0000-0000000000a1' and role = 'owner'), 1, 'new org creates owner membership');

-- ---------------------------------------------------------------- profiles
select tests.matrix('profiles read', 'select 1 from public.profiles', false, '{1,1,1,1,1}');
select tests.matrix('profiles insert', 'insert into public.profiles (id) values (auth.uid())', true, '{-1,-1,-1,-1,-1}');
select tests.matrix('profiles update own (device)', $$update public.profiles set full_name = 'x' where id = auth.uid()$$, false, '{0,0,0,0,0}');
select tests.matrix('profiles update own', $$update public.profiles set full_name = 'x' where id = auth.uid()$$, true, '{1,1,1,1,1}');
select tests.matrix('profiles update others', $$update public.profiles set full_name = 'x' where id <> auth.uid()$$, true, '{0,0,0,0,0}');
select tests.matrix('profiles delete', 'delete from public.profiles', true, '{0,0,0,0,0}');

-- ---------------------------------------------------------------- organizations
select tests.matrix('organizations read', 'select 1 from public.organizations', false, '{1,1,1,1,1}');
select tests.matrix('organizations insert (device)', $$insert into public.organizations (name, kind, owner_id) values ('n', 'solo', auth.uid())$$, false, '{-1,-1,-1,-1,-1}');
select tests.matrix('organizations insert own', $$insert into public.organizations (name, kind, owner_id) values ('n', 'solo', auth.uid())$$, true, '{1,1,1,1,1}');
select tests.matrix('organizations insert for another owner', $$insert into public.organizations (name, kind, owner_id) values ('n', 'solo', gen_random_uuid())$$, true, '{-1,-1,-1,-1,-1}');
select tests.matrix('organizations update A', $$update public.organizations set name = 'x' where id = '0000000a-0000-0000-0000-000000000000'$$, true, '{1,0,0,0,0}');
select tests.matrix('organizations update A (device)', $$update public.organizations set name = 'x' where id = '0000000a-0000-0000-0000-000000000000'$$, false, '{0,0,0,0,0}');
select tests.matrix('organizations delete', 'delete from public.organizations', true, '{0,0,0,0,0}');

-- ---------------------------------------------------------------- memberships
select tests.matrix('memberships read', 'select 1 from public.memberships', false, '{4,4,4,4,1}');
select tests.matrix('memberships insert into A', $$insert into public.memberships (org_id, user_id, role) values ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000b1', 'clerk')$$, true, '{1,-1,-1,-1,-1}');
select tests.matrix('memberships insert into A (device)', $$insert into public.memberships (org_id, user_id, role) values ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000b1', 'clerk')$$, false, '{-1,-1,-1,-1,-1}');
select tests.matrix('memberships update in A', $$update public.memberships set role = 'junior' where user_id = '00000000-0000-0000-0000-0000000000a4'$$, true, '{1,0,0,0,0}');
select tests.matrix('memberships delete', 'delete from public.memberships', true, '{0,0,0,0,0}');

-- ---------------------------------------------------------------- invites
select tests.matrix('invites read', 'select 1 from public.invites', false, '{1,1,1,1,0}');
select tests.matrix('invites insert into A', $$insert into public.invites (org_id, role, code, expires_at) values ('0000000a-0000-0000-0000-000000000000', 'clerk', gen_random_uuid()::text, now() + interval '1 day')$$, true, '{1,-1,-1,-1,-1}');
select tests.matrix('invites update in A', 'update public.invites set accepted_at = now()', true, '{1,0,0,0,0}');
select tests.matrix('invites delete', 'delete from public.invites', true, '{0,0,0,0,0}');

-- ---------------------------------------------------------------- devices
select tests.matrix('devices read', 'select 1 from public.devices', false, '{1,1,1,1,1}');
select tests.matrix('devices insert own', $$insert into public.devices (user_id, platform) values (auth.uid(), 'windows')$$, true, '{1,1,1,1,1}');
select tests.matrix('devices insert own (device)', $$insert into public.devices (user_id, platform) values (auth.uid(), 'windows')$$, false, '{-1,-1,-1,-1,-1}');
select tests.matrix('devices insert for another user', $$insert into public.devices (user_id, platform) values (case when auth.uid() = '00000000-0000-0000-0000-0000000000a1' then '00000000-0000-0000-0000-0000000000b1'::uuid else '00000000-0000-0000-0000-0000000000a1'::uuid end, 'ios')$$, true, '{-1,-1,-1,-1,-1}');
select tests.matrix('devices update', 'update public.devices set revoked_at = now()', true, '{1,1,1,1,1}');
select tests.matrix('devices delete', 'delete from public.devices', true, '{0,0,0,0,0}');

-- ---------------------------------------------------------------- platform_admins
select tests.matrix('platform_admins read', 'select 1 from public.platform_admins', false, '{0,0,0,0,0}');
select tests.matrix('platform_admins insert', $$insert into public.platform_admins (user_id, role) values (auth.uid(), 'super_admin')$$, true, '{-1,-1,-1,-1,-1}');
select tests.matrix('platform_admins update', $$update public.platform_admins set role = 'super_admin'$$, true, '{0,0,0,0,0}');
select tests.matrix('platform_admins delete', 'delete from public.platform_admins', true, '{0,0,0,0,0}');

-- ---------------------------------------------------------------- consents (append-only for users)
select tests.matrix('consents read', 'select 1 from public.consents', false, '{1,1,1,1,1}');
select tests.matrix('consents insert own', $$insert into public.consents (user_id, purpose, version, granted) values (auth.uid(), 'analytics', 'v1', false)$$, true, '{1,1,1,1,1}');
select tests.matrix('consents insert own (device)', $$insert into public.consents (user_id, purpose, version, granted) values (auth.uid(), 'analytics', 'v1', false)$$, false, '{-1,-1,-1,-1,-1}');
select tests.matrix('consents update', 'update public.consents set granted = false', true, '{-1,-1,-1,-1,-1}');
select tests.matrix('consents delete', 'delete from public.consents', true, '{-1,-1,-1,-1,-1}');

-- ---------------------------------------------------------------- audit_log (append-only)
select tests.matrix('audit_log read', 'select 1 from public.audit_log', false, '{1,0,0,0,1}');
select tests.matrix('audit_log insert in A', $$insert into public.audit_log (org_id, user_id, action) values ('0000000a-0000-0000-0000-000000000000', auth.uid(), 't')$$, true, '{1,1,1,1,-1}');
select tests.matrix('audit_log insert (device)', $$insert into public.audit_log (user_id, action) values (auth.uid(), 't')$$, false, '{-1,-1,-1,-1,-1}');
select tests.matrix('audit_log update', $$update public.audit_log set action = 'x'$$, true, '{-1,-1,-1,-1,-1}');
select tests.matrix('audit_log delete', 'delete from public.audit_log', true, '{-1,-1,-1,-1,-1}');
select throws_ok($$update public.audit_log set action = 'x'$$, '42501', 'audit_log is append-only', 'audit_log update blocked even for postgres');

-- ---------------------------------------------------------------- reference/config tables
select tests.matrix('feature_flags read', $$select 1 from public.feature_flags where key = 'fixture_flag'$$, false, '{1,1,1,1,1}');
select tests.matrix('feature_flags insert', $$insert into public.feature_flags (key) values ('x')$$, true, '{-1,-1,-1,-1,-1}');
select tests.matrix('feature_flags update', $$update public.feature_flags set value = 'true'$$, true, '{0,0,0,0,0}');
select tests.matrix('feature_flags delete', 'delete from public.feature_flags', true, '{0,0,0,0,0}');
select tests.matrix('app_config read', $$select 1 from public.app_config where key = 'fixture_key'$$, false, '{1,1,1,1,1}');
select tests.matrix('app_config insert', $$insert into public.app_config (key, value) values ('x', '1')$$, true, '{-1,-1,-1,-1,-1}');
select tests.matrix('app_config update', $$update public.app_config set value = '2'$$, true, '{0,0,0,0,0}');
select tests.matrix('app_config delete', 'delete from public.app_config', true, '{0,0,0,0,0}');
select tests.matrix('plans read', $$select 1 from public.plans where id = 'fixture_plan'$$, false, '{1,1,1,1,1}');
select tests.matrix('plans insert', $$insert into public.plans (id, name, price_paise, interval, limits) values ('x', 'x', 0, 'month', '{}')$$, true, '{-1,-1,-1,-1,-1}');
select tests.matrix('plans update', 'update public.plans set price_paise = 0', true, '{0,0,0,0,0}');
select tests.matrix('plans delete', 'delete from public.plans', true, '{0,0,0,0,0}');

-- ---------------------------------------------------------------- jobs
select tests.matrix('jobs read', 'select 1 from public.jobs', false, '{2,1,0,0,1}');
select tests.matrix('jobs insert in A', $$insert into public.jobs (org_id, user_id, kind) values ('0000000a-0000-0000-0000-000000000000', auth.uid(), 't')$$, true, '{1,1,1,1,-1}');
select tests.matrix('jobs insert (device)', $$insert into public.jobs (user_id, kind) values (auth.uid(), 't')$$, false, '{-1,-1,-1,-1,-1}');
select tests.matrix('jobs cancel own', $$update public.jobs set status = 'cancelled'$$, true, '{1,1,0,0,1}');
select tests.matrix('jobs delete', 'delete from public.jobs', true, '{0,0,0,0,0}');

-- ---------------------------------------------------------------- anon gets nothing
set local role anon;
select is(tests.try('select 1 from public.profiles'), -1, 'anon cannot read profiles');
select is(tests.try('select 1 from public.plans'), -1, 'anon cannot read plans');
reset role;

select * from finish();
rollback;
