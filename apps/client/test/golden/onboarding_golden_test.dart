@Tags(['golden'])
library;

import 'package:advocate_app/data/jobs.dart';
import 'package:advocate_app/features/onboarding/finding_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

/// "Finding your cases" mid-search (spec §4.1 step 7) × light/dark/sunlight × en/hi × text scale 1.0/2.0, on a
/// phone. Reference images are rendered on Windows, like the kit goldens.
void main() {
  setUpAll(loadAppFonts);
  const boundary = Key('finding');
  const job = Job(
    id: 'job-1',
    kind: 'find_cases',
    status: JobStatus.running,
    progress: {
      'found': 14,
      'groups': [
        {'key': 'HC', 'state': 'done', 'found': 12},
        {'key': 'DC', 'state': 'running', 'found': 2},
        {'key': 'SC', 'state': 'pending', 'found': 0},
      ],
    },
  );

  for (final MapEntry(key: name, value: theme) in themes.entries) {
    for (final locale in ['en', 'hi']) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('finding $name $locale ${scale}x', (tester) async {
          tester.view.physicalSize = const Size(432, 892);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                findJobIdProvider.overrideWith(_Following.new),
                jobProvider('job-1').overrideWithValue(const AsyncData(job)),
              ],
              child: host(
                const FindingScreen(),
                theme: theme,
                locale: locale,
                scale: scale,
                boundaryKey: boundary,
                width: 432,
                height: 892,
              ),
            ),
          );
          await tester.pump();
          await expectLater(
            find.byKey(boundary),
            matchesGoldenFile(
              'goldens/finding/${name}_${locale}_${scale}x.png',
            ),
          );
        });
      }
    }
  }
}

class _Following extends FindJobController {
  @override
  String? build() => 'job-1';
}
