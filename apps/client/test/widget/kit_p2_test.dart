import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/ui/ai_answer_card.dart';
import 'package:advocate_app/ui/item_tracker.dart';
import 'package:advocate_app/ui/mic_button.dart';
import 'package:advocate_app/ui/source_chip.dart';
import 'package:advocate_app/ui/voice_confirm_sheet.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

final AppLocalizations l = lookupAppLocalizations(const Locale('en'));

const _matters = {
  'wp': 'WP 1234/2024 · Sharma v. State',
  'cra': 'CRA 455/2023 · Mohan Lal v. State',
};

Future<List<VoiceDraft>> _sheet(WidgetTester tester, VoiceDraft draft) async {
  final saved = <VoiceDraft>[];
  await tester.pumpWidget(
    host(
      SingleChildScrollView(
        child: VoiceConfirmSheet(
          draft: draft,
          matters: _matters,
          onSave: saved.add,
          onCancel: () {},
        ),
      ),
      height: 600,
    ),
  );
  return saved;
}

Future<void> _tapSave(WidgetTester tester) async {
  await tester.ensureVisible(find.text(l.voiceSave));
  await tester.tap(find.text(l.voiceSave));
  await tester.pump();
}

Finder _field(String label) => find.widgetWithText(TextField, label);

/// The P2 kit components (ADR 0001, ADR 0021) behave as spec §5.11 and §12.9 say; their looks are in the kit goldens.
void main() {
  setUpAll(loadAppFonts);

  group('MicButton', () {
    Widget mic(List<String> log) => host(
      MicButton(
        state: MicState.idle,
        onTap: () => log.add('tap'),
        onHoldStart: () => log.add('start'),
        onHoldEnd: () => log.add('end'),
      ),
    );

    testWidgets('a tap is quick add; a hold records until let go', (
      tester,
    ) async {
      final log = <String>[];
      await tester.pumpWidget(mic(log));
      await tester.tap(find.byType(MicButton));
      await tester.pump();
      expect(log, ['tap']);

      final hold = await tester.startGesture(
        tester.getCenter(find.byType(MicButton)),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      expect(log, ['tap', 'start']);
      await hold.up();
      await tester.pump();
      expect(log, ['tap', 'start', 'end']);
    });

    testWidgets('a hold the system takes away, or a button that goes, still '
        'stops recording', (tester) async {
      final log = <String>[];
      await tester.pumpWidget(mic(log));
      final hold = await tester.startGesture(
        tester.getCenter(find.byType(MicButton)),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await hold.cancel();
      await tester.pump();
      expect(log, ['start', 'end']);

      await tester.startGesture(tester.getCenter(find.byType(MicButton)));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await tester.pumpWidget(host(const SizedBox()));
      await tester.pump();
      expect(log, ['start', 'end', 'start', 'end']);
    });

    testWidgets('says what it is doing in each state, and a screen reader '
        'can tap it', (tester) async {
      final handle = tester.ensureSemantics();
      for (final (state, label) in [
        (MicState.idle, l.micIdle),
        (MicState.recording, l.micRecording('1:05')),
        (MicState.processing, l.micProcessing),
        (MicState.error, l.micError),
      ]) {
        var taps = 0;
        await tester.pumpWidget(
          host(
            MicButton(
              state: state,
              elapsed: const Duration(seconds: 65),
              onTap: () => taps++,
            ),
          ),
        );
        tester.semantics.tap(find.semantics.byLabel(label));
        expect(taps, 1, reason: '$state');
      }
      handle.dispose();
    });

    testWidgets('its keyboard ring is drawn outside the fill', (tester) async {
      final was = FocusManager.instance.highlightStrategy;
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(() => FocusManager.instance.highlightStrategy = was);
      await tester.pumpWidget(
        host(MicButton(state: MicState.idle, onTap: () {})),
      );
      CircleBorder shape() =>
          tester
                  .widget<Material>(
                    find.descendant(
                      of: find.byType(MicButton),
                      matching: find.byType(Material),
                    ),
                  )
                  .shape!
              as CircleBorder;
      expect(shape().side, BorderSide.none);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(shape().side.width, 2);
      expect(shape().side.strokeAlign, greaterThan(0));
    });

    testWidgets('the reading pulse runs, and stops with reduce motion', (
      tester,
    ) async {
      Widget mic({required bool reduced}) => host(
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
            child: const MicButton(state: MicState.processing),
          ),
        ),
      );
      double opacity() => tester
          .widget<FadeTransition>(
            find.descendant(
              of: find.byType(MicButton),
              matching: find.byType(FadeTransition),
            ),
          )
          .opacity
          .value;
      await tester.pumpWidget(mic(reduced: false));
      await tester.pump(const Duration(milliseconds: 450));
      expect(opacity(), lessThan(1));
      await tester.pumpWidget(mic(reduced: true));
      await tester.pump(const Duration(milliseconds: 450));
      expect(opacity(), 1);
    });
  });

  group('VoiceConfirmSheet', () {
    testWidgets('saves nothing until Save, and Save needs a case', (
      tester,
    ) async {
      final saved = await _sheet(
        tester,
        const VoiceDraft(transcript: 'next date bees November'),
      );
      await _tapSave(tester);
      expect(saved, isEmpty);

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_matters['cra']!).last);
      await tester.pumpAndSettle();
      await _tapSave(tester);
      expect(saved.single.matter, 'cra');
    });

    testWidgets('saves the fields as corrected, without empty tasks', (
      tester,
    ) async {
      final saved = await _sheet(
        tester,
        VoiceDraft(
          transcript: 'reply file karna hai',
          matter: 'wp',
          nextDate: DateTime(2026, 11, 20),
          purpose: 'Reply',
          outcome: 'Adjourned',
          note: 'Client to bring the sale deed',
          tasks: [
            (title: 'File reply', due: DateTime(2026, 11, 18)),
            (title: 'Get certified copy', due: null),
          ],
        ),
      );
      await tester.enterText(_field(l.boardPurpose), '  Arguments ');
      await tester.enterText(_field(l.voiceTask(2)), ' ');
      await tester.ensureVisible(find.text(l.addTask));
      await tester.tap(find.text(l.addTask));
      await tester.pump();
      expect(_field(l.voiceTask(3)), findsOneWidget);
      await tester.enterText(_field(l.nextDate), '21-11-2026');
      await tester.enterText(_field(l.casePageDueDate).first, '19-11-2026');
      await _tapSave(tester);

      final d = saved.single;
      expect(d.matter, 'wp');
      expect(d.nextDate, DateTime(2026, 11, 21));
      expect(d.purpose, 'Arguments');
      expect(d.outcome, 'Adjourned');
      expect(d.note, 'Client to bring the sale deed');
      expect(d.tasks, [(title: 'File reply', due: DateTime(2026, 11, 19))]);
      expect(d.transcript, 'reply file karna hai');
    });

    testWidgets('a date that does not read blocks Save', (tester) async {
      final saved = await _sheet(
        tester,
        const VoiceDraft(
          transcript: 'x',
          matter: 'wp',
          tasks: [(title: 'File reply', due: null)],
        ),
      );
      await tester.enterText(_field(l.nextDate), '31-02-2026');
      await tester.pump();
      await _tapSave(tester);
      expect(saved, isEmpty);

      await tester.enterText(_field(l.nextDate), '');
      await tester.enterText(_field(l.casePageDueDate), '99-99-2026');
      await tester.pump();
      await _tapSave(tester);
      expect(saved, isEmpty);

      await tester.enterText(_field(l.casePageDueDate), '');
      await tester.pump();
      await _tapSave(tester);
      expect(saved.single.nextDate, isNull);
      expect(saved.single.tasks, [(title: 'File reply', due: null)]);
    });

    testWidgets('marks the fields it was unsure of until they change, and '
        'keeps the keyboard on the field being typed in', (tester) async {
      await _sheet(
        tester,
        VoiceDraft(
          transcript: 'x',
          matter: 'wp',
          matterUnsure: true,
          nextDate: DateTime(2026, 11, 20),
          nextDateUnsure: true,
        ),
      );
      expect(find.text(l.voiceUnsure), findsNWidgets(2));
      await tester.showKeyboard(_field(l.nextDate));
      await tester.enterText(_field(l.nextDate), '22-11-2026');
      await tester.pump();
      expect(find.text(l.voiceUnsure), findsOneWidget);
      final editable = tester.widget<EditableText>(
        find.descendant(
          of: _field(l.nextDate),
          matching: find.byType(EditableText),
        ),
      );
      expect(editable.focusNode.hasFocus, isTrue);
      expect(editable.controller.text, '22-11-2026');
    });

    testWidgets('removes a task', (tester) async {
      final saved = await _sheet(
        tester,
        const VoiceDraft(
          transcript: 'x',
          matter: 'wp',
          tasks: [
            (title: 'File reply', due: null),
            (title: 'Get certified copy', due: null),
          ],
        ),
      );
      await tester.tap(find.byTooltip(l.voiceRemoveTask(1)));
      await tester.pump();
      await tester.pump(); // the removed fields' controllers go after the frame
      expect(find.text('File reply'), findsNothing);
      await _tapSave(tester);
      expect(saved.single.tasks, [(title: 'Get certified copy', due: null)]);
    });
  });

  group('ItemTracker', () {
    var now = DateTime(2026, 11, 4, 11);
    DateTime clock() => now;
    setUp(() => now = DateTime(2026, 11, 4, 11));
    CourtUpdate at(String item, {int minutesAgo = 2}) => CourtUpdate(
      item: item,
      at: now.subtract(Duration(minutes: minutesAgo)),
      by: 'Priya',
    );
    Widget tracker(CourtUpdate? update, {String mine = '23'}) => host(
      ItemTracker(court: 'Court 12', mine: mine, update: update, clock: clock),
    );

    testWidgets('says how far away the item is, or that it is on or past', (
      tester,
    ) async {
      for (final (mine, item, says) in [
        ('23', '18', l.trackerAway(5)),
        ('23', '22', l.trackerAway(1)),
        ('23', '23', l.trackerNow),
        ('23', '25', l.trackerPassed),
        ('S-12', 's-5', l.trackerAway(7)),
      ]) {
        await tester.pumpWidget(tracker(at(item), mine: mine));
        await tester.pumpAndSettle(); // the count ticks to its new value
        expect(find.text(says), findsOneWidget, reason: '$mine $item');
        expect(find.text(l.trackerAt('Court 12', item)), findsOneWidget);
      }
      await tester.pumpWidget(tracker(null));
      expect(find.text(l.trackerNone), findsOneWidget);
    });

    testWidgets('items on different lists are not counted', (tester) async {
      await tester.pumpWidget(tracker(at('S-3'), mine: '12'));
      expect(find.text(l.trackerAt('Court 12', 'S-3')), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      for (final n in [-9, 9]) {
        expect(find.text(l.trackerAway(n)), findsNothing);
      }
      expect(find.text(l.trackerPassed), findsNothing);
    });

    testWidgets('ages and fades on its own after 20 minutes', (tester) async {
      await tester.pumpWidget(tracker(at('18', minutesAgo: 19)));
      expect(find.textContaining(l.trackerStale), findsNothing);
      expect(
        find.textContaining(l.trackerUpdated(19, 'Priya')),
        findsOneWidget,
      );
      now = now.add(const Duration(minutes: 2));
      await tester.pump(const Duration(minutes: 1));
      expect(find.textContaining(l.trackerStale), findsOneWidget);
      expect(
        find.textContaining(l.trackerUpdated(21, 'Priya')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox()); // its timer goes with it
    });

    testWidgets('an update without a person says only when', (tester) async {
      await tester.pumpWidget(tracker(CourtUpdate(item: '18', at: now)));
      expect(find.textContaining(l.trackerUpdatedAgo(0)), findsOneWidget);
    });

    testWidgets('reads out a move, once, but not on first showing', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final said = captureAnnouncements(tester);
      await tester.pumpWidget(tracker(at('18')));
      await tester.pumpAndSettle();
      expect(said, isEmpty);
      await tester.pumpWidget(tracker(at('20')));
      await tester.pump(const Duration(milliseconds: 100)); // mid-tick
      expect(find.semantics.byLabel(l.trackerAway(3)).evaluate().length, 1);
      await tester.pumpAndSettle();
      expect(said, [l.trackerAway(3)]);
      handle.dispose();
    });
  });

  testWidgets('a source chip reads its page and paragraph and opens it', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var opened = 0;
    await tester.pumpWidget(
      host(
        SourceChip(
          'Order',
          page: 2,
          paragraph: '12.1',
          check: CitationCheck.verified,
          onTap: () => opened++,
        ),
      ),
    );
    expect(
      find.text(
        [
          'Order',
          l.sourcePage(2),
          l.sourcePara('12.1'),
          l.citationVerified,
        ].join(' · '),
      ),
      findsOneWidget,
    );
    final spoken = [
      'Order',
      l.sourcePageSpoken(2),
      l.sourceParaSpoken('12.1'),
      l.citationVerified,
    ].join(', ');
    await tester.tap(find.byType(SourceChip));
    tester.semantics.tap(find.semantics.byLabel(spoken));
    expect(opened, 2);
    handle.dispose();
  });

  testWidgets('an AI answer shows the actions it is given and the check note', (
    tester,
  ) async {
    var undone = 0;
    await tester.pumpWidget(
      host(
        AIAnswerCard(
          lines: const [
            AnswerLine(
              'Reply within four weeks.',
              sources: [SourceChip('Order')],
            ),
          ],
          onUndo: () => undone++,
        ),
      ),
    );
    expect(find.text(l.aiBadge), findsOneWidget);
    expect(find.text(l.aiVerifyFooter), findsOneWidget);
    expect(find.text(l.aiCopy), findsNothing);
    expect(find.text(l.aiReport), findsNothing);
    await tester.tap(find.text(l.undo));
    expect(undone, 1);
  });
}
