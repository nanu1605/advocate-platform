import 'package:advocate_app/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';
import '../widget/phase_checks_test.dart' show openScene;

/// Goldens for phase-check scenes (test/widget/phase_checks_test.dart): each scene named in [scenes] (scene name →
/// image name) × light/dark/sunlight × en/hi × text scale 1.0/2.0, at
/// `goldens/<dir>/<image>_<theme>_<locale>_<scale>x.png`. A scene opens at 100% text, as in the checks, then the OS
/// text size goes to 200%.
void sceneGoldens(
  String dir,
  Map<String, String> scenes, {
  Size size = const Size(400, 860),
}) {
  for (final MapEntry(key: scene, value: image) in scenes.entries) {
    for (final MapEntry(key: name, value: theme) in themes.entries) {
      for (final locale in ['en', 'hi']) {
        for (final scale in [1.0, 2.0]) {
          testWidgets('$dir $image $name $locale ${scale}x', (tester) async {
            await openScene(
              tester,
              scene,
              size: size,
              locale: locale,
              theme: theme,
            );
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            await tester.pumpAndSettle();
            await expectLater(
              find.byType(App),
              matchesGoldenFile(
                'goldens/$dir/${image}_${name}_${locale}_${scale}x.png',
              ),
            );
          });
        }
      }
    }
  }
}
