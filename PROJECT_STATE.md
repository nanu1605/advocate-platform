# PROJECT_STATE
Current phase: 1 — Court diary MVP (status: building; started 24 Oct 2026 with the Phase 0 gate open, Track B on hold)
Last updated: 2026-10-24

## Done (this phase)
- Plan: [phase-1-plan.md](docs/phases/phase-1-plan.md) (Track A local, Track B on hold).
- Schema for the 26 P1 tables with RLS, write-path triggers and the beta tracked-case allowance; five reference courts;
  709 new pgTAP assertions (5 actors × CRUD + every trigger), 1009 in all ([ADR 0009](docs/adr/0009-p1-schema-additions.md)).
- Phase 0 Track A: see [phase-0-report.md](docs/phases/phase-0-report.md).

## In progress
- Nothing running. On hold by founder (24 Oct 2026): Track B accounts (P0 tasks 12–15, P1 tasks B0–B5), native-speaker
  Hindi review, privacy-policy page.

## Next up
1. P1 task 2: `court_data` package (interface, manual + eCourtsIndia providers, router, breaker, cost ledger, fixtures).
2. P1 task 3: transliteration search key (Python + Dart, 50-pair fixture).
3. P1 task 4: local sync (self-hosted PowerSync in Docker) and the Flutter data layer.

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
- Windows `APPLY_STANDARD_SETTINGS` defines `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS`: `local_auth_windows` 2.0.2 builds with `/await`, which MSVC 14.51 rejects (STL1011). Remove when the plugin moves to C++20 `<coroutine>`.

## Questions for the founder
- None open.

## Pinned versions
Flutter 3.47.7 · Dart 3.13.5 · Python 3.14.6 · uv 0.11.26 · Node 24.17 · Supabase CLI 2.122.0 · Postgres 17 · Redis 8 ·
FastAPI 0.161.1 · Pydantic 2.14.1 · SQLAlchemy 2.1.6 · asyncpg 0.32.0 · Celery 5.6.3 · PyJWT 2.15.1 · structlog 26.1.0 ·
ruff 0.17.2 · pyright 1.1.414 · pytest 9.1.1 · flutter_riverpod 3.4.3 · go_router 18.1.1 · supabase_flutter 2.18.3 ·
dio 5.11.1 · local_auth 3.0.2 · flutter_secure_storage 11.2.0 · animations 3.0.0 · window_manager 0.5.2 · intl 0.20.3 ·
very_good_analysis 11.0.0 · flutter_quill 11.6.0 (P4) · pdfrx 2.10.1 (P1) · PowerSync SDK — pending (Track B)
