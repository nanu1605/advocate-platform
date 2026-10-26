# PROJECT_STATE
Current phase: 2 — Daily AI assistant (status: planning; Phase 0 and 1 gates wait on Track B)
Last updated: 2026-10-26

## Done (this phase)
- Plan: [phase-2-plan.md](docs/phases/phase-2-plan.md) (Track A local, Track B on hold). Phase 2 started 26 Oct 2026
  on the founder's go-ahead.
- P2 schema ([ADR 0019](docs/adr/0019-p2-schema.md)): `document_chunks` (pgvector 1024-d, full text, trigram; shared
  court-order text), `voice_notes`, `ai_runs`, `ai_answers`, `public_summaries`, `client_messages` (approval enforced
  in the database, recipient fixed at approval), `display_board_snapshots`, `calendar_feeds`; voice notes and the live
  tracker sync; 329 new pgTAP assertions (1348 in all); sync tests for voice-note privacy.

## Done (Phase 1, Track A)
- Gate exceptions decided 26 Oct 2026 (the founder delegated the call) ([phase-1-report.md](docs/phases/phase-1-report.md)): the focus
  ring now reaches Material's own destinations (rail, bar, tabs, menus, segments); the rest accepted or deferred.
- Plan: [phase-1-plan.md](docs/phases/phase-1-plan.md) (Track A local, Track B on hold). Report:
  [phase-1-report.md](docs/phases/phase-1-report.md).
- P1 phase checks ([ADR 0018](docs/adr/0018-p1-phase-checks.md)): one sweep over all 80 screens, sheets and dialogs
  (en/hi, 360 dp phone and 1024 × 640 window, 100% and 200% text, tap-target and label guidelines, offline, a route
  guard); 960 goldens; 2 dp keyboard focus ring; announcements that reach Windows Narrator, sync completion said once,
  form errors announced; reduce motion and haptics off honoured; `deadline_due` reminders (3/1/0 days); end-to-end
  tests on the local stack for offline notes/tasks/hearings, onboarding → import → Today and the clerk join flow;
  tray notices cleared when their alert goes; text limits in code points like the API; Found-for-you badge on Cases.
- Schema for the 26 P1 tables with RLS, write-path triggers and the beta tracked-case allowance; five reference courts;
  709 new pgTAP assertions (5 actors × CRUD + every trigger), 1009 in all ([ADR 0009](docs/adr/0009-p1-schema-additions.md)).
- `court_data` package: provider interface and models, eCourtsIndia provider (from their public docs), router with
  fallback and circuit breaker (5 failures → 10 min), per-call cost records; synthetic stand-in API (8 made-up cases,
  dates shiftable to today) for tests and local runs; 26 contract and router tests.
- Transliteration search key, one algorithm in Python (`advocate_shared.search_key`) and Dart (`core/search_key.dart`),
  both tested against `config/fixtures/translit_pairs.yaml`: 50 Hindi/English name pairs with common spelling variants,
  plus CNRs, case numbers, nukta forms and half-typed queries.
- Local sync ([ADR 0010](docs/adr/0010-local-sync-powersync.md)): PowerSync service in Docker, Sync Streams mirroring
  §9.3, `powersync` publication; app database with all 25 synced tables plus local-only `found_selection`, Supabase
  upload connector, live offline banner and sync indicator, feature flags read from the synced table. 22 sync tests
  as six real users (leakage, publication/config/device-schema parity); Windows end-to-end test of offline writes.
- P1 API ([ADR 0011](docs/adr/0011-p1-api.md)): team invites/accept/members, find-cases and found-cases add/decision,
  jobs get/cancel, case search (cached, rate-limited, costed), add by CNR, manual cases, refresh, official link,
  delete, document upload/complete/download URLs, order PDF URL (fetched once, shared), Tomorrow's Board, feedback.
  Shared plumbing: Idempotency-Key, after-commit job enqueueing, court-data budgets and cost records, Storage signing.
