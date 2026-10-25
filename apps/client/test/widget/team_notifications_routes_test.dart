import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/router.dart';
import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/features/dashboard/dashboard_screen.dart';
import 'package:advocate_app/features/notifications/notification_centre.dart';
import 'package:advocate_app/features/notifications/notification_prefs_screen.dart';
import 'package:advocate_app/features/onboarding/join_screen.dart';
import 'package:advocate_app/features/team/team_screen.dart';
import 'package:advocate_app/features/today/today_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

String _at(WidgetTester tester) =>
    container(tester)
        .read(routerProvider)
        .routerDelegate
        .currentConfiguration
        .uri
        .toString();

/// Task 11's routes and the app-wide parts under them: the removed-member path, local notifications, More.
void main() {
  setUpAll(loadAppFonts);
  final en = lookupAppLocalizations(const Locale('en'));

  for (final locale in ['en', 'hi']) {
    final l = lookupAppLocalizations(Locale(locale));
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'removed from the only team: the role step says so and offers a code '
        '($locale, ${scale}x)',
        (tester) async {
          final api = await pumpApp(
            tester,
            account: juniorAccount,
            onboardingDone: true,
            locale: locale,
            textScale: scale,
          );
          expect(find.byType(TodayScreen), findsOneWidget);
          api.account = const Account(id: 'user-2');
          await container(tester).read(accountProvider.notifier).refresh();
          await tester.pumpAndSettle();
          expect(_at(tester), '/onboarding/role');
          expect(
            find.text(l.teamDataRemoved('Sharma Chambers')),
            findsOneWidget,
          );
          expect(
            container(tester).read(settingsProvider).onboardingDone,
            isFalse,
          );
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(find.text(l.teamDataJoinAnother));
          await tester.pumpAndSettle();
          await tester.tap(find.text(l.teamDataJoinAnother));
          await tester.pumpAndSettle();
          expect(find.byType(JoinScreen), findsOneWidget);
        },
      );
    }
  }

  testWidgets('removed while the app was closed: the generic line', (
    tester,
  ) async {
    await pumpApp(tester, account: newAccount, onboardingDone: true);
    expect(_at(tester), '/onboarding/role');
    expect(find.text(en.teamDataRemovedUnknown), findsOneWidget);
  });

  testWidgets('a new account on the role step sees no removal line', (
    tester,
  ) async {
    await pumpApp(tester, account: newAccount);
    expect(find.text(en.roleTitle), findsOneWidget);
    expect(find.text(en.teamDataRemovedUnknown), findsNothing);
    expect(find.text(en.teamDataJoinAnother), findsNothing);
  });

  group('local notifications from the shell', () {
    testWidgets(
      'a row arriving by sync becomes an OS notification; a tap opens its link',
      (tester) async {
        final notifier = FakeLocalNotifier();
        final notifications = FakeNotifications(
          rows: [
            notification(
              1,
              createdAt: testNow.subtract(const Duration(hours: 3)),
            ),
          ],
        );
        await pumpApp(
          tester,
          notifier: notifier,
          overrides: [
            clockProvider.overrideWithValue(() => testNow),
            ...notifications.overrides,
          ],
        );
        // An old row (before the app started) is never replayed.
        expect(notifier.shown, isEmpty);
        notifications.arrive(
          notification(
            2,
            createdAt: testNow,
            body: 'New order in WP 1002/2024.',
          ),
        );
        await tester.pumpAndSettle();
        expect(notifier.shown.single.body, 'New order in WP 1002/2024.');
        notifier.onTap!('/cases/m-2');
        await tester.pumpAndSettle();
        expect(_at(tester), '/cases/m-2');
        // A link that isn't one of the app's routes goes nowhere.
        notifier.onTap!('https://evil.test');
        await tester.pumpAndSettle();
        expect(_at(tester), '/cases/m-2');
      },
    );

    testWidgets('nothing pops up while the centre is open', (tester) async {
      final notifier = FakeLocalNotifier();
      final notifications = FakeNotifications();
      await pumpApp(
        tester,
        location: '/notifications',
        notifier: notifier,
        overrides: [
          clockProvider.overrideWithValue(() => testNow),
          ...notifications.overrides,
        ],
      );
      notifications.arrive(notification(1, createdAt: testNow));
      await tester.pumpAndSettle();
      expect(notifier.shown, isEmpty);
    });

    testWidgets('nor while the centre opened from the bell is open', (
      tester,
    ) async {
      final notifier = FakeLocalNotifier();
      final notifications = FakeNotifications();
      await pumpApp(
        tester,
        notifier: notifier,
        overrides: [
          clockProvider.overrideWithValue(() => testNow),
          ...notifications.overrides,
        ],
      );
      // The bell pushes the centre over Today.
      await tester.tap(find.byTooltip(en.navNotifications));
      await tester.pumpAndSettle();
      expect(find.byType(NotificationCentre), findsOneWidget);
      notifications.arrive(notification(1, createdAt: testNow));
      await tester.pumpAndSettle();
      expect(notifier.shown, isEmpty);
      // A case opened from the centre is not the centre: a new row pops up there.
      await tester.tap(find.text('New order'));
      await tester.pumpAndSettle();
      notifications.arrive(notification(2, createdAt: testNow));
      await tester.pumpAndSettle();
      expect(notifier.shown.single.body, 'New order in WP 1002/2024.');
    });

    testWidgets('a centre left open in the background still alerts', (
      tester,
    ) async {
      final notifier = FakeLocalNotifier();
      final notifications = FakeNotifications();
      await pumpApp(
        tester,
        location: '/notifications',
        notifier: notifier,
        overrides: [
          clockProvider.overrideWithValue(() => testNow),
          ...notifications.overrides,
        ],
      );
      void lifecycle(List<AppLifecycleState> states) =>
          states.forEach(tester.binding.handleAppLifecycleStateChanged);

      // Home pressed (Android) or the window minimised (Windows).
      lifecycle([AppLifecycleState.inactive, AppLifecycleState.hidden]);
      addTearDown(
        () =>
            lifecycle([AppLifecycleState.inactive, AppLifecycleState.resumed]),
      );
      notifications.arrive(notification(1, createdAt: testNow));
      await tester.pump();
      expect(notifier.shown, hasLength(1));
    });
  });

  testWidgets('More leads to the dashboard, team, notifications and feedback', (
    tester,
  ) async {
    await pumpApp(tester, location: '/more');
    for (final (label, screen) in [
      (en.navDashboard, DashboardScreen),
      (en.navTeam, TeamScreen),
      (en.navNotifications, NotificationCentre),
    ]) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(find.byType(screen), findsOneWidget, reason: label);
      container(tester).read(routerProvider).go('/more');
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text(en.navFeedback));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
  });

  testWidgets(
    'Settings reaches notification settings (the Windows rail has no More)',
    (tester) async {
      await pumpApp(tester, location: '/settings');
      await tester.scrollUntilVisible(
        find.text(en.navNotificationSettings),
        200,
      );
      await tester.tap(find.text(en.navNotificationSettings));
      await tester.pumpAndSettle();
      expect(find.byType(NotificationPrefsScreen), findsOneWidget);
      expect(_at(tester), '/settings/notifications');
    },
  );

  testWidgets("the dashboard's New orders opens the centre for that kind", (
    tester,
  ) async {
    await pumpApp(tester, location: '/notifications?kind=new_order');
    final centre = tester.widget<NotificationCentre>(
      find.byType(NotificationCentre),
    );
    expect(centre.kind, 'new_order');
  });
}
