@Tags(['golden'])
library;

import 'package:advocate_app/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

DateTime _day(int d) => DateTime.utc(2026, 11, d);

/// Cases list goldens (spec §4.3, §5.3): the phone list and the Windows two panes (list | case page) × light/dark/
/// sunlight × en/hi × text scale 1.0/2.0. Reference images are rendered on Windows; CI runs this file on
/// windows-latest. The detail pane is whatever CasePage renders: regenerate these when its goldens change.
void main() {
  setUpAll(loadAppFonts);
  final cases = [
    caseInfo(
      1,
      nextDate: _day(5),
      title: 'Ramesh Sharma v. State of MP',
      assigneeId: 'user-3',
      assigneeName: 'Neha Verma',
      judge: 'Justice A. B. Verma',
      stage: 'Admission',
    ),
    caseInfo(
      2,
      nextDate: _day(5),
      caseType: 'MCRC',
      title: 'शर्मा बनाम मध्य प्रदेश राज्य',
    ),
    caseInfo(
      3,
      nextDate: _day(9),
      court: testCourts[3],
      caseType: 'CS',
      courtNo: '5',
      title: 'Ramesh Kumar Gupta and others v. Madhya Pradesh Housing Board',
    ),
    caseInfo(4, nextDate: _day(20), title: 'Mohan Lal v. State of MP'),
    caseInfo(
      5,
      tracking: 'manual',
      courtName: 'Family Court Indore',
      courtNo: '3',
      title: 'Gupta v. Gupta',
    ),
    caseInfo(
      6,
      courtStatus: 'disposed',
      caseYear: 2018,
      title: 'Patel v. Joshi',
    ),
  ];
  const screens = {
    'phone': ('/cases', Size(400, 860)),
    'desktop': ('/cases/m-1', Size(1280, 800)),
  };

  for (final MapEntry(key: device, value: (location, size))
      in screens.entries) {
    for (final MapEntry(key: name, value: theme) in themes.entries) {
      for (final locale in ['en', 'hi']) {
        for (final scale in [1.0, 2.0]) {
          testWidgets('cases $device $name $locale ${scale}x', (tester) async {
            await pumpApp(
              tester,
              location: location,
              locale: locale,
              theme: theme,
              textScale: scale,
              size: size,
              overrides: FakeCases(cases: cases, pendingFound: 3).overrides,
            );
            await expectLater(
              find.byType(App),
              matchesGoldenFile(
                'goldens/cases/${device}_${name}_${locale}_${scale}x.png',
              ),
            );
          });
        }
      }
    }
  }
}
