import 'package:advocate_app/app.dart';
import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/auth.dart';
import 'package:advocate_app/data/device.dart';
import 'package:advocate_app/features/lock/app_lock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers.dart';

void main() {
  setUpAll(loadAppFonts);

  testWidgets(
    'first run: Hindi → phone → OTP → consent → PIN → Today, all in Hindi',
    (tester) async {
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

      // 1. Language.
      await tester.tap(find.text('हिंदी'));
      await tester.pumpAndSettle();

      // 2. Phone: invalid number shows an inline Hindi error; valid one sends the code.
      expect(find.text('अपने मोबाइल नंबर से साइन इन करें'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '12345');
      await tester.tap(find.text('कोड भेजें'));
      await tester.pumpAndSettle();
      expect(find.textContaining('10 अंकों का मोबाइल नंबर'), findsWidgets);
      await tester.enterText(find.byType(TextField), '9876543210');
      await tester.tap(find.text('कोड भेजें'));
      await tester.pumpAndSettle();
      expect(auth.sent, ['9876543210']);

      // 3. OTP (auto-submits at 6 digits).
      expect(find.text('कोड डालें'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '123456');
      await tester.pumpAndSettle();

      // 4. Consent: button disabled until the required box is ticked.
      expect(find.text('आपका डेटा, आपका नियंत्रण'), findsOneWidget);
      final agree = find.widgetWithText(FilledButton, 'सहमत हूँ, आगे बढ़ें');
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
      expect(find.text('ऐप लॉक करें'), findsOneWidget);
      await tester.tap(find.text('4 अंकों का PIN बनाएँ'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '2468');
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '2468');
      await tester.pumpAndSettle();
      expect(store.method, LockMethod.pin);

      // 6. Today, in Hindi, with the P1 bottom bar.
      expect(find.text('आज कोई केस नहीं है।'), findsOneWidget);
      expect(find.text('केस'), findsWidgets);
      expect(find.text('और'), findsOneWidget);
    },
  );
}
