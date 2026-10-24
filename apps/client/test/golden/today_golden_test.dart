@Tags(['golden'])
library;

import 'package:advocate_app/app.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';
import '../widget/today_test.dart' show sampleDiary;

/// Today goldens (spec §4.2, §5.3) on a phone: the morning (hero card, matters by court with a clash, tasks,
/// orders, needs attention) and the evening (Tomorrow banner) × light/dark/sunlight × en/hi × text scale 1.0/2.0.
/// Reference images are rendered on Windows; CI runs this file on windows-latest.
void main() {
  setUpAll(loadAppFonts);
  final scenes = {
    'morning': sampleDiary,
    'evening': () => sampleDiary(now: DateTime.utc(2026, 11, 5, 13)),
  };

  for (final MapEntry(key: scene, value: diary) in scenes.entries) {
    for (final MapEntry(key: name, value: theme) in themes.entries) {
      for (final locale in ['en', 'hi']) {
        for (final scale in [1.0, 2.0]) {
          testWidgets('today $scene $name $locale ${scale}x', (tester) async {
            await pumpApp(
              tester,
              locale: locale,
              theme: theme,
              textScale: scale,
              overrides: diary().overrides,
            );
            await expectLater(
              find.byType(App),
              matchesGoldenFile(
                'goldens/today/${scene}_${name}_${locale}_${scale}x.png',
              ),
            );
          });
        }
      }
    }
  }
}
