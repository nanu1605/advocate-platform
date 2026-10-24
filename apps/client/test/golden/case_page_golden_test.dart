@Tags(['golden'])
library;

import 'package:advocate_app/app.dart';
import 'package:advocate_app/features/case_page/case_page_text.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';
import '../widget/case_page_test.dart' show sampleCases, scrollToTabs;

/// Case page goldens (spec §4.3, §5.3) on a phone: WP 1001/2024 on each tab × light/dark/sunlight × en/hi × text
/// scale 1.0/2.0. At 2.0 the page is scrolled to the tabs, so the tab's content shows under the pinned tab bar.
/// Reference images are rendered on Windows; CI runs this file on windows-latest.
void main() {
  setUpAll(loadAppFonts);

  for (final tab in CaseTab.values) {
    for (final MapEntry(key: name, value: theme) in themes.entries) {
      for (final locale in ['en', 'hi']) {
        for (final scale in [1.0, 2.0]) {
          testWidgets('case page ${tab.name} $name $locale ${scale}x', (
            tester,
          ) async {
            await pumpApp(
              tester,
              location: '/cases/m-1?tab=${tab.name}',
              locale: locale,
              theme: theme,
              textScale: scale,
              overrides: sampleCases().overrides,
            );
            if (scale > 1) await scrollToTabs(tester);
            await expectLater(
              find.byType(App),
              matchesGoldenFile(
                'goldens/case_page/${tab.name}_${name}_${locale}_${scale}x.png',
              ),
            );
          });
        }
      }
    }
  }
}