- P1 workers ([ADR 0012](docs/adr/0012-p1-workers.md)): find-my-cases (cancellable, scored, capped), fetch for added
  cases, on-demand refresh, the §11.5 schedule (cause lists 18:30/20:30/22:00, post-hearing refresh and two retries,
  weekly sweep, auto-match, `advocate_watch` behind a flag, Today at 07:30), change detection with per-user event keys,
  fan-out to every tracking organisation, Tomorrow's Board with expected slots and clash groups, order PDF pipeline,
  ClamAV upload scan (fails closed), window flags, stale-job sweeper, §11.8 budgets. 104 worker tests.
- P1 Team, notifications, dashboard, feedback ([ADR 0017](docs/adr/0017-p1-team-notifications.md)): Team (members
  with assigned-case counts; owner changes roles and names, removes members, invites by role and optional phone with
  a code to share, sees and revokes open invites via new `GET`/`DELETE /v1/orgs/{id}/invites`); a removed member goes
  back to the role/join step; notification centre (unread bell on Today, Today/Yesterday/Earlier, collapse keys, mark
  read) and per-kind preferences with case titles and quiet hours; local notifications on Android and Windows for
  newly synced alerts and a finished background search (`flutter_local_notifications`); practice dashboard (four
  counts plus Today); in-app feedback; sign-out warns when changes or uploads are still waiting; every server error
  code has its own text (test-enforced).
- P1 Calendar, Clients, Documents ([ADR 0016](docs/adr/0016-p1-calendar-clients-docs.md)): Calendar (Day, Week,
  Month, Agenda over hearings, deadlines and tasks, type filter, Windows keys); Clients (list with transliterated
  search, profile, edit, WhatsApp opt-in, linked cases, two panes on Windows); Documents (list and filters, upload by
  ML Kit scan, file picker or drag-drop on Windows and onto a case, an offline upload queue that resumes after each
  step, pdfrx viewer with find and selection, Keep offline plus the last 10 opened and the latest order of today's and
  tomorrow's cases kept on the device, all cleared at sign-out).
- P1 Cases and case page ([ADR 0015](docs/adr/0015-p1-cases.md)): Cases list (Today · This week · Later · No next
  date · Disposed · Found for you; transliteration search over case number, party, client and CNR; court, client,
  status and assignee filters; three sorts; two panes on Windows); case page (header, refresh, share status, official
  portal, tracking on/off, archive, delete; Timeline with hearing notes and editable manual hearings, orders;
  Documents; Notes, tasks and manual deadlines; linked clients); Add case by CNR, court search or by hand;
  `PATCH /v1/matters/{id}` for tracking on/off.
- P1 Today and Tomorrow's Board ([ADR 0014](docs/adr/0014-p1-today-board.md)): Today in India time with the hero
  card (next open matter), Today by court with clashes, tasks due, new orders, needs attention, evening switch to the
  Tomorrow banner (`app_config.today_evening_switch`, default 18:30), pull-to-refresh / F5; Tomorrow's Board (kit
  table, clash explanation, Assign to and Mark proxy arranged with Undo for owners and advocates, the clash rule
  re-applied on the device and offline, share as text or image with titles opt-in); `/cases/:id` placeholder.
- P1 onboarding ([ADR 0013](docs/adr/0013-p1-onboarding.md)): role, join by code, advocate details, "Finding your
  cases" with live progress and cancel, Found cases (Add all / select, groups, filters, transliteration search,
  allowance, Windows keys, selection kept across restarts), Add by CNR sheet, notification explainer; account and
  current-org state, error texts in both languages, session cleanup on every sign-out path.
- Phase 0 Track A: see [phase-0-report.md](docs/phases/phase-0-report.md).

## In progress
- Nothing running. On hold by founder (24 Oct 2026): Track B accounts (P0 tasks 12–15, P1 tasks B0–B5), native-speaker
  Hindi review, privacy-policy page.

