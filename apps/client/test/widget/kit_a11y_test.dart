import 'package:advocate_app/features/dev_kitchen_sink/kitchen_sink.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

/// Tap-target size and labelling on every kit section, in every theme and both languages (spec §5.9, §16.4).
/// Colour contrast is checked exactly on the tokens by tools/check_contrast.py; Flutter's pixel-sampling
/// contrast guideline misreads thin anti-aliased glyphs, so it is not used here.
void main() {
  setUpAll(loadAppFonts);

  for (final section in kitSections) {
    for (final MapEntry(key: name, value: theme) in themes.entries) {
      for (final locale in ['en', 'hi']) {
        testWidgets('${section.id} $name $locale meets a11y guidelines', (
          tester,
        ) async {
          tester.view.physicalSize = Size(
            section.width + 32,
            section.height ?? 2400,
          );
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final handle = tester.ensureSemantics();
          await tester.pumpWidget(
            host(
              Builder(builder: section.build),
              theme: theme,
              locale: locale,
              width: section.width + 32,
              height: section.height,
            ),
          );
          await tester.pump();
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          handle.dispose();
        });
      }
    }
  }
}
