import 'dart:async';

import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:advocate_app/features/shell/home_shell.dart';
import 'package:advocate_app/features/today/today_screen.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers.dart';

void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  Future<void> pumpStream(
    WidgetTester tester,
    Stream<SyncView> views, {
    String locale = 'en',
  }) async {
    tester.view.physicalSize = const Size(400, 860); // phone layout
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(prefs),
          syncViewProvider.overrideWith((_) => views),
        ],
        child: host(
          const HomeShell(location: '/today', child: TodayScreen()),
          locale: locale,
          height: 800,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pump(WidgetTester tester, SyncView view) =>
      pumpStream(tester, Stream.value(view));

  testWidgets('online: no banner, indicator shows synced', (tester) async {
    await pump(tester, (status: SyncStatus.synced, offline: false));
    expect(find.byType(OfflineBanner), findsNothing);
    expect(
      tester.widget<SyncIndicator>(find.byType(SyncIndicator)).status,
      SyncStatus.synced,
    );
  });

  testWidgets('offline: banner shows, indicator waits', (tester) async {
    await pump(tester, (status: SyncStatus.syncing, offline: true));
    expect(find.byType(OfflineBanner), findsOneWidget);
    expect(
      tester.widget<SyncIndicator>(find.byType(SyncIndicator)).status,
      SyncStatus.syncing,
    );
  });

  for (final locale in ['en', 'hi']) {
    testWidgets('back online: "Up to date" is said once ($locale)', (
      tester,
    ) async {
      final l = lookupAppLocalizations(Locale(locale));
      final announced = captureAnnouncements(tester);
      final views = StreamController<SyncView>();
      addTearDown(views.close);
      await pumpStream(tester, views.stream, locale: locale);
      views.add((status: SyncStatus.syncing, offline: true));
      await tester.pumpAndSettle();
      expect(announced, [l.offlineBanner]);

      // Reconnecting syncs first; only catching up is said.
      views.add((status: SyncStatus.syncing, offline: false));
      await tester.pumpAndSettle();
      views.add((status: SyncStatus.synced, offline: false));
      await tester.pumpAndSettle();
      expect(announced, [l.offlineBanner, l.synced]);
      expect(find.text(l.synced), findsOneWidget);

      // The note goes after a moment; later writes are quiet.
      await tester.pump(const Duration(seconds: 5));
      expect(find.byType(OfflineBanner), findsNothing);
      views
        ..add((status: SyncStatus.syncing, offline: false))
        ..add((status: SyncStatus.synced, offline: false));
      await tester.pumpAndSettle();
      expect(announced, [l.offlineBanner, l.synced]);
    });
  }

  testWidgets('a failed upload that goes through is said once', (tester) async {
    final announced = captureAnnouncements(tester);
    final views = StreamController<SyncView>();
    addTearDown(views.close);
    await pumpStream(tester, views.stream);
    views.add((status: SyncStatus.failed, offline: false));
    await tester.pumpAndSettle();
    views.add((status: SyncStatus.synced, offline: false));
    await tester.pumpAndSettle();
    expect(announced, [en.synced]);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a local write syncing says nothing', (tester) async {
    final announced = captureAnnouncements(tester);
    final views = StreamController<SyncView>();
    addTearDown(views.close);
    await pumpStream(tester, views.stream);
    for (final status in [
      SyncStatus.synced,
      SyncStatus.syncing,
      SyncStatus.synced,
    ]) {
      views.add((status: status, offline: false));
      await tester.pumpAndSettle();
    }
    expect(announced, isEmpty);
    expect(find.byType(OfflineBanner), findsNothing);
  });
}
