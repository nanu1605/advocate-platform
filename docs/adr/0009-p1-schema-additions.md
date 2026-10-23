# 0009 — Phase 1 schema: additions to §9.2 and how §9.3 is enforced

Status: accepted (24 Oct 2026)

## Context
The Phase 1 tables in spec §9.2 leave out a few columns the P1 features need, and §9.3 lists which columns a device
may write without saying how Postgres should enforce it.

## Decision
**Added columns**
- `courts.name_hi`, `courts.short_name_hi`: court names are shown in both languages (hard rule 5).
- `board_entries.proxy_arranged`: §4.2's "Mark proxy arranged" action; device-writable like `assignee_id`.
- `documents.upload_status` (`pending`/`ready`/`quarantined`): the upload-URL → complete flow and the ClamAV quarantine (§4.3).
- `hearings.court_hearing_id`, `org_cause_list_entries.cause_list_entry_id`: fan-out upsert keys, so retries never
  duplicate rows; `orders` is unique on `(matter_id, court_order_id)` for the same reason.
- `board_entries.expected_slot` is a `time` (estimated start, IST); the clash heuristic gets its own ADR.

**Enforcement**
- Child rows reference `(matter_id, org_id)` and `(client_id, org_id)`, and assignees reference
  `memberships (org_id, user_id)`, so no row can point into another organisation or at a non-member.
- `device_columns(...)` triggers allow a device upload to change only the listed columns; `guard_columns(...)`
  triggers make the listed columns worker-only (`org_id` everywhere, court fields on `matters`). The API path is told
  apart by `via_api()` (ADR 0003).
- Deletes are soft. Devices get no DELETE except on `matter_clients` (a link) and per-user rows (`order_reads`,
  `document_offline_prefs`, `notification_prefs`). Devices may also set `documents.deleted_at`, which §9.3 does not
  list; documents have no delete endpoint otherwise.
- The beta allowance (`app_config.beta_tracked_case_allowance`, default 100) counts auto-tracked, non-deleted matters
  per organisation; manual cases do not count.
- Role limits on API-only actions (only owners and advocates delete matters, §10.2) are checked in the API.

## Consequences
- `supabase/tests/002_rls_court_diary.test.sql` covers every P1 table for five actors and each trigger.
- `cnr` has no format check in the database: providers may return Supreme Court identifiers that differ from the
  `^[A-Z]{4}\d{12}$` CNR the app validates on input.
