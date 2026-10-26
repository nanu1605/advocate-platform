# Phase 1 — Court diary MVP: interim report (Track A)

Date: 26 Oct 2026. Track A, tasks 1–12 of [phase-1-plan.md](phase-1-plan.md), is done and merged, and the gate exceptions
are decided (below; the founder delegated the call). The full gate is **not** reached: Track B (production, live providers, push,
store accounts, beta users) is on hold with the founder's accounts. On 26 Oct 2026 the founder started Phase 2 with
this gate still open, as Phase 1 started with Phase 0's.

## Exit criteria (spec §17 Phase 1)

| Criterion | Status | Evidence |
|---|---|---|
| First case on screen ≤ 60 s from OTP (median, 10 users); senior advocate completes import → tomorrow's matters → add next date → open last order, unaided; SUS ≥ 70 | **Not started** (Track B) | The whole path runs end to end locally: `onboarding_import_test` signs in, saves details, finds cases, adds all and reads tomorrow's diary. Timing and SUS need the usability rounds with real users |
| ≥ 95% of next dates correct within 24 h (50 cases, 2 weeks) | **Not started** (Track B) | Change detection, fan-out and refresh schedules are tested on synthetic fixtures (106 worker tests). Accuracy needs the live provider |
| Tomorrow's Board by 19:00 for ≥ 95% of eligible cases, 10 court days | **Not started** (Track B) | Schedules 18:30/20:30/22:00 IST and the board build are tested; delivery needs production |
| Offline create/edit of notes, tasks and manual hearings syncs without loss | **Pass** (automated, local); manual device check Track B | `integration_test/sync_test.dart`: 13 offline writes through the app's own writers, a restart, reconnect; exact Postgres rows, nothing refused, a server edit made meanwhile kept, rows back on a fresh device. Data-layer SQL tested against a real PowerSync database |
| Team: clerk joins by code, sees board and documents, no fees or private notes; assignment on the assignee's board | **Pass** (automated, local) | `test_team_flow.py`: invite and accept by code on an open sync stream; the clerk gets the board entry, document, matter and team note only; the owner's assignment reaches the advocate's board, the clerk's is refused. pgTAP for every role; 22 sync leakage tests. P1 has no fee tables (fees are P3), so "no fees" is vacuous until then |
| Crash-free ≥ 99.5%; cold start and scroll budgets on the low-end Android | **Not started** (Track B) | Needs Sentry, beta telemetry and the low-end device |
| Provider spend per case within ±30% of §11.9 | **Not started** (Track B) | Cost ledger and budget caps tested; spend needs live calls |
| RLS, trigger and sync leakage tests pass | **Pass** | 1019 pgTAP assertions; sync leakage tests as six real users; API-as-user isolation |

**Gate rule (§17).**
- **§4 acceptance criteria for the P1 features:** every criterion Track A can meet has a test that asserts it (task 12
  audit, 160 items mapped to code and tests). What remains is in Gate exceptions and Track B below.
- **§5.13 UX targets** that need users or devices are Track B (first case ≤ 60 s, senior advocate unaided, cold start
  and scroll, download size, SUS). "Next date in ≤ 3 taps" is not counted yet: the date picker adds taps, so
  count it in usability round 1.
- **Backup restore drill:** Track B (production).

## Phase checks (task 12)
- **Every screen, in one sweep** (ADR 0018): 80 scenes (every route, the lock overlay, the calendar views and 37
  sheets and dialogs) × en/hi × 360 × 800 phone and 1024 × 640 window × 100% and 200% text. No overflow or exception,
  48 dp tap targets and labelled targets throughout; shell screens also offline. A guard fails the build when a route
  has no scene.
- **Goldens** for every scene and kit section: light/dark/sunlight × en/hi × 1.0/2.0, 960 images, stable on two runs.
  Reviewing them at 200% found five layout bugs, all fixed.
- **Accessibility** (§5.9): a visible 2 dp keyboard focus ring; announcements that reach Windows Narrator (which
  ignores live regions); sync completion said once; every form error inline and announced once; reduce motion and
  haptics off honoured; the OTP timer reads in seconds and says when Resend is ready; colour tokens, including the
  focus colour, pass contrast in all three themes. Reading order on Today is tested in both languages.
- **Pseudo-locale** (§16.4): the widget suite with English 40% longer passes; CI fails on overflow.
- **Offline**: every shell screen renders under the banner; on the case page a next date, a note and a task still
  save and the online-only actions say they need a connection; the notification centre, preferences, client edits
  and documents work offline.
- **End to end against the local stack** (Windows, `just test-e2e`; not in CI, which has no Windows stack):
  offline sync, onboarding → import → Today, and the team join flow (pytest). Runs on 26 Oct 2026: see Test totals.
- **Mutation check**: 63 deliberate breaks of the new code, each caught by a failing test (9 weak tests were
  strengthened until they did).
