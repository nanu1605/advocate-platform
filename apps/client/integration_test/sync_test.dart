// End-to-end offline sync against the local stack (`just dev`): real Supabase sign-in, the PowerSync SDK and the
// Docker sync service. Run on a desktop or device:
//   flutter test integration_test/sync_test.dart -d windows --dart-define-from-file=env.local.json
import 'dart:io';

import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/auth.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/courts.dart';
import 'package:advocate_app/data/diary.dart';
import 'package:advocate_app/data/found_cases.dart';
import 'package:advocate_app/data/sync/schema.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:powersync/powersync.dart' hide SyncStatus;

import '../test/helpers.dart';
import 'local_stack.dart';

const _phone = '919999900038'; // local test number (supabase/config.toml)

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('offline writes upload on reconnect; refused ones roll back', (
    _,
  ) async {
    final supabase = await signIn(_phone);
    final me = supabase.auth.currentUser!.id;

    final dir = await Directory.systemTemp.createTemp('pairavi_sync');
    final db = PowerSyncDatabase(schema: schema, path: '${dir.path}/test.db');
    final connector = SupabaseConnector(supabase);
    addTearDown(() async {
      await db.disconnectAndClear();
      await db.close();
      await dropUser(me);
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
    await until(() async => (await db.getUploadQueueStats()).count == 0);
    final server = await supabase
        .from('notification_prefs')
        .select('channels, include_titles')
        .eq('id', mine)
        .single();
    expect(server, {
      'channels': ['push', 'whatsapp'],
      'include_titles': true,
    });
    await until(
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

  // Spec §17 P1 exit: offline notes, tasks and manual hearings sync without loss. The app's own writers, a
  // restart with the queue on disk, then the exact values in Postgres and back on a fresh device.
  testWidgets(
    'offline notes, tasks and manual hearings reach Postgres after a restart and reconnect',
    (_) async {
      final supabase = await signIn('919999900037');
      final me = supabase.auth.currentUser!.id;
      final api = apiAs(supabase);
      addTearDown(() => dropUser(me));
      final org = await api.createOrg(name: 'Offline test', kind: 'solo');
      final m = await api.addManual(
        orgId: org,
        title: 'Offline test case',
        courtId: 'c0000000-0000-0000-0000-000000000005', // seeded DC Indore
      );
      final today = istDay(istOf(DateTime.now()));
      DateTime day(int n) => today.add(Duration(days: n));
      DateTime at(int n) => istInstant(day(n).add(const Duration(hours: 10)));

      final dir = await Directory.systemTemp.createTemp('pairavi_offline');
      final path = '${dir.path}/test.db';
      var db = PowerSyncDatabase(schema: schema, path: path);
      final connector = SupabaseConnector(supabase);
      addTearDown(() async {
        await db.disconnectAndClear();
        await db.close();
      });
      Future<int> queued() async => (await db.getUploadQueueStats()).count;
      ProviderContainer open() => ProviderContainer(
        overrides: [
          syncDatabaseProvider.overrideWithValue(db),
          currentOrgIdProvider.overrideWithValue(org),
          currentUserIdProvider.overrideWithValue(me),
        ],
      );

      await db.connect(connector: connector);
      await db.waitForFirstSync();
      await until(
        () async => (await db.getAll('select id from matters where id = ?', [
          m,
        ])).isNotEmpty,
      );

      // Online: rows to change later.
      var c = open();
      final w = c.read(caseWriterProvider);
      final n0 = await w.addNote(m, 'Before', private: false);
      final n2 = await w.addNote(m, 'Before', private: false);
      final t0 = await w.addTask(title: 'Before', matterId: m);
      final t2 = await w.addTask(title: 'Before', matterId: m);
      final h0 = await w.addHearing(m, date: day(30));
      final h2 = await w.addHearing(m, date: day(30));
      await until(() async => await queued() == 0);

      // Offline: create, edit and delete. Meanwhile another device moves t0's due date on the server.
      await db.disconnect();
      final n1 = await w.addNote(m, 'Offline note', private: false);
      await w.editNote(n1, 'Offline note, edited', private: true);
      await w.editNote(n0, 'Edited offline', private: false);
      await w.deleteNote(n2);
      final t1 = await w.addTask(
        title: 'Offline task',
        matterId: m,
        dueAt: at(32),
        assigneeId: me,
      );
      await w.editTask(
        t1,
        title: 'Offline task, edited',
        dueAt: at(33),
        assigneeId: me,
      );
      await c.read(diaryWriterProvider).completeTask(t0);
      await w.deleteTask(t2);
      final h1 = await w.addHearing(
        m,
        date: day(37),
        courtNo: '3',
        purpose: 'Arguments',
      );
      await w.editHearing(
        h1,
        date: day(38),
        courtNo: '4',
        purpose: 'Final arguments',
      );
      await w.setHearingNote(h1, 'Bring the paper book');
      await w.editHearing(h0, date: day(31), purpose: 'Evidence');
      await w.deleteHearing(h2);
      await supabase
          .from('tasks')
          .update({'due_at': at(40).toIso8601String()})
          .eq('id', t0);
      expect(await queued(), 13);

      // The app is killed and started again: the queue is on disk.
      c.dispose();
      await db.close();
      db = PowerSyncDatabase(schema: schema, path: path);
      await db.initialize();
      expect(await queued(), 13);

      // Back online: the queue drains and the server refuses nothing (a refused write would be dropped).
      final refused = <String>[];
      final log = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message?.startsWith('Sync upload rejected') ?? false) {
          refused.add(message!);
        }
        log(message, wrapWidth: wrapWidth);
      };
      try {
        await db.connect(connector: connector);
        await until(() async => await queued() == 0);
      } finally {
        debugPrint = log;
      }
      expect(refused, isEmpty);

      // Postgres, as the user.
      Future<Map<String, dynamic>> server(
        String table,
        String id,
        String columns,
      ) => supabase.from(table).select(columns).eq('id', id).single();
      expect(
        await server(
          'notes',
          n1,
          'body, visibility, author_id, matter_id, deleted_at',
        ),
        {
          'body': 'Offline note, edited',
          'visibility': 'private',
          'author_id': me,
          'matter_id': m,
          'deleted_at': null,
        },
      );
      expect(await server('notes', n0, 'body'), {'body': 'Edited offline'});
      expect(
        (await server('notes', n2, 'deleted_at'))['deleted_at'],
        isNotNull,
      );
      final task = await server(
        'tasks',
        t1,
        'title, due_at, assignee_id, status, source, created_by',
      );
      expect(DateTime.parse(task.remove('due_at') as String), at(33));
      expect(task, {
        'title': 'Offline task, edited',
        'assignee_id': me,
        'status': 'open',
        'source': 'manual',
        'created_by': me,
      });
      // The device's patch carries only what it changed: the server's newer due date stays.
      final done = await server('tasks', t0, 'status, due_at');
      expect(done['status'], 'done');
      expect(DateTime.parse(done['due_at'] as String), at(40));
      expect(
        (await server('tasks', t2, 'deleted_at'))['deleted_at'],
        isNotNull,
      );
      expect(
        await server(
          'hearings',
          h1,
          'date, court_no, purpose, user_note, source, created_by',
        ),
        {
          'date': isoDate(day(38)),
          'court_no': '4',
          'purpose': 'Final arguments',
          'user_note': 'Bring the paper book',
          'source': 'manual',
          'created_by': me,
        },
      );
      expect(await server('hearings', h0, 'date, purpose'), {
        'date': isoDate(day(31)),
        'purpose': 'Evidence',
      });
      expect(
        (await server('hearings', h2, 'deleted_at'))['deleted_at'],
        isNotNull,
      );

      // A fresh device gets the same rows back, the private note through the author's own stream.
      await db.disconnectAndClear();
      await db.connect(connector: connector);
      await db.waitForFirstSync();
      Future<Map<String, Map<String, Object?>>> local(
        String table,
        String columns,
      ) async => {
        for (final r in await db.getAll(
          'select id, $columns from $table where matter_id = ?',
          [m],
        ))
          r['id'] as String: {...r}..remove('id'),
      };
      expect(await local('notes', 'body, visibility'), {
        n0: {'body': 'Edited offline', 'visibility': 'team'},
        n1: {'body': 'Offline note, edited', 'visibility': 'private'},
      });
      expect(await local('tasks', 'title, status'), {
        t0: {'title': 'Before', 'status': 'done'},
        t1: {'title': 'Offline task, edited', 'status': 'open'},
      });
      expect(await local('hearings', 'date, court_no, purpose, user_note'), {
        h0: {
          'date': isoDate(day(31)),
          'court_no': null,
          'purpose': 'Evidence',
          'user_note': null,
        },
        h1: {
          'date': isoDate(day(38)),
          'court_no': '4',
          'purpose': 'Final arguments',
          'user_note': 'Bring the paper book',
        },
      });
      c = open();
      addTearDown(c.dispose);
      final info = await c.listen(caseProvider(m).future, (_, _) {}).read();
      expect(info?.nextDate, day(31));
    },
  );

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