## Next up
1. P2 Track A tasks 2–14 in order ([phase-2-plan.md](docs/phases/phase-2-plan.md)); next is task 2, the `legal_ai`
   core.
2. iOS (P2): NSCameraUsageDescription and NSFaceIDUsageDescription in Info.plist.
3. Phase 0 and 1 gates: Track B (on hold); see [phase-1-report.md](docs/phases/phase-1-report.md).

## Deviations from spec (with ADR links)
- Kit: 5 P2-only components deferred to P2 start — [ADR 0001](docs/adr/0001-defer-p2-kit-components.md).
- Local backend on Docker Desktop from the Windows checkout, not inside WSL2 — [ADR 0002](docs/adr/0002-backend-dev-on-docker-desktop.md).
- Supabase local ports moved to 553xx: Windows reserves 54236–54335 on this machine.
- Phosphor icons from vendored fonts; `phosphor_flutter` no longer builds — [ADR 0007](docs/adr/0007-vendored-phosphor-icons.md).
- Rich-text editor: flutter_quill, not appflowy_editor (does not build on Flutter 3.47) — [ADR 0004](docs/adr/0004-rich-text-editor.md).
- Riverpod without the code generator, and no freezed/json_serializable yet: P0 has no data models. Add them with the P1 data layer.
- Dart API client is hand-typed (spec §7.1 allows "generated or typed").
- `Idempotency-Key` handling arrives with the first job/money/message endpoint (P1 import); no P0 POST needs it.
- Contrast is enforced on tokens (exact); Flutter's pixel-sampling contrast guideline misreads thin anti-aliased glyphs and is not used.
- iOS `hi.lproj/InfoPlist.strings` is generated but not yet registered in the Xcode project (needs the Codemagic/iOS build, Track B).
- Feature flags are compiled-in (all off) until PowerSync syncs `feature_flags`.
- Wrong-OTP lockout (spec §15.2) is enforced in the app, backed by Supabase's code expiry and per-IP verify limit; Supabase phone OTP allows no server-side per-number count — [ADR 0008](docs/adr/0008-otp-lockout.md).
- Phase 1 started before the Phase 0 gate closed (founder go-ahead, 24 Oct 2026); both gates wait on Track B.
- P1 schema additions to §9.2 and how §9.3 column rules are enforced — [ADR 0009](docs/adr/0009-p1-schema-additions.md).
- Court data: no "manual provider" class — manual tracking is `matters.tracking = 'manual'` plus manual hearings, which
  workers skip; LegalKart joins the router when keys exist (Track B). Contract tests run on a synthetic stand-in until
  spike 11e records real responses; section equivalents join the interface with the P3 law converter.
- Search keys use a small shared romanisation table in Python and Dart instead of `indic-transliteration` (§7.2): the two
  sides must give identical keys, which one table guarantees. `indic-transliteration` stays available for display needs.
- Sync runs on the PowerSync open edition (FSL) for development and CI only; production hosting (India Cloud region,
  or self-hosting as an approved FSL exception) waits for the founder. On-device encryption waits for spike 11b; until
  then OS storage encryption plus the app lock — [ADR 0010](docs/adr/0010-local-sync-powersync.md).
- Signed upload URLs last Supabase's fixed 2 hours, not the 5 minutes §15.5 sets for signed URLs; each is bound to one
  new path and can't read or overwrite. Download URLs are 5 minutes — [ADR 0011](docs/adr/0011-p1-api.md).
- Case search takes no Idempotency-Key (read-only, cached 24 h, rate-limited); order PDF URLs are a GET per §10.2,
  guarded by a lock and the shared file cache. Court-data webhooks wait for LegalKart keys (Track B).
- Workers: no free "available dates" call, so cause lists are retried per CNR; the weekly sweep is fortnightly (no
  change signal); one budget threshold per budget instead of §11.8's staged pause order; expected slots and clashes
  are a documented heuristic — [ADR 0012](docs/adr/0012-p1-workers.md).
