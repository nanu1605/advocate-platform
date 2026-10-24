// End-to-end offline sync against the local stack (`just dev`): real Supabase sign-in, the PowerSync SDK and the
// Docker sync service. Run on a desktop or device:
//   flutter test integration_test/sync_test.dart -d windows --dart-define-from-file=env.local.json
import 'dart:io';

import 'package:advocate_app/core/config.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/auth.dart';
import 'package:advocate_app/data/courts.dart';
import 'package:advocate_app/data/found_cases.dart';
import 'package:advocate_app/data/sync/schema.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:powersync/powersync.dart' hide SyncStatus;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../test/helpers.dart';

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

  // No server needed: the device's own SQL against PowerSync's views.
  testWidgets(
    'found_selection survives a restart; local reads match the schema',
    (_) async {
      final dir = await Directory.systemTemp.createTemp('pairavi_local');
      Future<PowerSyncDatabase> open() async {
        final db = PowerSyncDatabase(
          schema: schema,
          path: '${dir.path}/local.db',
        );
        await db.initialize();
        return db;
      }

      var db = await open();
      var store = FoundSelectionStore(db);
      await store.set('o1', {'a': true, 'b': false});
      await store.set('o1', {'b': true, 'c': false});
      await store.set('o2', {'x': true});
      await db.close();

      // The app was killed: the ticks are still there, per organisation, and never queued for upload.
      db = await open();
      addTearDown(db.close);
      store = FoundSelectionStore(db);
      expect(await store.watch('o1').first, {'a': true, 'b': true, 'c': false});
      await store.remove('o1', ['a']);
      expect(await store.watch('o1').first, {'b': true, 'c': false});
      expect(await store.watch('o2').first, {'x': true});
      expect((await db.getUploadQueueStats()).count, 0);

      // Synced rows, written locally here (never connected, so nothing uploads).
      Future<void> insert(String table, Map<String, Object?> row) => db.execute(
        'insert into $table (${row.keys.join(', ')}) '
        'values (${List.filled(row.length, '?').join(', ')})',
        row.values.toList(),
      );
      await insert('app_config', {
        'id': 'k1',
        'key': 'beta_tracked_case_allowance',
        'value': '100',
      });
      for (final (id, org, tracking, deleted) in [
        ('m1', 'o1', 'auto', null),
        ('m2', 'o1', 'manual', null),
        ('m3', 'o1', 'auto', '2026-10-01T00:00:00Z'),
        ('m4', 'o2', 'auto', null),
      ]) {
        await insert('matters', {
          'id': id,
          'org_id': org,
          'tracking': tracking,
          'deleted_at': deleted,
        });
      }
      for (final (id, level, name) in [
        ('sc', 'SC', 'Supreme Court'),
        ('dc', 'DC', 'District Court Indore'),
        ('hc', 'HC', 'MPHC Indore'),
      ]) {
        await insert('courts', {
          'id': id,
          'level': level,
          'name': name,
          'short_name': name,
        });
      }
      await insert('found_cases', {
        'id': 'f1',
        'org_id': 'o1',
        'cnr': 'MPHC010000000001',
        'court_id': 'hc',
        'case_type': 'WP',
        'case_number': '1001',
        'case_year': 2024,
        'case_status': 'pending',
        'confidence': 'low',
        'decision': 'pending',
        'next_date': '2026-11-05',
      });
      // A previous account's row still on the device is never taken for the signed-in user (FakeAuth: user-1).
      await insert('profiles', {'id': 'u0', 'full_name': 'Someone Else'});
      await insert('profiles', {
        'id': 'user-1',
        'full_name': 'Ramesh Sharma',
        'enrolment_no': 'MP/1/2010',
        'bar_council_state': 'MP',
        'practice_court_ids': '["hc"]',
      });
      await insert('organizations', {
        'id': 'o1',
        'name': 'Sharma',
        'kind': 'solo',
      });
      await insert('memberships', {
        'id': 'ms1',
        'org_id': 'o1',
        'user_id': 'user-1',
        'role': 'owner',
        'status': 'active',
        'created_at': '2026-10-01T00:00:00Z',
      });

      final c = ProviderContainer(
        overrides: [
          syncDatabaseProvider.overrideWithValue(db),
          authRepositoryProvider.overrideWithValue(FakeAuth(signedIn: true)),
          apiClientProvider.overrideWithValue(FakeApi()..offline = true),
        ],
      );
      addTearDown(c.dispose);

      // Riverpod pauses providers nobody listens to, so listen while reading.
      Future<T> first<T>(ProviderListenable<Future<T>> p) =>
          c.listen(p, (_, _) {}).read();

      // Offline, the account comes from the synced profile and memberships.
      final account = await first(accountProvider.future);
      expect(account?.fullName, 'Ramesh Sharma');
      expect(account?.stage, AccountStage.owner);
      expect(account?.practiceCourtIds, ['hc']);
      expect(c.read(currentOrgIdProvider), 'o1');

      expect(await first(remainingAllowanceProvider.future), 99);
      expect((await first(courtsProvider.future)).map((c) => c.level), [
        'HC',
        'DC',
        'SC',
      ]);
      final found = (await first(foundCasesProvider.future)).single;
      expect(found.nextDate, DateTime(2026, 11, 5));
      expect(found.tickedByDefault, isFalse);
    },
  );
}
