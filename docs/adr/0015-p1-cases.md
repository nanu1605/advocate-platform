# 0015 — Phase 1 Cases and case page

Status: accepted (24 Oct 2026)

## Context
P1 task 9 builds the Cases list, the case page and Add case (spec §4.3, §5.3) on the synced database. The spec
leaves the app some gaps (which next date a case has, what "Found for you" counts, how the case page turns tracking
on and off) and the API one: §9.3 forbids devices changing `matters.tracking`, but §10.2 lists no endpoint for the
case page's "Tracking on/off". This ADR records the data-layer and endpoint decisions; the screens add theirs.

## Decision
**One next-date rule** (`nextDateOf` in `lib/data/cases.dart`), used by the list, its sections, the case page and the
shared status: auto- and off-tracked cases use the court's `matters.next_hearing_date`; manual cases the earliest
live hearing dated today or later (IST). A court date before today (IST) is no next date: the court hasn't
published the next one yet, so the list files the case under "No next date" and the header, the shared status and
the spoken row say "No next date yet" rather than an old date. The query passes today in, and the case providers
re-read at midnight IST. It matches task 8's diary rule. An off-tracked case keeps its last court date while it is
today or later; the header says "Tracking off".

**Sections**: Today · This week (tomorrow to today + 6) · Later · No next date (pending with none, or a past one) ·
Disposed (court status disposed or transferred, whatever the date). Archived cases form their own section, shown only
under the status filter "Archived"; no status filter shows every unarchived case. Empty sections are left out.
"Found for you" counts the org's found cases still waiting for a decision (`decision = 'pending'`, disposed ones
included, as /found lists them) and links to /found; it is hidden at zero.

**Search** matches the case label, CNR, title and client names literally (also with spaces and punctuation removed,
so a CNR typed in groups is found), or by `searchKey` words (spec §4.3 transliteration: every query word's key must
appear in the title's or the clients' keys). Each case's search text and keys are built once per data emission, on
the first search over it, never per keystroke. Clients are found by name the same way, or by phone digits.

**Filter and sort** (court, client, status, assignee; next date, recently updated, case number with numbers
compared as numbers) live in a provider for as long as the app runs; they aren't persisted. All filtering is Dart over
one query of the org's live cases. Orgs reach about 1,200 cases, which one query and a lazy list handle; a
`ponytail:` note marks moving it into SQL if emissions get slow.

**Case page reads** are one provider per tab over the synced tables (hearings, orders with the user's read state,
documents, notes, tasks, deadlines, linked clients). Hearings show the court's value with the user's as "you noted"
where it differs (`courtWins`); the header's purpose for the next date is that day's hearing's, else the case's
stage. Private notes of other members never reach the device (sync streams); the query also checks the author.

**Local writes** go through one `CaseWriter`, each touching only the columns §9.3 lets a device change: matters
`assigned_to` and `status` (Assign to, Archive and its Undo); manual hearings inserted with `source = 'manual'`,
edited whole and soft-deleted, and `user_note` on any hearing; notes, tasks, deadlines and clients inserted,
updated and soft-deleted (`deleted_at`); `matter_clients` rows deleted to unlink; the user's own `order_reads` row
when an order is opened (once). Inserts carry a client-generated id, the org and a local `created_at` (so new rows
sort right before they sync); a note carries its author. New clients get `search_key` from the app's `searchKey`,
the same algorithm as the server's. A test against a real on-device database checks every write's columns.

**Tracking on/off: `PATCH /v1/matters/{id}` with `{"tracking": "auto" | "off"}`**, an addition to §10.2 (Cases).
All roles (§15.3 "add / edit matters"). It refuses manual matters (409 `MANUAL_CASE`) and matters without a CNR (409
`NO_CNR`); setting the value it already has is a no-op. Turning tracking on goes through the `matters_allowance`
trigger, so the allowance gives `TRACKED_CASE_LIMIT` (409, details `{limit}`) like by-cnr. It then fetches the case
with the same `fetch_cases` job by-cnr enqueues (after commit), unless the case was fetched in the last 6 hours
(`court_fetched_at`) or a refresh holds the case's 6-hour refresh claim; the fetch takes that claim, so turning
tracking off and on again doesn't fetch twice and the next Refresh says "Already up to date". No Idempotency-Key:
the call is idempotent by value, and the claim guards the fetch.

