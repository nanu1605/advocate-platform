import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/data/courts.dart';
import 'package:advocate_app/data/diary.dart';
import 'package:advocate_app/data/diary_text.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:advocate_app/features/board/board_screen.dart';
import 'package:advocate_app/features/cases/case_placeholder_screen.dart';
import 'package:advocate_app/features/lock/app_lock.dart';
import 'package:advocate_app/ui/case_card.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

final Court _district = testCourts[3];

/// Today at 10:00 IST: WP 1001 (Court 7, item 4, about 10:42) is next; WP 1002 (Court 12, item 23, about 11:58)
/// clashes with CS-like WP 1003 at the district court (about 12:30); WP 1004 is a manual case with no item yet.
List<DiaryEntry> todaySample() => [
  diaryEntry(2, item: 23),
  diaryEntry(
    3,
    court: _district,
    courtNo: '5',
    item: 8,
    slot: const Duration(hours: 12, minutes: 30),
  ),
  diaryEntry(1, courtNo: '7', item: 4, title: 'Verma v. State of MP'),
  diaryEntry(
    4,
    court: _district,
    courtNo: '5',
    boarded: false,
    tracking: 'manual',
  ),
];

/// Tomorrow: 3 matters in 2 courts.
List<DiaryEntry> tomorrowSample() => [
  diaryEntry(5),
  diaryEntry(6, item: 9),
  diaryEntry(7, court: _district, courtNo: '5'),
];

FakeDiary sampleDiary({
  List<DiaryEntry>? today,
  List<DiaryEntry>? tomorrow,
  bool? hasMatters = true,
  DateTime? now,
  Duration eveningSwitch = defaultEveningSwitch,
}) => FakeDiary(
  days: {
    testToday: today ?? todaySample(),
    testTomorrow: tomorrow ?? tomorrowSample(),
  },
  tasks: [
    DueTask(
      id: 't-1',
      title: 'File reply',
      dueAt: DateTime.utc(2026, 11, 5, 11, 30),
      matterId: 'm-2',
      caseLabel: 'WP 1002/2024',
    ),
    DueTask(
      id: 't-2',
      title: 'Collect certified copy',
      dueAt: DateTime.utc(2026, 11, 3, 6),
      overdue: true,
    ),
  ],
  orders: const [
    DiaryNotice(
      id: 'n-1',
      kind: 'new_order',
      matterId: 'm-2',
      link: '/cases/m-2',
      caseLabel: 'WP 1002/2024',
    ),
  ],
  attention: [
    AttentionItem(
      AttentionKind.dateMismatch,
      matterId: 'm-9',
      caseLabel: 'CRA 455/2023',
      courtDate: DateTime.utc(2026, 11, 12),
      userDate: DateTime.utc(2026, 11, 14),
    ),
    const AttentionItem(AttentionKind.courtDataDelayed, notificationId: 'n-9'),
  ],
  hasMatters: hasMatters,
  now: now,
  eveningSwitch: eveningSwitch,
);

/// 18:30 IST on 5 Nov.
final _evening = DateTime.utc(2026, 11, 5, 13);

Future<FakeApi> _open(
  WidgetTester tester,
  FakeDiary diary, {
  String locale = 'en',
  double scale = 1,
  Size size = const Size(400, 860),
  bool offline = false,
}) => pumpApp(
  tester,
  locale: locale,
  textScale: scale,
  size: size,
  overrides: [
    ...diary.overrides,
    if (offline)
      syncViewProvider.overrideWithValue(
        const AsyncData((status: SyncStatus.syncing, offline: true)),
      ),
  ],
);

/// The court takes a second to answer each refresh.
class _SlowApi extends FakeApi {
  _SlowApi() : super(account: ownerAccount);

  @override
  Future<String> refreshMatter({
    required String orgId,
    required String matterId,
    required String idempotencyKey,
  }) async {
    await Future<void>.delayed(const Duration(seconds: 1));
    return await super.refreshMatter(
      orgId: orgId,
      matterId: matterId,
      idempotencyKey: idempotencyKey,
    );
  }
}

Future<void> _pullToRefresh(WidgetTester tester) async {
  await tester.fling(find.byType(RefreshIndicator), const Offset(0, 400), 1000);
  await tester.pumpAndSettle();
}

Iterable<Map<dynamic, dynamic>> _refreshCalls(FakeApi api) => [
  for (final c in api.calls)
    if (c.name == 'refreshMatter') c.args! as Map,
];

