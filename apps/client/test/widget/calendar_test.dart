import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/router.dart';
import 'package:advocate_app/data/calendar.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/features/calendar/calendar_screen.dart';
import 'package:advocate_app/features/calendar/calendar_widgets.dart';
import 'package:advocate_app/features/case_page/case_page.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:advocate_app/ui/tiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

DateTime _nov(int d) => DateTime.utc(2026, 11, d);

/// Today is Thu 5 Nov 2026 (IST). On 5 Nov: WP 1001's court next date and WP 1002's hearing (its next date is the
/// same day: one item), a limitation deadline, an open task at 5 pm and a done one. On 6 Nov a manual hearing and a
/// task without a case; 9 and 20 Nov hearings; a done filing deadline on 12 Nov; a hearing on 3 Nov (past) and one
/// in January 2027 (the agenda's third month).
FakeCases sampleCalendar() => FakeCases(
  cases: [
    caseInfo(1, nextDate: _nov(5), stage: 'Admission'),
    caseInfo(2, nextDate: _nov(5), caseType: 'MCRC'),
    caseInfo(
      3,
      nextDate: _nov(9),
      court: testCourts[3],
      caseType: 'CS',
      courtNo: '5',
    ),
    caseInfo(4, nextDate: _nov(20)),
    caseInfo(
      5,
      tracking: 'manual',
      courtName: 'Family Court Indore',
      courtNo: '3',
    ),
    caseInfo(6, nextDate: DateTime.utc(2027, 1, 14)),
  ],
  hearings: {
    'm-2': [
      CaseHearing(
        id: 'h-2',
        date: _nov(5),
        courtNo: '7',
        itemNo: '23',
        purpose: 'Arguments',
      ),
    ],
    'm-4': [CaseHearing(id: 'h-4', date: _nov(3), purpose: 'Notice')],
    'm-5': [
      CaseHearing(
        id: 'h-5',
        date: _nov(6),
        source: 'manual',
        userPurpose: 'Evidence',
      ),
    ],
  },
  deadlines: {
    'm-1': [CaseDeadline(id: 'dl-1', kind: 'limitation', dueDate: _nov(5))],
    'm-3': [
      CaseDeadline(
        id: 'dl-2',
        kind: 'filing',
        dueDate: _nov(12),
        status: 'done',
      ),
    ],
  },
  tasks: {
    // 5:00 pm IST on 5 Nov.
    'm-2': [
      CaseTask(
        id: 't-1',
        title: 'File reply',
        dueAt: DateTime.utc(2026, 11, 5, 11, 30),
      ),
    ],
    // 6 Nov, no time.
    '': [
      CaseTask(
        id: 't-2',
        title: 'Collect certified copy',
        dueAt: DateTime.utc(2026, 11, 5, 18, 30),
      ),
    ],
    'm-1': [
      CaseTask(
        id: 't-3',
        title: 'Pay court fee',
        dueAt: DateTime.utc(2026, 11, 4, 18, 30),
        status: 'done',
      ),
    ],
  },
);

const _tall = Size(400, 1800);
const _wide = Size(1280, 900);

/// The case page on top (opened with push, so the router's location stays `/calendar`).
String _openCase(WidgetTester tester) =>
    tester.widget<CasePage>(find.byType(CasePage)).matterId;