- Found cases rows show status as text, not a StatusPill; the allowance message has no "see plans" link until P3;
  notification permission through a method channel instead of a plugin — [ADR 0013](docs/adr/0013-p1-onboarding.md).
- Today/Board: clashes computed on the device (worker's `clash_group` unread), the diary skips the court-holiday
  check, "New orders" are unread `new_order` notifications, the §5.5 list stagger and check-mark draw are deferred,
  `share_plus` added for the OS share sheet — [ADR 0014](docs/adr/0014-p1-today-board.md).
- Cases: `PATCH /v1/matters/{id}` added to §10.2 for tracking on/off (devices can't change `tracking`); `POST
  /v1/matters/manual` still takes no Idempotency-Key — [ADR 0015](docs/adr/0015-p1-cases.md).
- Documents: `desktop_drop` stays on 0.8.4 until `file_picker`/`share_plus` accept `cross_file` 0.4; `open_filex` hands
  Word files to another app on Android; auto-kept orders are the latest per case on today's and tomorrow's diary —
  [ADR 0016](docs/adr/0016-p1-calendar-clients-docs.md).
- Team: `GET`/`DELETE /v1/orgs/{id}/invites` added to §10.2 (invites aren't synced and hold a seat for 7 days); no
  SMS is sent with an invite until messaging (Track B); "urgent alerts may break quiet hours" is a device setting;
  local notifications stand in for push until FCM (Track B) — [ADR 0017](docs/adr/0017-p1-team-notifications.md).
- Phase checks: reduce motion shows sheets without animation rather than §5.5's 100 ms cross-fade; haptics Flutter
  fires itself (pickers, text selection) follow the phone's setting, not the app's; the Devanagari digits setting, the
  Found counter flight and Windows keep-running-in-tray are deferred; end-to-end tests run locally on Windows, not in
  CI — [ADR 0018](docs/adr/0018-p1-phase-checks.md).
- P2 schema additions to §9.2 (shared court-order chunks, `calendar_feeds`, client-message approval in the database)
  — [ADR 0019](docs/adr/0019-p2-schema.md).
- Phase 2 started before the Phase 1 gate closed (founder go-ahead, 26 Oct 2026); both earlier gates wait on Track B.
- Windows `APPLY_STANDARD_SETTINGS` defines `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS`: `local_auth_windows` 2.0.2 builds with `/await`, which MSVC 14.51 rejects (STL1011). Remove when the plugin moves to C++20 `<coroutine>`.

## Questions for the founder
- Before production (Track B): PowerSync Cloud in an India region, or self-host the FSL open edition on AWS Mumbai as
  an exception to hard rule 7? See [ADR 0010](docs/adr/0010-local-sync-powersync.md).

## Pinned versions
Flutter 3.47.7 · Dart 3.13.5 · Python 3.14.6 · uv 0.11.26 · Node 24.17 · Supabase CLI 2.122.0 · Postgres 17 · Redis 8 ·
FastAPI 0.161.1 · Pydantic 2.14.1 · SQLAlchemy 2.1.6 · asyncpg 0.32.0 · Celery 5.6.3 · PyJWT 2.15.1 · structlog 26.1.0 ·
ruff 0.17.2 · pyright 1.1.414 · pytest 9.1.1 · flutter_riverpod 3.4.3 · go_router 18.1.1 · supabase_flutter 2.18.3 ·
dio 5.11.1 · local_auth 3.0.2 · flutter_secure_storage 11.2.0 · animations 3.0.0 · window_manager 0.5.2 · intl 0.20.3 ·
very_good_analysis 11.0.0 · flutter_quill 11.6.0 (P4) · pdfrx 2.10.1 · share_plus 13.3.1 · cunning_document_scanner 3.0.4 · file_picker 13.2.0 · desktop_drop 0.8.4 ·
open_filex 5.0.0 · flutter_local_notifications 22.3.2 · powersync (Flutter SDK) 2.5.0 · PowerSync Service 1.27.1 (local/CI)
