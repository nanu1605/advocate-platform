# 0017 — Phase 1 Team, notifications, dashboard and feedback

Status: accepted (25 Oct 2026)

## Context
P1 task 11 adds the Team screen (invite by phone, link or code; roles; assignment), the notification centre and
preferences, local notifications on Android and Windows, a basic practice dashboard and in-app feedback (spec §4.4
F16/F18, §13, §10.2). The workers already write `notifications` rows and read `notification_prefs` (ADR 0012); push
is Track B. It also closes ADR 0013's follow-ups. This ADR records the data-layer, API and notifier decisions; the
screens add theirs.

## Decision
**Two Team endpoints added to §10.2.** Invites never sync (§9.4), and an open invite holds one of the 10 seats for
7 days, so the owner must see and cancel them:
- `GET /v1/orgs/{org_id}/invites` → the open invites (not accepted, not expired), newest first, with the same fields
  as the create response (`id, code, role, phone, expires_at, link`).
- `DELETE /v1/orgs/{org_id}/invites/{invite_id}` → 204. Revoking sets `expires_at` to `-infinity`, so the code stops
  working and the seat is free at once; the row stays (no delete policy needed, nothing to audit under §15.7). Not
  `now()`: an accept already under way compares against its own, earlier transaction time and would still pass. 404
  for an accepted, expired, already revoked or unknown invite.

Both are owner only, like the other team writes: 404 for outsiders, `ROLE_NOT_ALLOWED` for other roles.

**Team data** (`lib/data/team.dart`). Members are the org's active synced memberships (task 8's query; removed ones are
left out), the owner first. Each member's case count is their unarchived live cases from task 9's case list, the
number its assignee filter shows. Only the owner manages members (§15.3). Role names follow Appendix C: मालिक,
अधिवक्ता, जूनियर अधिवक्ता, मुंशी.

**A member removed from their only team** goes back to the role step, never to an empty Today. The router's rule: a
device that finished onboarding whose account has loaded in no team is sent to `/onboarding/role`; the router then
resets `onboardingDone` to false, so onboarding continues normally from there (join another team by code, or set up
on their own). Sync clears the old org's rows by itself. The account reloads `/v1/me` whenever sync takes one of the
user's active memberships away (the current team's, or the last), so this happens while the app runs, not only at
the next start, and a user removed from the current team but still in another moves to that one. The role screen says
"You're no longer part of Sharma Chambers" when the team was seen in this run, else a generic line, and offers "Join
another team with a code" first (multi-org switching comes later).

**Notification centre.** The user's synced rows in the current org, plus org-less ones, newest first. Rows sharing
`data.collapse_key` show as the newest with the older ones folded under it; a group counts once in the bell's badge
while any of it is unread, and opening it marks the whole group read. A row's title and body are shown as the server
wrote them (localised, case titles only when allowed). `data.link` opens only if it is one of `/today`,
`/board/tomorrow`, `/cases/{id}` or `/found`; otherwise the row is just marked read. Reads write `read_at` only (the
one device column, §9.3); "Mark all read" covers the current org.

**Preferences** are the user's own `notification_prefs` rows, created on demand. A row's id is a v5 UUID of
`"<user id>:<kind>"` in namespace `24cc73e1-d649-4f6f-bab6-8c3662d30cb6` (Python: `uuid.uuid5(NS, f"{user}:{kind}")`),
so two devices never create two rows for one kind (unique `(user_id, kind)`); a synced row under another id is
updated instead. Off is `channels = {}` (the workers then skip that kind for the user), on is `{push}`. "Include case
titles" and the quiet hours are one setting each, written to every kind's row, so the newest row speaks for all; a
new row copies them. Writes are local and upload later. The kinds listed are the seven the P1 workers write plus
`deadline_due`.

**Quiet hours** (default 22:00–07:00) are IST wall-clock times, like the rest of the app; a window across midnight
wraps, equal times mean none. Urgent kinds may break them (§13.2): `listed_unexpectedly`, and `deadline_due` whose
`data.due_date` is today (IST); the worker that writes `deadline_due` must put `due_date` in `data`. "Urgent alerts may
break quiet hours" is a device setting (`AppSettings.urgentBreaksQuiet`, default on, cleared on sign-out): the schema
has no column for it. When push arrives (Track B) it needs a `notification_prefs` column, then this setting moves
there.

