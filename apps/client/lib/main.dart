import 'package:advocate_app/app.dart';
import 'package:advocate_app/core/config.dart';
import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/core/window.dart';
import 'package:advocate_app/data/auth.dart';
import 'package:advocate_app/data/documents.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:advocate_app/features/lock/app_lock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart' show pdfrxFlutterInitialize;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Config.hasBackend) {
    // Developer-facing only: release builds always carry the config.
    runApp(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: Text(
            'Missing config: run with --dart-define-from-file=env.local.json (just setup)',
          ),
        ),
      ),
    );
    return;
  }
  final prefs = await SharedPreferences.getInstance();
  await Supabase.initialize(
    url: Config.supabaseUrl,
    publishableKey: Config.supabaseAnonKey,
    authOptions: const FlutterAuthClientOptions(
      localStorage: SecureSessionStorage(),
    ),
  );
  final lock = await LockStore().load();
  final db = await openSyncDatabase();
  final support = await getApplicationSupportDirectory();
  // PDFium for the document viewer (ADR 0005); it needs path_provider, so tests use a stand-in instead.
  await pdfrxFlutterInitialize();
  if (defaultTargetPlatform == TargetPlatform.windows) await setUpWindow(prefs);

  runApp(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        initialLockProvider.overrideWithValue(lock),
        syncDatabaseProvider.overrideWithValue(db),
        appSupportDirProvider.overrideWithValue(support),
      ],
      child: const App(),
    ),
  );
}
