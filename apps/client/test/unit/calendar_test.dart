import 'package:advocate_app/data/calendar.dart';
import 'package:advocate_app/data/diary.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:powersync/powersync.dart' hide SyncStatus;

import 'sync_db.dart';

DateTime _d(int y, int m, int d) => DateTime.utc(y, m, d);

/// The calendar's dates and its range query (spec §4.3 Calendar, ADR 0016).
void main() {
  // IST now listens for the app resuming.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('dates (IST days, weeks from Monday)', () {
    test('a week runs Monday to Sunday', () {
      // Thu 5 Nov 2026.
      expect(weekStart(_d(2026, 11, 5)), _d(2026, 11, 2));
      expect(weekStart(_d(2026, 11, 2)), _d(2026, 11, 2));
      expect(weekStart(_d(2026, 11, 8)), _d(2026, 11, 2));
      expect(weekRange(_d(2026, 11, 5)), (
        from: _d(2026, 11, 2),
        to: _d(2026, 11, 8),
      ));
    });

    test('the month grid is whole Monday weeks around the month', () {
      // 1 Nov 2026 is a Sunday and 30 Nov a Monday: six rows.
      final nov = monthGridRange(_d(2026, 11, 17));
      expect(nov, (from: _d(2026, 10, 26), to: _d(2026, 12, 6)));
      final days = daysOf(nov);
      expect(days, hasLength(42));
      expect(days.every((d) => d.isUtc && d.hour == 0), isTrue);
      expect(days.first.weekday, DateTime.monday);
      // February 2027 starts on a Monday and ends on a Sunday: four rows, no other month's days.
      expect(daysOf(monthGridRange(_d(2027, 2, 10))), hasLength(28));
      expect(monthRange(_d(2027, 2, 10)), (
        from: _d(2027, 2, 1),
        to: _d(2027, 2, 28),
      ));
    });

    test('months move to the same day, or the month end', () {
      expect(addMonths(_d(2027, 1, 31), 1), _d(2027, 2, 28));
      expect(addMonths(_d(2026, 12, 5), 1), _d(2027, 1, 5));
      expect(addMonths(_d(2026, 1, 5), -1), _d(2025, 12, 5));
    });
  });

  test('a day lists hearings in diary order, then deadlines, then tasks', () {
    CalendarHearing hearing(String matter, String courtNo) => CalendarHearing(
      day: _d(2026, 11, 5),
      entry: DiaryEntry(
        matterId: matter,
        caseLabel: 'WP $matter',
        courtNo: courtNo,
      ),
    );
    final days = calendarDays(
      [hearing('b', '12'), hearing('a', '7')],
      [
        CalendarDeadline(
          id: 'done',
          day: _d(2026, 11, 5),
          kind: 'compliance',
          done: true,
        ),
        CalendarDeadline(id: 'filing', day: _d(2026, 11, 5), kind: 'filing'),
        CalendarDeadline(id: 'later', day: _d(2026, 11, 6), kind: 'other'),
      ],
      [
        CalendarTask(
          id: 'done',
          title: 'x',
          dueAt: DateTime.utc(2026, 11, 5, 1),
          done: true,
        ),
        CalendarTask(
          id: 'late',
          title: 'x',
          dueAt: DateTime.utc(2026, 11, 5, 9),
        ),
        CalendarTask(
          id: 'early',
          title: 'x',
          dueAt: DateTime.utc(2026, 11, 5, 2),
        ),
      ],
    );
    expect(days.keys, [_d(2026, 11, 5), _d(2026, 11, 6)]);
    expect(
      [
        for (final i in days[_d(2026, 11, 5)]!)
          switch (i) {
            CalendarHearing(:final matterId) => 'h:$matterId',
            CalendarDeadline(:final id) => 'd:$id',
            CalendarTask(:final id) => 't:$id',
          },
      ],
      ['h:a', 'h:b', 'd:filing', 'd:done', 't:early', 't:late', 't:done'],
    );
  });

  group('range query', () {
    late PowerSyncDatabase db;

    Map<String, Object?> matter(
      String id, [
      Map<String, Object?> f = const {},
    ]) => {
      'id': id,
      'org_id': 'org-1',
      'case_type': 'WP',
      'case_number': id.substring(1),
      'case_year': 2024,
      'title': 'Sharma v. State of MP',
      'court_id': 'c-hc',
      'court_no': '12',
      'stage': 'Admission',
      'status': 'active',
      'tracking': 'auto',
      ...f,
    };

    Map<String, Object?> row(String id, Map<String, Object?> f) => {
      'id': id,
      'org_id': 'org-1',
      ...f,
    };

    setUp(() async {
      db = await openTestDb();
      await insertRows(db, 'courts', [
        {
          'id': 'c-hc',
          'level': 'HC',
          'name': 'MPHC',
          'short_name': 'MPHC Indore',
        },
      ]);
      await insertRows(db, 'matters', [
        // A court next date with no hearing row (a deleted one doesn't count).
        matter('m1', {'next_hearing_date': '2026-11-05'}),
        // A court row and a manual row on one day: one item, the court's.
        matter('m2', {'next_hearing_date': '2026-11-06'}),
        // Manual: its hearings rows only, never next_hearing_date.
        matter('m3', {'tracking': 'manual', 'next_hearing_date': '2026-11-07'}),
        // Archived: its rows still show, its next date doesn't.
        matter('m4', {'status': 'archived', 'next_hearing_date': '2026-11-05'}),
        matter('m5', {'deleted_at': '2026-11-01T00:00:00Z'}),
        matter('m6', {'tracking': 'off', 'next_hearing_date': '2026-11-08'}),
        {...matter('m9'), 'org_id': 'org-2', 'next_hearing_date': '2026-11-05'},
      ]);
      await insertRows(db, 'hearings', [
        row('h1-deleted', {
          'matter_id': 'm1',
          'date': '2026-11-05',
          'source': 'court',
          'deleted_at': '2026-11-02T00:00:00Z',
        }),
        row('h1-later', {
          'matter_id': 'm1',
          'date': '2026-11-20',
          'source': 'court',
        }),
        row('h2-manual', {
          'matter_id': 'm2',
          'date': '2026-11-06',
          'source': 'manual',
          'purpose': 'Arguments',
          'created_at': '2026-11-01T00:00:00Z',
        }),
        row('h2', {
          'matter_id': 'm2',
          'date': '2026-11-06',
          'source': 'court',
          'court_no': '7',
          'item_no': '23',
          'user_purpose': 'Final hearing',
          'created_at': '2026-11-02T00:00:00Z',
        }),
        row('h3', {
          'matter_id': 'm3',
          'date': '2026-11-04',
          'source': 'manual',
        }),
        row('h4', {'matter_id': 'm4', 'date': '2026-11-03', 'source': 'court'}),
        row('h5', {'matter_id': 'm5', 'date': '2026-11-05', 'source': 'court'}),
      ]);
      await insertRows(db, 'deadlines', [
        for (final (id, matterId, status, date, deleted) in [
          ('dl-active', 'm1', 'active', '2026-11-05', false),
          ('dl-done', 'm2', 'done', '2026-11-05', false),
          ('dl-proposed', 'm1', 'proposed', '2026-11-05', false),
          ('dl-dismissed', 'm1', 'dismissed', '2026-11-05', false),
          ('dl-deleted', 'm1', 'active', '2026-11-05', true),
          ('dl-later', 'm1', 'active', '2026-11-09', false),
        ])
          row(id, {
            'matter_id': matterId,
            'kind': 'limitation',
            'status': status,
            'due_date': date,
            'deleted_at': deleted ? '2026-11-01T00:00:00Z' : null,
          }),
      ]);
      await insertRows(db, 'tasks', [
        for (final (id, due, status) in [
          // 11:59 pm IST on Thu 5 Nov.
          ('t-thu-night', '2026-11-05T18:29:00Z', 'open'),
          // 12:00 am IST on Mon 9 Nov: next week.
          ('t-next-week', '2026-11-08T18:30:00Z', 'open'),
          // 12:00 am IST on Mon 2 Nov, stored the way Postgres sends it.
          ('t-mon', '2026-11-01 18:30:00+00', 'open'),
          ('t-done', '2026-11-05T04:30:00Z', 'done'),
          ('t-dismissed', '2026-11-05T04:30:00Z', 'dismissed'),
          ('t-sun-ist', '2026-11-08 23:00:00+05:30', 'open'),
          ('t-undated', null, 'open'),
        ])
          row(id, {
            'title': 'File reply',
            'due_at': due,
            'status': status,
            'matter_id': id == 't-mon' ? null : 'm1',
          }),
      ]);
    });

    test('hearings, deadlines and tasks of the week, one hearing per case '
        'per day', () async {
      final c = dbContainer(db);
      final week = weekRange(_d(2026, 11, 5));
      final days = await firstValue(c, calendarProvider(week));

      List<String> on(int day) => [
        for (final i in days[_d(2026, 11, day)] ?? const <CalendarItem>[])
          switch (i) {
            CalendarHearing(:final matterId, :final hearingId) =>
              'h:$matterId:${hearingId ?? 'next'}',
            CalendarDeadline(:final id) => 'd:$id',
            CalendarTask(:final id) => 't:$id',
          },
      ];
      expect(on(2), ['t:t-mon']);
      expect(on(3), ['h:m4:h4']);
      expect(on(4), ['h:m3:h3']);
      expect(on(5), [
        'h:m1:next',
        'd:dl-active',
        'd:dl-done',
        't:t-thu-night',
        't:t-done',
      ]);
      expect(on(6), ['h:m2:h2']);
      expect(on(7), isEmpty);
      expect(on(8), ['h:m6:next', 't:t-sun-ist']);
      expect(
        days.keys.every((d) => !d.isBefore(week.from) && !d.isAfter(week.to)),
        isTrue,
      );

      final m2 = days[_d(2026, 11, 6)]!.single as CalendarHearing;
      expect(m2.entry.caseLabel, 'WP 2/2024');
      expect(m2.entry.court?.shortName, 'MPHC Indore');
      expect((m2.entry.courtNo, m2.entry.itemNo), ('7', '23'));
      // The court row's purpose, else the user's.
      expect(m2.entry.purpose, 'Final hearing');
      final m1 = days[_d(2026, 11, 5)]!.first as CalendarHearing;
      expect((m1.entry.courtNo, m1.entry.purpose), ('12', 'Admission'));
      final deadline = days[_d(2026, 11, 5)]![1] as CalendarDeadline;
      expect(
        (deadline.caseLabel, deadline.kind, deadline.done),
        ('WP 1/2024', 'limitation', false),
      );
      final done = days[_d(2026, 11, 5)]!.last as CalendarTask;
      expect(
        (done.done, done.matterId, done.caseLabel),
        (true, 'm1', 'WP 1/2024'),
      );
      final noCase = days[_d(2026, 11, 2)]!.single as CalendarTask;
      expect((noCase.matterId, noCase.caseLabel), (null, null));
    });

    test('a task marked done stays on its day, struck through', () async {
      final c = dbContainer(db);
      final day = (from: _d(2026, 11, 5), to: _d(2026, 11, 5));
      await firstValue(c, calendarProvider(day));
      await db.execute(
        "update tasks set status = 'done' where id = 't-thu-night'",
      );
      final after = await firstValue(
        c,
        calendarProvider(day),
        (d) =>
            d[_d(2026, 11, 5)]!.whereType<CalendarTask>().every((t) => t.done),
      );
      expect(after[_d(2026, 11, 5)]!.whereType<CalendarTask>(), hasLength(2));
    });
  });
}