**Local notifications** (`lib/data/local_notifier.dart`, flutter_local_notifications 22.3.2, BSD-3). A `LocalNotifier`
interface (plugin-backed on Android and Windows, faked in tests) and a service the shell starts:
- New rows as they sync while the app runs (Android also in the background while the process lives; Windows while it
  runs). A row is shown once: unread, created after the service started less 5 minutes (so a first sync after
  sign-in or a reinstall never replays old rows) and at most an hour before it syncs (after a sleep, Doze or a long
  offline spell, yesterday's "Tomorrow: 6 matters" would mislead), kind on, and not in quiet hours unless urgent.
  The service starts afresh for each signed-in user. Nothing shows while the user is on the centre: the top page,
  pushed ones included (the bell pushes it; a case opened from it is not the centre), and only while the app is in
  front (a centre left open in the background or minimised isn't being read). A held-back row is never shown later.
  Of rows sharing a collapse key, the newest; the key is the OS notification's tag and (FNV-1a hashed) id, so updates
  replace instead of stacking. Rows are remembered by id and text (the last 200, in preferences, so a restart doesn't
  repeat them; forgotten on sign-out): a row the server rewrites (the evening board's later attempt) is shown again
  and replaces its notice instead of leaving the old count in the tray.
- "We found 37 cases. Tap to review." → `/found` when a find-cases search the service saw running finishes, unless
  the user is on Finding or Found cases or it is quiet hours (the result waits in Cases' "Found for you"). A search
  that finished before the shell started finished on the Finding screen, which went on to Found cases, so it says
  nothing. Once per job; not for a failed or stopped search.
- A tap opens the notice's link (validated as above), also when it launched the app.
- The plugin counts as started only when it initialises (Windows can fail to register the app id); showing and
  clearing are best effort, so sign-out always goes on to wipe the account's files.
- Android: two channels, "Case updates" (default importance) and "Urgent alerts" (high), named in the user's language
  when a notice is shown; the launcher icon as the small icon; core library desugaring (desugar_jdk_libs 2.1.5).
- Windows: toasts while the app runs, with app id `in.jainavinfotech.advocate` (the never-changing Android id, §2.2)
  and toast activator CLSID `d70975db-0054-4132-9dc6-494bc79016cd`. An unpackaged build registers both under
  `HKCU\Software\Classes\AppUserModelId\in.jainavinfotech.advocate` itself at first start. For the signed installer:
  give its Start-menu shortcut `System.AppUserModel.ID` = that id and `System.AppUserModel.ToastActivatorCLSID` = that
  CLSID, and remove the registry key on uninstall. For the MSIX build: the plugin uses the package identity; declare
  `desktop:ToastNotificationActivation` (and the COM server) with the same CLSID so a tap on a toast opens the app.
- The MainActivity permission channel stays: the plugin can ask for the permission but can't open the app's
  notification settings, which the denied state needs. It gains `enabled` (whether notifications are on now), for
  the preferences screen.
- No FCM.

**Dashboard** counts reuse the existing queries: active cases (task 9's list: live, unarchived, not disposed or
transferred), hearings this week (task 10's calendar hearings for Monday–Sunday IST, one per case per day), overdue
tasks (Today's tasks due, due before now), new orders (Today's unread `new_order` notifications). A chamber's owner
also gets each member's (clerks aside) assigned cases with a hearing this week.

**Feedback** names the screen as the top page's matched route pattern ("/cases/:id", a pushed page included: the
router's own pattern leaves pushes out); anything that isn't a lower-case route word or a `:param` becomes `:id`, and
the query is dropped, so no id, code or name leaves the device. The app version comes from package_info_plus. A note
that couldn't be sent stays in memory while the app runs, and is dropped on sign-out.

**Sign-out warning.** Settings counts what signing out would lose: PowerSync's upload queue (one per change) and
task 10's upload queue (failed items too: their file is only on this device).

**Error codes.** Every code the API raises (`ApiError`, the SQL business rules, responses built directly such as the
court-data `CASE_NOT_FOUND` and `COURT_PROVIDER_ERROR`) and every code a worker fails a job with (its own, and a
court-data `ProviderError`'s) has its own text in `lib/core/errors.dart`; `INTERNAL`, `INTERNAL_ERROR` and the API's
catch-alls `METHOD_NOT_ALLOWED` and `HTTP_ERROR` use the generic text, as does an unexpected code a provider passes
through. A unit test reads the API, worker and court-data source and fails on a code without text.

## Consequences
- ADR 0013's follow-ups are closed: the finished-search notification, the removed-member path and the sign-out
  warning (with this ADR's counts).
- Unpackaged Windows builds can't take shown toasts back, so sign-out clears the Android tray only; the Action
  Centre keeps the last toasts until dismissed. The MSIX build can.
- The removed-member line names the team only if this run saw it; after a restart it is generic.
- Android's small icon is the launcher icon (drawn as a silhouette) until the brand work adds a monochrome one.
- A notification row arriving while the shell isn't up (e.g. on Found cases) is shown when the shell returns, if it
  is still new by the rules above.
- All new Hindi strings wait for the native-speaker review.

## Screens: dashboard, feedback, sign-out
- **Dashboard** (`/dashboard`). Each count opens the view that shows the same rows: Active cases opens Cases with the
  status filter Pending (other filters and the search cleared, sort kept); Hearings this week opens the calendar's
  week on today with every type shown (hearings may have been filtered out there); Overdue tasks opens Today (its
  Tasks due section); New orders opens the centre for `new_order`. New orders counts orders, as Today's "New orders
  (n)" does; the centre folds a case's orders into one row ("+1 earlier"). Tiles sit four in a row when they fit at
  the current text size (Windows), else two or one. Today's matters are Today's own list (`TodayMatters`). The empty
  state ("Add your first case") is for an org with no cases; one whose cases are all closed sees the tiles at zero.
  The owner's Team row is read-only: its count (cases with a hearing this week) isn't a filter the Cases list has.
- **Feedback** is a sheet over the current screen. The note (1–4000 characters, with a counter), the screen pattern
  and the version are shown to the user before sending ("We'll include the screen you were on (/cases/:id)…"). It
  checks for a connection first (sync's offline state), then sends; `RATE_LIMITED` (10 an hour) has its own text.
  Nothing is retried in the background: feedback isn't a device write.
- **Sign-out.** The confirm lists the pending changes and documents and says they'll be lost, with "Sign out anyway"
  and "Stay signed in"; the kit's `ConfirmDialog` gained an optional cancel label for this.

**Notification centre and preferences screens.**
- **Bell.** On Today's app bar after the sync indicator (§5.3 wireframe), with a badge of unread groups; screen
  readers hear "Notifications, 3 unread" (the badge digits are excluded). It pushes `/notifications`.
- **Centre.** Today / Yesterday / Earlier by IST day; times in the first two, the date in Earlier. Unread rows are
  bold with a dot (read out as "Unread"). A tap marks the group read and pushes its validated link; a row with no
  valid link is only marked read. "Mark as read" is a row menu (keyboard and screen readers) and a swipe (the row
  stays, losing its dot). "Mark all read" covers the org, or only the rows on screen when the centre shows one kind
  (`?kind=new_order`, shown as a selected chip that returns to every kind; the message then names the kind). A folded
  group shows "+2 earlier" and doesn't expand. The gear opens preferences. Today's New orders and Needs attention
  mark read through the same `NotificationWriter`, the one writer for `read_at`.
- **Preferences.** One switch per kind; the screen says that a kind turned off reaches the user nowhere, not even
  the centre (the workers write no row for it). Quiet hours use 12-hour pickers (forced even where the OS prefers
  24-hour) and, until push arrives (Track B), only hold back the local pop-ups; the screen says the rows still land
  in the centre. On Android, when the OS has the app's notifications off, the screen shows onboarding's denied text
  with "Open settings", and checks again when the app resumes; where the permission channel is missing it assumes
  on.

**Team screen** (`lib/features/team/`).
- **Members** are read from the synced memberships, so the list works offline. Each row shows the role. If the
  member has no display name, the role is the title. Each row also shows how many unarchived cases are assigned to
  them. A tap opens the Cases list filtered to that member. The other filters and the search are cleared, so the list
  matches the count. A clerk with nothing assigned shows no count, because Assign never offers clerks.
- **Owner actions** go through the API (§9.3: memberships are written through the API), so offline they say they
  need a connection. The owner can change a role (a sheet), edit a name (a dialog that keeps the text when saving
  fails) and remove a member. Removing asks first and says how many cases are still assigned to that member. A
  removed member leaves the list at once, before sync takes the membership away. The owner's own row has no actions.
  Everyone else sees the list only, with a line saying that only the owner manages members.
- **Pending invites** are fetched when the screen opens, after the invite sheet closes, when the device comes
  back online, and when the synced team changes size (someone joined with a code while the owner looks on, so
  their invite is gone). They are never cached (§9.4). A failure shows the error text with Retry in place of the section.
  Revoke asks first. `NOT_FOUND` (the invite was used, ran out or was revoked elsewhere) is said plainly, and the list
  is refreshed.
- **The invite sheet** has the role (chips, default Junior advocate) and an optional number, checked like the API
  (10 digits, starting 6–9). Only one create is in flight at a time, because each call makes a new invite. When the
  team is full, the owner gets their own message: make room by removing a member or revoking an invite, since open
  invites hold places too. The result shows the code large, read out letter by letter. The primary action is "Share
  invite" (the OS share sheet), with Copy below it. The share message is in the app's language, carries the link once
  `APP_LINK_BASE` exists, and never includes the phone number. The sheet says plainly that nothing was sent for the
  owner (SMS and WhatsApp are Track B).
