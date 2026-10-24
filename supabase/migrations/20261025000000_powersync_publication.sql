-- Tables PowerSync replicates to devices (spec §9.4, ADR 0010). Must match the tables named in
-- infra/powersync/sync-config.yaml; a test checks both lists. Shared court_* tables, costs and audit rows are never here.
create publication powersync for table
  public.profiles, public.organizations, public.memberships, public.jobs,
  public.courts, public.court_holidays, public.plans, public.feature_flags, public.app_config,
  public.matters, public.hearings, public.orders, public.order_reads,
  public.org_cause_list_entries, public.board_entries, public.found_cases,
  public.clients, public.matter_clients, public.notes, public.tasks, public.deadlines,
  public.documents, public.document_offline_prefs, public.notifications, public.notification_prefs;