- **Fixes found on the way**: manual deadlines now send `deadline_due` reminders (3 days, 1 day, the day); a tray
  notice goes when its alert is deleted, leaves the window or is read elsewhere; text limits count code points like
  the API (a long Hindi feedback note was refused); the Found-for-you count shows as a badge on Cases; dashboard
  counts use Indian grouping; the local beat container starts again.

## Test totals (local, 26 Oct 2026)
- pgTAP: 1019 assertions pass (RLS for five actors × CRUD on every table, every trigger, workers' SQL).
- pytest: 298 pass: API (incl. the team join flow against PowerSync), workers (incl. `deadline_due`), court_data
  contract and router tests, shared search keys, the LLM guard.
- Flutter: 1276 unit and widget tests pass (the screen sweep alone is 353); 960 goldens pass, stable on two runs;
  the pseudo-locale run passes 932 widget tests; `flutter analyze` clean.
- End to end on Windows against the local stack (`just test-e2e`): `sync_test` 3 pass (incl. offline notes, tasks
  and hearings), `onboarding_import_test` 1 passes; each also passed twice back to back.
- ruff, ruff format, pyright, brand-sync, seed-sync and contrast (0 failures) checks clean; Android and Windows debug
  builds succeed.
- At the start of task 12: 874 Flutter tests, 552 goldens, 537 pseudo-locale tests, 294 pytest.

## Gate exceptions (decided 26 Oct 2026)
1. Material's own destinations (NavigationRail, NavigationBar, TabBar, popup menu items, SegmentedButton) showed only
   the focus tint, not the 2 dp ring (§5.9). **Fixed**: `DestinationFocusRing` wraps the app's navigator and draws the
   ring 2 dp inside whichever of them has keyboard focus, menus included, under the same focus-visible rule as the
   other rings (`a11y_test`).
2. Haptics that Flutter fires outside the theme (date and time pickers, long-press text selection) still vibrate with
   haptics off. **Accepted**: they go through the OS haptics API, which follows the phone's own haptics setting; the
   app's switch covers everything the app itself fires. Revisit if a beta tester reports it.
3. With reduce motion on, bottom sheets appear without any animation rather than the §5.5 100 ms cross-fade, which a
   bottom sheet can't do. **Accepted** as the reading of §5.5: reduce motion means no movement, and no animation is
   the closest a sheet gets.
4. **Deferred**: the Devanagari digits setting (§5.10, optional) until a beta tester asks or P7's languages; the Found
   cases counter that flies to the Cases tab (§5.5) until usability round 1 shows the badge isn't enough; keeping
   Windows alerts running from the tray after the window closes (§5.12, optional) until the Windows beta asks.
5. Provider down during the first search says "We'll keep looking and notify you": later matches arrive as the Cases
   badge and in Found for you, not as a push (§13.1 has no kind for it). **Accepted**; revisit with FCM push (B3).

## Known issues
- A PostgREST or Postgres error outside the permanent set (e.g. an unknown column after a schema change) retries
  forever and holds every later upload. The schema-parity test guards against it; a `sync_issue` after N retries would
  make it visible.
- PDF text selection is built (pdfrx) but not yet checked by hand on the Windows build.
- In sunlight the rail's New button and selected indicator have no visible container.
- The ≥ 8 dp spacing between targets has no automated check; it is part of the manual pass.
- A morning the beat misses isn't caught up for deadline reminders.

## What shipped
See `PROJECT_STATE.md` → Done.

## Deviations
See `PROJECT_STATE.md` → Deviations (ADRs 0009–0018). Contrast is checked exactly on the tokens rather than by
Flutter's pixel-sampling guideline, which misreads anti-aliased glyphs; Android's 48 dp target check implies iOS's 44 pt.

## Track B — what the gate still needs (on hold)
- **B0 production:** Terraform prod, Supabase Pro Mumbai with PITR, PowerSync hosting in India (founder decision),
  live keys with a daily cap, Sentry; the restore drill.
- **B1 eCourtsIndia live:** spike 11e on 20 MP CNRs (replaces the synthetic fixtures), terms ADR, `advocate_watch`.
- **B2 LegalKart** fallback; **B3 FCM push** on Android; **B5 OTP** over WhatsApp or DLT SMS.
- **B4 beta operations:** Play closed testing, signed Windows installer (Partner Center), feedback triage.
- **Checks on devices:** manual TalkBack, VoiceOver and Narrator pass; offline on Android and Windows; local
  notifications and tray clearing on a real phone and PC; pdfrx with 100+ page scans on the low-end Android; cold
  start, scroll and download size.
- **Invite links** opening the app need the app-link domain.

## Founder actions needed
1. On hold since 24 Oct 2026: the Track B accounts (spec §18) and the PowerSync production hosting decision.
2. Before the beta: the native-speaker Hindi review of all P0–P1 strings, the privacy policy page, this year's MPHC
   and Indore district court holiday calendars (verified), a check of the court list, and the beta cohort for
   usability rounds 1–2.
3. ~~Decide the gate exceptions above~~: done 26 Oct 2026.
