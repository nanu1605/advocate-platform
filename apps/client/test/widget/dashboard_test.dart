import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/router.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/diary.dart';
import 'package:advocate_app/features/calendar/calendar_screen.dart';
import 'package:advocate_app/features/calendar/calendar_widgets.dart';
import 'package:advocate_app/features/case_page/case_page.dart';
import 'package:advocate_app/features/dashboard/dashboard_screen.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

/// The owner of a chamber with complete details (the dashboard's Team row).
const chamberOwner = Account(
  id: 'user-1',
  fullName: 'Ramesh Sharma',
  enrolmentNo: 'MP/1234/2010',
  barCouncilState: 'MP',
  memberships: [
    Membership(
      orgId: 'org-1',
      orgName: 'Sharma Chambers',
      orgKind: 'chamber',
      role: 'owner',
    ),
  ],
);

/// Thu 5 Nov 2026, 10:00 IST (week Mon 2 – Sun 8 Nov): 4 active cases (m-5 is disposed), 2 heard this week (m-1 on
/// the 5th, m-2 on the 7th, both Neha Verma's), 1 overdue task, 3 new orders; WP 1001 and WP 1003 in court today.
List<Override> sampleDashboard() => [
  ...FakeDiary(
    days: {
      testToday: [
        diaryEntry(1, courtNo: '7', item: 4),
        diaryEntry(3, item: 23),
      ],
    },
    tasks: [
      DueTask(
        id: 't-1',
        title: 'Collect certified copy',
        dueAt: DateTime.utc(2026, 11, 3, 6),
        overdue: true,
      ),
      DueTask(
        id: 't-2',
        title: 'File reply',
        dueAt: DateTime.utc(2026, 11, 5, 11, 30),
      ),
    ],
    orders: const [
      DiaryNotice(id: 'n-1', kind: 'new_order', matterId: 'm-1'),
      DiaryNotice(id: 'n-2', kind: 'new_order', matterId: 'm-2'),
      DiaryNotice(id: 'n-3', kind: 'new_order', matterId: 'm-3'),
    ],
  ).overrides,
  ...FakeCases(
    cases: [
      caseInfo(1, nextDate: DateTime.utc(2026, 11, 5), assigneeId: 'user-3'),
      caseInfo(2, nextDate: DateTime.utc(2026, 11, 7), assigneeId: 'user-3'),
      caseInfo(3, nextDate: DateTime.utc(2026, 11, 12), assigneeId: 'user-2'),
      caseInfo(4),
      caseInfo(5, courtStatus: 'disposed'),
    ],
  ).caseOverrides,
];

String _at(WidgetTester tester) =>
    container(tester)
        .read(routerProvider)
        .routerDelegate
        .currentConfiguration
        .uri
        .toString();

