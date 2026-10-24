import 'package:advocate_app/core/router.dart';
import 'package:advocate_app/features/board/board_screen.dart';
import 'package:advocate_app/features/case_page/case_page.dart';
import 'package:advocate_app/features/cases/cases_screen.dart';
import 'package:advocate_app/features/cases/manual_case_screen.dart';
import 'package:advocate_app/features/cases/search_cases_screen.dart';
import 'package:advocate_app/features/today/today_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

/// Routes for Today, the board and cases, including every `data.link` the workers write (spec §13.2 deep links).
void main() {
  FakeDiary diary() => FakeDiary(
    days: {
      testToday: [diaryEntry(1)],
      testTomorrow: [diaryEntry(2, boarded: false)],
    },
  );

  testWidgets(
    'a case link opens the case page on its tab; wide windows keep the list',
    (tester) async {
      final cases = FakeCases(cases: [caseInfo(1), caseInfo(2)]);
      await pumpApp(
        tester,
        location: '/cases/m-1?tab=notes',
        overrides: [...diary().overrides, ...cases.caseOverrides],
      );
      final page = tester.widget<CasePage>(find.byType(CasePage));
      expect((page.matterId, page.tab), ('m-1', 'notes'));
      expect(find.byType(CasesScreen), findsNothing);
      expect(find.widgetWithText(AppBar, 'WP 1001/2024'), findsOneWidget);
      expect(find.text('Sharma v. State of MP'), findsOneWidget);

      tester.view.physicalSize = const Size(1280, 800);
      await tester.pumpAndSettle();
      final list = tester.widget<CasesScreen>(find.byType(CasesScreen));
      expect((list.selectedId, list.tab), ('m-1', 'notes'));
      expect(find.byType(CasePage), findsOneWidget);
      final state = tester.state(find.byType(CasesScreen));

      // Another case on a wide window keeps the same page (and list): only the selection changes.
      container(tester).read(routerProvider).go('/cases/m-2');
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(CasesScreen)), same(state));
      expect(tester.widget<CasePage>(find.byType(CasePage)).matterId, 'm-2');
    },
  );

  testWidgets('add case routes: search and by hand', (tester) async {
    await pumpApp(
      tester,
      location: '/cases/search',
      overrides: diary().overrides,
    );
    expect(find.byType(SearchCasesScreen), findsOneWidget);
    container(tester).read(routerProvider).go('/cases/manual');
    await tester.pumpAndSettle();
    expect(find.byType(ManualCaseScreen), findsOneWidget);
  });

  testWidgets('notification links resolve; the board sits under Today', (
    tester,
  ) async {
    await pumpApp(tester, overrides: diary().overrides);
    final router = container(tester).read(routerProvider);
    for (final (link, screen) in [
      ('/board/tomorrow', BoardScreen),
      ('/cases/m-1', CasePage),
      ('/today', TodayScreen),
    ]) {
      router.go(link);
      await tester.pumpAndSettle();
      expect(find.byType(screen), findsOneWidget, reason: link);
      if (link != '/cases/m-1') {
        expect(
          tester
              .widget<NavigationBar>(find.byType(NavigationBar))
              .selectedIndex,
          0,
          reason: link,
        );
      }
    }
  });

  testWidgets('board title is tomorrow in IST, in Hindi at 200%', (
    tester,
  ) async {
    await pumpApp(
      tester,
      location: '/board/tomorrow',
      locale: 'hi',
      textScale: 2,
      overrides: diary().overrides,
    );
    expect(find.textContaining('कल का बोर्ड'), findsOneWidget);
    expect(find.textContaining('6 नवंबर'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
