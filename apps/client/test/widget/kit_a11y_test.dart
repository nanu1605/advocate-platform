import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/features/dev_kitchen_sink/kitchen_sink.dart';
import 'package:advocate_app/ui/pdf_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

/// Tap-target size and labelling on every kit section, in every theme and both languages (spec §5.9, §16.4).
/// Colour contrast is checked exactly on the tokens by tools/check_contrast.py; Flutter's pixel-sampling
/// contrast guideline misreads thin anti-aliased glyphs, so it is not used here.
void main() {
  setUpAll(loadAppFonts);

  // With the real fonts: a long court file's page count stays whole on a 360 dp phone at 200%.
  testWidgets(
    'the PDF page bar keeps "Page 1 of 140" at 200% on a 360 dp phone',
    (tester) async {
      tester.view.physicalSize = const Size(392, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        host(
          AppPdfViewer(SamplePdfPages(List.filled(140, 'Page'))),
          scale: 2,
          width: 392,
          height: 800,
        ),
      );
      await tester.pump();
      final text = lookupAppLocalizations(const Locale('en')).docsPage(1, 140);
      final label = tester.renderObject<RenderParagraph>(find.text(text));
      final button = tester.getSize(
        find.ancestor(of: find.text(text), matching: find.byType(TextButton)),
      );
      // It fits; or, with the pseudo-locale's 40% longer text, it has all the width the three buttons leave
      // (208 dp; the old layout gave it 166).
      expect(!label.didExceedMaxLines || button.width > 200, isTrue);
    },
  );

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
