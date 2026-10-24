// End-to-end offline sync against the local stack (`just dev`): real Supabase sign-in, the PowerSync SDK and the
// Docker sync service. Run on a desktop or device:
//   flutter test integration_test/sync_test.dart -d windows --dart-define-from-file=env.local.json
import 'dart:io';

import 'package:advocate_app/core/config.dart';
import 'package:advocate_app/data/sync/schema.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:powersync/powersync.dart' hide SyncStatus;
import 'package:supabase_flutter/supabase_flutter.dart';

const _phone = '+919999900002'; // local test number (supabase/config.toml)

Future<void> _until(Future<bool> Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!await done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('offline writes upload on reconnect; refused ones roll back', (
    _,
  ) async {
    expect(Config.powersyncUrl, isNotEmpty, reason: 'pass env.local.json');
    await Supabase.initialize(
      url: Config.supabaseUrl,
      publishableKey: Config.supabaseAnonKey,
      authOptions: const FlutterAuthClientOptions(
        localStorage: EmptyLocalStorage(),
      ),
    );
    final supabase = Supabase.instance.client;
    await supabase.auth.signInWithOtp(phone: _phone);
    await supabase.auth.verifyOTP(
      phone: _phone,
      token: '123456',
      type: OtpType.sms,
    );
    final me = supabase.auth.currentUser!.id;

    final dir = await Directory.systemTemp.createTemp('pairavi_sync');
    final db = PowerSyncDatabase(schema: schema, path: '${dir.path}/test.db');
    final connector = SupabaseConnector(supabase);
    addTearDown(() async {
      await db.disconnectAndClear();
      await db.close();
      await supabase.from('notification_prefs').delete().eq('user_id', me);
    });

    // Download: reference rows and the user's own profile.
    await db.connect(connector: connector);
    await db.waitForFirstSync();
    final courts = await db.get('select count(*) as n from courts');
    expect(courts['n'] as int, greaterThanOrEqualTo(5));
    final profiles = await db.getAll('select id from profiles');
    expect(profiles.map((r) => r['id']), [me]);

    // Offline: writes queue on the device.
    await db.disconnect();
    final mine = uuid.v4();
    final foreign = uuid.v4();
    await db.execute(
      'insert into notification_prefs (id, user_id, kind, channels, include_titles) values (?, ?, ?, ?, ?)',
      [mine, me, 'new_order', '["push","whatsapp"]', 1],
    );
    // Someone else's row: row-level security refuses it for good.
    await db.execute(
      'insert into notification_prefs (id, user_id, kind) values (?, ?, ?)',
      [foreign, uuid.v4(), 'new_order'],
    );
    expect((await db.getUploadQueueStats()).count, 2);

    // Back online: the queue drains, the accepted row is in Postgres with a real array and boolean, and the
    // refused row disappears from the device once the server's state syncs back.
    await db.connect(connector: connector);
    await _until(() async => (await db.getUploadQueueStats()).count == 0);
    final server = await supabase
        .from('notification_prefs')
        .select('channels, include_titles')
        .eq('id', mine)
        .single();
    expect(server, {
      'channels': ['push', 'whatsapp'],
      'include_titles': true,
    });
    await _until(
      () async => (await db.getAll(
        'select id from notification_prefs where id = ?',
        [foreign],
      )).isEmpty,
    );
    expect(
      await db.getAll('select id from notification_prefs where id = ?', [mine]),
      hasLength(1),
    );
  });
}
