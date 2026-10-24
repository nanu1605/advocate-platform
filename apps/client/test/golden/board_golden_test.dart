@Tags(['golden'])
library;

import 'package:advocate_app/app.dart';
import 'package:advocate_app/data/courts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

final Court _district = testCourts[3];

/// Tomorrow's Board goldens (spec §4.2, §5.3): phone and desktop, with a clash, a proxy and an assignee ×
/// light/dark/sunlight × en/hi × text scale 1.0/2.0. Reference images are rendered on Windows; CI runs this file on
/// windows-latest.
void main() {
  setUpAll(loadAppFonts);
  final tomorrow = [
    diaryEntry(1, item: 23),
    diaryEntry(
      2,
      court: _district,
      courtNo: '5',
      item: 5,
      slot: const Duration(hours: 11, minutes: 30),
      purpose: 'Evidence',
      title: 'Ramesh Kumar Gupta and others v. Madhya Pradesh Housing Board',
    ),
    diaryEntry(
      3,
      courtNo: '7',
      item: 41,
      assigneeId: 'user-1',
      assigneeName: 'Ramesh Sharma',
      proxy: true,
    ),
    diaryEntry(
      4,
      court: _district,
      courtNo: '9',
      item: 2,
      slot: const Duration(hours: 14),
      assigneeId: 'user-3',
      assigneeName: 'Neha Verma',
    ),
  ];
  const sizes = {'phone': Size(400, 860), 'desktop': Size(1280, 800)};

  for (final MapEntry(key: device, value: size) in sizes.entries) {
    for (final MapEntry(key: name, value: theme) in themes.entries) {
      for (final locale in ['en', 'hi']) {
        for (final scale in [1.0, 2.0]) {
          testWidgets('board $device $name $locale ${scale}x', (tester) async {
            await pumpApp(
              tester,
              location: '/board/tomorrow',
              locale: locale,
              theme: theme,
              textScale: scale,
              size: size,
              overrides: FakeDiary(days: {testTomorrow: tomorrow}).overrides,
            );
            await expectLater(
              find.byType(App),
              matchesGoldenFile(
                'goldens/board/${device}_${name}_${locale}_${scale}x.png',
              ),
            );
          });
        }
      }
    }
  }
}
