import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/router.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/features/case_page/case_page.dart';
import 'package:advocate_app/features/cases/cases_screen.dart';
import 'package:advocate_app/features/found_cases/found_cases_screen.dart';
import 'package:advocate_app/ui/case_card.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:advocate_app/ui/status_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

DateTime _day(int d) => DateTime.utc(2026, 11, d);

/// Today is Thu 5 Nov (IST): two cases today (one assigned, one with a Hindi title and another client), one this
/// week at the district court, one later, a manual one with no next date, a disposed one and an archived one.
List<CaseInfo> sampleCases() => [
  caseInfo(
    1,
    nextDate: _day(5),
    title: 'Ramesh Sharma v. State of MP',
    assigneeId: 'user-3',
    assigneeName: 'Neha Verma',
  ),
  caseInfo(
    2,
    nextDate: _day(5),
    title: 'शर्मा बनाम मध्य प्रदेश राज्य',
    clients: const [(id: 'cl-2', name: 'Anil Gupta')],
  ),
  caseInfo(
    3,
    nextDate: _day(9),
    court: testCourts[3],
    caseType: 'CS',
    courtNo: '5',
    title: 'Verma v. Jain',
  ),
  caseInfo(4, nextDate: _day(20), title: 'Mohan Lal v. State of MP'),
  caseInfo(5, tracking: 'manual', title: 'Gupta v. Housing Board'),
  caseInfo(6, courtStatus: 'disposed', title: 'Patel v. Joshi'),
  caseInfo(7, status: 'archived', title: 'Old v. Archive'),
];

const _tall = Size(400, 1600);
const _wide = Size(1280, 800);

String _path(WidgetTester tester) =>
    container(tester)
        .read(routerProvider)
        .routerDelegate
        .currentConfiguration
        .uri
        .path;

/// The rows on screen, by case label, top to bottom.
List<String> _rows(WidgetTester tester) => [
  for (final card in tester.widgetList<CaseCard>(find.byType(CaseCard)))
    card.data.caseNumber,
];

