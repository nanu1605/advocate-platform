import 'dart:convert';

import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/auth.dart';
import 'package:advocate_app/data/notifications.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:powersync/powersync.dart' hide SyncStatus;

import '../helpers.dart';
import 'sync_db.dart';

/// A notification row of user-1 in org-1 (unread), plus [fields].
Map<String, Object?> _row(
  String id,
  String created, [
  Map<String, Object?> fields = const {},
]) => {
  'id': id,
  'org_id': 'org-1',
  'user_id': 'user-1',
  'kind': 'new_order',
  'title': 'New order',
  'body': 'New order in WP 1/2024.',
  'data': jsonEncode({'link': '/cases/m1', 'collapse_key': 'new_order:$id'}),
  'created_at': created,
  ...fields,
};

/// The notification centre's SQL, the writer and the sign-out count against a real on-device database (§9.3, §13).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PowerSyncDatabase db;

  setUp(() async => db = await openTestDb());

  group('centre', () {
    setUp(() async {
      final nextDate = jsonEncode({
        'link': '/cases/m1',
        'collapse_key': 'next_date_set:m1',
      });
      await insertRows(db, 'notifications', [
        _row('a', '2026-11-05 04:00:00Z'),
        _row('b', '2026-11-05 04:20:00Z', {
          'kind': 'next_date_set',
          'data': nextDate,
        }),
        _row('c', '2026-11-05 04:10:00Z', {
          'kind': 'next_date_set',
          'data': nextDate,
          'read_at': '2026-11-05 04:15:00Z',
        }),
        _row('d', '2026-11-04 10:00:00Z', {
          'org_id': null,
          'kind': 'sync_issue',
          'data': '{}',
        }),
        _row('e', '2026-11-05 04:30:00Z', {'org_id': 'org-2'}),
        _row('f', '2026-11-05 04:30:00Z', {'user_id': 'user-2'}),
      ]);
      await clearPendingWrites(db);
    });

    test(
      "the user's rows in the current org and org-less ones, newest first",
      () async {
        final c = dbContainer(db);
        final rows = await firstValue(c, notificationRowsProvider);
        expect(rows.map((n) => n.id), ['b', 'c', 'a', 'd']);
        expect(rows.first.link, '/cases/m1');
        expect(rows.first.collapseKey, 'next_date_set:m1');
        expect(rows[1].readAt, DateTime.utc(2026, 11, 5, 4, 15));
        expect(rows.last.collapseKey, 'd');
      },
    );

    test('collapsed, with the unread badge counting groups', () async {
      final c = dbContainer(db);
      await firstValue(c, notificationRowsProvider);
      final sub = c.listen(notificationCentreProvider, (_, _) {});
      addTearDown(sub.close);
      final items = c.read(notificationCentreProvider).value!;
      expect(items.map((n) => n.id), ['b', 'a', 'd']);
      expect(items.first.earlier.single.id, 'c');
      expect(c.read(unreadNotificationCountProvider), 3);
    });

    test(
      "mark read and mark all read write read_at only, on the user's rows",
      () async {
        final c = dbContainer(db);
        final writer = c.read(notificationWriterProvider);
        await writer.markRead(['b', 'c']);
        expect(await pendingWrites(db), [
          [
            UpdateType.patch,
            'notifications',
            'b',
            {'read_at': testNow.toIso8601String()},
          ],
        ]);
        await writer.markAllRead();
        final unread = await db.getAll(
          'select id from notifications where read_at is null order by id',
        );
        // Another org's and another user's rows stay as they were.
        expect(unread.map((r) => r['id']), ['e', 'f']);
        final writes = await pendingWrites(db);
        expect(writes.map((w) => w[2]), ['b', 'a', 'd']);
        expect(
          writes.every((w) => (w[3]! as Map).keys.single == 'read_at'),
          isTrue,
        );
      },
    );
  });

  group('preferences', () {
    test('a kind turned off creates its row with the deterministic id, then updates it', () async {
      final c = dbContainer(db);
      final writer = c.read(notificationWriterProvider);
      final id = prefsRowId('user-1', 'new_order');
      await writer.setKindEnabled('new_order', enabled: false);
      final [op, table, rowId, data] = await lastWrite(db);
      expect((op, table, rowId), (UpdateType.put, 'notification_prefs', id));
      expect(data, {
        'user_id': 'user-1',
        'kind': 'new_order',
        'channels': '[]',
        'quiet_start': '22:00:00',
        'quiet_end': '07:00:00',
        'include_titles': 0,
        'updated_at': testNow.toIso8601String(),
      });
      await writer.setKindEnabled('new_order', enabled: true);
      expect(await lastWrite(db), [
        UpdateType.patch,
        'notification_prefs',
        id,
        // updated_at is unchanged at the test's fixed clock.
        {'channels': '["push"]'},
      ]);
      expect(
        await db.getAll('select id from notification_prefs'),
        hasLength(1),
      );
    });

    test("quiet hours and titles go on every kind's row, keeping each kind on or off", () async {
      final c = dbContainer(db);
      final writer = c.read(notificationWriterProvider);
      await writer.setKindEnabled('sync_issue', enabled: false);
      await writer.setQuietHours(
        const Duration(hours: 23),
        const Duration(hours: 6, minutes: 30),
      );
      await writer.setIncludeTitles(include: true);
      final rows = await db.getAll(
        'select id, kind, channels, quiet_start, quiet_end, include_titles '
        'from notification_prefs order by kind',
      );
      expect(rows.map((r) => r['kind']), [...notificationKinds]..sort());
      for (final r in rows) {
        expect(r['id'], prefsRowId('user-1', r['kind'] as String));
        expect(r['channels'], r['kind'] == 'sync_issue' ? '[]' : '["push"]');
        expect(
          (r['quiet_start'], r['quiet_end'], r['include_titles']),
          ('23:00:00', '06:30:00', 1),
        );
      }
      final prefs = await firstValue(c, notificationPrefsProvider);
      expect(prefs.off, {'sync_issue'});
      expect(prefs.includeTitles, isTrue);
      expect(prefs.quietStart, const Duration(hours: 23));
      expect(prefs.quietEnd, const Duration(hours: 6, minutes: 30));
    });

    test('a synced row under another id is updated, not doubled', () async {
      await insertRows(db, 'notification_prefs', [
        {
          'id': 'server-row',
          'user_id': 'user-1',
          'kind': 'new_order',
          'channels': '["push"]',
        },
      ]);
      await clearPendingWrites(db);
      final writer = dbContainer(db).read(notificationWriterProvider);
      await writer.setKindEnabled('new_order', enabled: false);
      expect((await lastWrite(db)).take(3), [
        UpdateType.patch,
        'notification_prefs',
        'server-row',
      ]);
      expect(
        await db.getAll(
          "select id from notification_prefs where kind = 'new_order'",
        ),
        hasLength(1),
      );
    });

    test('no rows: defaults, every kind on', () async {
      final prefs = await firstValue(
        dbContainer(db),
        notificationPrefsProvider,
      );
      expect(prefs.off, isEmpty);
      expect(prefs.includeTitles, isFalse);
      expect(
        (prefs.quietStart, prefs.quietEnd),
        (defaultQuietStart, defaultQuietEnd),
      );
    });
  });

  test(
    'sign-out counts writes waiting to upload and queued documents',
    () async {
      final c = dbContainer(db);
      final count = c.read(pendingChangesProvider);
      expect(await count(), (changes: 0, uploads: 0));
      await insertRows(db, 'tasks', [
        {
          'id': 't1',
          'org_id': 'org-1',
          'title': 'File reply',
          'status': 'open',
        },
      ]);
      await db.execute("update tasks set status = 'done' where id = 't1'");
      await insertRows(db, 'upload_queue', [
        {
          'id': 'q1',
          'org_id': 'org-1',
          'title': 'Vakalatnama',
          'state': 'queued',
        },
        {'id': 'q2', 'org_id': 'org-1', 'title': 'Reply', 'state': 'failed'},
      ]);
      expect(await count(), (changes: 2, uploads: 2));
      await clearPendingWrites(db);
      expect(await count(), (changes: 0, uploads: 2));
    },
  );

  test('when sync takes a membership away (the current team, or the last), the account reloads', () async {
    await insertRows(db, 'memberships', [
      {
        'id': 'ms-1',
        'org_id': 'org-1',
        'user_id': 'user-1',
        'role': 'junior',
        'status': 'active',
      },
      {
        'id': 'ms-2',
        'org_id': 'org-2',
        'user_id': 'user-1',
        'role': 'junior',
        'status': 'active',
      },
    ]);
    final api = FakeApi(
      account: Account(id: 'user-1', memberships: juniorAccount.memberships),
    );
    final c = ProviderContainer(
      overrides: [
        syncDatabaseProvider.overrideWithValue(db),
        authRepositoryProvider.overrideWithValue(FakeAuth(signedIn: true)),
        apiClientProvider.overrideWithValue(api),
      ],
    );
    addTearDown(c.dispose);
    final sub = c.listen(accountProvider, (_, _) {});
    addTearDown(sub.close);
    expect((await c.read(accountProvider.future))!.org, isNotNull);
    int loads() => api.callNames.where((n) => n == 'me').length;
    Future<void> reloads(int n) async {
      for (var i = 0; i < 50 && loads() < n; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(loads(), n);
    }

    // The membership count has been read once (2) before sync takes a row away.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(loads(), 1);
    // Removed from the current team while still in another: the account moves on.
    await db.execute(
      "update memberships set status = 'removed' where id = 'ms-1'",
    );
    await reloads(2);
    // Then from the last one.
    api.account = const Account(id: 'user-1');
    await db.execute("delete from memberships where id = 'ms-2'");
    await reloads(3);
    expect((await c.read(accountProvider.future))!.org, isNull);
  });
}
