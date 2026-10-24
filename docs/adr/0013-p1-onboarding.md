# 0013 — Phase 1 onboarding and Found cases

Status: accepted (24 Oct 2026)

## Context
P1 task 7 finishes onboarding (spec §4.1 steps 5–10): role, advocate details, "Finding your cases", Found cases and
the notification explainer. The API (ADR 0011) and the find-cases job (ADR 0012) already exist. These choices fill
the gaps the spec leaves.

## Decision
**Where onboarding stands.** The app loads `GET /v1/me` after sign-in; the first active membership is the current
organisation (switching comes with multi-org). A per-account device flag `onboardingDone` is null until the account
first loads on this device, false while this device onboards it and true when done, so a killed app resumes where it
was. An account that already has a membership and a complete profile counts as done on a new device, so a second
device never runs a second paid search. Every way a session ends (sign-out, or the session ending by itself) clears
the flag, the consent marker, the app lock and the synced data.

**The organisation is created when the details are submitted**, not on the role screen, and a retry reuses the one
the server already has (from the `PATCH /v1/me` reply), so a lost reply never makes a second organisation.

**Add all.** The bottom bar always sends the ticked ids. The header's "Add all" sends `{all: true}` only once the
user's newest find job has finished (until then it sends the ids on screen), so it can't add rows the user hasn't
seen. Both give the same server state for the same set (§4.1 AC). An idempotency key is reused only for a retry of
the same set.

**Status in a row** is text in the subtitle ("Court 12 · Next 5 Nov · Pending", as the §5.3 wireframe draws it),
not a StatusPill: the pill has no pending kind and non-pending rows are already folded under "Disposed (n)", which
also holds transferred cases and cases whose status the provider didn't give (each labelled as what it is).

**Allowance message** drops "or see plans": P1 has no plans screen. It returns with billing in P3.

**Notification permission** is asked through a small method channel in `MainActivity.kt` (the Android 13+ prompt
and the app's notification settings after a denial), not a plugin. Windows needs no prompt; iOS is asked with iOS
push in P2. WhatsApp alerts are P2, so there is no WhatsApp step yet.

**Android backups are off** (`allowBackup="false"`): a restore would bring back the onboarding and consent flags
and synced case data without the signed-in session.

## Consequences
- Invite links route inside the app (`/join/:code`), but no Android App Link or Windows protocol opens the app from
  a URL yet, and a link opened before sign-in loses its code. Both need the app-link domain (Track B).
- The local notification when a background search finishes comes with task 11.
- A member removed from their only team is sent to Today and can rejoin only through an invite link; task 11 (Team)
  covers it.
- Ending a session clears unsent offline changes. Tasks 8–11 add offline writes: warn before a manual sign-out
  while changes are waiting.
- All new Hindi strings wait for the native-speaker review.
