import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/case_label.dart';
import 'package:advocate_app/data/courts.dart';
import 'package:advocate_app/data/diary.dart';
import 'package:advocate_app/data/diary_text.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../helpers.dart';

final Court _jabalpur = testCourts[1];
final Court _district = testCourts[3];

/// IST wall-clock [h]:[m] on 5 Nov 2026.
DateTime _ist(int h, [int m = 0]) => DateTime.utc(2026, 11, 5, h, m);

Duration _at(int h, [int m = 0]) => Duration(hours: h, minutes: m);

/// Today and Tomorrow's Board data rules (spec §4.2, §11.6): ordering, hero, evening switch, needs attention.
void main() {
  // IST now listens for the app resuming.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('case label', () {
    test('type, number and year; CNR fallback', () {
      expect(
        caseLabelOf(caseType: 'WP', caseNumber: '1234', caseYear: 2024),
        'WP 1234/2024',
      );
      expect(caseLabelOf(caseNumber: '1234', caseYear: 2024), '1234/2024');
      expect(caseLabelOf(caseType: 'WP', caseNumber: '1234'), 'WP 1234');
      expect(
        caseLabelOf(caseType: 'WP', caseNumber: '', cnr: 'MPHC010012342024'),
        'MPHC010012342024',
      );
      expect(caseLabelOf(), '');
      expect(foundCase(1).caseLabel, 'WP 1001/2024');
    });
  });

  group('IST and the evening switch', () {
    test('IST whatever the device zone', () {
      final instant = DateTime.utc(2026, 11, 5, 13); // 18:30 IST
      for (final t in [instant, instant.toLocal()]) {
        final ist = istOf(t);
        expect((ist.hour, ist.minute), (18, 30));
        expect(isoDate(istDay(ist)), '2026-11-05');
      }
      // 00:10 IST on the 6th is still the 5th in UTC.
      final late = istOf(DateTime.utc(2026, 11, 5, 18, 40));
      expect(isoDate(istDay(late)), '2026-11-06');
      expect(istInstant(istDay(late)), DateTime.utc(2026, 11, 5, 18, 30));
    });

    test('from the switch time until midnight', () {
      expect(isEvening(_ist(18, 29), defaultEveningSwitch), isFalse);
      expect(isEvening(_ist(18, 30), defaultEveningSwitch), isTrue);
      expect(isEvening(_ist(23, 59), defaultEveningSwitch), isTrue);
      expect(isEvening(_ist(0), defaultEveningSwitch), isFalse);
      expect(isEvening(_ist(18, 45), _at(19)), isFalse);
    });

    test('configured time, or 18:30', () {
      expect(parseEveningSwitch('19:00'), _at(19));
      expect(parseEveningSwitch(' 7:05 '), _at(7, 5));
      for (final bad in [null, '', '25:00', '18:60', 'evening', 1830]) {
        expect(parseEveningSwitch(bad), defaultEveningSwitch, reason: '$bad');
      }
    });

    testWidgets(
      'IST now ticks on the minute and re-reads the clock on resume',
      (tester) async {
        var now = DateTime.utc(2026, 11, 5, 18, 29, 30); // 23:59:30 IST
        final c = ProviderContainer(
          overrides: [clockProvider.overrideWithValue(() => now)],
        );
        final sub = c.listen(istTodayProvider, (_, _) {});
        expect(sub.read(), DateTime.utc(2026, 11, 5));
        now = now.add(const Duration(seconds: 30));
        await tester.pump(const Duration(seconds: 30));
        expect(
          sub.read(),
          DateTime.utc(2026, 11, 6),
          reason: 'midnight, on time',
        );

        // The phone slept overnight: no timer ran, so nothing ticked.
        now = DateTime.utc(2026, 11, 6, 2, 30, 10); // 08:00:10 IST
        expect(c.read(istNowProvider), DateTime.utc(2026, 11, 6));
        tester.binding
          ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
          ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        expect(c.read(istNowProvider), istOf(now));
        sub.close();
        c.dispose();
      },
    );

    test('providers follow the clock in IST', () {
      var now = DateTime.utc(2026, 11, 5, 13); // 18:30 IST
      ProviderContainer make([Duration? switchAt]) {
        final c = ProviderContainer(
          overrides: [
            clockProvider.overrideWithValue(() => now),
            if (switchAt != null)
              eveningSwitchProvider.overrideWithValue(AsyncData(switchAt)),
          ],
        );
        addTearDown(c.dispose);
        return c;
      }

      final c = make();
      expect(c.read(istTodayProvider), DateTime.utc(2026, 11, 5));
      expect(c.read(istTomorrowProvider), DateTime.utc(2026, 11, 6));
      expect(c.read(eveningProvider), isTrue);
      expect(make(_at(19)).read(eveningProvider), isFalse);
      now = DateTime.utc(2026, 11, 5, 18, 31); // 00:01 IST on the 6th
      final next = make();
      expect(next.read(istTodayProvider), DateTime.utc(2026, 11, 6));
      expect(next.read(eveningProvider), isFalse);
    });
  });

  group('diary order', () {
    test('complexes by earliest slot, then court and item numerically', () {
      final dc = diaryEntry(
        1,
        court: _district,
        courtNo: '5',
        item: 1,
      ); // 10:30
      final entries = [
        diaryEntry(2, item: 23), // MPHC Indore, Court 12: 11:58
        diaryEntry(3, courtNo: '7', item: 41), // 13:10
        diaryEntry(4, courtNo: 'Room A', item: 2),
        diaryEntry(5, item: 3),
        diaryEntry(6, court: _district, courtNo: '5', item: 2),
        diaryEntry(7, court: _jabalpur, boarded: false),
        diaryEntry(8, boarded: false), // no item yet: last in its court
        const DiaryEntry(matterId: 'm-9', caseLabel: 'CS 9/2020'), // no court
        dc,
      ];
      expect(orderDiary(entries).map((e) => e.matterId), [
        // District Court Indore: earliest 10:30.
        'm-1', 'm-6',
        // MPHC Indore: earliest 10:34 (item 2).
        'm-3', 'm-5', 'm-2', 'm-8', 'm-4',
        // No slots: by name, unknown court last.
        'm-7', 'm-9',
      ]);
    });

    test('two complexes without slots go by name', () {
      final entries = [
        diaryEntry(1, boarded: false),
        diaryEntry(2, court: _district, boarded: false),
      ];
      expect(orderDiary(entries).map((e) => e.matterId), ['m-2', 'm-1']);
    });
  });

  group('hero card', () {
    final ordered = [
      diaryEntry(1, slot: _at(10, 30)),
      diaryEntry(2, slot: _at(11)),
      diaryEntry(3, boarded: false),
    ];
    String? hero(int h, int m) => heroEntry(ordered, _ist(h, m))?.matterId;

    test('the first whose window has not ended', () {
      expect(hero(9, 0), 'm-1');
      expect(hero(11, 29), 'm-1');
      expect(hero(11, 30), 'm-2');
      expect(hero(12, 0), 'm-3'); // no slot: never ended
    });

    test('none left', () {
      expect(heroEntry(ordered.take(2).toList(), _ist(12)), isNull);
      expect(heroEntry(const [], _ist(9)), isNull);
    });

    test('a matter on now beats a later one in a complex listed first', () {
      // MPHC (earliest 10:30) is listed before the District Court (11:00), but at 11:35 item 1's window is over
      // and the District matter (11:00–12:00) is on, before MPHC item 50 (13:46).
      final day = orderDiary([
        diaryEntry(1, item: 1),
        diaryEntry(2, item: 50, slot: _at(13, 46)),
        diaryEntry(3, court: _district, courtNo: '5', item: 1, slot: _at(11)),
        diaryEntry(4, boarded: false),
      ]);
      expect(day.map((e) => e.matterId), ['m-1', 'm-2', 'm-4', 'm-3']);
      String? at(int h, int m) => heroEntry(day, _ist(h, m))?.matterId;
      expect(at(10, 0), 'm-1');
      expect(at(11, 35), 'm-3');
      expect(at(12, 30), 'm-2');
      expect(at(15, 0), 'm-4'); // no slot: never ended, and only then
    });
  });

  group('clashes', () {
    final hc = diaryEntry(1, slot: _at(10, 30));
    final dc = diaryEntry(2, court: _district, slot: _at(11));
    final later = diaryEntry(3, court: _jabalpur, slot: _at(15));

    test('different complexes within the window, same person', () {
      final day = withClashes([hc, dc, later], 'user-1');
      expect([for (final e in day) e.clash], [true, true, false]);
      expect(day[0].clashWith, ['m-2']);
      expect(day[1].clashWith, ['m-1']);
      expect(day[0].clashGroup, day[1].clashGroup);
    });

    test('a proxy or a different assignee clears it', () {
      expect(
        withClashes([
          hc,
          dc.copyWith(proxyArranged: true),
        ], 'user-1').any((e) => e.clash),
        isFalse,
      );
      expect(
        withClashes([
          hc,
          dc.copyWith(assignee: (id: 'user-3', name: null)),
        ], 'user-1').any((e) => e.clash),
        isFalse,
      );
      // The owner assigned to one row is the advocate of an unassigned one.
      expect(
        withClashes([
          hc,
          dc.copyWith(assignee: (id: 'user-1', name: null)),
        ], 'user-1').every((e) => e.clash),
        isTrue,
      );
    });

    test('day summary', () {
      final day = [hc, dc, diaryEntry(4, boarded: false)];
      expect(day.courtCount, 2);
      expect(day.boardBuilt, isTrue);
      expect([diaryEntry(5, boarded: false)].boardBuilt, isFalse);
    });
  });

  group('tasks due', () {
    final today = DateTime.utc(2026, 11, 5);
    Map<String, dynamic> task(String id, String dueAt, {String? matter}) => {
      'id': id,
      'title': 'File reply',
      'due_at': dueAt,
      'matter_id': matter,
      'case_type': matter == null ? null : 'WP',
      'case_number': matter == null ? null : '1234',
      'case_year': matter == null ? null : 2024,
    };

    test('by end of today IST, overdue marked, soonest first', () {
      final due = dueTasks([
        task('late', '2026-11-05T18:30:00Z'), // 00:00 IST on the 6th
        task('today', '2026-11-05 18:29:00+00', matter: 'm-1'),
        task('overdue', '2026-11-04T18:29:59.000Z'), // 23:59 IST on the 4th
        task('morning', '2026-11-04 18:30:00'), // no zone = UTC: 00:00 IST
      ], today);
      expect(due.map((t) => t.id), ['overdue', 'morning', 'today']);
      expect(due.map((t) => t.overdue), [true, false, false]);
      expect(due.last.caseLabel, 'WP 1234/2024');
    });
  });

  group('needs attention', () {
    final now = _ist(10); // 04:30 UTC
    Map<String, dynamic> matter(
      String id, {
      String tracking = 'auto',
      String? fetched = '2026-11-01T10:00:00Z',
      String status = 'pending',
      String? next,
      String? lastHearing,
      String? noted,
      String created = '2026-10-01T10:00:00Z',
    }) => {
      'id': id,
      'case_type': 'WP',
      'case_number': id,
      'case_year': 2024,
      'tracking': tracking,
      'court_fetched_at': fetched,
      'court_status': status,
      'next_hearing_date': next,
      'last_hearing_date': lastHearing,
      'user_next_date': noted,
      'created_at': created,
    };
    List<(AttentionKind, String?)> items(
      List<Map<String, dynamic>> rows, [
      List<DiaryNotice> issues = const [],
    ]) => [
      for (final i in needsAttention(rows, issues, now))
        (i.kind, i.matterId ?? i.notificationId),
    ];

    test('no next date: fetched, pending, missing or past', () {
      expect(
        items([
          matter('1'),
          matter('2', next: '2026-11-04'),
          matter('3', next: '2026-11-05'),
          matter('4', status: 'disposed'),
        ]),
        [(AttentionKind.noNextDate, '1'), (AttentionKind.noNextDate, '2')],
      );
    });

    test('court data not fetched over an hour after adding', () {
      expect(
        items([
          matter('1', fetched: null, created: '2026-11-05T03:30:00Z'),
          matter('2', fetched: null, created: '2026-11-05T03:31:00Z'),
        ]),
        [(AttentionKind.courtDataPending, '1')],
      );
    });

    test('a sync issue from the last 2 days, once', () {
      DiaryNotice issue(String id, DateTime at) =>
          DiaryNotice(id: id, kind: 'sync_issue', createdAt: at);
      expect(
        items(const [], [
          issue('n-new', DateTime.utc(2026, 11, 5, 2)),
          issue('n-old', DateTime.utc(2026, 11, 4)),
        ]),
        [(AttentionKind.courtDataDelayed, 'n-new')],
      );
      expect(items(const [], [issue('n', DateTime.utc(2026, 11, 3))]), isEmpty);
    });

    test('manual case with no hearing today or later', () {
      expect(
        items([
          matter('1', tracking: 'manual'),
          matter('2', tracking: 'manual', lastHearing: '2026-11-04'),
          matter('3', tracking: 'manual', lastHearing: '2026-11-05'),
        ]),
        [(AttentionKind.addNextDate, '1'), (AttentionKind.addNextDate, '2')],
      );
    });

    test('court and user dates differ', () {
      final found = needsAttention(
        [
          matter('1', next: '2026-11-12', noted: '2026-11-14'),
          matter('2', next: '2026-11-12', noted: '2026-11-12'),
          matter(
            '3',
            next: '2026-11-12',
            noted: '2026-11-04',
          ), // noted date passed
          matter(
            '4',
            next: '2026-11-01',
            noted: '2026-11-14',
          ), // wins over "no next date"
        ],
        const [],
        now,
      );
      expect(found.map((i) => (i.kind, i.matterId)), [
        (AttentionKind.dateMismatch, '1'),
        (AttentionKind.dateMismatch, '4'),
      ]);
      expect(found.first.courtDate, DateTime.utc(2026, 11, 12));
      expect(found.first.userDate, DateTime.utc(2026, 11, 14));
      expect(found.first.caseLabel, 'WP 1/2024');
    });
  });

  group('diary text', () {
    setUpAll(() async {
      await initializeDateFormatting('en');
      await initializeDateFormatting('hi');
    });

    final day = withClashes([
      diaryEntry(1, item: 23, slot: _at(11, 58)),
      diaryEntry(2, court: _district, courtNo: '5', item: 1, slot: _at(11)),
    ], 'user-1');

    test('screen-reader row and clash explanation in English', () {
      final l = lookupAppLocalizations(const Locale('en'));
      const en = Locale('en');
      expect(
        diaryRowLabel(l, en, day[0]),
        'WP 1001 of 2024. MP High Court Indore. Court 12, item 23. Clash.',
      );
      expect(
        clashExplanation(l, en, day[0], day),
        'Clashes with WP 1002/2024 at District Court Indore, about 11:00 am. '
        'Times are estimated from item numbers.',
      );
      expect(
        diaryRowLabel(l, en, diaryEntry(3, boarded: false, proxy: true)),
        'WP 1003 of 2024. MP High Court Indore. Court 12. Item number not out yet. '
        'Proxy arranged.',
      );
      expect(positionText(l, diaryEntry(3, boarded: false)), 'Court 12');
      expect(positionText(l, diaryEntry(3, courtNo: null)), 'Item 3');
      expect(clashExplanation(l, en, diaryEntry(4), day), isNull);
    });

    test('and in Hindi', () {
      final l = lookupAppLocalizations(const Locale('hi'));
      const hi = Locale('hi');
      expect(
        diaryRowLabel(l, hi, day[0]),
        'WP 1001 सन 2024। MP हाई कोर्ट इंदौर। कोर्ट 12, आइटम 23। एक साथ पेशी।',
      );
      expect(
        diaryRowLabel(l, hi, diaryEntry(3, boarded: false)),
        'WP 1003 सन 2024। MP हाई कोर्ट इंदौर। कोर्ट 12। आइटम नंबर अभी नहीं आया।',
      );
      expect(
        clashExplanation(l, hi, day[1], day),
        'एक साथ पेशी: MPHC इंदौर में WP 1001/2024, लगभग सुबह 11:58। '
        'समय आइटम नंबर से अनुमानित है।',
      );
    });
  });

  test('owners and advocates manage the board', () {
    Membership as(String role) =>
        Membership(orgId: 'o', orgName: 'o', orgKind: 'solo', role: role);
    expect(
      ['owner', 'advocate', 'junior', 'clerk'].map((r) => as(r).managesBoard),
      [true, true, false, false],
    );
  });

  test('the fake diary re-applies the clash rule on writes', () async {
    final diary = FakeDiary(
      days: {
        testToday: [
          diaryEntry(1, slot: _at(10, 30)),
          diaryEntry(2, court: _district, slot: _at(11)),
        ],
      },
    );
    final c = ProviderContainer(overrides: diary.overrides);
    addTearDown(c.dispose);
    final seen = <List<bool>>[];
    c.listen(
      diaryProvider(testToday),
      (_, next) => seen.add([
        for (final e in next.value ?? const <DiaryEntry>[]) e.clash,
      ]),
      fireImmediately: true,
    );
    await pumpEventQueue();
    await diary.setProxy('b-2', arranged: true);
    await pumpEventQueue();
    expect(seen.where((s) => s.isNotEmpty), [
      [true, true],
      [false, false],
    ]);
    expect(diary.writes.single.name, 'setProxy');
  });
}
