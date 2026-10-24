# PROJECT_STATE
Current phase: 1 — Court diary MVP (status: building; started 24 Oct 2026 with the Phase 0 gate open, Track B on hold)
Last updated: 2026-10-24

## Done (this phase)
- Plan: [phase-1-plan.md](docs/phases/phase-1-plan.md) (Track A local, Track B on hold).
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
- Phase 0 Track A: see [phase-0-report.md](docs/phases/phase-0-report.md).

## In progress
- Nothing running. On hold by founder (24 Oct 2026): Track B accounts (P0 tasks 12–15, P1 tasks B0–B5), native-speaker
  Hindi review, privacy-policy page.

## Next up
1. P1 task 6: workers (find-cases, fetch and refresh, schedules, diff and fan-out, Tomorrow's Board, document scan).
2. P1 task 7: onboarding rest and Found cases.
3. P1 task 8: Today and Tomorrow's Board screens.

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
- Windows `APPLY_STANDARD_SETTINGS` defines `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS`: `local_auth_windows` 2.0.2 builds with `/await`, which MSVC 14.51 rejects (STL1011). Remove when the plugin moves to C++20 `<coroutine>`.

## Questions for the founder
- Before production (Track B): PowerSync Cloud in an India region, or self-host the FSL open edition on AWS Mumbai as
  an exception to hard rule 7? See [ADR 0010](docs/adr/0010-local-sync-powersync.md).

## Pinned versions
Flutter 3.47.7 · Dart 3.13.5 · Python 3.14.6 · uv 0.11.26 · Node 24.17 · Supabase CLI 2.122.0 · Postgres 17 · Redis 8 ·
FastAPI 0.161.1 · Pydantic 2.14.1 · SQLAlchemy 2.1.6 · asyncpg 0.32.0 · Celery 5.6.3 · PyJWT 2.15.1 · structlog 26.1.0 ·
ruff 0.17.2 · pyright 1.1.414 · pytest 9.1.1 · flutter_riverpod 3.4.3 · go_router 18.1.1 · supabase_flutter 2.18.3 ·
dio 5.11.1 · local_auth 3.0.2 · flutter_secure_storage 11.2.0 · animations 3.0.0 · window_manager 0.5.2 · intl 0.20.3 ·
very_good_analysis 11.0.0 · flutter_quill 11.6.0 (P4) · pdfrx 2.10.1 (P1) · powersync (Flutter SDK) 2.5.0 · PowerSync Service 1.27.1 (local/CI)
