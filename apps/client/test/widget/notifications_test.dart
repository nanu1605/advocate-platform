import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/router.dart';
import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/data/notifications.dart';
import 'package:advocate_app/features/case_page/case_page.dart';
import 'package:advocate_app/features/notifications/notification_centre.dart';
import 'package:advocate_app/features/notifications/notification_prefs_screen.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

/// Thu 5 Nov 2026 10:00 IST ([testNow]): a new order (unread); a next-date update with an older one under the same
/// collapse key (both unread); last evening's board (read); Monday's court-data delay (read, a link that isn't an
/// app route). Titles and bodies as the server writes them in [hi] or English.
FakeNotifications sampleNotifications({bool hi = false}) => FakeNotifications(
  rows: [
    notification(
      1,
      title: hi ? 'नया ऑर्डर' : 'New order',
      body: hi
          ? 'WP 1001/2024 में नया ऑर्डर — 2 काम मिले।'
          : 'New order in WP 1001/2024 — 2 actions found.',
    ),
    notification(
      2,
      kind: 'next_date_set',
      title: hi ? 'अगली तारीख' : 'Next date',
      body: hi
          ? 'WP 1002/2024: अगली तारीख गुरु, 12 नवंबर।'
          : 'WP 1002/2024: next date Thu 12 Nov.',
    ),
    notification(
      3,
      kind: 'next_date_set',
      title: hi ? 'अगली तारीख' : 'Next date',
      body: hi
          ? 'WP 1002/2024: अगली तारीख मंगल, 10 नवंबर।'
          : 'WP 1002/2024: next date Tue 10 Nov.',
      createdAt: testNow.subtract(const Duration(hours: 2)),
      link: '/cases/m-2',
      collapseKey: 'next_date_set:m-2',
    ),
    notification(
      4,
      kind: 'tomorrow_board',
      title: hi ? 'कल का बोर्ड' : "Tomorrow's board",
      body: hi ? 'कल: 3 कोर्ट में 6 केस। पहला: MPHC इंदौर, कोर्ट 12, आइटम 23।' : 'Tomorrow: 6 matters in 3 courts. First: MPHC Indore, Court 12, item 23.',
      createdAt: testNow.subtract(const Duration(hours: 15)),
      read: true,
      link: '/board/tomorrow',
      collapseKey: 'tomorrow_board:2026-11-05',
    ),
    notification(
      5,
      kind: 'sync_issue',
      title: hi ? 'कोर्ट डेटा में देरी' : 'Court data is delayed',
      body: hi
          ? 'कोर्ट डेटा में देरी है। हम शाम 7 बजे फिर कोशिश करेंगे।'
          : "Court data is delayed. We'll retry at 7 pm.",
      createdAt: DateTime.utc(2026, 11, 2, 6),
      read: true,
      link: 'https://example.test/status',
      collapseKey: 'sync_issue',
    ),
  ],
);

String _at(WidgetTester tester) =>
    container(tester)
        .read(routerProvider)
        .routerDelegate
        .currentConfiguration
        .uri
        .toString();

/// The last write (the only one with [only]) was [name] with [args].
void _wrote(
  FakeNotifications fake,
  String name,
  Object? args, {
  bool only = false,
}) {
  if (only) expect(fake.writes, hasLength(1));
  expect(fake.writes.last.name, name);
  expect(fake.writes.last.args, args);
}

/// Tall enough that every sample row is built at 200% text.
const _tall = Size(400, 2400);

