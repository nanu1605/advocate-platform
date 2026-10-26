# 0018 — Phase 1 phase checks

Status: accepted (26 Oct 2026)

## Context
P1 task 12 checks the whole Phase 1 app against spec §5.9 (accessibility, "must pass in every phase"), §5.10,
§16.1, §16.4 and §16.6 before the gate. An audit of every screen found the per-task tests left gaps: Phase 0 screens
and most sheets had no golden, accessibility or 200% check; keyboard focus showed only a faint tint; Windows Narrator
heard none of the app's live regions; manual deadlines never sent a reminder; and two exit criteria (offline notes,
tasks and hearings; a clerk joining by code) had no end-to-end test. These choices close or record each gap.

## Decision
**One sweep over every screen** (`test/widget/phase_checks_test.dart`). A table of 80 scenes (every route, the lock
overlay, the calendar views, 37 sheets and dialogs), each opened in English and Hindi on a 360 × 800 phone and a
1024 × 640 window (the minimum, §5.2), at 100% and then 200% text in place. Each step asserts no exception or overflow
and Flutter's tap-target and labelled-target guidelines; shell screens also run offline and must show the banner. A
guard test reads `router.dart` and fails when a route has no scene, so a new screen can't skip the checks. It runs in
the light theme: targets and labels don't change with the theme, contrast is checked on the tokens, and the goldens
cover the three themes. The goldens reuse the same scenes (`test/golden/scene_goldens.dart`): every scene in
light/dark/sunlight × en/hi × 1.0/2.0, 960 images in all.

**Keyboard focus ring** (§5.9: visible, 2 dp). Buttons, chips and the rail's New button get it from the theme, 2 dp
outside the control so it never sits on a primary fill of its own colour; rows (cards, tiles, list rows, board rows,
calendar headings, palette rows) wrap in `FocusRing`, 2 dp inside, so a list's clip can't cut it. It shows like the
web's `:focus-visible`: after a key press, never after a touch or a mouse click. Flutter keeps a desktop in keyboard
mode for a mouse, so the app tracks "a pointer went down since the last key" itself. A selected row in a two-pane list
takes focus when opened, so Tab goes on from there. The focus colour is checked against bg, surface, surfaceAlt and
primarySoft (≥ 3:1, ≥ 7:1 in sunlight) by `check_contrast.py`.

**Announcements reach Windows.** Flutter's Windows bridge never maps live regions, so Narrator heard none of them.
`AnnouncedText` (`lib/ui/states.dart`) is a live region on Android only and calls `announce()` elsewhere when it
shows or changes, never both; it replaces the bare live regions (error and offline states, step notices, the PDF
find count once a search settles, the calendar's period title, "Refreshing", account loading). `showSnack` announces
snackbars on Windows (iOS and Android read the snackbar's own region). Form errors on sign-in, OTP, consent, PIN
set-up and unlock, invites and the PDF page jump are announced; each is said once (tests count it).

**Sync completion** (§5.9: polite). After a spell offline or a failed sync, the shell shows "Up to date" in the banner
slot for 4 s once sync catches up; its `AnnouncedText` is what TalkBack and Narrator hear (TalkBack needs a node on
screen: Flutter drops zero-size ones). A local write's "Syncing" blip says nothing; the sync indicator is no longer a
live region. During onboarding and on `/loading` the offline banner says the steps need the internet instead of
"showing saved data", and isn't read out on every step.

**Motion and haptics.** With reduce motion on (the OS flag, followed while the app runs, or the app's setting) bottom
sheets appear and go without sliding: a sheet can't cross-fade, and a 100 ms slide is still a slide. Haptics off also
turns off Flutter's own feedback through the theme (buttons, list tiles, tooltips, the rail's New button); on Android
that flag also silences the tap click.

**OTP timer** (§5.9 timing): "Resend code in 42 seconds" (a plural, not "42s"), and "Resend code" is announced when it
becomes available.

**Deadline reminders** (§13.1 `deadline_due`, F04). A beat task at 07:30 IST (`notify.deadline_reminders`) writes one
row per member for each live, open deadline whose IST days left are in its `reminder_offsets` (default 3, 1, 0),
through the same `notify.write` as the other kinds: kind off means no row; the member's language; case number and
court position, the title only with "Include case titles"; a manual case without a number is named by its file number,
else its court. Event key `deadline_due:{id}:{offset}` (re-runs never notify twice), collapse key `deadline_due:{id}`,
link `/cases/{id}?tab=notes` (where deadlines are listed; `appLink` now accepts a case page tab). Offsets that would
fall after the due date are ignored. The app already treated the day-of reminder as urgent.

**Smaller gaps closed.** A badge with the pending Found-for-you count on the Cases destination (§4.1 auto-match "with
a badge"), read as "3 found cases to review"; dashboard counts in Indian grouping (`Formats.number`); a hint that a
case number goes in "Any other words" (the provider searches that text). Layout fixes the sweep and goldens found:
12 dp side gutters below 368 dp so the month grid's day cells stay 48 dp; avatar initials fit their circle at 200%;
field hints wrap to two lines; the edit-name dialog is capped at 560 dp; the rail's selected icon uses the primary
colour (it vanished in sunlight).

**End-to-end tests on the local stack** (§16.1). `integration_test/sync_test.dart` drives the app's own writers
offline (13 writes: notes, tasks and manual hearings created, edited and soft-deleted), restarts the database,
reconnects, checks the exact Postgres rows, that nothing was refused and that a server edit made meanwhile survives,
then resyncs as a fresh device. `integration_test/onboarding_import_test.dart` signs in a fresh number, saves the
synthetic advocate's details, runs find-cases, adds all and checks the app's diary query lists tomorrow's cases.
`services/api/tests/test_team_flow.py` invites a clerk, accepts by code on an open sync stream and checks the clerk
gets the board, documents and team note but no private notes, and that the owner's assignment reaches the advocate's
board. Each run uses a fresh account (test numbers 32–40 were added), since Supabase allows one OTP per number a
minute. `just test-e2e` runs the two app tests; they need Windows and the stack, so CI doesn't run them yet.

## Consequences
- Phase 1 gate exceptions, for the manual screen-reader pass and Track B:
  - Material's own destinations (NavigationRail, NavigationBar, TabBar, popup menu items, SegmentedButton) still
    show only the focus tint.
  - Haptics Flutter fires outside the theme (date and time pickers, long-press text selection) still vibrate with
    haptics off.
  - The manual TalkBack, VoiceOver and Narrator pass (§16.4) needs devices. It should listen in particular for
    text now read when it first appears (the calendar's period title, "Loading your account").
- A morning the beat misses isn't caught up, and a deadline whose date moves keeps the reminders already sent. P1
  can't edit a deadline's date (only add, mark done, delete).
- Deferred with reasons: the Devanagari digits setting (§5.10, optional); the Found cases counter that flies to the
  Cases tab (§5.5); keeping Windows alerts running from the tray after the window closes (§5.12, optional); opening
  invite links in the app (needs the app-link domain, Track B).
- In sunlight the rail's New button and selected indicator have no visible container (primarySoft is white there);
  the filled icon and label still show the selection.
- The phone tab reads "3 found cases to review, Cases": NavigationBar reads the badge before the label.
- Golden images grew from 27 MB (552) to 43 MB (960).
- All new Hindi strings wait for the native-speaker review.
