@Tags(['golden'])
library;

import 'package:advocate_app/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

const _district = 'c0000000-0000-0000-0000-000000000005';
const _supreme = 'c0000000-0000-0000-0000-000000000001';

/// Found cases screen goldens (spec §4.1, §5.3): phone and desktop × light/dark/sunlight × en/hi × text scale
/// 1.0/2.0. Reference images are rendered on Windows; CI runs this file on windows-latest.
void main() {
  setUpAll(loadAppFonts);
  final next = DateTime(2026, 11, 5);
  final found = [
    foundCase(1, nextDate: next),
    foundCase(2, title: 'Verma v. State of MP', courtNo: '7'),
    foundCase(
      3,
      confidence: 'low',
      caseType: 'MCRC',
      title: 'Ramesh Kumar Gupta and others v. Madhya Pradesh Housing Board through its Commissioner',
    ),
    foundCase(
      4,
      courtId: _district,
      caseType: 'CS',
      caseYear: 2019,
      courtNo: '5',
      nextDate: next,
    ),
    foundCase(5, courtId: _supreme, caseType: 'SLP', courtNo: null),
    foundCase(6, status: 'disposed', caseYear: 2018),
  ];
  const sizes = {'phone': Size(400, 860), 'desktop': Size(1280, 800)};

  for (final MapEntry(key: device, value: size) in sizes.entries) {
    for (final MapEntry(key: name, value: theme) in themes.entries) {
      for (final locale in ['en', 'hi']) {
        for (final scale in [1.0, 2.0]) {
          testWidgets('found_cases $device $name $locale ${scale}x', (
            tester,
          ) async {
            await pumpApp(
              tester,
              location: '/found',
              onboardingDone: false,
              locale: locale,
              theme: theme,
              textScale: scale,
              size: size,
              overrides: syncedData(found: found),
            );
            await expectLater(
              find.byType(App),
              matchesGoldenFile(
                'goldens/found_cases/${device}_${name}_${locale}_${scale}x.png',
              ),
            );
          });
        }
      }
    }
  }
}
