# Phase 1 — Court diary MVP: plan

Goal (spec §17): "My diary runs itself." Import cases, see today and tomorrow, get alerts, keep clients and documents,
work as a small team — all of it offline. Closed beta on Android + Windows, 20–30 Indore advocates.

**Start condition.** The founder started Phase 1 on 24 Oct 2026 with the Phase 0 gate still open: Track B (accounts)
is on hold. So Phase 1 is split the same way as Phase 0. **Track A** builds everything locally, against recorded or
synthetic provider fixtures and a local sync server. **Track B** needs accounts and keys and waits for the hold to lift.
The Phase 1 gate cannot close on Track A alone: the beta, the accuracy and cost measurements and the restore drill
need production.

## Track A — local only, in order

Each row is one or more PRs; CI stays green after each.

| # | Task | Main files |
|---|---|---|
| 1 | **Schema + RLS + triggers + pgTAP** for the 26 P1 tables (spec §9.2, §17 P1); courts reference rows; tracked-case allowance; 5 actors × CRUD + every trigger | `supabase/migrations/20261024000000_court_diary.sql`, `supabase/tests/*` |
| 2 | **`court_data` package**: models, `CourtDataProvider`, manual provider, eCourtsIndia provider (from their public docs), LegalKart stub, router, circuit breaker, cost ledger; contract tests on fixtures | `packages/court_data/*` |
| 3 | **Search key** (transliteration): one algorithm in Python and Dart, 50 Hindi/English name pairs as the shared fixture | `packages/shared/.../search_key.py`, `apps/client/lib/core/search_key.dart`, `config/fixtures/translit_pairs.yaml` |
| 4 | **Local sync**: self-hosted PowerSync service in Docker (no account), Sync Streams mirroring §9.3, leakage tests; Flutter local database, upload connector, offline banner and sync indicator; local-only `found_selection` | `infra/docker/compose.yml`, `infra/powersync/*`, `apps/client/lib/data/*` |
| 5 | **API (P1 endpoints, §10.2)**: team invites/accept/members; find-cases job, found-cases add/decision; jobs get/cancel; case search, add by CNR, manual, refresh, official link, delete; document upload/complete/download URLs; order PDF URL; board; feedback; `Idempotency-Key` | `services/api/src/advocate_api/routes/*` |
| 6 | **Workers**: find-cases (cancellable), batch detail fetch, §11.5 schedules, diff → events → fan-out, Tomorrow's Board + clash detection, budgets and caps (§11.8), window-flag jobs | `services/workers/src/advocate_workers/*` |
| 7 | **App — onboarding rest**: role, advocate details, "Finding your cases", Found cases (Add all / select / groups / filters / Windows keys / allowance), notification explainer | `apps/client/lib/features/onboarding/*`, `features/found_cases/*` |
| 8 | **App — Today and Tomorrow's Board**: hero card, sections, evening switch, board with clash, Assign to, proxy, share | `features/today/*`, `features/board/*` |
| 9 | **App — Cases and case page**: sections, transliteration search, filters, Found for you; timeline, documents, notes & tasks, client; add by CNR / search / manual | `features/cases/*`, `features/case_page/*` |
| 10 | **App — Calendar, Clients, Documents**: day/week/month/agenda; client list and profile; upload, camera capture, viewer (pdfrx), keep offline | `features/calendar/*`, `features/clients/*`, `features/documents/*` |
| 11 | **App — Team, notifications, dashboard, feedback**: invite by phone/link/code, roles, assignment; notification centre + preferences; Windows local toasts; basic dashboard; in-app feedback | `features/team/*`, `features/notifications/*`, `features/dashboard/*` |
| 12 | **Phase checks**: goldens, accessibility and 200% text for every new screen; pseudo-locale; offline tests; `phase-1-report.md` | `apps/client/test/*`, `docs/phases/phase-1-report.md` |

## Track B — on hold with the founder's accounts

| # | Task | Blocked on |
|---|---|---|
| B0 | Production: Terraform prod (separate AWS account), Supabase prod Mumbai with PITR, PowerSync prod in India, live keys with a daily cap, Sentry | AWS, Supabase Pro, PowerSync hosting decision |
| B1 | eCourtsIndia live: spike 11e (20 MP CNRs → sanitised fixtures replace the synthetic ones), terms ADR (§11.1 founder gate), `advocate_watch` decision | eCourtsIndia key, 20 CNRs |
| B2 | LegalKart as fallback provider | LegalKart keys |
| B3 | FCM push on Android | Firebase project |
| B4 | Beta operations: Play closed testing, signed Windows installer, restore drill, feedback triage | Google Play, Partner Center, production |
| B5 | OTP over WhatsApp or DLT SMS live before beta sign-ups | Meta / DLT approval |

## Defaults taken (change any of them in `app_config` or by telling me)
- **Beta tracked-case allowance:** 100 per organisation (`app_config.beta_tracked_case_allowance`), enforced by a trigger on `matters`; plan limits replace it in P3.
- **Local sync:** the open-source PowerSync service runs in Docker for development and CI. Production hosting in India stays a Track B decision (ADR at task 4).
- **Provider fixtures:** until spike 11e, contract tests use synthetic fixtures with obviously fake CNRs, marked as such. They never ship as data.
- **Court holidays:** the table ships empty. Holidays come only from the verified MPHC and Indore district calendars (founder input), never invented.

## Founder inputs (spec §17 P1)
Beta cohort; usability rounds 1–2; this year's MPHC and Indore district court holiday calendars, verified; a check of the
court list; the WhatsApp `otp_login` template and/or DLT SMS before beta sign-ups.

## Exit criteria (spec §17 P1) and where each is checked
| Criterion | Track A | Needs Track B |
|---|---|---|
| First case ≤ 60 s from OTP; unaided senior-advocate task; SUS ≥ 70 | Flow built and timed locally | Usability rounds with real users |
| ≥ 95% next dates correct within 24 h (50 cases, 2 weeks) | Diff/fan-out tests | Live provider |
| Board by 19:00 for ≥ 95% on 10 court days | Schedule + build tests | Production |
| Offline create/edit of notes, tasks, manual hearings syncs without loss | Automated against local sync | Manual check on devices |
| Team: clerk joins by code, sees board and documents, no fees or private notes; assignment shows on assignee's board | pgTAP + sync leakage + widget tests | — |
| Crash-free ≥ 99.5%; cold start and scroll budgets on low-end Android | Profile builds | Beta telemetry, device |
| Provider spend per case within ±30% of §11.9 | Cost ledger tests | Live spend |
| RLS, trigger and sync leakage tests pass | Yes | — |
