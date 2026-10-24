import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:advocate_app/features/shell/home_shell.dart';
import 'package:advocate_app/features/shell/screens.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers.dart';

void main() {
  Future<void> pump(WidgetTester tester, SyncView view) async {
    tester.view.physicalSize = const Size(400, 860); // phone layout
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(prefs),
          syncViewProvider.overrideWith((_) => Stream.value(view)),
        ],
        child: host(
          const HomeShell(location: '/today', child: TodayScreen()),
          height: 800,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

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
}
