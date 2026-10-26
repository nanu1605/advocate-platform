# 0021 — Phase 2 kit components: AI answers, sources, mic, voice confirm, item tracker

Status: accepted (27 Oct 2026)

## Context
P2 task 3: the five kit components deferred from Phase 0 ([ADR 0001](0001-defer-p2-kit-components.md)) are built
before any P2 screen, with the same golden matrix as the rest of the kit (3 themes × en/hi × 1.0/2.0), a
`/dev/kitchen-sink` section each, and the tap-target and labelling checks. They are shaped to the data the features
will hand them: `document_chunks`, `VoiceParse` and `display_board_snapshots` (ADR 0019, ADR 0020).

## Decision
- **SourceChip** (`lib/ui/source_chip.dart`) is one widget for sources and citations: a label, an optional page and
  paragraph, and an optional `CitationCheck` (verified, needs review, not found, check manually) shown as an icon and a
  word in that status's colours. The paragraph is text, as chunks store it ("12.1", "4(a)"). It is not a Material chip:
  a chip's label can't wrap, and a long citation must at 200% text. A screen reader hears "page 3, paragraph 4", not
  "p. 3".
- **AIAnswerCard** (`lib/ui/ai_answer_card.dart`) shows the AI badge, the answer line by line (`AnswerLine`) with each
  line's source chips, the actions it is given (copy, insert, undo, report), and always the footer "AI can make
  mistakes. Check the sources before you rely on it." The "couldn't find this in the case files" text belongs to the
  feature (task 6).
- **MicButton** (`lib/ui/mic_button.dart`): idle, recording (a live waveform, in the urgent colours), processing (a
  pulse, still with reduce motion) and error. It stays 56 dp round in every state, so it fits the bottom bar's centre
  slot (72 dp on a 360 dp phone); the time recorded is in its spoken label, and a screen that wants it shown shows it
  beside. Tap and hold are separate callbacks, and the caller decides what each does in each state. A hold always ends
  with `onHoldEnd`, whether the finger lifts, the system takes the touch or the button goes, so recording never runs
  on. The keyboard ring is drawn outside the fill, which can be the focus colour itself. Holding has no screen-reader
  gesture, so the tap's quick-add sheet must offer a voice note too. `AppScaffold`'s centre slot takes an icon today;
  task 7 gives it the button.
- **VoiceConfirmSheet** (`lib/ui/voice_confirm_sheet.dart`): the transcript and the parsed fields, all editable,
  including each task's due date (`VoiceTask.due`). Fields the model was unsure of are marked "Please check" until
  changed, without the field losing focus as the mark goes. Save is the only way out with data, and needs a case and
  dates that read; empty fields and tasks are dropped. The chosen case wraps at 200% text, so its parties stay visible.
- **ItemTracker** (`lib/ui/item_tracker.dart`): "Court 12 is at item 18", "You're 5 items away" (or on now, or gone
  past), a bar, and the update's age and author. Items are text, as cause lists write them; they are counted only on the
  same list ("S-5" and "S-12", not "12" and "S-3"). It re-reads its clock each minute, so an update ages and, after
  20 minutes, says it may be out of date on an open screen; dropping it after 2 hours is the caller's. The clock is an
  instant (`clockProvider`), never the IST wall-clock `istNowProvider`. The count ticks and the bar eases over `base`;
  a move is read out once, and nothing is read out when the tracker first shows.
- `AnnouncedText` takes `onShow: false` for that, and keeps a shown child out of the screen reader, whose label is the
  text already.
- New icons are added to `AppIcons` from the vendored Phosphor font ([ADR 0007](0007-vendored-phosphor-icons.md)).

## Review
An independent review (four lenses, each finding checked by a skeptic) confirmed 12 issues, all fixed here: item
numbers and paragraphs typed as numbers, task due dates dropped, a tracker that only faded when something else
rebuilt it, a doubled and flickering spoken headline, a recording button too wide for the bar, a hold that a cancel
left recording, an invisible focus ring on the mic, a field that lost focus on its first keystroke, the chosen case cut
off at 200%, AI actions 4 dp apart, and two untested paths (the screen-reader tap, the note and outcome on save).

## Consequences
- ADR 0001's deferral is closed: all 22 §5.11 components are in the kit.
- All new Hindi strings wait for the native-speaker review; ask especially about `trackerAway` ("आपका नंबर 5 आइटम बाद
  है"), `citationNeedsReview` ("दोबारा देखें") and `citationCheckManually` ("खुद जाँचें").
