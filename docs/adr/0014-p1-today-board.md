# 0014 — Phase 1 Today and Tomorrow's Board

Status: accepted (24 Oct 2026)

## Context
P1 task 8 builds Today and Tomorrow's Board (spec §4.2) on the synced database. The worker already builds
`board_entries` after the evening cause-list check and flags clashes (ADR 0012). These choices fill the gaps the
spec leaves for the app.

## Decision
**India time.** "Today", "tomorrow" and the evening switch are IST (UTC+05:30) whatever zone the device is in, from
the one testable clock (`lib/core/clock.dart`). "Now" ticks on each whole minute, so 18:30 and midnight switch on
time, and is re-read when the app resumes, because Dart timers stop while a phone sleeps.

**Evening switch time** comes from `app_config` key `today_evening_switch` ("HH:MM", IST), default 18:30 when the
key is missing or malformed. No migration: the row is optional.

**The diary for a date** is one local query, used by Today and the board: live matters of the org that are on the
board that day, on that day's cause list, auto-tracked with that court next date, or manual with a live hearing
that day. That mirrors the worker's `build_board`, so tomorrow's matters show before the evening build (without
item numbers). Item numbers come from the board entry, else the cause list, else the hearing. It skips the worker's
court-holiday check.

**Clashes are computed on the device** from the day's current rows with a Dart port of `board.clashes` and
`clash_groups` (same rule, same 60-minute window, tested against `config/fixtures/board_clash.yaml`). Assign to and
Mark proxy arranged then re-apply the rule at once and offline; the worker's `clash_group` column isn't read.

**Writes** (assignee, proxy arranged, task status, notification read) are local updates of only the columns the
server's `device_columns` triggers accept, uploaded by sync; a refused write is dropped and the server row returns.

**Hero card** is "the next matter" (spec §4.2): of today's entries whose estimated window (slot + 60 minutes) hasn't
ended, the one with the earliest slot; an entry without a slot never counts as ended and comes after those with one;
ties keep diary order. Taking the first open entry in diary order instead would show a later matter in a complex
listed first (MPHC item 50 at 13:46) while one in another complex is on now (District Court, 11:00–12:00).

**Needs attention** rules run in Dart over rows the query returns (one item per case; a court/user date mismatch
wins over "No next date"). "New orders" are unread `new_order` notifications, not a scan of `orders`.

**The data layer's SQL is tested against a real on-device database**: PowerSync's build hook bundles its SQLite
extension, so `flutter test` opens a temporary database with the app's schema.

**Today refresh** (pull-to-refresh, F5): one `POST /v1/matters/{id}/refresh` per auto-tracked matter on today's
diary, three at a time, each with its own Idempotency-Key. `RATE_LIMITED` (refreshed in the last 6 h) counts as up to
date and manual or untracked cases are skipped, so the user sees one summary ("Checking 4 cases with the court" or
"Already up to date"). When sync reports offline, no call is made. F5 is a `HardwareKeyboard` handler while Today is
the top page and the app isn't locked (the lock screen covers Today without changing its route), because the shell
holds keyboard focus until the user tabs in. While a refresh runs, Today says "Fetching from court…" on screen. On Windows, Today is a centred column
720 dp wide rather than two panes.

**Board share** uses `share_plus` 13.3.1 (BSD-3-Clause), the one new dependency: neither Flutter nor an existing
dependency opens the OS share sheet, and it shares text and files on Android and on Windows 10 1809+ (older Windows
gets text by e-mail and a "couldn't share" message for the image). The shared text is a pure function: the date,
then per court the case numbers with court and item numbers. Titles only behind "Include case titles" (off); never
clients or assignees; a manual case with no number or CNR (labelled by its title) shows as "Case without a number".
The image is the on-screen preview captured as a PNG, so it is exactly what the text says. The app writes it itself
to one folder, `<temp>/board_share/board-YYYY-MM-DD.png`, built with the platform's separators: given bytes alone,
share_plus writes a new `<temp>/<uuid>/` folder per share and never deletes it, and on Windows that path mixes `\`
and `/`, which the WinRT share API can't open (the image silently goes missing). The folder is emptied before each
image share and at sign-out (`Session.forget`), since an image may carry case titles.

**Board actions** (Assign to, Mark proxy arranged) show inline on clash rows and in every boarded row's menu, only for
owners and advocates. Both have a 5 s Undo; Assign to's puts back the previous assignee, or no one (the sheet
can't pick "unassigned", which falls to the owner for clashes). When an action clears the clash its buttons go, and keyboard focus returns to the row's menu
(the focus scope's history), so Tab carries on from that row. The board's date sits under the app bar rather than in
it, so 200% text can't cut it off. On phones a row names the client and the assignee ("Client: …", "Assignee: …"),
which the desktop table does with column headers. Today's list is the same kit `BoardTable`, so it shows the same
clash note and "Proxy arranged" state. The kit `BoardTable` desktop layout is a column of flex rows rather than a `Table`, so each
case is one tap target and one keyboard stop (Enter opens it).

**Motion** (spec §5.5): completing a task gives a light haptic (unless switched off in settings). The list entry
fade-and-rise and the check-mark draw are deferred to the kit's motion work; a `ponytail:` comment in
`today_screen.dart` marks it.

## Consequences
- A next date that falls on a court holiday shows in the diary although the worker leaves it off the board.
- The clash rule and window live in two places (worker and app); the shared fixture keeps them equal.
- `/board/tomorrow` always means tomorrow in IST: a `tomorrow_board` notification opened after midnight shows the
  next day's board, not the one it announced (its `board_date` is ignored). A dated board route can fix it if beta
  users hit it.
- Hindi plural `=1` branches print the count, not a literal 1: intl puts Hindi 0 in the "one" category, so
  `=1{1 पेज}` read "1 पेज" for 0. A unit test guards the ARB file.
- All new Hindi strings wait for the native-speaker review. Ask especially about `boardProxyMark` ("प्रॉक्सी की
  व्यवस्था दर्ज करें", an action, next to the state "प्रॉक्सी की व्यवस्था है"), `statusOverdue` ("तारीख निकल गई",
  for tasks), `boardNotBuiltLate` and the singular of `todayRefreshChecking`.