/// The practice dashboard (spec §4.4 F18): counts, their taps, Today, the Team row, empty org, Windows layout.
void main() {
  setUpAll(loadAppFonts);
  final en = lookupAppLocalizations(const Locale('en'));

  Finder tile(int count, String label) =>
      find.bySemanticsLabel('$count $label');

  for (final locale in ['en', 'hi']) {
    final l = lookupAppLocalizations(Locale(locale));
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'counts, Today and the team read in full ($locale ${scale}x)',
        (tester) async {
          final handle = tester.ensureSemantics();
          await pumpApp(
            tester,
            location: '/dashboard',
            account: chamberOwner,
            locale: locale,
            textScale: scale,
            overrides: sampleDashboard(),
          );
          expect(find.text(l.navDashboard), findsWidgets);
          expect(tile(4, l.dashActiveCases), findsOneWidget);
          expect(tile(2, l.dashHearingsThisWeek), findsOneWidget);
          expect(tile(1, l.dashOverdueTasks), findsOneWidget);
          expect(tile(3, l.todayNewOrders), findsOneWidget);
          final list = find.byType(Scrollable).first;
          await tester.scrollUntilVisible(
            find.text('${l.navToday} (2)'),
            200,
            scrollable: list,
          );
          expect(find.textContaining('WP 1001/2024'), findsWidgets);
          await tester.scrollUntilVisible(
            find.text(l.dashTeam),
            200,
            scrollable: list,
          );
          // Clerks have no row; Neha Verma has both cases heard this week.
          for (final (name, n) in [
            ('Ramesh Sharma', 0),
            ('Neha Verma', 2),
            ('Rakesh Jain', 0),
          ]) {
            await tester.scrollUntilVisible(
              find.text(name),
              200,
              scrollable: list,
            );
            expect(
              find.bySemanticsLabel(
                RegExp(
                  '$name.*${RegExp.escape(l.dashMemberCases(n))}',
                  dotAll: true,
                ),
              ),
              findsOneWidget,
            );
          }
          expect(find.text('Mohan Lal'), findsNothing);
          expect(tester.takeException(), isNull);
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          handle.dispose();
        },
      );
    }
  }

  group('each count opens its view', () {
    Future<void> tapTile(WidgetTester tester, Finder f) async {
      await pumpApp(
        tester,
        location: '/dashboard',
        account: chamberOwner,
        overrides: sampleDashboard(),
      );
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    testWidgets('active cases: the Cases list showing just those', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tapTile(tester, tile(4, en.dashActiveCases));
      expect(_at(tester), '/cases');
      expect(
        container(tester).read(caseFilterProvider).status,
        CaseStatusFilter.pending,
      );
      handle.dispose();
    });

    testWidgets('hearings this week: the calendar week, hearings shown', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpApp(
        tester,
        location: '/dashboard',
        account: chamberOwner,
        overrides: sampleDashboard(),
      );
      // Hearings were switched off in the calendar's filters earlier.
      container(tester)
          .read(calendarPrefsProvider.notifier)
          .toggle(CalendarType.hearing);
      await tester.tap(tile(2, en.dashHearingsThisWeek));
      await tester.pumpAndSettle();
      expect(_at(tester), '/calendar');
      final prefs = container(tester).read(calendarPrefsProvider);
      expect(prefs.view, CalendarView.week);
      expect(prefs.day, isNull);
      expect(prefs.types, CalendarType.values.toSet());
      handle.dispose();
    });

    testWidgets("overdue tasks: Today's tasks", (tester) async {
      final handle = tester.ensureSemantics();
      await tapTile(tester, tile(1, en.dashOverdueTasks));
      expect(_at(tester), '/today');
      handle.dispose();
    });

    testWidgets('new orders: the notification centre for new orders', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tapTile(tester, tile(3, en.todayNewOrders));
      expect(_at(tester), '/notifications?kind=new_order');
      handle.dispose();
    });

    testWidgets('a row of Today opens its case', (tester) async {
      await pumpApp(
        tester,
        location: '/dashboard',
        account: chamberOwner,
        overrides: sampleDashboard(),
      );
      await tester.scrollUntilVisible(
        find.textContaining('WP 1003/2024').first,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.textContaining('WP 1003/2024').first);
      await tester.pumpAndSettle();
      expect(tester.widget<CasePage>(find.byType(CasePage)).matterId, 'm-3');
    });
  });

  testWidgets('someone else in the chamber sees the counts but no team row', (
    tester,
  ) async {
    await pumpApp(
      tester,
      location: '/dashboard',
      account: juniorAccount,
      overrides: sampleDashboard(),
    );
    expect(find.text(en.dashActiveCases), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('${en.navToday} (2)'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text(en.dashTeam), findsNothing);
  });

  testWidgets('every case closed: the counts at zero, not the empty state', (
    tester,
  ) async {
    await pumpApp(
      tester,
      location: '/dashboard',
      overrides: [
        ...FakeDiary(members: [testMembers.first]).overrides,
        ...FakeCases(cases: [caseInfo(1, courtStatus: 'disposed')])
            .caseOverrides,
      ],
    );
    expect(find.text(en.dashEmpty), findsNothing);
    expect(find.text(en.dashActiveCases), findsOneWidget);
  });

  testWidgets('an empty practice: one line and Add your first case', (
    tester,
  ) async {
    await pumpApp(
      tester,
      location: '/dashboard',
      overrides: [
        ...FakeDiary(members: [testMembers.first]).overrides,
        ...FakeCases().caseOverrides,
      ],
    );
    expect(find.text(en.dashEmpty), findsOneWidget);
    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text(en.addFirstCase), findsOneWidget);
    expect(find.text(en.dashActiveCases), findsNothing);
  });

  // Spec §16.6: the dashboard reads the synced database, so it works offline.
  testWidgets('offline: the counts and Today show under the banner', (
    tester,
  ) async {
    await pumpApp(
      tester,
      location: '/dashboard',
      account: chamberOwner,
      overrides: [...sampleDashboard(), ...syncedData(offline: true)],
    );
    expect(find.byType(OfflineBanner), findsOneWidget);
    expect(find.text(en.dashActiveCases), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    expect(find.text('${en.navToday} (2)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows: the four counts in one row, Today below', (
    tester,
  ) async {
    await pumpApp(
      tester,
      location: '/dashboard',
      account: chamberOwner,
      size: const Size(1280, 800),
      overrides: sampleDashboard(),
    );
    expect(find.byType(DashboardScreen), findsOneWidget);
    final tops = {
      for (final label in [
        en.dashActiveCases,
        en.dashHearingsThisWeek,
        en.dashOverdueTasks,
        en.todayNewOrders,
      ])
        tester.getTopLeft(find.text(label)).dy,
    };
    expect(tops, hasLength(1));
    expect(
      tester.getTopLeft(find.text('${en.navToday} (2)')).dy,
      greaterThan(tops.single),
    );
    expect(tester.takeException(), isNull);
  });
}