/// Calendar (spec §4.3, §5.9, §5.12).
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  Future<FakeCases> open(
    WidgetTester tester, {
    FakeCases? fake,
    String locale = 'en',
    double scale = 1,
    Size size = _tall,
    bool offline = false,
    CalendarView? view,
  }) async {
    final f = fake ?? sampleCalendar();
    await pumpApp(
      tester,
      location: '/calendar',
      locale: locale,
      textScale: scale,
      size: size,
      overrides: [...f.overrides, if (offline) ...syncedData(offline: true)],
    );
    if (view != null) {
      container(tester).read(calendarPrefsProvider.notifier).setView(view);
      await tester.pumpAndSettle();
    }
    return f;
  }

  Future<void> tapView(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  group('month', () {
    testWidgets('a grid from Monday; each cell says its day and counts', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await open(tester);
      expect(find.text('November 2026'), findsOneWidget);
      expect(find.byType(MonthGrid), findsOneWidget);
      // 26 Oct to 6 Dec: six weeks, Monday first.
      expect(
        find.bySemanticsLabel(RegExp('^Monday 26 October')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          'Thursday 5 November. ${en.relToday}. ${en.calendarCountHearings(2)}, '
          '${en.calendarCountDeadlines(1)}, ${en.calendarCountTasks(2)}.',
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          'Friday 6 November. ${en.calendarCountHearings(1)}, '
          '${en.calendarCountTasks(1)}.',
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Saturday 7 November. ${en.calendarEmptyDay}'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp('^Sunday 6 December')),
        findsOneWidget,
      );
      // Five items: three dots and "+2".
      expect(find.text('+2'), findsOneWidget);

      // Today's items under the grid: hearings in diary order, the deadline, then tasks (done last).
      expect(find.text('${en.relToday} · Thu, 5 Nov 2026'), findsOneWidget);
      expect(find.text('WP 1001/2024'), findsOneWidget);
      expect(find.text('MCRC 1002/2024'), findsOneWidget);
      expect(
        find.text(
          'MPHC Indore · ${en.courtNo('7')} · ${en.itemNo('23')} · Arguments',
        ),
        findsOne,
      );
      expect(find.text(en.casesDeadlineLimitation), findsOneWidget);
      expect(find.text('File reply · MCRC 1002/2024'), findsOneWidget);
      expect(find.text(en.taskDue('5:00 pm')), findsOneWidget);
      final done = tester.widget<TaskItem>(
        find.widgetWithText(TaskItem, 'Pay court fee · WP 1001/2024'),
      );
      expect((done.done, done.due), (true, null));

      // Another day: its items.
      await tester.tap(find.bySemanticsLabel(RegExp('^Friday 6 November')));
      await tester.pumpAndSettle();
      expect(find.text('${en.relTomorrow} · Fri, 6 Nov 2026'), findsOneWidget);
      expect(find.text('WP 1005/2024'), findsOneWidget);
      expect(
        find.text('${en.foundOtherCourt} · ${en.courtNo('3')} · Evidence'),
        findsOneWidget,
      );
      expect(find.text('Collect certified copy'), findsOneWidget);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });

    testWidgets('previous and next move by month; Today comes back', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.byTooltip(en.calendarNext('month')));
      await tester.pumpAndSettle();
      expect(find.text('December 2026'), findsOneWidget);
      expect(find.text('Sat, 5 Dec 2026'), findsOneWidget);
      expect(find.text(en.calendarEmptyDay), findsOneWidget);
      await tester.tap(find.byTooltip(en.calendarPrevious('month')));
      await tester.pump();
      await tester.tap(find.byTooltip(en.calendarPrevious('month')));
      await tester.pumpAndSettle();
      expect(find.text('October 2026'), findsOneWidget);
      await tester.tap(find.byTooltip(en.calendarGoToToday));
      await tester.pumpAndSettle();
      expect(find.text('November 2026'), findsOneWidget);
      expect(find.text('${en.relToday} · Thu, 5 Nov 2026'), findsOneWidget);
    });

    testWidgets('Windows: the day beside the grid', (tester) async {
      await open(tester, size: _wide);
      final grid = tester.getRect(find.byType(MonthGrid));
      final heading = tester.getRect(
        find.text('${en.relToday} · Thu, 5 Nov 2026'),
      );
      expect(heading.left, greaterThan(grid.right));
      expect(heading.top, lessThan(grid.bottom));
      // Weekdays have room for three letters.
      expect(find.text('Mon'), findsOneWidget);
    });
  });

  testWidgets('type filter: chips hide a type; all hidden says so', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await open(tester);
    await tester.tap(find.text(en.calendarHearings));
    await tester.pumpAndSettle();
    expect(find.text('WP 1001/2024'), findsNothing);
    expect(find.text('File reply · MCRC 1002/2024'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        'Thursday 5 November. ${en.relToday}. ${en.calendarCountDeadlines(1)}, '
        '${en.calendarCountTasks(2)}.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text(en.casePageDeadlines));
    await tester.tap(find.text(en.casePageTasks));
    await tester.pumpAndSettle();
    expect(find.text(en.calendarAllHidden), findsOneWidget);
    expect(find.byType(MonthGrid), findsNothing);
    await tester.tap(find.text(en.calendarShowAll));
    await tester.pumpAndSettle();
    expect(find.text('WP 1001/2024'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('day: grouped by type; previous and next move a day', (
    tester,
  ) async {
    await open(tester);
    await tapView(tester, en.calendarViewDay);
    expect(find.text('${en.relToday} · Thu, 5 Nov 2026'), findsOneWidget);
    expect(find.text('${en.calendarHearings} (2)'), findsOneWidget);
    expect(find.text('${en.casePageDeadlines} (1)'), findsOneWidget);
    expect(find.text('${en.casePageTasks} (2)'), findsOneWidget);
    double top(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(top('WP 1001/2024'), lessThan(top(en.casesDeadlineLimitation)));
    expect(
      top(en.casesDeadlineLimitation),
      lessThan(top('File reply · MCRC 1002/2024')),
    );

    await tester.tap(find.byTooltip(en.calendarNext('day')));
    await tester.pumpAndSettle();
    expect(find.text('${en.relTomorrow} · Fri, 6 Nov 2026'), findsOneWidget);
    expect(find.text('WP 1005/2024'), findsOneWidget);
    await tester.tap(find.byTooltip(en.calendarNext('day')));
    await tester.pumpAndSettle();
    expect(find.text(en.calendarEmptyDay), findsOneWidget);
    expect(find.byType(EmptyState), findsOneWidget);
  });

  testWidgets('week: Monday to Sunday; a day heading opens the day', (
    tester,
  ) async {
    await open(tester);
    await tapView(tester, en.calendarViewWeek);
    expect(find.text('2 Nov – 8 Nov 2026'), findsOneWidget);
    for (final day in [
      'Mon, 2 Nov 2026',
      'Tue, 3 Nov 2026',
      'Wed, 4 Nov 2026',
      '${en.relToday} · Thu, 5 Nov 2026',
      '${en.relTomorrow} · Fri, 6 Nov 2026',
      'Sat, 7 Nov 2026',
      'Sun, 8 Nov 2026',
    ]) {
      expect(find.text(day), findsOneWidget);
    }
    expect(find.text('WP 1004/2024'), findsOneWidget);
    expect(find.text(en.calendarEmptyDay), findsNWidgets(4));
    await tester.tap(find.byTooltip(en.calendarNext('week')));
    await tester.pumpAndSettle();
    expect(find.text('9 Nov – 15 Nov 2026'), findsOneWidget);
    // A done deadline is struck through.
    final filing = tester.widget<Text>(find.text(en.casesDeadlineFiling));
    expect(filing.style?.decoration, TextDecoration.lineThrough);
    expect(
      find.text('${en.calendarDeadline} · CS 1003/2024 · ${en.calendarDone}'),
      findsOneWidget,
    );

    await tester.tap(find.text('Thu, 12 Nov 2026'));
    await tester.pumpAndSettle();
    expect(
      container(tester).read(calendarPrefsProvider).view,
      CalendarView.day,
    );
    expect(find.text('Thu, 12 Nov 2026'), findsOneWidget);
  });

  testWidgets('week: a week with nothing says so', (tester) async {
    await open(tester, view: CalendarView.week);
    await tester.tap(find.byTooltip(en.calendarNext('week')));
    await tester.pump();
    await tester.tap(find.byTooltip(en.calendarNext('week')));
    await tester.pumpAndSettle();
    expect(find.text('16 Nov – 22 Nov 2026'), findsOneWidget);
    expect(find.text('WP 1004/2024'), findsOneWidget);
    await tester.tap(find.byTooltip(en.calendarNext('week')));
    await tester.pumpAndSettle();
    expect(find.text(en.calendarEmptyWeek), findsOneWidget);
  });

  testWidgets('agenda: from today, by date, a month at a time', (tester) async {
    await open(tester, view: CalendarView.agenda);
    expect(find.text('${en.relToday} · Thu, 5 Nov 2026'), findsOneWidget);
    expect(find.text('${en.relTomorrow} · Fri, 6 Nov 2026'), findsOneWidget);
    expect(find.text('Mon, 9 Nov 2026'), findsOneWidget);
    // The past isn't in it; no previous and next.
    expect(find.text('WP 1004/2024'), findsOneWidget);
    expect(find.text('Tue, 3 Nov 2026'), findsNothing);
    expect(find.byTooltip(en.calendarNext('month')), findsNothing);
    expect(find.byTooltip(en.calendarGoToToday), findsNothing);
    // Later months load as the end comes into view.
    await tester.scrollUntilVisible(find.text('Thu, 14 Jan 2027'), 300);
    expect(find.text('WP 1006/2024'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text(en.calendarAgendaEnd('Sun, 31 Oct 2027')),
      300,
    );
  });

  testWidgets('agenda: nothing coming up', (tester) async {
    await open(tester, fake: FakeCases(), view: CalendarView.agenda);
    expect(find.text(en.calendarEmptyAgenda(12)), findsOneWidget);
  });

  testWidgets('a task is ticked done with Undo; its arrow opens the case', (
    tester,
  ) async {
    final fake = await open(tester);
    await tester.tap(find.text('File reply · MCRC 1002/2024'));
    await tester.pumpAndSettle();
    expect(fake.writes.last.name, 'setTaskDone');
    expect(fake.writes.last.args, {'id': 't-1', 'done': true});
    expect(find.text(en.todayTaskDone), findsOneWidget);
    // Done stays on its day, struck through.
    expect(
      tester
          .widget<TaskItem>(
            find.widgetWithText(TaskItem, 'File reply · MCRC 1002/2024'),
          )
          .done,
      isTrue,
    );
    await tester.tap(find.text(en.undo));
    await tester.pumpAndSettle();
    expect(fake.writes.last.args, {'id': 't-1', 'done': false});

    await tester.tap(find.byTooltip(en.calendarOpenCase('MCRC 1002/2024')));
    await tester.pumpAndSettle();
    expect(_openCase(tester), 'm-2');
  });

  testWidgets('a hearing opens its case; the calendar is as left on return', (
    tester,
  ) async {
    await open(tester, view: CalendarView.week);
    await tester.tap(find.text('WP 1001/2024'));
    await tester.pumpAndSettle();
    expect(_openCase(tester), 'm-1');
    container(tester).read(routerProvider).go('/today');
    await tester.pumpAndSettle();
    container(tester).read(routerProvider).go('/calendar');
    await tester.pumpAndSettle();
    expect(find.text('2 Nov – 8 Nov 2026'), findsOneWidget);
  });

  testWidgets('a deadline without a case is not a link', (tester) async {
    final fake = sampleCalendar();
    fake.deadlines[''] = [
      CaseDeadline(id: 'dl-3', kind: 'other', dueDate: _nov(5)),
    ];
    await open(tester, fake: fake, view: CalendarView.day);
    await tester.tap(find.text(en.casesDeadlineOther));
    await tester.pumpAndSettle();
    expect(find.byType(CasePage), findsNothing);
  });

  testWidgets('offline: the saved calendar shows under the banner', (
    tester,
  ) async {
    await open(tester, offline: true);
    expect(find.byType(OfflineBanner), findsOneWidget);
    expect(find.text('WP 1001/2024'), findsOneWidget);
  });

  testWidgets('a failed read says so with Retry, never a code', (tester) async {
    var reads = 0;
    await pumpApp(
      tester,
      location: '/calendar',
      overrides: [
        clockProvider.overrideWithValue(() => testNow),
        calendarHearingsProvider.overrideWith((ref, _) {
          reads++;
          return Stream.error(StateError('hearings failed'));
        }),
        calendarDeadlinesProvider.overrideWith((ref, _) => Stream.value([])),
        calendarTasksProvider.overrideWith((ref, _) => Stream.value([])),
      ],
    );
    expect(find.byType(ErrorState), findsOneWidget);
    expect(find.textContaining('failed'), findsNothing);
    final before = reads;
    await tester.tap(find.text(en.retry));
    await tester.pumpAndSettle();
    expect(reads, greaterThan(before));
  });

  group('keys (Windows)', () {
    testWidgets('arrows move the day; Page Up/Down the month; T today', (
      tester,
    ) async {
      await open(tester, size: _wide);
      DateTime? selected() => container(tester).read(calendarPrefsProvider).day;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(selected(), _nov(6));
      expect(find.text('${en.relTomorrow} · Fri, 6 Nov 2026'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(selected(), _nov(12));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(selected(), _nov(5));
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      expect(find.text('December 2026'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await tester.pumpAndSettle();
      expect(find.text('October 2026'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
      await tester.pumpAndSettle();
      expect(selected(), isNull);
      expect(find.text('November 2026'), findsOneWidget);

      // Week: every arrow moves a day; Page Down a week.
      container(tester)
          .read(calendarPrefsProvider.notifier)
          .setView(CalendarView.week);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(selected(), _nov(6));
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      expect(selected(), _nov(13));
      expect(find.text('9 Nov – 15 Nov 2026'), findsOneWidget);
    });

    testWidgets('from a row, arrows move the day once and focus its heading; '
        'Enter there opens the day', (tester) async {
      await open(tester, size: _wide);
      DateTime? selected() => container(tester).read(calendarPrefsProvider).day;
      bool focused(String heading) =>
          Focus.of(tester.element(find.text(heading))).hasPrimaryFocus;

      // Month: a row in the selected day's list.
      Focus.of(tester.element(find.text('MCRC 1002/2024'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(selected(), _nov(12));
      expect(focused('Thu, 12 Nov 2026'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(selected(), _nov(13));
      expect(focused('Fri, 13 Nov 2026'), isTrue);

      // Week: the focus moves with the selected day.
      container(tester).read(calendarPrefsProvider.notifier)
        ..select(null)
        ..setView(CalendarView.week);
      await tester.pumpAndSettle();
      Focus.of(tester.element(find.text('WP 1001/2024'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(selected(), _nov(6));
      expect(focused('${en.relTomorrow} · Fri, 6 Nov 2026'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        container(tester).read(calendarPrefsProvider).view,
        CalendarView.day,
      );
    });

    testWidgets('Enter opens the focused item', (tester) async {
      await open(tester, size: _wide, view: CalendarView.day);
      Focus.of(tester.element(find.text('MCRC 1002/2024'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(_openCase(tester), 'm-2');
    });

    testWidgets('keys are left alone while a dialog is open', (tester) async {
      await open(tester, size: _wide);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(container(tester).read(calendarPrefsProvider).day, isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(container(tester).read(calendarPrefsProvider).day, _nov(6));
    });
  });

  for (final locale in ['en', 'hi']) {
    final l = lookupAppLocalizations(Locale(locale));
    testWidgets('a 360 dp phone at 200% ($locale): day numbers and view names '
        'stay on one line', (tester) async {
      await open(tester, locale: locale, scale: 2, size: const Size(360, 1800));
      double height(Finder f) => tester.getSize(f.first).height;
      final line = height(find.text('5'));
      for (final day in ['26', '30']) {
        expect(height(find.text(day)), line, reason: day);
      }
      for (final view in [
        l.calendarViewDay,
        l.calendarViewWeek,
        l.calendarViewMonth,
        l.calendarViewAgenda,
      ]) {
        expect(height(find.text(view)), lessThan(line * 1.5), reason: view);
      }
      expect(tester.takeException(), isNull);
    });
    for (final scale in [1.0, 2.0]) {
      testWidgets('every view fits ($locale ${scale}x)', (tester) async {
        final handle = tester.ensureSemantics();
        await open(tester, locale: locale, scale: scale);
        expect(find.byType(MonthGrid), findsOneWidget);
        if (locale == 'hi') {
          expect(
            find.bySemanticsLabel(
              'गुरुवार 5 नवंबर। आज। 2 सुनवाई, 1 समय-सीमा, 2 काम।',
            ),
            findsOneWidget,
          );
        }
        for (final view in [
          l.calendarViewDay,
          l.calendarViewWeek,
          l.calendarViewAgenda,
          l.calendarViewMonth,
        ]) {
          await tapView(tester, view);
          expect(tester.takeException(), isNull);
          expect(find.text('WP 1001/2024'), findsOneWidget);
        }
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        handle.dispose();
      });
    }
  }
}
