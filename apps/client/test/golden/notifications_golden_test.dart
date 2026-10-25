@Tags(['golden'])
library;

import 'package:advocate_app/app.dart';
import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/data/notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';
import '../widget/notifications_test.dart' show sampleNotifications;

/// Notification centre and preferences goldens (spec §13) on a phone: the centre (today's unread rows, a folded
/// update, yesterday and earlier) and preferences (one kind off, case titles on) × light/dark/sunlight × en/hi ×
/// text scale 1.0/2.0. Reference images are rendered on Windows; CI runs this file on windows-latest.
void main() {
  setUpAll(loadAppFonts);
  final screens = {
    'centre': ('/notifications', sampleNotifications),
    'prefs': (
      '/settings/notifications',
      ({bool hi = false}) => FakeNotifications(
        prefs: const NotificationPrefs(
          off: {'sync_issue'},
          includeTitles: true,
        ),
      ),
    ),
  };

  for (final MapEntry(key: screen, value: (location, fake))
      in screens.entries) {
    for (final MapEntry(key: name, value: theme) in themes.entries) {
      for (final locale in ['en', 'hi']) {
        for (final scale in [1.0, 2.0]) {
          testWidgets('notifications $screen $name $locale ${scale}x', (
            tester,
          ) async {
            await pumpApp(
              tester,
              location: location,
              locale: locale,
              theme: theme,
              textScale: scale,
              overrides: [
                clockProvider.overrideWithValue(() => testNow),
                ...fake(hi: locale == 'hi').overrides,
                FakePermission().asOverride,
              ],
            );
            await expectLater(
              find.byType(App),
              matchesGoldenFile(
                'goldens/notifications/${screen}_${name}_${locale}_${scale}x.png',
              ),
            );
          });
        }
      }
    }
  }
}
