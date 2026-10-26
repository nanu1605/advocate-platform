@Tags(['golden'])
library;

import 'package:advocate_app/app.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/data/document_files.dart';
import 'package:advocate_app/features/documents/upload_flow.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';
import '../widget/documents_test.dart'
    show FakeSources, fakeFile, sampleDocCases, sampleQueue;
import 'scene_goldens.dart';

/// Documents goldens (spec §4.3) on a phone: the list (uploads waiting, failed and sending; documents ready, kept
/// offline, being checked and blocked), the upload sheet and the viewer × light/dark/sunlight × en/hi × text scale
/// 1.0/2.0. Reference images are rendered on Windows; CI runs this file on windows-latest.
void main() {
  setUpAll(loadAppFonts);
  sceneGoldens('documents', {
    'document viewer': 'viewer',
    'documents, search inside': 'search_inside',
  });

  for (final screen in ['list', 'upload']) {
    for (final MapEntry(key: name, value: theme) in themes.entries) {
      for (final locale in ['en', 'hi']) {
        for (final scale in [1.0, 2.0]) {
          testWidgets('documents $screen $name $locale ${scale}x', (
            tester,
          ) async {
            final l = lookupAppLocalizations(Locale(locale));
            await pumpApp(
              tester,
              location: '/documents',
              locale: locale,
              theme: theme,
              textScale: scale,
              onboardingDone: true,
              overrides: [
                ...sampleDocCases().overrides,
                ...FakeDocuments(queue: sampleQueue()).overrides,
                uploadSourcesProvider.overrideWithValue(
                  FakeSources(files: [fakeFile('Rejoinder final.pdf')]),
                ),
              ],
            );
            container(tester)
                .read(uploadProgressProvider.notifier)
                .set('up-1', 0.4);
            await tester.pumpAndSettle();
            if (screen == 'upload') {
              await tester.tap(find.byTooltip(l.addDocument));
              await tester.pumpAndSettle();
              await tester.tap(find.text(l.docsChooseFiles));
              await tester.pumpAndSettle();
            }
            await expectLater(
              find.byType(App),
              matchesGoldenFile(
                'goldens/documents/${screen}_${name}_${locale}_${scale}x.png',
              ),
            );
          });
        }
      }
    }
  }
}