Future<void> _ctrl(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

/// The Cases list (spec §4.3, §5.3, §5.12).
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  Future<FakeCases> pumpCases(
    WidgetTester tester, {
    List<CaseInfo>? cases,
    int pendingFound = 0,
    String location = '/cases',
    Size size = _tall,
    String locale = 'en',
    double textScale = 1,
    bool offline = false,
  }) async {
    final fake = FakeCases(
      cases: cases ?? sampleCases(),
      pendingFound: pendingFound,
    );
    await pumpApp(
      tester,
      location: location,
      size: size,
      locale: locale,
      textScale: textScale,
      overrides: [...fake.overrides, if (offline) ...syncedData(offline: true)],
    );
    return fake;
  }

  testWidgets(
    'sections in order with counts; archived cases hidden; Found for you',
    (tester) async {
      await pumpCases(tester, pendingFound: 3);
      for (final header in [
        '${en.casesSectionToday} (2)',
        '${en.casesSectionThisWeek} (1)',
        '${en.casesSectionLater} (1)',
        '${en.casesSectionNoNextDate} (1)',
        '${en.casesSectionDisposed} (1)',
      ]) {
        expect(find.text(header), findsOneWidget, reason: header);
      }
      expect(_rows(tester), [
        'WP 1001/2024',
        'WP 1002/2024',
        'CS 1003/2024',
        'WP 1004/2024',
        'WP 1005/2024',
        'WP 1006/2024',
      ]);
      expect(find.text(en.casesSectionArchived), findsNothing);
      // The Hindi title shows; the assignee's initials show.
      expect(find.text('शर्मा बनाम मध्य प्रदेश राज्य'), findsOneWidget);
      expect(find.text('NV'), findsOneWidget);

      final found = find.text('${en.casesFoundForYou} (3)');
      await tester.dragUntilVisible(
        found,
        find.byKey(const PageStorageKey('cases.list')),
        const Offset(0, -300),
      );
      await tester.tap(found);
      await tester.pumpAndSettle();
      expect(find.byType(FoundCasesScreen), findsOneWidget);
    },
  );

  testWidgets('a transferred case sits under Disposed without a Disposed '
      'pill', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpCases(
      tester,
      cases: [
        caseInfo(6, courtStatus: 'disposed'),
        caseInfo(8, courtStatus: 'transferred'),
      ],
    );
    expect(find.text('${en.casesSectionDisposed} (2)'), findsOneWidget);
    expect(find.byType(StatusPill), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp(RegExp.escape(en.foundTransferred))),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('every case archived: say so, Add case, show the archived', (
    tester,
  ) async {
    await pumpCases(tester, cases: [caseInfo(7, status: 'archived')]);
    expect(find.text(en.casesListAllArchived), findsOneWidget);
    expect(find.text(en.foundClearFilters), findsNothing);
    expect(find.widgetWithText(FilledButton, en.addCase), findsOneWidget);
    await tester.tap(find.text(en.casesListShowArchived));
    await tester.pumpAndSettle();
    expect(_rows(tester), ['WP 1007/2024']);
    expect(
      container(tester).read(caseFilterProvider).status,
      CaseStatusFilter.archived,
    );
  });

  testWidgets('Found for you is hidden at zero', (tester) async {
    await pumpCases(tester);
    expect(find.textContaining(en.casesFoundForYou), findsNothing);
    expect(find.byType(Badge), findsNothing);
  });

  // Spec §4.1 auto-match: newly found cases appear in Found for you "with a badge".
  for (final locale in ['en', 'hi']) {
    final l = lookupAppLocalizations(Locale(locale));
    for (final (device, size) in [('phone', _tall), ('Windows', _wide)]) {
      testWidgets('$device, $locale: found cases to review badge the Cases '
          'tab, read with it', (tester) async {
        final semantics = tester.ensureSemantics();
        await pumpCases(tester, size: size, locale: locale, pendingFound: 3);
        final badge = find.byType(Badge);
        expect(badge, findsOneWidget);
        expect(
          find.descendant(of: badge, matching: find.text('3')),
          findsOneWidget,
        );
        expect(
          tester
              .getSemantics(find.bySemanticsLabel(RegExp(l.navCasesFound(3))))
              .label,
          contains(l.navCases),
        );
        semantics.dispose();
      });
    }
  }

  testWidgets('a section header collapses and opens its rows', (tester) async {
    await pumpCases(tester);
    await tester.tap(find.text('${en.casesSectionToday} (2)'));
    await tester.pumpAndSettle();
    expect(find.text('WP 1001/2024'), findsNothing);
    expect(find.text('CS 1003/2024'), findsOneWidget);
    await tester.tap(find.text('${en.casesSectionToday} (2)'));
    await tester.pumpAndSettle();
    expect(find.text('WP 1001/2024'), findsOneWidget);
  });

  testWidgets('a row reads as one item; tapping it opens the case', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpCases(tester);
    expect(
      find.bySemanticsLabel(
        [
          en.diaryCaseOfYear('WP 1001', '2024'),
          'Ramesh Sharma v. State of MP',
          'MP ${en.highCourt} Indore, ${en.courtNo('12')}',
          en.casesListNextOn('Thu, 5 Nov 2026'),
          en.foundPending,
          en.boardAssigneeIs('Neha Verma'),
        ].map((s) => '$s.').join(' '),
      ),
      findsOneWidget,
    );
    semantics.dispose();

    await tester.tap(find.text('WP 1004/2024'));
    await tester.pumpAndSettle();
    expect(tester.widget<CasePage>(find.byType(CasePage)).matterId, 'm-4');
    expect(find.byType(CasesScreen), findsNothing);
  });

  group('search', () {
    Future<void> search(WidgetTester tester, String q) async {
      await tester.enterText(find.byType(TextField), q);
      await tester.pumpAndSettle();
    }

    testWidgets('transliterates both ways', (tester) async {
      await pumpCases(tester);
      await search(tester, 'sharma');
      expect(_rows(tester), ['WP 1001/2024', 'WP 1002/2024']);
      await search(tester, 'शर्मा');
      expect(_rows(tester), ['WP 1001/2024', 'WP 1002/2024']);
    });

    testWidgets('by case number, CNR and client', (tester) async {
      await pumpCases(tester);
      await search(tester, '1003');
      expect(_rows(tester), ['CS 1003/2024']);
      await search(tester, 'MPHC01 0000000004');
      expect(_rows(tester), ['WP 1004/2024']);
      await search(tester, 'anil');
      expect(_rows(tester), ['WP 1002/2024']);
    });

    testWidgets('no results say so; Clear filters shows every case again', (
      tester,
    ) async {
      await pumpCases(tester);
      await search(tester, 'nobody');
      expect(find.byType(CaseCard), findsNothing);
      expect(find.text(en.foundNoMatches), findsOneWidget);
      await tester.tap(find.text(en.foundClearFilters));
      await tester.pumpAndSettle();
      expect(_rows(tester), hasLength(6));
      expect(find.text('nobody'), findsNothing);
    });

    testWidgets('search and filters stay while the app runs', (tester) async {
      await pumpCases(tester);
      await search(tester, 'gupta');
      container(tester).read(routerProvider).go('/today');
      await tester.pumpAndSettle();
      container(tester).read(routerProvider).go('/cases');
      await tester.pumpAndSettle();
      expect(find.text('gupta'), findsOneWidget);
      expect(_rows(tester), ['WP 1002/2024', 'WP 1005/2024']);
    });
  });

  group('filters', () {
    Future<void> filter(
      WidgetTester tester,
      List<String> chips, {
      int count = 0,
    }) async {
      await tester.tap(find.text(en.foundFilters(count)));
      await tester.pumpAndSettle();
      if (count > 0) {
        await tester.tap(find.text(en.foundClearFilters).last);
        await tester.pump();
      }
      for (final chip in chips) {
        await tester.tap(find.widgetWithText(ChoiceChip, chip));
        await tester.pump();
      }
      await tester.tap(find.text(en.foundShowCases));
      await tester.pumpAndSettle();
    }

    testWidgets('status Archived shows only archived cases', (tester) async {
      await pumpCases(tester);
      await filter(tester, [en.casesSectionArchived]);
      expect(find.text('${en.casesSectionArchived} (1)'), findsOneWidget);
      expect(_rows(tester), ['WP 1007/2024']);
      expect(find.text(en.foundFilters(1)), findsOneWidget);
    });

    testWidgets('court, client and assignee', (tester) async {
      await pumpCases(tester);
      await filter(tester, ['District Court Indore']);
      expect(_rows(tester), ['CS 1003/2024']);

      await filter(tester, ['Anil Gupta'], count: 1);
      expect(_rows(tester), ['WP 1002/2024']);

      await filter(tester, ['Neha Verma'], count: 1);
      expect(_rows(tester), ['WP 1001/2024']);
    });

    testWidgets('past a dozen clients, a search box narrows them', (
      tester,
    ) async {
      await pumpCases(
        tester,
        cases: [
          for (var n = 1; n <= 13; n++)
            caseInfo(
              n,
              nextDate: _day(20),
              clients: [(id: 'cl-$n', name: 'Client $n')],
            ),
        ],
      );
      await tester.tap(find.text(en.foundFilters(0)));
      await tester.pumpAndSettle();
      final box = find.widgetWithText(TextField, en.casePageSearchClients);
      expect(box, findsOneWidget);
      await tester.enterText(box, 'Client 13');
      await tester.pump();
      expect(find.widgetWithText(ChoiceChip, 'Client 13'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Client 2'), findsNothing);
    });

    testWidgets('sort by case number is kept in the filter', (tester) async {
      await pumpCases(tester);
      await filter(tester, [en.casesSortNumber]);
      expect(
        container(tester).read(caseFilterProvider).sort,
        CaseSort.caseNumber,
      );
      // Sort isn't a filter.
      expect(find.text(en.foundFilters(0)), findsOneWidget);
    });
  });

  testWidgets('an org without cases: No cases yet, Add case, Found for you', (
    tester,
  ) async {
    await pumpCases(tester, cases: const [], pendingFound: 2);
    expect(find.text(en.casesListEmpty), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('${en.casesFoundForYou} (2)'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, en.addCase));
    await tester.pumpAndSettle();
    expect(find.text(en.casesAddTitle), findsOneWidget);
  });

  testWidgets('offline: the saved cases show under the offline banner', (
    tester,
  ) async {
    await pumpCases(tester, offline: true);
    expect(find.byType(OfflineBanner), findsOneWidget);
    expect(_rows(tester), hasLength(6));
  });

  group('Windows', () {
    testWidgets('two panes: the list beside the chosen case', (tester) async {
      await pumpCases(tester, size: _wide);
      expect(find.text(en.casesListPickCase), findsOneWidget);
      expect(find.byType(CasePage), findsNothing);

      await tester.tap(find.text('CS 1003/2024'));
      await tester.pumpAndSettle();
      expect(_path(tester), '/cases/m-3');
      expect(tester.widget<CasePage>(find.byType(CasePage)).matterId, 'm-3');
      CaseCard card(String label) => tester.widget<CaseCard>(
        find.ancestor(of: find.text(label), matching: find.byType(CaseCard)),
      );
      expect(card('CS 1003/2024').selected, isTrue);
      expect(card('WP 1001/2024').selected, isFalse);
    });

    testWidgets('back on the list, its search box and sections are as left', (
      tester,
    ) async {
      await pumpCases(tester, size: _wide);
      await tester.tap(find.text('CS 1003/2024'));
      await tester.pumpAndSettle();
      // The list beside the case is another page over the first.
      await tester.enterText(find.byType(TextField), 'gupta');
      await tester.pumpAndSettle();
      await tester.tap(find.text('${en.casesSectionNoNextDate} (1)'));
      await tester.pumpAndSettle();

      container(tester).read(routerProvider).go('/cases');
      await tester.pumpAndSettle();
      expect(find.byType(CasePage), findsNothing);
      expect(find.text('gupta'), findsOneWidget);
      expect(_rows(tester), ['WP 1002/2024']);
      expect(find.text('WP 1005/2024'), findsNothing);
    });

    testWidgets('opening a case keeps the list where it was scrolled', (
      tester,
    ) async {
      await pumpCases(
        tester,
        size: _wide,
        cases: [for (var n = 1; n <= 30; n++) caseInfo(n, nextDate: _day(20))],
      );
      ScrollPosition position() => tester
          .state<ScrollableState>(
            find.descendant(
              of: find.byKey(const PageStorageKey('cases.list')),
              matching: find.byType(Scrollable),
            ),
          )
          .position;
      await tester.drag(find.text('WP 1002/2024'), const Offset(0, -600));
      await tester.pumpAndSettle();
      final scrolled = position().pixels;
      expect(scrolled, greaterThan(0));

      await tester.tap(find.byType(CaseCard).hitTestable().first);
      await tester.pumpAndSettle();
      expect(find.byType(CasePage), findsOneWidget);
      expect(position().pixels, scrolled);
    });

    testWidgets('Ctrl+F finds; Up and Down move through rows; Enter opens', (
      tester,
    ) async {
      await pumpCases(tester, size: _wide);
      await _ctrl(tester, LogicalKeyboardKey.keyF);
      final field = tester.widget<EditableText>(find.byType(EditableText));
      expect(field.focusNode.hasFocus, isTrue);

      // Search box → the Today header → its first row.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(tester.widget<CasePage>(find.byType(CasePage)).matterId, 'm-1');

      // Focus stays on the case just opened, so the next row is one key away.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(tester.widget<CasePage>(find.byType(CasePage)).matterId, 'm-2');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(tester.widget<CasePage>(find.byType(CasePage)).matterId, 'm-1');
    });
  });

  for (final locale in ['en', 'hi']) {
    testWidgets('200% text in $locale: phone and two panes fit', (
      tester,
    ) async {
      await pumpCases(
        tester,
        locale: locale,
        textScale: 2,
        size: const Size(400, 860),
        pendingFound: 3,
      );
      expect(find.byType(CaseCard), findsWidgets);
      await tester.tap(
        find.text(lookupAppLocalizations(Locale(locale)).foundFilters(0)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      Navigator.of(tester.element(find.byType(BottomSheet))).pop();
      await tester.pumpAndSettle();

      tester.view.physicalSize = _wide;
      container(tester).read(routerProvider).go('/cases/m-1');
      await tester.pumpAndSettle();
      expect(find.byType(CasePage), findsOneWidget);
      expect(find.byType(CasesScreen), findsOneWidget);
    });
  }
}