/// Today (spec §4.2, §5.3): hero card by time, sections, empty state, the evening switch, refresh, writes,
/// Windows keys, both languages at 200% and the a11y guidelines.
void main() {
  setUpAll(loadAppFonts);
  final en = lookupAppLocalizations(const Locale('en'));

  for (final locale in ['en', 'hi']) {
    final l = lookupAppLocalizations(Locale(locale));
    final loc = Locale(locale);
    for (final scale in [1.0, 2.0]) {
      testWidgets('hero, sections and rows read in full ($locale ${scale}x)', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await _open(tester, sampleDiary(), locale: locale, scale: scale);
        final date = locale == 'hi' ? 'गुरु, 5 नवंबर' : 'Thu, 5 Nov';
        expect(find.text('${l.navToday} · $date'), findsOneWidget);
        expect(find.text(l.todayNext), findsOneWidget);
        final hero = tester.widget<CaseCard>(find.byType(CaseCard));
        expect(hero.data.caseNumber, 'WP 1001/2024');
        expect(hero.data.title, 'Verma v. State of MP');
        expect(find.text(l.todayOpen), findsOneWidget);
        expect(find.text(l.caseNotes), findsOneWidget);
        expect(find.text(l.todayBriefMe), findsNothing);
        expect(find.text('${l.navToday} (4)'), findsOneWidget);

        final day = orderDiary(withClashes(todaySample(), 'user-1'));
        expect(day.map((e) => e.matterId), ['m-1', 'm-2', 'm-3', 'm-4']);
        final clashing = day[1];
        expect(clashing.clash, isTrue);
        expect(
          find.bySemanticsLabel(diaryRowLabel(l, loc, clashing)),
          findsOneWidget,
        );
        expect(
          find.text(clashExplanation(l, loc, clashing, day)!),
          findsOneWidget,
        );
        expect(find.text(l.statusClash), findsNWidgets(2));
        // The manual case has no item number yet, and says so, also to screen readers.
        expect(
          find.text('${l.courtNo('5')} · ${l.todayNoItem}'),
          findsOneWidget,
        );
        expect(
          find.bySemanticsLabel(diaryRowLabel(l, loc, day[3])),
          findsOneWidget,
        );
        expect(day[3].itemNo, isNull);

        final list = find.byType(Scrollable).first;
        for (final (title, n) in [
          (l.todayTasksDue, 2),
          (l.todayNewOrders, 1),
          (l.todayAttention, 2),
        ]) {
          await tester.scrollUntilVisible(
            find.text('$title ($n)'),
            300,
            scrollable: list,
          );
        }
        await tester.scrollUntilVisible(
          find.text(l.todayTomorrowLink(3)),
          300,
          scrollable: list,
        );
        expect(tester.takeException(), isNull);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        handle.dispose();
      });
    }
  }

  testWidgets('the hero is the next matter whose window has not ended', (
    tester,
  ) async {
    // 11:45 IST: WP 1001's estimated window (10:42–11:42) is over; WP 1002 (11:58) is next.
    await _open(tester, sampleDiary(now: DateTime.utc(2026, 11, 5, 6, 15)));
    expect(
      tester.widget<CaseCard>(find.byType(CaseCard)).data.caseNumber,
      'WP 1002/2024',
    );
  });

  testWidgets('a device clock in UTC at 23:30 is 05:00 IST the next day', (
    tester,
  ) async {
    // 23:30 on 4 Nov in UTC: Today is Thu 5 Nov in India, morning, so the hero leads.
    await _open(tester, sampleDiary(now: DateTime.utc(2026, 11, 4, 23, 30)));
    expect(find.text('${en.navToday} · Thu, 5 Nov'), findsOneWidget);
    expect(
      tester.widget<CaseCard>(find.byType(CaseCard)).data.caseNumber,
      'WP 1001/2024',
    );
    expect(find.text(en.todayTomorrowBanner(3, 2)), findsNothing);
  });

  testWidgets('a hero without an item number says so', (tester) async {
    await _open(
      tester,
      sampleDiary(today: [diaryEntry(1, boarded: false, bench: 'Justice A')]),
    );
    final data = tester.widget<CaseCard>(find.byType(CaseCard)).data;
    expect(data.itemNo, isNull);
    expect(data.judge, 'Justice A');
    expect(data.purpose, 'Admission · ${en.todayNoItem}');
  });

  testWidgets('hero Open and Notes open the case', (tester) async {
    await _open(tester, sampleDiary());
    await tester.tap(find.text(en.caseNotes));
    await tester.pumpAndSettle();
    var page = tester.widget<CasePlaceholderScreen>(
      find.byType(CasePlaceholderScreen),
    );
    expect((page.matterId, page.tab), ('m-1', 'notes'));
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.todayOpen));
    await tester.pumpAndSettle();
    page = tester.widget<CasePlaceholderScreen>(
      find.byType(CasePlaceholderScreen),
    );
    expect((page.matterId, page.tab), ('m-1', null));
  });

  testWidgets('a row opens its case', (tester) async {
    await _open(tester, sampleDiary());
    await tester.tap(find.text('WP 1003/2024'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CasePlaceholderScreen>(find.byType(CasePlaceholderScreen))
          .matterId,
      'm-3',
    );
  });

  group('empty', () {
    testWidgets('no matters today: a link to tomorrow', (tester) async {
      await _open(tester, sampleDiary(today: []));
      expect(find.text(en.todayEmpty), findsOneWidget);
      expect(find.byType(CaseCard), findsNothing);
      await tester.tap(find.text(en.todayTomorrowLink(3)));
      await tester.pumpAndSettle();
      expect(find.byType(BoardScreen), findsOneWidget);
    });

    testWidgets('cases today but nothing tomorrow: no link to an empty board', (
      tester,
    ) async {
      await _open(tester, sampleDiary(tomorrow: []));
      await tester.scrollUntilVisible(
        find.text('${en.todayAttention} (2)'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('Tomorrow:'), findsNothing);
    });

    testWidgets('still finding out whether there are cases: no action yet', (
      tester,
    ) async {
      await _open(
        tester,
        sampleDiary(today: [], tomorrow: [], hasMatters: null),
      );
      expect(find.text(en.todayEmpty), findsOneWidget);
      expect(find.text(en.addFirstCase), findsNothing);
    });

    testWidgets('nothing tomorrow either, but cases exist: no action', (
      tester,
    ) async {
      await _open(tester, sampleDiary(today: [], tomorrow: []));
      expect(find.text(en.todayEmpty), findsOneWidget);
      expect(find.text(en.addFirstCase), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      // The other sections still show.
      expect(find.text('${en.todayTasksDue} (2)'), findsOneWidget);
    });

    testWidgets('no cases at all: add the first one', (tester) async {
      await _open(
        tester,
        sampleDiary(today: [], tomorrow: [], hasMatters: false),
      );
      expect(find.text(en.addFirstCase), findsOneWidget);
    });
  });

  group('evening switch', () {
    testWidgets('from 18:30 IST the Tomorrow banner leads', (tester) async {
      await _open(tester, sampleDiary(now: _evening));
      expect(find.byType(CaseCard), findsNothing);
      expect(find.text(en.todayTomorrowBanner(3, 2)), findsOneWidget);
      expect(find.text(en.todayTomorrowLink(3)), findsNothing);
      await tester.tap(find.text(en.todayTomorrowBanner(3, 2)));
      await tester.pumpAndSettle();
      expect(find.byType(BoardScreen), findsOneWidget);
    });

    testWidgets('in Hindi at 200%, plural-correct for one', (tester) async {
      await _open(
        tester,
        sampleDiary(now: _evening, tomorrow: [diaryEntry(5)]),
        locale: 'hi',
        scale: 2,
      );
      final hi = lookupAppLocalizations(const Locale('hi'));
      expect(find.text(hi.todayTomorrowBanner(1, 1)), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('nothing listed for tomorrow', (tester) async {
      await _open(tester, sampleDiary(now: _evening, tomorrow: []));
      expect(find.text(en.todayTomorrowNone), findsOneWidget);
    });

    testWidgets('the switch time is configurable', (tester) async {
      await _open(
        tester,
        sampleDiary(now: _evening, eveningSwitch: const Duration(hours: 20)),
      );
      expect(find.text(en.todayTomorrowBanner(3, 2)), findsNothing);
      // 18:30: every estimated window has ended; WP 1004 has no estimate, so it is still the hero.
      expect(
        tester.widget<CaseCard>(find.byType(CaseCard)).data.caseNumber,
        'WP 1004/2024',
      );
    });
  });

  group('refresh', () {
    testWidgets("today's tracked cases, one summary", (tester) async {
      final api = await _open(tester, sampleDiary());
      await _pullToRefresh(tester);
      // The manual case isn't asked about.
      expect(
        {for (final a in _refreshCalls(api)) a['id']},
        {'m-1', 'm-2', 'm-3'},
      );
      expect(find.text(en.todayRefreshChecking(3)), findsOneWidget);
    });

    testWidgets('refreshed recently counts as up to date', (tester) async {
      final api = FakeApi(account: ownerAccount)
        ..refreshedRecently.addAll(['m-1', 'm-2', 'm-3']);
      await pumpApp(tester, api: api, overrides: sampleDiary().overrides);
      await _pullToRefresh(tester);
      expect(find.text(en.todayRefreshUpToDate), findsOneWidget);
      expect(find.text(en.errorTooMany), findsNothing);
    });

    testWidgets('offline: the banner, saved data and no calls', (tester) async {
      final api = await _open(tester, sampleDiary(), offline: true);
      expect(find.byType(OfflineBanner), findsOneWidget);
      expect(find.byType(CaseCard), findsOneWidget);
      await _pullToRefresh(tester);
      expect(_refreshCalls(api), isEmpty);
      expect(find.text(en.todayRefreshOffline), findsOneWidget);
    });

    testWidgets('while it runs, it says so on screen', (tester) async {
      final api = _SlowApi();
      await pumpApp(tester, api: api, overrides: sampleDiary().overrides);
      await tester.fling(
        find.byType(RefreshIndicator),
        const Offset(0, 400),
        1000,
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text(en.todayRefreshing), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(find.text(en.todayRefreshing), findsNothing);
      expect(find.text(en.todayRefreshChecking(3)), findsOneWidget);
    });

    testWidgets('F5 does nothing while the app is locked', (tester) async {
      final api = await _open(
        tester,
        sampleDiary(),
        size: const Size(1280, 800),
      );
      final lock = container(tester).read(appLockProvider.notifier);
      await lock.usePin('2468');
      await lock.setTimeoutMinutes(0);
      lock
        ..backgrounded()
        ..resumed();
      await tester.pumpAndSettle();
      expect(container(tester).read(appLockProvider).locked, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.f5);
      await tester.pumpAndSettle();
      expect(_refreshCalls(api), isEmpty);
    });

    testWidgets('F5 on Windows refreshes', (tester) async {
      final api = await _open(
        tester,
        sampleDiary(),
        size: const Size(1280, 800),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.f5);
      await tester.pumpAndSettle();
      expect(_refreshCalls(api), hasLength(3));
      expect(find.text(en.todayRefreshChecking(3)), findsOneWidget);
    });
  });

  testWidgets('a task done hides it, with a haptic and undo', (tester) async {
    final diary = sampleDiary();
    final haptics = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          haptics.add(call.arguments);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _open(tester, diary);
    final task = find.text('File reply · WP 1002/2024');
    await tester.scrollUntilVisible(
      task,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text(en.taskDue('5:00 pm')), findsOneWidget);
    // Overdue tasks show their date, marked overdue (not "urgent").
    expect(find.text(en.taskDue('Tue, 3 Nov')), findsOneWidget);
    expect(find.text(en.statusOverdue), findsOneWidget);
    expect(find.text(en.statusUrgent), findsNothing);
    await tester.tap(task);
    await tester.pump();
    expect(diary.writes.last, (name: 'completeTask', args: 't-1'));
    expect(haptics, ['HapticFeedbackType.lightImpact']);
    await tester.pumpAndSettle();
    expect(find.text(en.todayTaskDone), findsOneWidget);
    expect(task, findsNothing);
    expect(find.text('${en.todayTasksDue} (1)'), findsOneWidget);
    await tester.tap(find.text(en.undo));
    await tester.pumpAndSettle();
    expect(diary.writes.last, (name: 'reopenTask', args: 't-1'));
    expect(task, findsOneWidget);
  });

  testWidgets('a new order is marked read and opens its case', (tester) async {
    final diary = sampleDiary();
    await _open(tester, diary);
    final order = find.text(en.statusNewOrder);
    await tester.scrollUntilVisible(
      order,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(order);
    await tester.pumpAndSettle();
    expect(diary.readNotifications, {'n-1'});
    expect(
      tester
          .widget<CasePlaceholderScreen>(find.byType(CasePlaceholderScreen))
          .matterId,
      'm-2',
    );
  });

  testWidgets('needs attention: court and user dates; delayed data hides', (
    tester,
  ) async {
    final diary = sampleDiary();
    await _open(tester, diary);
    final mismatch = find.text(
      en.todayAttnMismatch('Thu, 12 Nov', 'Sat, 14 Nov'),
    );
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(mismatch, 300, scrollable: list);
    await tester.scrollUntilVisible(
      find.text(en.todayAttnDelayed),
      100,
      scrollable: list,
    );
    await tester.tap(find.text(en.todayAttnDelayed));
    await tester.pumpAndSettle();
    expect(diary.readNotifications, {'n-9'});
    expect(find.text(en.todayAttnDelayed), findsNothing);
    expect(find.text('${en.todayAttention} (1)'), findsOneWidget);
    await tester.tap(mismatch);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CasePlaceholderScreen>(find.byType(CasePlaceholderScreen))
          .matterId,
      'm-9',
    );
  });

  testWidgets('Windows: a readable column; Enter opens the focused row', (
    tester,
  ) async {
    await _open(tester, sampleDiary(), size: const Size(1280, 800));
    expect(tester.getSize(find.byType(CaseCard)).width, lessThanOrEqualTo(720));
    final row = find.text('WP 1002/2024').first;
    Focus.of(tester.element(row)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CasePlaceholderScreen>(find.byType(CasePlaceholderScreen))
          .matterId,
      'm-2',
    );
  });
}
