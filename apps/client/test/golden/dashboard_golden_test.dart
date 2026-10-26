@Tags(['golden'])
library;

import 'package:advocate_app/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';
import '../widget/dashboard_test.dart' show chamberOwner, sampleDashboard;

/// Practice dashboard goldens (spec §4.4 F18): a chamber owner's counts, Today and Team on a phone (tiles two by
/// two, one per row at 200%) and on Windows (one row) × light/dark/sunlight × en/hi × text scale 1.0/2.0.
/// Reference images are rendered on Windows; CI runs this file on windows-latest.
void main() {
  setUpAll(loadAppFonts);
  const sizes = {'phone': Size(400, 860), 'desktop': Size(1280, 800)};

  for (final MapEntry(key: device, value: size) in sizes.entries) {
    for (final MapEntry(key: name, value: theme) in themes.entries) {
      for (final locale in ['en', 'hi']) {
        for (final scale in [1.0, 2.0]) {
          testWidgets('dashboard $device $name $locale ${scale}x', (
            tester,
          ) async {
            await pumpApp(
              tester,
              location: '/dashboard',
              account: chamberOwner,
              locale: locale,
              theme: theme,
              textScale: scale,
              size: size,
              overrides: sampleDashboard(),
            );
            await expectLater(
              find.byType(App),
              matchesGoldenFile(
                'goldens/dashboard/${device}_${name}_${locale}_${scale}x.png',
              ),
            );
          });
        }
      }
    }
  }
}
