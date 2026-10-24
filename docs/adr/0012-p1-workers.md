# 0012 — Phase 1 workers: board heuristics, budgets, event keys and schedule deviations

Status: accepted (24 Oct 2026)

## Context
P1 task 6 adds the Celery workers (`services/workers`): the §11.5 schedule, change detection and fan-out (§11.6),
notifications (§13), Tomorrow's Board (§4.2), the upload scan (§4.3) and the jobs the API enqueues (ADR 0011).
§4.2 asks for the clash heuristic in an ADR, and §11.5 asks for any fallback the provider forces to be recorded.

## Decision
**Expected slots and clashes** (`board.py`, fixtures in `config/fixtures/board_clash.yaml`). A slot is the court
level's session start plus a fixed time per item, skipping lunch (`SITTINGS`: SC and HC from 10:30, District Courts
from 11:00, 3–5 minutes per item). A non-numeric item ("S-12"), an unknown court level or an item past the sitting
gets no slot and is never flagged. Two entries clash when they are in different court complexes, their windows (slot
to slot + 60 minutes, `CLASH_WINDOW_MIN`) overlap, the same person appears and neither has a proxy arranged. An
unassigned entry is the organisation's advocate, its owner, so the owner assigned to one entry and an unassigned one
are the same person. Connected clashes share a group, numbered by earliest slot. The sitting times and the window are
DRAFT – VERIFY rows in `docs/legal-verification.md`. A matter is on the board on a court day for its court (not a
Sunday, not a VERIFIED holiday) unless the court published a list for it that day.

**Budgets (§11.8)** use one threshold per budget instead of the staged pause order:
- Global daily cap reached: everything pauses except `cause_list_tomorrow` and the first `post_hearing_refresh`.
- An organisation's monthly budget reached: its own jobs pause (`advocate_watch`, on-demand refresh, find-cases,
  auto-match, fetch-cases), with `COURT_DATA_BUDGET_REACHED`.
- `post_hearing_retry_2` and the order pipeline (platform-costed) skip a CNR when every organisation tracking it is
  over budget.
- Budgets are checked before each paid call. 80% and 100% are logged once per day per scope (the admin and founder
  alert until the P3 admin view and Sentry).

Organisation-initiated calls are costed to the organisation; shared scheduled fetches are platform rows (§11.8).

**Event keys** are `(cnr, event, value)`, stored per user in `notifications.data->>'event_key'` under a unique index,
so a retried fan-out never notifies twice. The first fetch of a CNR is the baseline and produces no events. The
evening board message has one key per organisation and date: later attempts rewrite it only when it changed, and an
emptied board takes it back. `data.collapse_key` lets the app replace rather than stack (§13.2).

**Court sittings** are one per case and date (`court_hearings` unique on `cnr, hearing_date`). A corrected purpose
updates the sitting in place, so diary hearings and their user notes stay attached. A date the provider no longer
lists is removed and the diary hearings copied from it are soft-deleted, except one a member wrote on (note, outcome,
own date or purpose, confirmed), which stays as a hearing of its own. An empty history is never treated as every
sitting withdrawn. Change detection locks the CNR's tracking matters before it touches a diary row, the order
`delete_matter` uses, so the two never deadlock.

**Schedule deviations (§11.5)**
- The provider interface has no free "available dates" call. Attempt 1 checks every tracked CNR whose court next date
  is tomorrow; attempts 2 and 3 check only those still without a listing.
- eCourtsIndia gives no change signal, so the weekly sweep refreshes a CNR at most fortnightly (13 days). It also
  takes every tracked CNR that was never fetched (an import that failed or paused part-way) and CNRs whose status the
  provider didn't name.
- `post_hearing_retry_2` leaves out CNRs heard again that day: `post_hearing_refresh` fetches them at the same 19:30.
- The beat's tasks run on their own `scheduled` queue and worker (`worker-scheduled` in `infra/docker/compose.yml`),
  so uploads and user jobs never delay the evening board.

**advocate_watch** is behind the `advocate_watch` feature flag (default off) until spike 11e shows the provider's
cause-list search filters by advocate and date. Each advocate member is searched in their practice courts: the one
court when there is one, else their state. A member with no practice courts and no Bar Council state is skipped. A
listing counts as early only before the court next date (or with none), not after a past one. If spike 11e rules the
filter out, paid plans run `auto_match` daily instead and early-listing alerts are not offered (§11.5).

**Find my cases** accepts the Bar Council state as a code ("MP") or a name ("Madhya Pradesh", the onboarding default).
With no court the provider can search, the job fails with `NO_SEARCHABLE_COURTS` instead of reporting nothing found.
Honorifics are dropped by the word as written, never by its phonetic key ("Dhar" and "Dr" share one).

**Job safety.** A fetch-cases job records a CNR the provider rejects (`failed`, with the code) or doesn't know
(`not_found`) and goes on; only retryable errors retry the task. A job whose user is no longer an active member of
its organisation fails with `NOT_A_MEMBER` before it runs. Fan-out locks the tracking matters first, so a concurrent
`delete_matter` waits for it and then soft-deletes what it wrote.

**Upload scan.** clamd runs with `AlertExceedsMax`, so a file past a scan limit (archive entries, nesting, size,
`MaxScanTime`) is a `FOUND` verdict and is quarantined, not passed as `OK`. The worker waits longer than
`MaxScanTime` for the verdict. No verdict after the whole file was sent fails the job at once (the document stays
pending); only connection failures retry. Production clamd needs the same settings.

## Consequences
- New error codes `NO_SEARCHABLE_COURTS` and `NOT_A_MEMBER` (on jobs) need Hindi and English text in the app.
- `STATE_CODES` (find.py) lists only states with seeded courts; adding a state's courts (P7) adds its names there.
- Production runs two worker processes: the default queue and `-Q scheduled`.
- The board heuristics change together in `board.SITTINGS`, the fixture file and `docs/legal-verification.md`.
