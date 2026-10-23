@Tags(['golden'])
library;

import 'package:advocate_app/features/dev_kitchen_sink/kitchen_sink.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

/// Kit goldens: every section × light/dark/sunlight × en/hi × text scale 1.0/2.0 (spec §5.11, ADR 0001).
/// Reference images are rendered on Windows; CI runs this file on windows-latest.
void main() {
  setUpAll(loadAppFonts);
  const boundary = Key('kit');

  for (final section in kitSections) {
    for (final MapEntry(key: name, value: theme) in themes.entries) {
      for (final locale in ['en', 'hi']) {
        for (final scale in [1.0, 2.0]) {
          testWidgets('${section.id} $name $locale ${scale}x', (tester) async {
            final width = section.width + 32;
            tester.view.physicalSize = Size(width, section.height ?? 3200);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            await tester.pumpWidget(
              host(
                Builder(builder: section.build),
                theme: theme,
                locale: locale,
                scale: scale,
                boundaryKey: boundary,
                width: width,
                height: section.height,
              ),
            );
            await tester.pump();
            await expectLater(
              find.byKey(boundary),
              matchesGoldenFile(
                'goldens/${section.id}/${name}_${locale}_${scale}x.png',
              ),
            );
          });
        }
      }
    }
  }
}
