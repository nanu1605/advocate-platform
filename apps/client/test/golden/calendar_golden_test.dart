@Tags(['golden'])
library;

import 'package:advocate_app/app.dart';
import 'package:advocate_app/features/calendar/calendar_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';
import '../widget/calendar_test.dart' show sampleCalendar;

/// Calendar goldens (spec §4.3, §5.3): the month on a low-end phone 360 dp wide (spec §16.2; today's items under
/// the grid) and on Windows (beside it), and the day, week and agenda on a phone × light/dark/sunlight × en/hi ×
/// text scale 1.0/2.0. Reference images are rendered on Windows; CI runs this file on windows-latest.
void main() {
  setUpAll(loadAppFonts);
  const scenes = {
    'month_phone': (CalendarView.month, Size(360, 860)),
    'month_desktop': (CalendarView.month, Size(1280, 800)),
    'day_phone': (CalendarView.day, Size(400, 860)),
    'week_phone': (CalendarView.week, Size(400, 860)),
    'agenda_phone': (CalendarView.agenda, Size(400, 860)),
  };

  for (final MapEntry(key: scene, value: (view, size)) in scenes.entries) {
    for (final MapEntry(key: name, value: theme) in themes.entries) {
      for (final locale in ['en', 'hi']) {
        for (final scale in [1.0, 2.0]) {
          testWidgets('calendar $scene $name $locale ${scale}x', (
            tester,
          ) async {
            await pumpApp(
              tester,
              location: '/calendar',
              locale: locale,
              theme: theme,
              textScale: scale,
              size: size,
              overrides: sampleCalendar().overrides,
            );
            container(tester)
                .read(calendarPrefsProvider.notifier)
                .setView(view);
            await tester.pumpAndSettle();
            await expectLater(
              find.byType(App),
              matchesGoldenFile(
                'goldens/calendar/${scene}_${name}_${locale}_${scale}x.png',
              ),
            );
          });
        }
      }
    }
  }
}
