import 'package:advocate_app/data/diary.dart';
import 'package:advocate_app/data/notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:powersync/powersync.dart' hide SyncStatus;

import '../helpers.dart';
import 'sync_db.dart';

const _hc = 'c-hc';
const _dc = 'c-dc';

/// A live auto-tracked case of org-1 at MPHC Indore ("m3" is WP 3/2024), plus [fields].
Map<String, Object?> _matter(
  String id, [
  Map<String, Object?> fields = const {},
]) => {
  'id': id,
  'org_id': 'org-1',
  'case_type': 'WP',
  'case_number': id.substring(1),
  'case_year': 2024,
  'title': 'Sharma v. State of MP',
  'court_id': _hc,
  'status': 'active',
  'tracking': 'auto',
  ...fields,
};

/// The SQL behind Today and the board, against a real on-device database (spec §4.2, §11.6).
void main() {
  // IST now listens for the app resuming.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('diary for a date', () {
    late PowerSyncDatabase db;

    setUp(() async {
      db = await openTestDb();
      await insertRows(db, 'organizations', [
        {'id': 'org-1', 'owner_id': 'user-1', 'name': 'Sharma'},
        {'id': 'org-2', 'owner_id': 'user-9', 'name': 'Other'},
      ]);
      await insertRows(db, 'courts', [
        {
          'id': _hc,
          'level': 'HC',
          'name': 'High Court of Madhya Pradesh, Bench at Indore',
          'short_name': 'MPHC Indore',
          'short_name_hi': 'MPHC इंदौर',
        },
        {
          'id': _dc,
          'level': 'DC',
          'name': 'District and Sessions Court, Indore',
          'short_name': 'District Court Indore',
          'short_name_hi': 'जिला कोर्ट इंदौर',
        },
      ]);
      await insertRows(db, 'memberships', [
        for (final (id, user, role, name, status) in [
          ('ms-1', 'user-1', 'owner', 'Ramesh Sharma', 'active'),
          ('ms-2', 'user-2', 'junior', 'Rakesh Jain', 'active'),
          ('ms-3', 'user-3', 'advocate', 'Neha Verma', 'active'),
          ('ms-4', 'user-5', 'clerk', 'Left Already', 'removed'),
        ])
          {
            'id': id,
            'org_id': 'org-1',
            'user_id': user,
            'role': role,
            'display_name': name,
            'status': status,
          },
      ]);
      await insertRows(db, 'matters', [
        _matter('m1', {'next_hearing_date': testToday, 'judge': 'Justice X'}),
        _matter('m2', {'next_hearing_date': testToday, 'court_id': _dc}),
        _matter('m3', {'next_hearing_date': testToday, 'stage': 'Arguments'}),
        _matter('m4', {
          'tracking': 'manual',
          'judge': 'Justice M',
          'assigned_to': 'user-2',
        }),
        _matter('m5', {'next_hearing_date': testTomorrow}),
        _matter('m6', {
          'next_hearing_date': testToday,
          'deleted_at': '2026-11-01T00:00:00Z',
        }),
        _matter('m7', {'next_hearing_date': testToday, 'status': 'archived'}),
        _matter('m8', {'next_hearing_date': testToday, 'org_id': 'org-2'}),
        _matter('m9', {'tracking': 'manual'}),
        _matter('m10', {'next_hearing_date': testTomorrow}),
      ]);
      Map<String, Object?> board(
        String id,
        String matter,
        String court,
        String no,
        String item,
        String slot, [
        String? assignee,
      ]) => {
        'id': id,
        'org_id': 'org-1',
        'board_date': testToday,
        'matter_id': matter,
        'court_id': court,
        'court_no': no,
        'item_no': item,
        'expected_slot': slot,
        'assignee_id': assignee,
        'proxy_arranged': 0,
        'is_current': 1,
      };
      await insertRows(db, 'board_entries', [
        board('b1', 'm1', _hc, '12', '23', '11:58:00'),
        board('b2', 'm2', _dc, '5', '1', '11:00:00'),
        // Listed earlier than its next date (tomorrow).
        board('b10', 'm10', _hc, '12', '30', '12:26:00', 'user-3'),
      ]);
      await insertRows(db, 'org_cause_list_entries', [
        {
          'id': 'o1',
          'org_id': 'org-1',
          'matter_id': 'm1',
          'list_date': testToday,
          'court_id': _hc,
          'court_no': '12',
          'item_no': '99',
          'bench': 'Justice A. B.',
          'is_current': 1,
        },
        {
          'id': 'o3',
          'org_id': 'org-1',
          'matter_id': 'm3',
          'list_date': testToday,
          'court_id': _hc,
          'court_no': '7',
          'item_no': '41',
          'bench': 'Justice C',
          'is_current': 1,
        },
      ]);
      await insertRows(db, 'hearings', [
        {
          'id': 'h1',
          'org_id': 'org-1',
          'matter_id': 'm1',
          'date': testToday,
          'purpose': 'Admission',
        },
        {
          'id': 'h4',
          'org_id': 'org-1',
          'matter_id': 'm4',
          'date': testToday,
          'court_no': '3',
          'item_no': '8',
          'user_purpose': 'Final hearing',
        },
        {
          'id': 'h9',
          'org_id': 'org-1',
          'matter_id': 'm9',
          'date': testToday,
          'deleted_at': '2026-11-02T00:00:00Z',
        },
        {
          'id': 'h9b',
          'org_id': 'org-1',
          'matter_id': 'm9',
          'date': '2026-11-04',
        },
      ]);
      await insertRows(db, 'clients', [
        {'id': 'cl1', 'org_id': 'org-1', 'name': 'Suresh Patel'},
      ]);
      await insertRows(db, 'matter_clients', [
        {'id': 'mc1', 'org_id': 'org-1', 'matter_id': 'm1', 'client_id': 'cl1'},
      ]);
    });

    test('which matters, in diary order, with clashes', () async {
      final c = dbContainer(db);
      final day = await firstValue(c, diaryProvider(testToday));
      expect(day.map((e) => e.matterId), ['m2', 'm4', 'm3', 'm1', 'm10']);
      final byId = {for (final e in day) e.matterId: e};

      final m1 = byId['m1']!;
      expect(m1.caseLabel, 'WP 1/2024');
      expect(m1.court?.shortName, 'MPHC Indore');
      expect(
        (m1.courtNo, m1.itemNo, m1.slot),
        ('12', '23', const Duration(hours: 11, minutes: 58)),
      );
      expect(
        (m1.bench, m1.purpose, m1.client),
        ('Justice A. B.', 'Admission', 'Suresh Patel'),
      );
      expect(m1.boardEntryId, 'b1');

      final m3 = byId['m3']!; // cause list, no board yet
      expect(
        (m3.courtNo, m3.itemNo, m3.bench, m3.purpose),
        ('7', '41', 'Justice C', 'Arguments'),
      );
      expect((m3.boardEntryId, m3.slot), (null, null));

      final m4 = byId['m4']!; // manual, from its hearing
      expect(
        (m4.courtNo, m4.itemNo, m4.bench, m4.purpose),
        ('3', '8', 'Justice M', 'Final hearing'),
      );
      expect((m4.assigneeId, m4.assigneeName), ('user-2', 'Rakesh Jain'));
      expect(byId['m10']!.assigneeName, 'Neha Verma');

      expect([for (final e in day) e.clash], [true, false, false, true, false]);
      expect(m1.clashWith, ['m2']);

      final tomorrow = await firstValue(c, diaryProvider(testTomorrow));
      expect(tomorrow.map((e) => e.matterId), ['m10', 'm5']);
      expect(tomorrow.boardBuilt, isFalse);
    });

    test('Assign to and proxy write locally and re-apply the clash', () async {
      final c = dbContainer(db);
      final writer = c.read(diaryWriterProvider);
      await firstValue(
        c,
        diaryProvider(testToday),
        (d) => d.any((e) => e.clash),
      );

      await writer.setProxy('b2', arranged: true);
      await firstValue(
        c,
        diaryProvider(testToday),
        (d) => d.every((e) => !e.clash),
      );
      expect(await lastWrite(db), [
        UpdateType.patch,
        'board_entries',
        'b2',
        {'proxy_arranged': 1},
      ]);

      await writer.assign('b10', 'user-1');
      final day = await firstValue(
        c,
        diaryProvider(testToday),
        (d) => d.any((e) => e.assigneeId == 'user-1'),
      );
      expect(day.last.assigneeName, 'Ramesh Sharma');
      expect(await lastWrite(db), [
        UpdateType.patch,
        'board_entries',
        'b10',
        {'assignee_id': 'user-1'},
      ]);

      await writer.setProxy('b2', arranged: false);
      await firstValue(c, diaryProvider(testToday), (d) => d.first.clash);
    });

    test('members, any cases', () async {
      final c = dbContainer(db);
      expect(
        (await firstValue(c, orgMembersProvider)).map((m) => (m.name, m.role)),
        [
          ('Neha Verma', 'advocate'),
          ('Rakesh Jain', 'junior'),
          ('Ramesh Sharma', 'owner'),
        ],
      );
      expect(await firstValue(c, hasMattersProvider), isTrue);
      expect(
        await firstValue(dbContainer(db, org: 'org-3'), hasMattersProvider),
        isFalse,
      );
    });
  });

  test('tasks due: mine or unassigned, open, by end of today', () async {
    final db = await openTestDb();
    await insertRows(db, 'matters', [_matter('m1')]);
    await insertRows(db, 'tasks', [
      for (final (id, due, assignee, status) in [
        ('t1', '2026-11-04T06:00:00Z', 'user-1', 'open'), // overdue
        ('t2', '2026-11-05 17:00:00+00', null, 'open'), // 22:30 IST today
        ('t3', '2026-11-05T19:00:00Z', 'user-1', 'open'), // tomorrow IST
        ('t4', '2026-11-05T06:00:00Z', 'user-2', 'open'), // someone else's
        ('t5', '2026-11-05T06:00:00Z', 'user-1', 'done'),
        ('t6', null, 'user-1', 'open'),
      ])
        {
          'id': id,
          'org_id': 'org-1',
          'matter_id': 'm1',
          'title': 'File reply',
          'due_at': due,
          'assignee_id': assignee,
          'status': status,
        },
    ]);
    final c = dbContainer(db);
    final due = await firstValue(c, tasksDueProvider);
    expect(due.map((t) => (t.id, t.overdue)), [('t1', true), ('t2', false)]);
    expect(due.first.caseLabel, 'WP 1/2024');

    await c.read(diaryWriterProvider).completeTask('t2');
    await firstValue(c, tasksDueProvider, (d) => d.length == 1);
    expect(await lastWrite(db), [
      UpdateType.patch,
      'tasks',
      't2',
      {'status': 'done'},
    ]);
    await c.read(diaryWriterProvider).reopenTask('t2');
    await firstValue(c, tasksDueProvider, (d) => d.length == 2);
  });

  test('new orders: my unread new_order notifications in this org', () async {
    final db = await openTestDb();
    await insertRows(db, 'matters', [_matter('m1')]);
    Map<String, Object?> notice(
      String id, {
      String kind = 'new_order',
      String user = 'user-1',
      String org = 'org-1',
      String? readAt,
    }) => {
      'id': id,
      'org_id': org,
      'user_id': user,
      'kind': kind,
      'data': '{"matter_id": "m1", "link": "/cases/m1"}',
      'read_at': readAt,
      'created_at': '2026-11-05T02:00:00Z',
    };
    await insertRows(db, 'notifications', [
      notice('n1'),
      notice('n2', readAt: '2026-11-05T03:00:00Z'),
      notice('n3', user: 'user-2'),
      notice('n4', kind: 'sync_issue'),
      notice('n5', org: 'org-2'),
    ]);
    final c = dbContainer(db);
    final orders = await firstValue(c, newOrdersProvider);
    expect(orders.map((n) => (n.id, n.matterId, n.link, n.caseLabel)), [
      ('n1', 'm1', '/cases/m1', 'WP 1/2024'),
    ]);

    // Today marks a notice read through the notification writer (the one writer for read_at).
    await c.read(notificationWriterProvider).markRead(['n1']);
    await firstValue(c, newOrdersProvider, (o) => o.isEmpty);
    final write = await lastWrite(db);
    expect(write.take(3), [UpdateType.patch, 'notifications', 'n1']);
    expect((write.last! as Map).keys, ['read_at']);
  });

  test('needs attention from the synced rows', () async {
    final db = await openTestDb();
    await insertRows(db, 'matters', [
      _matter('a1', {
        'court_fetched_at': '2026-11-01T10:00:00Z',
        'court_status': 'pending',
      }),
      _matter('a2', {'created_at': '2026-11-05T03:00:00Z'}),
      _matter('a3', {'tracking': 'manual'}),
      _matter('a4', {
        'court_fetched_at': '2026-11-01T10:00:00Z',
        'court_status': 'pending',
        'next_hearing_date': '2026-11-12',
      }),
      _matter('a5', {'tracking': 'manual'}),
      _matter('a6', {'tracking': 'off'}),
    ]);
    await insertRows(db, 'hearings', [
      for (final (id, matter, date, noted, deleted) in [
        ('h1', 'a3', '2026-11-01', null, null),
        ('h2', 'a3', '2026-11-10', null, '2026-11-02T00:00:00Z'),
        ('h3', 'a4', '2026-10-01', '2026-11-14', null),
        ('h4', 'a4', '2026-09-01', '2026-11-12', null),
        ('h5', 'a5', '2026-11-20', null, null),
      ])
        {
          'id': id,
          'org_id': 'org-1',
          'matter_id': matter,
          'date': date,
          'user_next_date': noted,
          'deleted_at': deleted,
        },
    ]);
    await insertRows(db, 'notifications', [
      {
        'id': 'n1',
        'org_id': 'org-1',
        'user_id': 'user-1',
        'kind': 'sync_issue',
        'data': '{"link": "/today"}',
        'created_at': '2026-11-05T01:00:00Z',
      },
    ]);
    final c = dbContainer(db);
    final items = await firstValue(c, needsAttentionProvider);
    expect(items.map((i) => (i.kind, i.matterId ?? i.notificationId)), [
      (AttentionKind.noNextDate, 'a1'),
      (AttentionKind.courtDataPending, 'a2'),
      (AttentionKind.courtDataDelayed, 'n1'),
      (AttentionKind.addNextDate, 'a3'),
      (AttentionKind.dateMismatch, 'a4'),
    ]);
    expect(items.last.userDate, DateTime.utc(2026, 11, 14));
  });

  test('evening switch from app_config', () async {
    final db = await openTestDb();
    final c = dbContainer(db);
    expect(await firstValue(c, eveningSwitchProvider), defaultEveningSwitch);
    await insertRows(db, 'app_config', [
      {'id': 'cfg', 'key': 'today_evening_switch', 'value': '"19:00"'},
    ]);
    expect(
      await firstValue(
        c,
        eveningSwitchProvider,
        (d) => d != defaultEveningSwitch,
      ),
      const Duration(hours: 19),
    );
  });
}
