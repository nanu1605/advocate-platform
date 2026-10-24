@Tags(['golden'])
library;

import 'package:advocate_app/app.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/courts.dart';
import 'package:advocate_app/features/cases/search_cases_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

/// Add case goldens (spec §4.1, §11.7): search results and the Add by hand form (with its inline errors), on a
/// phone × light/dark/sunlight × en/hi × text scale 1.0/2.0. Reference images are rendered on Windows.
void main() {
  setUpAll(loadAppFonts);
  final results = CaseSearchPage(
    items: [
      CaseHit(
        cnr: 'MPHC010000000001',
        courtCode: 'MPHC01',
        caseType: 'WP',
        caseNumber: '1001',
        caseYear: 2024,
        title: 'Sharma v. State of MP',
        status: 'pending',
        nextHearingDate: DateTime.utc(2026, 11, 6),
        advocates: const [(name: 'R. K. Verma', side: 'petitioner')],
      ),
      CaseHit(
        cnr: 'MPHC010000000002',
        courtCode: 'MPHC01',
        caseType: 'MCRC',
        caseNumber: '9921',
        caseYear: 2025,
        title: 'Ramesh Kumar Gupta and others v. Madhya Pradesh Housing Board through its Commissioner',
        status: 'pending',
        nextHearingDate: DateTime.utc(2026, 11, 20),
        advocates: const [
          (name: 'Neha Verma', side: 'petitioner'),
          (name: 'A. K. Jain', side: 'respondent'),
          (name: 'S. P. Tiwari', side: 'respondent'),
        ],
        tracked: true,
      ),
      const CaseHit(
        cnr: 'MPHC010000000003',
        courtCode: 'XX99',
        caseType: 'CRA',
        caseNumber: '455',
        caseYear: 2019,
        title: 'Verma v. State of MP',
        status: 'disposed',
      ),
    ],
    total: 23,
    page: 1,
    hasNext: true,
    ignoredCourtIds: [testCourts[4].id],
  );
  final overrides = [
    ...FakeCases().overrides,
    courtsProvider.overrideWithValue(const AsyncData(testCourts)),
    courtsByCodeProvider.overrideWithValue(
      AsyncData({'MPHC01': testCourts.first}),
    ),
  ];

  for (final MapEntry(key: name, value: theme) in themes.entries) {
    for (final locale in ['en', 'hi']) {
      final l = lookupAppLocalizations(Locale(locale));
      for (final scale in [1.0, 2.0]) {
        testWidgets('add_case search $name $locale ${scale}x', (tester) async {
          final api = FakeApi(account: ownerAccount)..searchPages = [results];
          await pumpApp(
            tester,
            location: '/cases/search',
            locale: locale,
            theme: theme,
            textScale: scale,
            api: api,
            overrides: overrides,
          );
          await tester.enterText(
            find.widgetWithText(TextField, l.addCaseParty),
            'Sharma',
          );
          // The field scrolls itself back into view first.
          await tester.pumpAndSettle();
          for (final target in [
            find.widgetWithText(
              FilterChip,
              testCourts[0].label(Locale(locale)),
            ),
            find.widgetWithText(
              FilterChip,
              testCourts[4].label(Locale(locale)),
            ),
            find.text(l.addCaseSearchAction),
          ]) {
            await tester.ensureVisible(target);
            await tester.pumpAndSettle();
            await tester.tap(target);
            await tester.pumpAndSettle();
          }
          await expectLater(
            find.byType(App),
            matchesGoldenFile(
              'goldens/add_case/search_${name}_${locale}_${scale}x.png',
            ),
          );
        });

        testWidgets('add_case manual $name $locale ${scale}x', (tester) async {
          await pumpApp(
            tester,
            location: '/cases/manual',
            locale: locale,
            theme: theme,
            textScale: scale,
            overrides: overrides,
          );
          await tester.tap(find.widgetWithText(FilledButton, l.addCase));
          await tester.pumpAndSettle();
          await expectLater(
            find.byType(App),
            matchesGoldenFile(
              'goldens/add_case/manual_${name}_${locale}_${scale}x.png',
            ),
          );
        });
      }
    }
  }
}
