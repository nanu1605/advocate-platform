import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/data/calendar.dart';
import 'package:advocate_app/data/diary.dart';
import 'package:advocate_app/features/calendar/calendar_screen.dart';
import 'package:advocate_app/features/calendar/calendar_widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

DateTime _d(int y, int m, int d) => DateTime.utc(y, m, d);

/// The calendar screen's pure parts: stepping periods, agenda pages, the type filter and what a month cell says.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('en_IN');
    await initializeDateFormatting('hi');
  });

  test('previous and next move a day, a week or a month', () {
    expect(
      calendarStep(CalendarView.day, _d(2026, 10, 31), 1),
      _d(2026, 11, 1),
    );
    expect(
      calendarStep(CalendarView.week, _d(2026, 11, 5), -1),
      _d(2026, 10, 29),
    );
    expect(
      calendarStep(CalendarView.month, _d(2027, 1, 31), 1),
      _d(2027, 2, 28),
    );
    expect(
      calendarStep(CalendarView.month, _d(2026, 11, 5), -11),
      _d(2025, 12, 5),
    );
  });

  test('agenda pages: the rest of this month, then whole months', () {
    final today = _d(2026, 11, 5);
    expect(agendaPage(today, 0), (from: today, to: _d(2026, 11, 30)));
    expect(agendaPage(today, 1), (from: _d(2026, 12, 1), to: _d(2026, 12, 31)));
    expect(agendaPage(today, 2), (from: _d(2027, 1, 1), to: _d(2027, 1, 31)));
    // From the 31st the next page is still the whole of the next month.
    expect(agendaPage(_d(2027, 1, 31), 1), (
      from: _d(2027, 2, 1),
      to: _d(2027, 2, 28),
    ));
  });

  final day = _d(2026, 11, 5);
  final hearing = CalendarHearing(
    day: day,
    entry: const DiaryEntry(matterId: 'm-1', caseLabel: 'WP 1/2024'),
  );
  final deadline = CalendarDeadline(id: 'd', day: day, kind: 'filing');
  final task = CalendarTask(
    id: 't',
    title: 'File reply',
    dueAt: DateTime.utc(2026, 11, 5, 6),
  );

  test('the type filter keeps only shown types and drops emptied days', () {
    final days = calendarDays([hearing], [deadline], [
      task,
      CalendarTask(id: 't2', title: 'x', dueAt: DateTime.utc(2026, 11, 6, 6)),
    ]);
    expect(filterDays(days, CalendarType.values.toSet()), same(days));
    final noTasks = filterDays(days, {
      CalendarType.hearing,
      CalendarType.deadline,
    });
    expect(noTasks.keys, [day]);
    expect(noTasks[day], [hearing, deadline]);
    expect(filterDays(days, {}), isEmpty);
  });

  test('a cell says its day, today and its counts in both languages', () {
    final en = lookupAppLocalizations(const Locale('en'));
    final hi = lookupAppLocalizations(const Locale('hi'));
    final items = <CalendarItem>[hearing, hearing, deadline, task];
    expect(calendarCountText(en, items), '2 hearings, 1 deadline, 1 task');
    expect(calendarCountText(en, const []), isEmpty);
    expect(
      calendarDayLabel(en, const Locale('en'), day, items, today: day),
      'Thursday 5 November. Today. 2 hearings, 1 deadline, 1 task.',
    );
    expect(
      calendarDayLabel(
        en,
        const Locale('en'),
        _d(2026, 11, 7),
        const [],
        today: day,
      ),
      'Saturday 7 November. Nothing on this day.',
    );
    expect(
      calendarDayLabel(hi, const Locale('hi'), day, [
        task,
      ], today: _d(2026, 11, 4)),
      'गुरुवार 5 नवंबर। 1 काम।',
    );
    expect(
      calendarDayTitle(en, const Locale('en'), _d(2026, 11, 6), day),
      'Tomorrow · Fri, 6 Nov 2026',
    );
  });

  test('the view, day and filter are kept and changed in one place', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final prefs = c.read(calendarPrefsProvider.notifier);
    expect(c.read(calendarPrefsProvider).view, CalendarView.month);
    prefs
      ..setView(CalendarView.week)
      ..select(day)
      ..toggle(CalendarType.task)
      ..toggle(CalendarType.hearing);
    final p = c.read(calendarPrefsProvider);
    expect((p.view, p.day), (CalendarView.week, day));
    expect(p.types, {CalendarType.deadline});
    prefs
      ..toggle(CalendarType.task)
      ..select(null);
    expect(c.read(calendarPrefsProvider).types, {
      CalendarType.deadline,
      CalendarType.task,
    });
    expect(c.read(calendarPrefsProvider).day, isNull);
    prefs.showAll();
    expect(c.read(calendarPrefsProvider).types, CalendarType.values.toSet());
  });
}
