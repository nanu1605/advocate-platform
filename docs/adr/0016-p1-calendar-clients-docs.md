# 0016 — Phase 1 Calendar, Clients and Documents

Status: accepted (25 Oct 2026)

## Context
P1 task 10 adds the Calendar, Clients and Documents screens (spec §4.3, §5.2) with uploads (camera scan, files,
drag-and-drop on Windows), an in-app viewer and "Keep offline". The spec says what each screen shows; it leaves the
app to decide how a hearing is counted on a calendar day, how an upload made offline waits, and what the offline
cache holds and for how long. This ADR records the data-layer, queue and cache decisions; the screens add theirs.

## Decision
**Calendar** (`lib/data/calendar.dart`). One range query per type over the synced tables, all IST days:
- *Hearings*: live hearings rows (court and manual) dated in the range, one per case per day (the court's row before
  a manual one), plus the court next date of auto- and off-tracked, unarchived live cases with no hearings row that
  day. Manual cases count only their rows (their `next_hearing_date` is the court's, which they don't have). An
  archived case's rows still show, as its history; its court next date doesn't, as on Today. Each item carries the
  case as a `DiaryEntry`, so the calendar orders a day's hearings like task 8's diary and reuses its row text.
- *Deadlines*: live, `active` or `done` (proposed and dismissed ones are not the user's yet, or any more).
- *Tasks*: live, `open` or `done`, by the IST day of `due_at`. Timestamps arrive in more than one text form, so the
  SQL takes a day either side and Dart keeps the exact days.
- A day lists hearings, then deadlines (active first), then tasks (open first, by time). Views filter by type
  themselves. Weeks start on Monday (courts list Monday to Saturday); the month grid is whole weeks around the month
  (four to six rows). No calendar package: lists and one grid.

**Clients** stay with task 9's code in `cases.dart` (one `ClientInfo`, one `CaseWriter`), extended with the profile
fields, a live case count (archived cases count, deleted ones don't), one client, and its linked cases (its
`matter_clients` rows over the cases list, so linked cases look like the Cases list's). Writes: create and edit whole
(`search_key` follows the name), WhatsApp opt-in (on records `whatsapp_opt_in_at`; off clears both), soft delete
(links stay; every read joins live clients, so the case page stops showing a deleted one). Phones are stored as `+91`
and 10 digits from what was typed (with or without +91, 91 or 0); `tel:` is built from the digits.

**Documents.** `CaseDocument` (task 9) now carries its case, the user's Keep offline and whether a copy is on the
device; the org's list, one document and a case's documents share one query. Keep offline writes the user's own
`document_offline_prefs` row (on inserts or sets 1, off deletes it). Rename, re-file and soft delete write only the
columns §9.3 allows. Before anything is copied or sent, a picked file must be PDF, JPG, PNG or DOCX by extension
*and* by its first bytes (DOCX as a ZIP whose first entry is an Office package part, so a renamed .zip or .apk is
refused; a renamed .xlsx still passes), and 1 byte to 50 MB. A dropped folder is the wrong type; a file that can't
be read is said so.

**Upload queue** (`upload_queue`, local only; `Uploads` in `lib/data/document_files.dart`). Every upload, online or
not, is copied into `<support>/uploads/` and queued, so one made offline (or interrupted) keeps its file until sent.
A drainer sends one item at a time, oldest first, on app start, on reconnect and after each enqueue:
POST upload-url → PUT the bytes → POST complete with `Idempotency-Key` = the queue item's id (reused on every
retry). Each step is recorded (`document_id`, `upload_url` and its expiry, `uploaded`), so a restart resumes after
the last step done. An upload URL within 15 minutes of its 2 h expiry, or refused by storage, is replaced before the
PUT, and the old attempt's documents row is soft-deleted (it would otherwise show "being checked" for ever). A PUT
that storage says is already there counts as sent; `UPLOAD_MISSING` from complete sends the file again;
`ALREADY_COMPLETE` counts as done. Retryable failures (offline, 5xx, rate limit, a session being refreshed) stop the
queue and retry after 15 s, doubling to 15 minutes, or at once when the device reconnects. Anything else (wrong type,
too large, the case deleted, the copy gone) marks the item failed with its code, for the user to Remove, and the queue
goes on. The copy is deleted once complete succeeds; the synced documents row (hidden while its queue item exists)
then takes over, showing the safety check. Progress is in memory, in whole percents, and the item being sent has an
entry from its first step (upload-url), so the lists show it as uploading, without Remove; Remove re-checks after
its read, and the drainer re-checks the row once it has claimed it, so a removed item is never sent. A copy that
can't be made (a full device) is `SAVE_FAILED` and leaves nothing behind; in the upload flow each file fails on its
own, and the scanner's and picker's copies are cleaned up however the flow ends.

**Offline cache** (`offline_files`, local only; `OfflineFiles`). Files live in `<support>/offline/<id>.<ext>`.
The viewer opens the cached copy, else downloads through the signed URL (streamed to `<file>.part`, renamed when
complete, cancellable) into the cache; either way it is "opened". The keeper keeps:
- the user's Keep offline documents that are ready;
- the last 10 files opened (in the current org), of documents and orders still live;
- the latest order of each case on today's and tomorrow's diary (task 8's rule, IST): its court copy, else its
  uploaded document.

It runs while the shell is up and the device online: at start, on reconnect, when the kept set changes (a Keep
offline toggle, a document becoming ready, a new order, the diary at the IST day change). The keeper waits for a
fresh kept set, and the set for both days' diaries (a set or diary that is reloading, e.g. as the account loads
at start, still holds its old list), so a start never deletes the kept files only to fetch them again. It deletes cached files
outside that set, never one open in the viewer (a file another app holds keeps its row for the next run), sweeps
files the index lost (a crash mid-download), then fetches missing kept files one at a time, stopping when offline or
the device is full and skipping any not ready yet. The bound is therefore Keep offline + 10 + one order per case
listed today or tomorrow; there is no byte quota in P1. Once the account has loaded in no organisation (left or
removed), the cache and the upload queue are emptied, online or not.

The viewer and the keeper share a download of the same file: each follows its progress, the viewer's Cancel drops
it out, and the download stops when no one is left waiting. Transfers use a client with a 15 s connect timeout and
a 60 s wait for a response, and a 60 s idle watchdog on the bytes (dio's timeouts don't cover a body that stalls
part-way), so a stalled PUT or download fails as `NETWORK` and the queue or keeper moves on. A download the device
can't store is `SAVE_FAILED` (said as such, never as offline).

**Signed URLs and privacy.** The PUT and downloads go through a separate HTTP client with no API token; signed URLs
carry ids, never titles. Queued and cached files sit in the app's private support folder and are deleted at sign-out
(`Session.forget`): the upload and the keeper are stopped first (Windows won't delete a file being read or written),
then the files go one by one, and the scanner's and picker's caches are cleared; the two tables go with the database
(`disconnectAndClear` clears local-only tables).

**Routes** (in the shell): `/calendar`, `/clients`, `/clients/:id` (list beside profile at ≥ 840 dp, as Cases),
`/documents`, `/documents/:id` and `/cases/:id/orders/:orderId` (the viewer). The "+" sheet's Add document opens the
upload flow.

## Consequences
- Prefetching the latest order of each listed case can be the first fetch of a court order, which costs provider
  money once (then it is shared, ADR 0011). It is bounded by the two days' diary.
- If upload-url's response is lost (the server made the row, the app never heard), that pending row stays; and an
  expired attempt's row is deleted only once it has synced to the device. Both show as "being checked".
- An item stopped by a retryable error holds up those behind it until the retry: they would fail the same way.
- Files a viewer or another app holds open on Windows are deleted by a later sweep or at the next sign-out.
- Uploads queued in an org the user left while staying in another fail as not a member and stay hidden from the
  other org's lists until sign-out.
- The keeper fetches nothing while offline and doesn't evict for space; a large Keep offline set is the user's.
- Hindi review: `clientsDataNameTooLong` ("नाम {max} अक्षरों तक ही रखें।"), `docsDataTooLarge`, `docsDataFileMissing`,
  `docsDataUnreadable`, `docsDataSaveFailed`.

**Clients screens** (`lib/features/clients/`): the list's search is kept while the app runs and shared by its two
pages (`/clients` and the list beside `/clients/:id`), as on Cases. Delete is a soft delete with Undo (task 9's
`deleteWithUndo`, no confirm): the client leaves the list at once and `deleted_at` is written when the snackbar
closes; its `matter_clients` rows stay, and cases simply stop showing it. Link case is the client's side of task 9's
Link client: unarchived, not-yet-linked cases by `CaseQuery`, the first 30 matches. The WhatsApp switch needs a mobile
number to turn on and can always be turned off. The kit's `ClientTile` gained `selected`, `autofocus` and
`semanticsLabel` (the Windows two panes and the spoken row "Name. 2 cases. +91 98765 43210."), and its avatar now
grows with the text. Opening a client from a case's Client tab, or a case from a client's profile, pushes it over
the page on a phone, so Back returns there (spec §5.1); on a wide window it goes to that section's two panes, so the
rail follows. Hindi review: `clientsWhatsappHint`, `clientsLinkCase` ("केस से जोड़ें").

## Calendar screen
`lib/features/calendar/`. Month is the first view; the view, the selected day (none = today, so it follows the IST
day change) and the type filter live in a provider for as long as the app runs, not across restarts. Month is one
hand-built grid (Monday first; weekday initials are intl's narrow names, "सो मं बु…" in Hindi), each day with up to
three dots coloured by type in the day's order and "+n"; the filter chips double as the legend, and each cell tells a
screen reader its day and counts ("Thursday 5 November. 2 hearings, 1 task."). Cells are tap targets but not Tab stops:
on Windows the arrows move the selected day (Month: a day or a week; Week: a day), Page Up/Down change the period and
T goes to today, but only while focus is on the calendar or the shell above it, never while a dialog or sheet holds
it. With focus inside the calendar it takes these keys first, so the app's arrow-key focus moves don't run as well;
focus then follows the selected day to its heading (Month's list heading, Week's day), which opens the Day view.
Enter on a focused row opens it. On a 360 dp phone at 200% the day numbers and the view names shrink to one line. Hearings and deadlines open their case; tasks are ticked done with Undo there
(deadlines are marked done on the case page). Agenda loads a month at a time as its end comes into view and stops a
year ahead (a ponytail: "Show more" if advocates need further).

## Documents screens
`lib/features/documents/`. **Packages** (latest stable on 25 Oct 2026, all permissive):
- `pdfrx` 2.10.1 (MIT; PDFium BSD-3) for PDFs, as ADR 0005. `pdfrxFlutterInitialize()` runs in `main`; tests and the
  kitchen sink draw a stand-in (`SamplePdfPages`) behind the kit's `PdfPages`, as PDFium doesn't run under flutter test.
- `cunning_document_scanner` 3.0.4 (MIT), the spec's scanner: ML Kit's document scanner on Android (a free Play
  services API: edges found, perspective fixed, several pages), with the plugin's own cropper where Play services is
  missing. It returns the pages as one PDF (`asPdf`), so no PDF-building package. The app declares no CAMERA
  permission: ML Kit's scanner runs in Play services, and the fallback takes photos through the camera app
  (`ACTION_IMAGE_CAPTURE`), which Android refuses to an app that declares CAMERA without being granted it. So there
  is no permission to deny; a scanner that can't start says to choose a file.
- `file_picker` 13.2.0 (MIT): PDF, JPG, PNG and DOCX, several at once.
- `desktop_drop` 0.8.4 (Apache-2.0): files dropped on the Documents screen on Windows start an upload. Not 0.9.x: it
  needs `cross_file` 0.4, which `file_picker` 13 and `share_plus` 13 don't accept yet. 0.8.4's Android part still
  applies the Kotlin Gradle plugin, which Flutter warns will stop building: move to 0.9 when those two allow it.
- `open_filex` 5.0.0 (BSD-3), Android only: Word files have no viewer here and open in another app, which needs a
  content URI that `url_launcher` can't make for an app-private file. Its storage and media permissions are removed
  from the merged manifest (the files are the app's own). Windows opens them with `url_launcher` (a file URI).

The scanner's and the Android picker's own copies (the scan sits in the app's external Pictures folder, the
plugin's choice) are deleted once the queue has its copy, however the flow ends, and again at sign-out, so no file
outlives sign-out outside `<support>/uploads` and `<support>/offline`.

**Upload**: Add document (the "+" sheet, the screen's app bar, a case's Documents tab with the case preset, or a
drop) asks scan or files where there is a camera, else opens the picker; each file is checked (type by extension and
first bytes, 50 MB) and gets one sheet: title (the file name; required, up to the API's 300 characters), type, case.
Files that fail the check are named, with why, in one message at the end beside "Uploading 2 files", so no snackbar
covers the next file's sheet. **Rows** (Documents screen and the case's tab): the kit's `DocumentTile` gained the file
type's icon, a status line (Checking for safety… / Blocked / Waiting to upload / Uploading 40% with a bar / why it
failed; "Available offline" moved there from the trailing icon) and a trailing slot for the Keep offline toggle or an
upload's Remove (asked first: the copy is deleted). A document's menu edits its title, type and case (§9.3) or deletes
it with Undo. Queued uploads list first; filters (type chips, a case sheet of the cases that have documents) and the
search are kept while the app runs. **Viewer**: the kit's `AppPdfViewer` (find with count, next and previous; zoom
buttons and Ctrl+= / Ctrl+-; the page in view, which jumps to a page; Ctrl+F, Enter / Shift+Enter, Esc), images in an
`InteractiveViewer`, Word files with a note and "Open in another app". The bar shows "Opening…" until bytes arrive
(no spinner), then the download's percent and Cancel. A document opens over the list or case it came from (`push`), so
Back returns there; an order opens over its case at `/cases/:id/orders/:orderId` (`push` too) and is marked read once
its file is here. Offline without a copy, the viewer says what will bring it: an order opens once online (today's and
tomorrow's are saved by themselves), a Keep offline document downloads when back online, any other suggests Keep
offline. A failure that isn't the network's gets the generic message with Retry. The page bar gives the page count
all the width left, so "Page 12 of 140" fits at 200% on a phone. Ctrl+F finds on the Documents screen, and files
dropped on a case page (or its pane on a wide window) upload into that case. Timeline orders say "Available offline"
when their file is on the device. Task 9's open-in-browser helper (`openFromApi`) and its two status strings are
gone.

Consequences: the theme's selected chips now show a primary tick in every theme, and in Sunlight (where a selected
chip's fill is as white as the rest) a 2 px primary border, so a chosen type or language never rests on a tint; the
goldens with selected chips changed with it. A kept document that hasn't downloaded yet shows its Keep offline toggle
on but no "will download" line on its row; the viewer says it. Hindi review: `docsScanHint`, `docsQueuedOffline`,
`docsNoCopy`, `docsNoCopyKept`, `docsNoCopyOrder`, `docsCannotShow`, `docsStateBlocked` ("रोका गया…").