**Routes**: `/cases`, `/cases/:id` (`?tab=timeline|documents|notes|client`), `/cases/search` and `/cases/manual`,
all in the shell. On a window at least 840 dp wide, `/cases/:id` shows the list beside the case page; going to
another case keeps the same page (go_router keys a page by its route pattern), so the list keeps its scroll and only
the selection changes. On phones it is the case page alone. Ctrl+N opens Add case's chooser (By CNR, Search the
courts, Add by hand) rather than the "+" sheet (spec §5.12 "New case"); the "+" sheet's Add case, the Cases empty
state and Today's "Add your first case" open it too.

**Order and document files** open from a short-lived signed URL in the system viewer for now (the in-app viewer is
task 10).

## Consequences
- The Cases list shows archived cases only under "Archived", so an archived case with a hearing today is not in
  Today's section (Today's diary leaves archived cases out too).
- An off-tracked case's next date can be out of date while it is today or later; it is still shown and sorted by it.
- A manual case's next date moves past a hearing at midnight IST, not when the hearing ends.
- Search and filters run in Dart over every case on each keystroke (cheap per case: the keys are cached).
- The case page's tracking switch needs the network; everything else on the case page works offline.
- All new Hindi strings wait for the native-speaker review; ask especially about `casesDocPleading` ("प्लीडिंग"),
  `casesDocAnnexure` ("संलग्नक"), `casesSectionArchived` and the `updatedFromRecord` / `casesUpdatedOn` phrasing
  ("आधिकारिक रिकॉर्ड से … पर अपडेट").

## Add case screens
**Search the courts** (`/cases/search`) is one scrolling page: the form, then the results, which scroll into view
after a search; the form stays filled for the next search or a retry. The coverage note names the chosen courts the
provider can search, as they are said ("Searching MP High Court Indore + MP High Court Jabalpur…"), or "every court we cover"
when none is chosen or none of the chosen can be searched (the API then searches every court); further notes say
which chosen courts were left out (`ignored_court_ids`) and that case type and year thin out pages
(`post_filtered`). A page Load more fetched for an earlier search is dropped if a new search replaced the results. The count is the provider's total, or the hits loaded so far once a page was
thinned (the total then overstates). A hit names its court through `courts.provider_codes` (the `ecourtsindia`
code the API searches with); a code the device doesn't know shows no court. "Track this case" posts by-cnr with one
Idempotency-Key per CNR attempt (reused on retry) and opens the case; a hit whose CNR is already a case on the
device opens that case without a request, and an unsynced tracked one gets its id back from by-cnr ("already in
your list"). A case just added (by CNR, search or by hand) opens before sync has brought its row, so the case page
shows it loading for up to a minute (`addedCasesProvider`) instead of "This case was removed"; a `ponytail:` note
marks watching the sync status if slow links need longer. A notification link opened before the first sync still
reads "removed" until the row arrives. `TRACKED_CASE_LIMIT` there and in the By CNR sheet reads `casesTrackingLimit` (the server sends
`{limit}` only). A provider outage gets its own text, since `errorProviderDown` promises a notification a search
never sends. The search itself takes no Idempotency-Key (read-only, ADR 0011).

**Add by hand** (`/cases/manual`) picks a synced court or "Other court" with a typed name. "Our side" stays free text,
as the API stores it (so it reads back as typed, in either language), with "e.g. Petitioner" as the hint. The next date goes as an IST
day, and the server adds it as the first manual hearing. Fields stop at the API's lengths (`ManualIn`), so a long
title can't fail the request with a generic error. Errors are inline and read out; the court field takes
`COURT_REQUIRED`/`UNKNOWN_COURT`, anything else (offline included) shows above the pinned button. The kit's
`DateField` gained an optional controller so a form can refuse a typed date that doesn't parse (its `onChanged`
gives null for empty and invalid alike).

- POST /v1/matters/manual has no Idempotency-Key, so a retry after a lost response can add the case twice (the busy
  guard only stops double taps).
