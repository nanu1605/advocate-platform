import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/features/onboarding/sign_in_screens.dart';
import 'package:advocate_app/features/settings/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

/// Opens Settings and taps Sign out.
Future<void> _signOut(
  WidgetTester tester, {
  int changes = 0,
  int uploads = 0,
  String locale = 'en',
  double scale = 1,
}) async {
  await pumpApp(
    tester,
    location: '/settings',
    onboardingDone: true,
    locale: locale,
    textScale: scale,
    overrides: [pendingChanges(changes: changes, uploads: uploads)],
  );
  final l = lookupAppLocalizations(Locale(locale));
  // About comes after the button, so the button is clear of the bottom bar.
  await tester.scrollUntilVisible(find.text(l.about), 200);
  await tester.tap(find.widgetWithText(OutlinedButton, l.signOut));
  await tester.pumpAndSettle();
}

/// Settings' sign-out confirm (ADR 0013 follow-up, 0017): signing out clears this device's queues, so it says how
/// many changes and documents haven't reached the server yet.
void main() {
  setUpAll(loadAppFonts);
  final en = lookupAppLocalizations(const Locale('en'));

  testWidgets('nothing waiting: the usual confirm, then signed out', (
    tester,
  ) async {
    await _signOut(tester);
    expect(find.text(en.signOutConfirm), findsOneWidget);
    expect(find.text(en.signOutPendingStay), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, en.signOut));
    await tester.pumpAndSettle();
    expect(find.byType(PhoneScreen), findsOneWidget);
  });

  for (final locale in ['en', 'hi']) {
    final l = lookupAppLocalizations(Locale(locale));
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'changes and documents waiting: says so; Stay signed in keeps them '
        '($locale ${scale}x)',
        (tester) async {
          await _signOut(
            tester,
            changes: 3,
            uploads: 2,
            locale: locale,
            scale: scale,
          );
          expect(
            find.text(
              [
                l.signOutPendingChanges(3),
                l.signOutPendingUploads(2),
                l.signOutPendingLost,
              ].join(' '),
            ),
            findsOneWidget,
          );
          expect(find.text(l.signOutConfirm), findsNothing);
          expect(tester.takeException(), isNull);
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await tester.tap(find.text(l.signOutPendingStay));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(find.byType(SettingsScreen), findsOneWidget);
        },
      );
    }
  }

  testWidgets('one change waiting: Sign out anyway signs out', (tester) async {
    await _signOut(tester, changes: 1);
    expect(
      find.text('${en.signOutPendingChanges(1)} ${en.signOutPendingLost}'),
      findsOneWidget,
    );
    expect(en.signOutPendingChanges(1), contains('1 change '));
    await tester.tap(find.text(en.signOutPendingConfirm));
    await tester.pumpAndSettle();
    expect(find.byType(PhoneScreen), findsOneWidget);
  });

  testWidgets('only a document waiting says so', (tester) async {
    await _signOut(tester, uploads: 1);
    expect(
      find.text('${en.signOutPendingUploads(1)} ${en.signOutPendingLost}'),
      findsOneWidget,
    );
  });
}