void main() {
  setUpAll(loadAppFonts);
  final en = lookupAppLocalizations(const Locale('en'));

  Future<FakeNotifications> pump(
    WidgetTester tester, {
    String location = '/notifications',
    FakeNotifications? fake,
    String locale = 'en',
    double scale = 1,
    Size size = _tall,
    FakePermission? permission,
    bool offline = false,
  }) async {
    final notifications = fake ?? sampleNotifications(hi: locale == 'hi');
    await pumpApp(
      tester,
      location: location,
      locale: locale,
      textScale: scale,
      size: size,
      overrides: [
        clockProvider.overrideWithValue(() => testNow),
        ...notifications.overrides,
        (permission ?? FakePermission()).asOverride,
        if (offline) ...syncedData(offline: true),
      ],
    );
    return notifications;
  }

  for (final locale in ['en', 'hi']) {
    final l = lookupAppLocalizations(Locale(locale));
    final hi = locale == 'hi';
    for (final scale in [1.0, 2.0]) {
      final tag = '($locale, ${scale}x)';

      testWidgets('the bell shows the unread count and opens the centre $tag', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await pump(tester, location: '/today', locale: locale, scale: scale);
        // The new order, and the next-date group once.
        expect(find.byTooltip(l.notifBellUnread(2)), findsOneWidget);
        expect(find.text('2'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip(l.notifBellUnread(2)));
        await tester.pumpAndSettle();
        expect(find.byType(NotificationCentre), findsOneWidget);
        handle.dispose();
      });

      testWidgets(
        'the centre groups by day, folds a collapse key and marks unread $tag',
        (tester) async {
          final handle = tester.ensureSemantics();
          await pump(tester, locale: locale, scale: scale);
          for (final header in [
            l.relToday,
            l.relYesterday,
            l.notifCentreEarlier,
          ]) {
            expect(
              find.descendant(
                of: find.byType(NotificationCentre),
                matching: find.text(header),
              ),
              findsOneWidget,
              reason: header,
            );
          }
          // The newest next-date update shows; the older one is folded under it.
          expect(
            find.text(
              hi
                  ? 'WP 1002/2024: अगली तारीख गुरु, 12 नवंबर।'
                  : 'WP 1002/2024: next date Thu 12 Nov.',
            ),
            findsOneWidget,
          );
          expect(
            find.text(
              hi
                  ? 'WP 1002/2024: अगली तारीख मंगल, 10 नवंबर।'
                  : 'WP 1002/2024: next date Tue 10 Nov.',
            ),
            findsNothing,
          );
          expect(find.textContaining(l.notifCentreFolded(1)), findsOneWidget);
          // Two unread rows: bold, a dot each, read out as unread.
          expect(
            find.bySemanticsLabel(RegExp(RegExp.escape(l.notifCentreUnread))),
            findsNWidgets(2),
          );
          final title = tester.widget<Text>(
            find.text(hi ? 'नया ऑर्डर' : 'New order'),
          );
          expect(title.style?.fontWeight, FontWeight.w700);
          final read = tester.widget<Text>(
            find.text(hi ? 'कल का बोर्ड' : "Tomorrow's board"),
          );
          expect(read.style?.fontWeight, isNot(FontWeight.w700));
          expect(tester.takeException(), isNull);
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          handle.dispose();
        },
      );

      testWidgets('a tap marks the group read and opens its link $tag', (
        tester,
      ) async {
        final fake = await pump(tester, locale: locale, scale: scale);
        await tester.tap(find.text(hi ? 'अगली तारीख' : 'Next date'));
        await tester.pumpAndSettle();
        _wrote(fake, 'markRead', ['n-2', 'n-3'], only: true);
        expect(tester.widget<CasePage>(find.byType(CasePage)).matterId, 'm-2');
      });

      testWidgets('Mark all read clears the badge and says so $tag', (
        tester,
      ) async {
        final fake = await pump(tester, locale: locale, scale: scale);
        await tester.tap(find.byTooltip(l.notifCentreMarkAll));
        await tester.pumpAndSettle();
        expect(fake.writes.single.name, 'markAllRead');
        expect(find.text(l.notifCentreAllRead), findsOneWidget);
        expect(find.byTooltip(l.notifCentreMoreActions('x')), findsNothing);
        expect(container(tester).read(unreadNotificationCountProvider), 0);
        // Nothing left to mark.
        final button = tester.widget<IconButton>(
          find.ancestor(
            of: find.byTooltip(l.notifCentreMarkAll),
            matching: find.byType(IconButton),
          ),
        );
        expect(button.onPressed, isNull);
      });

      testWidgets('empty: what will arrive here $tag', (tester) async {
        await pump(
          tester,
          fake: FakeNotifications(),
          locale: locale,
          scale: scale,
          size: const Size(400, 860),
        );
        expect(find.text(l.notifCentreEmpty), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('preferences: each kind, titles and urgent write $tag', (
        tester,
      ) async {
        final fake = await pump(
          tester,
          location: '/settings/notifications',
          locale: locale,
          scale: scale,
        );
        expect(find.byType(NotificationPrefsScreen), findsOneWidget);
        for (final kind in notificationKinds) {
          expect(
            find.text(notificationKindLabel(l, kind)),
            findsOneWidget,
            reason: kind,
          );
        }
        expect(find.text(l.notifyExplainerDenied), findsNothing);
        await tester.tap(find.text(l.notifDataKindTomorrowBoard));
        await tester.pumpAndSettle();
        _wrote(fake, 'setKindEnabled', {
          'kind': 'tomorrow_board',
          'enabled': false,
        });
        final board = tester.widget<SwitchListTile>(
          find.ancestor(
            of: find.text(l.notifDataKindTomorrowBoard),
            matching: find.byType(SwitchListTile),
          ),
        );
        expect(board.value, isFalse);

        await tester.ensureVisible(find.text(l.notifPrefsTitles));
        await tester.tap(find.text(l.notifPrefsTitles));
        await tester.pumpAndSettle();
        _wrote(fake, 'setIncludeTitles', true);

        await tester.ensureVisible(find.text(l.notifPrefsUrgent));
        await tester.tap(find.text(l.notifPrefsUrgent));
        await tester.pumpAndSettle();
        expect(
          container(tester).read(settingsProvider).urgentBreaksQuiet,
          isFalse,
        );
        // Quiet hours show the defaults in 12-hour time.
        final f = Formats(Locale(locale));
        expect(find.text(f.time(DateTime.utc(2000, 1, 1, 22))), findsOneWidget);
        expect(find.text(f.time(DateTime.utc(2000, 1, 1, 7))), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('preferences: notifications off in Android settings $tag', (
        tester,
      ) async {
        final permission = FakePermission(enabled: false);
        await pump(
          tester,
          location: '/settings/notifications',
          locale: locale,
          scale: scale,
          permission: permission,
        );
        expect(find.text(l.notifyExplainerDenied), findsOneWidget);
        await tester.tap(find.text(l.notifyExplainerOpenSettings));
        await tester.pumpAndSettle();
        expect(permission.settingsOpened, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('a link that is not an app route is only marked read', (
    tester,
  ) async {
    final fake = await pump(tester);
    await tester.tap(find.text('Court data is delayed'));
    await tester.pumpAndSettle();
    // Already read: nothing to write, and nowhere to go.
    expect(fake.writes, isEmpty);
    expect(find.byType(CasePage), findsNothing);
    expect(_at(tester), '/notifications');
    fake.arrive(notification(9, link: 'https://example.test/x'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New order in WP 1009/2024.'));
    await tester.pumpAndSettle();
    _wrote(fake, 'markRead', ['n-9'], only: true);
    expect(find.byType(CasePage), findsNothing);
    expect(_at(tester), '/notifications');
  });

  // Spec §16.6: both read and write the synced database, so they work offline.
  testWidgets('offline: the centre and preferences show under the banner; '
      'marking read and a preference still save on the device', (tester) async {
    final fake = await pump(tester, offline: true);
    expect(find.byType(OfflineBanner), findsOneWidget);
    expect(find.text('New order'), findsOneWidget);
    await tester.tap(find.byTooltip(en.notifCentreMarkAll));
    await tester.pumpAndSettle();
    _wrote(fake, 'markAllRead', null, only: true);

    container(tester).read(routerProvider).go('/settings/notifications');
    await tester.pumpAndSettle();
    expect(find.byType(OfflineBanner), findsOneWidget);
    await tester.tap(find.text(en.notifDataKindTomorrowBoard));
    await tester.pumpAndSettle();
    _wrote(fake, 'setKindEnabled', {
      'kind': 'tomorrow_board',
      'enabled': false,
    });
    expect(find.text(en.errorNeedsNetwork), findsNothing);
  });

  testWidgets('the menu and a swipe mark one row read', (tester) async {
    final fake = await pump(tester);
    await tester.tap(find.byTooltip(en.notifCentreMoreActions('New order')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.notifCentreMarkRead));
    await tester.pumpAndSettle();
    _wrote(fake, 'markRead', ['n-1'], only: true);
    expect(find.byType(CasePage), findsNothing);
    expect(_at(tester), '/notifications');
    // Swiped, the row stays, without its dot.
    await tester.drag(find.text('Next date'), const Offset(-300, 0));
    await tester.pumpAndSettle();
    _wrote(fake, 'markRead', ['n-2', 'n-3']);
    expect(find.text('Next date'), findsOneWidget);
    expect(
      find.byTooltip(en.notifCentreMoreActions('Next date')),
      findsNothing,
    );
  });

  testWidgets(
    "one kind (the dashboard's New orders): only that kind, and Mark all read marks only it",
    (tester) async {
      final fake = await pump(
        tester,
        location: '/notifications?kind=new_order',
      );
      expect(find.text('New order'), findsOneWidget);
      expect(find.text('Next date'), findsNothing);
      await tester.tap(find.byTooltip(en.notifCentreMarkAll));
      await tester.pumpAndSettle();
      _wrote(fake, 'markRead', ['n-1'], only: true);
      // Only new orders were marked, and the message says so.
      expect(
        find.text(en.notifCentreKindRead(en.notifDataKindNewOrder)),
        findsOneWidget,
      );
      expect(find.text(en.notifCentreAllRead), findsNothing);
      // The chip shows every kind again.
      await tester.tap(find.text(en.notifDataKindNewOrder));
      await tester.pumpAndSettle();
      expect(find.byType(CasePage), findsNothing);
      expect(_at(tester), '/notifications');
      expect(find.text('Next date'), findsOneWidget);
    },
  );

  testWidgets('one kind with nothing in it offers every kind', (tester) async {
    await pump(tester, location: '/notifications?kind=deadline_due');
    expect(find.text(en.notifCentreEmptyKind), findsOneWidget);
    await tester.tap(find.text(en.notifCentreShowAll));
    await tester.pumpAndSettle();
    expect(find.text('New order'), findsOneWidget);
  });

  testWidgets('the gear opens preferences', (tester) async {
    await pump(tester);
    await tester.tap(find.byTooltip(en.navNotificationSettings));
    await tester.pumpAndSettle();
    expect(find.byType(NotificationPrefsScreen), findsOneWidget);
  });

  testWidgets('no unread: the bell has no badge', (tester) async {
    await pump(tester, location: '/today', fake: FakeNotifications());
    expect(find.byTooltip(en.navNotifications), findsOneWidget);
    final badge = tester.widget<Badge>(find.byType(Badge));
    expect(badge.isLabelVisible, isFalse);
  });

  testWidgets('quiet hours: a 12-hour picker writes both ends', (tester) async {
    final fake = await pump(tester, location: '/settings/notifications');
    await tester.ensureVisible(find.text(en.notifPrefsQuietStart));
    await tester.tap(find.text(en.notifPrefsQuietStart));
    await tester.pumpAndSettle();
    expect(find.text(en.notifPrefsPickStart), findsOneWidget);
    // Type 11:30 (the picker keeps PM from 10 pm).
    await tester.tap(find.byIcon(Icons.keyboard_outlined));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '11');
    await tester.enterText(fields.at(1), '30');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    _wrote(fake, 'setQuietHours', {
      'start': const Duration(hours: 23, minutes: 30),
      'end': defaultQuietEnd,
    }, only: true);
    expect(find.text('11:30 pm'), findsOneWidget);
  });
}