- Hindi review: `addCaseNarrowed`, `addCaseTracking` ("ट्रैक हो रहा है · खोलें") and `addCaseProviderDown`.
- Cases list: rows are the kit's compact `CaseCard`, which now shows the court and next date on one line, the
  assignee's initials, a selected state (the case open beside the list) and a spoken label; collapsible section
  headers are the kit's `SectionHeader` with `onToggle`. Filters and sort share one sheet; its courts, clients and
  assignees come from the org's cases, and past 12 clients a search box (transliterated, with the stored
  `search_key`s) narrows the client chips. Titles show up to two lines (spec §5.7); the search box's hint, its only
  label, wraps at 200% (the kit's `SearchField`). A transferred case sits under Disposed without a Disposed pill.
  When every case is archived the list says so, with Add case and "Show archived cases".
  The list's scroll lives in a `PageStorageBucket` shared by its pages, so opening the first case on a wide window
  (a new `/cases/:id` page over the first) doesn't reset the list; collapsed sections are a provider, and each
  page's search box follows the query in `caseFilterProvider`, so the page underneath matches when the user comes
  back. The case beside the list has no back arrow. The case page, beside the list or alone on a phone, is a fresh
  page per case (keyed by its id), so nothing of the last case (a refresh in flight) carries over. Up/Down use Flutter's directional focus;
  Ctrl+F is a `HardwareKeyboard` handler like Today's F5. Hindi review: `casesListSearchHint`, `casesListSortBy`
  ("क्रम").

## Case page
**One scroll view**: the header, a pinned tab bar, then the open tab's rows as a lazy list (no swiping between tabs),
so a tall header at 200% text scrolls away instead of clipping, and the tabs grow with the text. The header's pills
are Listed (next date today or tomorrow), Disposed and New order (an order the user hasn't opened); "Transferred" and
"Archived" go in the status line with "Updated … from the official record". A case with no next date says so with
Refresh (tracked) or Add date (manual), spec §5.4. The AppBar's case number shrinks rather than clips at 200%.

**Actions**: Refresh only on auto-tracked cases, through Today's `refreshMatters` (one Idempotency-Key, a recent
refresh reads "Already up to date"), also on F5. Share case status reuses the board's share path; the title is
behind "Include the case title", clients never go. Open on official portal fetches the link, copies the CNR and says
the portal may ask for a CAPTCHA before opening it outside the app. Turning tracking off asks first;
`TRACKED_CASE_LIMIT` reads `casesTrackingLimit`. Archive has Undo. Delete is offered to owners and advocates only,
asks, then goes back to `/cases`. Links open through `openExternalProvider` (url_launcher, external app), which
tests override. Assign to is the board's sheet, moved to `features/board/assign_sheet.dart`, with "No one" here.

**Tabs**: each shows a skeleton while it loads and an error with Retry if its read fails. An order is marked read
once its file link comes back, so one that couldn't open (offline, not published) stays "New". Documents still being
checked or quarantined say so without a request. Deleting a hearing, note, task or deadline takes the row away at
once with a 5 s Undo (spec §5.5) and writes the soft delete only when the snackbar closes without Undo: sync drops a
deleted row from the device within seconds, so restoring it afterwards would have nothing to update. Closing the app
in those 5 s keeps the row. Flutter now keeps a snackbar with an action until dismissed; the kit's Undo snackbar
sets it to go after 5 s, and to stay only while a screen reader is on. Unlinking a client has Undo (it links
again). Any member edits a note they can see; only its author switches it between team and
private; each note's menu is named by the note's first words. A task's due date is optional and its time more so:
a date alone is stored as midnight IST (a `ponytail:` note marks that a task really due at 12:00 am reads as
date-only), and a time without a date is refused inline. A task assigned to someone no longer in the team keeps them,
shown as "Former member".

- Kit: `SectionHeader`'s action moves under its title when both don't fit (it was a private copy in Notes &
  tasks); `showUndoSnackbar` returns its controller.
- Kit: `AppIcons.phone`; `TimelineItem`'s date column grows with the text up to 1.5× so a Hindi month isn't broken
  mid-word (the kit's timeline goldens at 2.0 changed).
- Hindi review: `casePageYouNoted` ("आपने लिखा"), `casePageDueDate` ("आख़िरी तारीख"), `casePageDeadlines`
  ("समय-सीमाएँ") and `casePageDocQuarantined`.
