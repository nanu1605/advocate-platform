import 'dart:async';
import 'dart:io';

import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/router.dart';
import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/auth.dart';
import 'package:advocate_app/data/documents.dart';
import 'package:advocate_app/data/feedback.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:advocate_app/features/board/board_share.dart';
import 'package:advocate_app/features/documents/upload_flow.dart';
import 'package:advocate_app/features/lock/app_lock.dart';
import 'package:advocate_app/features/onboarding/consent_screen.dart';
import 'package:advocate_app/features/onboarding/lock_setup_screen.dart';
import 'package:advocate_app/features/onboarding/sign_in_screens.dart';
import 'package:advocate_app/features/session.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers.dart';

/// Routing after app lock (spec §4.1 steps 5–10): the account decides the step, /loading never guesses.
void main() {
  setUpAll(loadAppFonts);
  final en = lookupAppLocalizations(const Locale('en'));

  testWidgets(
    'a new account lands on the role screen and is marked as onboarding here',
    (tester) async {
      await pumpApp(tester, account: newAccount);
      expect(find.text(en.roleTitle), findsOneWidget);
      expect(container(tester).read(settingsProvider).onboardingDone, isFalse);
    },
  );

  testWidgets(
    'a device that was onboarding resumes at Finding, then may open Found cases',
    (tester) async {
      await pumpApp(tester, onboardingDone: false);
      expect(find.text(en.findingTitle), findsOneWidget);
      container(tester).read(routerProvider).go('/found');
      await tester.pumpAndSettle();
      expect(find.text(en.foundTitle), findsOneWidget);
    },
  );

  testWidgets('someone who joined a team goes straight to notifications', (
    tester,
  ) async {
    await pumpApp(tester, account: juniorAccount, onboardingDone: false);
    expect(find.text(en.notificationsTitle), findsOneWidget);
  });

  testWidgets('the join deep link is open before an organisation exists', (
    tester,
  ) async {
    await pumpApp(tester, account: newAccount, location: '/join/ABC234');
    expect(find.text(en.joinTitle), findsOneWidget);
  });

  testWidgets('while the account loads, a skeleton (no wrong screen)', (
    tester,
  ) async {
    // Reduce motion keeps the skeleton still, so the frame settles.
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final api = _NeverApi();
    await pumpApp(tester, api: api);
    expect(find.bySemanticsLabel(en.accountLoading), findsOneWidget);
    expect(find.text(en.todayEmpty), findsNothing);
  });

  for (final locale in ['en', 'hi']) {
    final l = lookupAppLocalizations(Locale(locale));
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'offline with nothing cached: offline state, Retry carries on ($locale ${scale}x)',
        (tester) async {
          final handle = tester.ensureSemantics();
          final api = FakeApi()..offline = true;
          await pumpApp(tester, api: api, locale: locale, textScale: scale);
          expect(find.byType(OfflineBanner), findsOneWidget);
          expect(find.text(l.errorNetwork), findsOneWidget);
          expect(tester.takeException(), isNull);
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

          api.offline = false;
          await tester.tap(find.text(l.retry));
          await tester.pumpAndSettle();
          expect(find.text(l.roleTitle), findsOneWidget);
          handle.dispose();
        },
      );
    }
  }

  testWidgets(
    'a session that ends by itself forgets the account: the next person starts at consent',
    (tester) async {
      await pumpApp(tester, onboardingDone: true);
      expect(find.text(en.todayEmpty), findsOneWidget);
      final auth = container(tester).read(authRepositoryProvider) as FakeAuth;
      // A revoked or expired refresh token: Supabase signs out without Session.signOut.
      await auth.signOut();
      await tester.pumpAndSettle();
      final s = container(tester).read(settingsProvider);
      expect(s.onboardingDone, isNull);
      expect(s.consentVersion, isNull);
      expect(s.locale, const Locale('en'));
      expect(find.byType(PhoneScreen), findsOneWidget);
    },
  );

  testWidgets(
    'after sign-out, a new person on the same device is onboarded, not sent to Today',
    (tester) async {
      final api = await pumpApp(tester, onboardingDone: true);
      final c = container(tester);
      await c.read(sessionProvider).signOut();
      await tester.pumpAndSettle();
      expect(find.byType(PhoneScreen), findsOneWidget);

      api.account = const Account(id: 'user-2');
      final auth = c.read(authRepositoryProvider) as FakeAuth;
      await auth.verifyOtp('9876543210', '123456');
      await tester.pumpAndSettle();
      expect(find.byType(ConsentScreen), findsOneWidget);
      await c
          .read(settingsProvider.notifier)
          .setConsentVersion(consentNoticeVersion);
      await tester.pumpAndSettle();
      expect(find.byType(LockSetupScreen), findsOneWidget);
      await c.read(appLockProvider.notifier).skip();
      await tester.pumpAndSettle();
      expect(find.text(en.roleTitle), findsOneWidget);
      expect(c.read(settingsProvider).onboardingDone, isFalse);
    },
  );

  test('back online after a failed load, the account loads again', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final sync = StreamController<SyncView>();
    addTearDown(sync.close);
    final api = FakeApi(account: ownerAccount)..offline = true;
    final c = ProviderContainer(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        authRepositoryProvider.overrideWithValue(FakeAuth(signedIn: true)),
        apiClientProvider.overrideWithValue(api),
        syncViewProvider.overrideWith((_) => sync.stream),
      ],
    );
    addTearDown(c.dispose);
    final sub = c.listen(accountProvider, (_, _) {});
    addTearDown(sub.close);
    await expectLater(
      c.read(accountProvider.future),
      throwsA(isA<ApiException>()),
    );
    sync.add((status: SyncStatus.syncing, offline: true));
    await pumpEventQueue();
    api.offline = false;
    sync.add((status: SyncStatus.synced, offline: false));
    await pumpEventQueue();
    expect(await c.read(accountProvider.future), same(ownerAccount));
  });

  test('sign-out forgets the onboarding flag, queued and offline files, but '
      'keeps the language', () async {
    SharedPreferences.setMockInitialValues({
      'settings.locale': 'hi',
      'settings.onboarding_done': true,
    });
    final prefs = await SharedPreferences.getInstance();
    // The app's support folder with a queued upload and an offline copy; the scanner's and picker's caches.
    final support = Directory.systemTemp.createTempSync('pairavi_support');
    addTearDown(() => support.deleteSync(recursive: true));
    for (final f in ['uploads/q1.pdf', 'offline/d1.pdf']) {
      File('${support.path}/$f')
        ..createSync(recursive: true)
        ..writeAsBytesSync([0]);
    }
    final sources = _CountingSources();
    final c = ProviderContainer(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        authRepositoryProvider.overrideWithValue(FakeAuth(signedIn: true)),
        lockStoreProvider.overrideWithValue(MemoryLockStore()),
        testShareDir(),
        appSupportDirProvider.overrideWithValue(support),
        uploadSourcesProvider.overrideWithValue(sources),
      ],
    );
    addTearDown(c.dispose);
    expect(c.read(settingsProvider).onboardingDone, isTrue);
    // A board image shared earlier, which may hold case titles.
    final shares = await c.read(boardShareDirProvider)();
    File('${shares.path}${Platform.pathSeparator}board-2026-11-06.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync([0]);
    // A feedback note that couldn't be sent.
    c.read(feedbackDraftProvider.notifier).text = 'Court 7 is missing.';
    await c.read(sessionProvider).signOut();
    expect(c.read(feedbackDraftProvider), '');
    expect(shares.existsSync(), isFalse);
    expect(filesDir(support, 'uploads').existsSync(), isFalse);
    expect(filesDir(support, 'offline').existsSync(), isFalse);
    expect(sources.cleaned, 1);
    expect(c.read(settingsProvider).onboardingDone, isNull);
    expect(prefs.getBool('settings.onboarding_done'), isNull);
    expect(c.read(settingsProvider).locale, const Locale('hi'));
  });
}

/// The scanner's and picker's clean-up, counted.
class _CountingSources extends UploadSources {
  int cleaned = 0;

  @override
  Future<void> cleanUp() async => cleaned++;
}

/// /v1/me never answers.
class _NeverApi extends FakeApi {
  @override
  Future<Never> me() => Completer<Never>().future;
}
