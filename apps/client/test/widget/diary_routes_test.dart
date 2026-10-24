import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/router.dart';
import 'package:advocate_app/features/board/board_screen.dart';
import 'package:advocate_app/features/cases/case_placeholder_screen.dart';
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

  testWidgets('a case link opens the case placeholder on its tab', (
    tester,
  ) async {
    final l = lookupAppLocalizations(const Locale('en'));
    await pumpApp(
      tester,
      location: '/cases/m-1?tab=notes',
      overrides: diary().overrides,
    );
    expect(find.byType(CasePlaceholderScreen), findsOneWidget);
    expect(find.text('WP 1001/2024'), findsOneWidget);
    expect(find.text('Sharma v. State of MP'), findsOneWidget);
    expect(find.text(l.caseNotes), findsOneWidget);
    expect(find.text(l.casePageSoon), findsOneWidget);
  });

  testWidgets('notification links resolve; the board sits under Today', (
    tester,
  ) async {
    await pumpApp(tester, overrides: diary().overrides);
    final router = container(tester).read(routerProvider);
    for (final (link, screen) in [
      ('/board/tomorrow', BoardScreen),
      ('/cases/m-1', CasePlaceholderScreen),
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
