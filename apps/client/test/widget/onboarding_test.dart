import 'package:advocate_app/app.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/auth.dart';
import 'package:advocate_app/data/device.dart';
import 'package:advocate_app/features/lock/app_lock.dart';
import 'package:advocate_app/features/lock/lock_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers.dart';

/// The whole app on a 400 × 860 phone with fake auth, API and lock storage.
Future<(FakeAuth, FakeApi, MemoryLockStore)> _pumpApp(
  WidgetTester tester,
) async {
  tester.view.physicalSize = const Size(400, 860);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final auth = FakeAuth();
  final api = FakeApi();
  final store = MemoryLockStore();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        authRepositoryProvider.overrideWithValue(auth),
        apiClientProvider.overrideWithValue(api),
        deviceRegistrarProvider.overrideWithValue(FakeRegistrar()),
        lockStoreProvider.overrideWithValue(store),
        deviceAuthProvider.overrideWithValue(FakeDeviceAuth()),
      ],
      child: const App(),
    ),
  );
  await tester.pumpAndSettle();
  return (auth, api, store);
}

void main() {
  setUpAll(loadAppFonts);

  // English also runs under tools/pseudo_l10n.py (+40% text) to catch overflow (spec §16.4).
  for (final (locale, language) in [('hi', 'हिंदी'), ('en', 'English')]) {
    final l = lookupAppLocalizations(Locale(locale));
    testWidgets(
      'first run in $locale: language → phone → OTP → consent → PIN → role',
      (tester) async {
        final (auth, api, store) = await _pumpApp(tester);

        // 1. Language.
        await tester.tap(find.text(language));
        await tester.pumpAndSettle();

        // 2. Phone: invalid number shows an inline error; valid one sends the code.
        expect(find.text(l.signInTitle), findsOneWidget);
        await tester.enterText(find.byType(TextField), '12345');
        await tester.tap(find.text(l.sendCode));
        await tester.pumpAndSettle();
        expect(find.text(l.phoneInvalid), findsWidgets);
        await tester.enterText(find.byType(TextField), '9876543210');
        await tester.tap(find.text(l.sendCode));
        await tester.pumpAndSettle();
        expect(auth.sent, ['9876543210']);

        // 3. OTP (auto-submits at 6 digits).
        expect(find.text(l.otpTitle), findsOneWidget);
        await tester.enterText(find.byType(TextField), '123456');
        await tester.pumpAndSettle();

        // 4. Consent: an itemised notice (what, why, where: India); button disabled until the required box is
        // ticked.
        expect(find.text(l.consentTitle), findsOneWidget);
        for (final item in [l.consentWhat, l.consentWhy, l.consentWhere]) {
          expect(find.text(item), findsOneWidget, reason: item);
        }
        final agree = find.widgetWithText(FilledButton, l.agreeContinue);
        expect(tester.widget<FilledButton>(agree).onPressed, isNull);
        await tester.tap(find.byType(Checkbox));
        await tester.pumpAndSettle();
        await tester.ensureVisible(agree);
        await tester.tap(agree);
        await tester.pumpAndSettle();
        expect(api.consents.single, {
          'account_processing': true,
          'whatsapp_alerts': false,
          'analytics': false,
        });

        // 5. App lock: no device auth here, so set a PIN twice.
        expect(find.text(l.lockTitle), findsOneWidget);
        expect(find.text(l.lockWhy), findsOneWidget);
        await tester.tap(find.text(l.lockSetPin));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '2468');
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '2468');
        await tester.pumpAndSettle();
        expect(store.method, LockMethod.pin);

        // 6. A new account (no organisation) goes on to choose a role.
        expect(find.text(l.roleTitle), findsOneWidget);
      },
    );
  }

  for (final locale in ['hi', 'en']) {
    final l = lookupAppLocalizations(Locale(locale));
    testWidgets(
      'a set-up account on a new device skips onboarding in $locale: Today → Settings',
      (tester) async {
        await pumpApp(tester, locale: locale);

        // Today, in the chosen language, with the P1 bottom bar.
        expect(find.text(l.todayEmpty), findsOneWidget);
        expect(find.text(l.navCases), findsWidgets);
        expect(find.text(l.navMore), findsOneWidget);
        expect(container(tester).read(settingsProvider).onboardingDone, isTrue);

        // More → Settings.
        await tester.tap(find.text(l.navMore));
        await tester.pumpAndSettle();
        await tester.tap(find.text(l.navSettings));
        await tester.pumpAndSettle();
        expect(find.text(l.navSettings), findsWidgets);

        // The language chosen at the start can be changed here (spec §4.1 step 1): the app switches at once.
        final other = locale == 'hi' ? 'en' : 'hi';
        final o = lookupAppLocalizations(Locale(other));
        await tester.tap(find.text(other == 'hi' ? 'हिंदी' : 'English'));
        await tester.pumpAndSettle();
        expect(container(tester).read(settingsProvider).locale, Locale(other));
        expect(find.text(o.settingsLanguage), findsOneWidget);
        expect(find.text(l.settingsLanguage), findsNothing);
      },
    );
  }

  for (final (locale, language) in [('hi', 'हिंदी'), ('en', 'English')]) {
    final l = lookupAppLocalizations(Locale(locale));
    testWidgets('errors on the way in are inline and read out in $locale', (
      tester,
    ) async {
      final announced = captureAnnouncements(tester);
      final (_, api, store) = await _pumpApp(tester);
      await tester.tap(find.text(language));
      await tester.pumpAndSettle();

      // Phone: not a mobile number.
      await tester.enterText(find.byType(TextField), '12345');
      await tester.tap(find.text(l.sendCode));
      await tester.pumpAndSettle();
      expect(find.text(l.phoneInvalid), findsWidgets);
      expect(announced, [l.phoneInvalid]);
      await tester.enterText(find.byType(TextField), '9876543210');
      await tester.tap(find.text(l.sendCode));
      await tester.pumpAndSettle();

      // Code: too short, then wrong (6 digits send themselves).
      await tester.enterText(find.byType(TextField), '123');
      await tester.tap(find.text(l.verify));
      await tester.pumpAndSettle();
      expect(find.text(l.otpInvalid), findsOneWidget);
      await tester.enterText(find.byType(TextField), '000000');
      await tester.pumpAndSettle();
      expect(find.text(l.otpInvalid), findsOneWidget);
      expect(announced, [l.phoneInvalid, l.otpInvalid, l.otpInvalid]);
      await tester.enterText(find.byType(TextField), '123456');
      await tester.pumpAndSettle();

      // Consent: offline says so and keeps the screen.
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      final agree = find.widgetWithText(FilledButton, l.agreeContinue);
      api.fail['postConsents'] = const ApiException('NETWORK');
      announced.clear();
      await tester.ensureVisible(agree);
      await tester.tap(agree);
      await tester.pumpAndSettle();
      expect(find.text(l.errorNetwork), findsOneWidget);
      expect(announced, [l.errorNetwork]);
      api.fail.clear();
      await tester.tap(agree);
      await tester.pumpAndSettle();

      // PIN: two that differ start again.
      await tester.tap(find.text(l.lockSetPin));
      await tester.pumpAndSettle();
      announced.clear();
      await tester.enterText(find.byType(TextField), '2468');
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '1357');
      await tester.pumpAndSettle();
      expect(find.text(l.lockPinMismatch), findsOneWidget);
      expect(announced, [l.lockPinMismatch]);
      expect(store.method, isNull);
    });

    testWidgets(
      'a wrong PIN on the lock screen is inline and read out in $locale',
      (tester) async {
        final announced = captureAnnouncements(tester);
        final store = MemoryLockStore()
          ..method = LockMethod.pin
          ..salt = 'salt'
          ..hash = hashPin('2468', 'salt');
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              lockStoreProvider.overrideWithValue(store),
              initialLockProvider.overrideWithValue(
                const AppLockState(method: LockMethod.pin, locked: true),
              ),
            ],
            child: host(const LockScreen(), locale: locale, height: 600),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '1357');
        await tester.pumpAndSettle();
        expect(find.text(l.unlockWrongPin(maxPinFailures - 1)), findsOneWidget);
        expect(announced, [l.unlockWrongPin(maxPinFailures - 1)]);
      },
    );
  }

  testWidgets(
    'the resend wait reads as seconds, and says when Resend is ready',
    (tester) async {
      final announced = captureAnnouncements(tester);
      await _pumpApp(tester);
      final l = lookupAppLocalizations(const Locale('en'));
      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '9876543210');
      await tester.tap(find.text(l.sendCode));
      await tester.pumpAndSettle();
      expect(find.text(l.resendIn(60)), findsOneWidget);
      await tester.pump(const Duration(seconds: 59));
      expect(find.text(l.resendIn(1)), findsOneWidget);
      announced.clear();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(l.resend), findsOneWidget);
      expect(announced, [l.resend]);
    },
  );

  testWidgets('five wrong codes lock the code until a new one is sent', (
    tester,
  ) async {
    final (auth, _, _) = await _pumpApp(tester);
    final l = lookupAppLocalizations(const Locale('en'));
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '9876543210');
    await tester.tap(find.text(l.sendCode));
    await tester.pumpAndSettle();

    for (var i = 1; i <= 5; i++) {
      await tester.enterText(find.byType(TextField), '00000$i');
      await tester.pumpAndSettle();
      expect(find.text(i < 5 ? l.otpInvalid : l.otpLocked), findsOneWidget);
    }
    final verify = find.widgetWithText(FilledButton, l.verify);
    expect(tester.widget<FilledButton>(verify).onPressed, isNull);

    // A new code (after the resend wait) unlocks entry again.
    await tester.pump(const Duration(seconds: 60));
    await tester.tap(find.text(l.resend));
    await tester.pumpAndSettle();
    expect(auth.sent, hasLength(2));
    await tester.enterText(find.byType(TextField), '123456');
    await tester.pumpAndSettle();
    expect(find.text(l.consentTitle), findsOneWidget);
  });
}
