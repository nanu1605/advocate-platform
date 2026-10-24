import 'package:advocate_app/data/cases.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:powersync/powersync.dart' hide SyncStatus;

import '../helpers.dart';
import 'sync_db.dart';

const _hc = 'c-hc';

/// A live case of org-1 ("m3" is WP 3/2024 at MPHC Indore, auto-tracked), plus [fields].
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
  'source': 'cnr',
  ...fields,
};

Map<String, Object?> _row(String id, Map<String, Object?> fields) => {
  'id': id,
  'org_id': 'org-1',
  ...fields,
};

/// The SQL behind the Cases list and the case page, against a real on-device database (spec §4.3, §9.3).
void main() {
  // IST now listens for the app resuming.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('reads', () {
    late PowerSyncDatabase db;

    setUp(() async {
      db = await openTestDb();
      await insertRows(db, 'courts', [
        {
          'id': _hc,
          'level': 'HC',
          'name': 'High Court of Madhya Pradesh, Bench at Indore',
          'short_name': 'MPHC Indore',
          'short_name_hi': 'MPHC इंदौर',
        },
      ]);
      await insertRows(db, 'memberships', [
        for (final (id, user, role, name, status) in [
          ('ms-1', 'user-1', 'owner', 'Ramesh Sharma', 'active'),
          ('ms-2', 'user-2', 'junior', 'Rakesh Jain', 'active'),
          ('ms-3', 'user-3', 'advocate', 'Neha Verma', 'active'),
          ('ms-5', 'user-5', 'clerk', 'Left Already', 'removed'),
        ])
          _row(id, {
            'user_id': user,
            'role': role,
            'display_name': name,
            'status': status,
          }),
      ]);
      await insertRows(db, 'matters', [
        _matter('m1', {
          'cnr': 'MPHC010000012024',
          'next_hearing_date': testToday,
          'court_status': 'pending',
          'court_fetched_at': '2026-11-04T14:12:00Z',
          'judge': 'Justice A. B.',
          'stage': 'Admission',
          'court_no': '12',
          'assigned_to': 'user-2',
          'updated_at': '2026-11-04T14:12:00Z',
        }),
        _matter('m2', {
          'tracking': 'manual',
          'source': 'manual',
          'case_type': null,
          'case_number': null,
          'case_year': null,
          'title': 'Demo v. State',
          'court_id': null,
          'court_name': 'Family Court, Dewas',
          'next_hearing_date':
              '2026-11-06', // ignored: manual cases use their hearings
          'assigned_to': 'user-5', // left the team: no name
        }),
        _matter('m3', {'status': 'archived', 'court_status': 'disposed'}),
        _matter('m4', {'deleted_at': '2026-11-01T00:00:00Z'}),
        _matter('m5', {'org_id': 'org-2'}),
        _matter('m6', {'tracking': 'off', 'next_hearing_date': '2026-10-02'}),
      ]);
      await insertRows(db, 'hearings', [
        for (final (id, matter, date, deleted) in [
          ('h2a', 'm2', '2026-11-01', null),
          ('h2b', 'm2', '2026-11-06', '2026-11-02T00:00:00Z'),
          ('h2c', 'm2', '2026-11-10', null),
          ('h2d', 'm2', '2026-11-08', null),
        ])
          _row(id, {
            'matter_id': matter,
            'date': date,
            'source': 'manual',
            'deleted_at': deleted,
          }),
        _row('h1a', {
          'matter_id': 'm1',
          'date': '2026-10-20',
          'source': 'court',
          'court_no': '12',
          'item_no': '23',
          'purpose': 'Admission',
          'outcome': 'Adjourned',
          'next_date': testToday,
          'user_purpose': 'Final hearing',
          'user_note': 'Bring the paper book',
          'created_at': '2026-10-20T10:00:00Z',
        }),
      ]);
      await insertRows(db, 'orders', [
        _row('o1', {
          'matter_id': 'm1',
          'order_date': '2026-10-20',
          'title': 'Order',
          'court_order_id': 'co-1',
        }),
        _row('o2', {'matter_id': 'm1', 'order_date': '2026-10-01'}),
        _row('o3', {
          'matter_id': 'm1',
          'order_date': '2026-10-25',
          'deleted_at': '2026-10-26T00:00:00Z',
        }),
      ]);
      await insertRows(db, 'order_reads', [
        _row('r1', {'user_id': 'user-1', 'order_id': 'o2'}),
        _row('r2', {'user_id': 'user-3', 'order_id': 'o1'}),
      ]);
      await insertRows(db, 'documents', [
        _row('d1', {
          'matter_id': 'm1',
          'title': 'Petition',
          'kind': 'pleading',
          'size_bytes': 120000,
          'upload_status': 'ready',
        }),
        _row('d2', {
          'matter_id': 'm1',
          'title': 'Old',
          'deleted_at': '2026-11-01T00:00:00Z',
        }),
        _row('d3', {'matter_id': 'm6', 'title': 'Elsewhere'}),
      ]);
      await insertRows(db, 'notes', [
        for (final (id, author, visibility, at, deleted) in [
          ('n1', 'user-3', 'team', '2026-11-01T00:00:00Z', null),
          ('n2', 'user-1', 'private', '2026-11-02T00:00:00Z', null),
          ('n3', 'user-3', 'private', '2026-11-03T00:00:00Z', null),
          ('n4', 'user-1', 'team', '2026-11-04T00:00:00Z', '2026-11-04T01:00Z'),
        ])
          _row(id, {
            'matter_id': 'm1',
            'author_id': author,
            'body': 'Note $id',
            'visibility': visibility,
            'created_at': at,
            'deleted_at': deleted,
          }),
      ]);
      await insertRows(db, 'tasks', [
        for (final (id, due, status, deleted) in [
          ('t1', '2026-11-09T06:00:00Z', 'open', null),
          ('t2', '2026-11-06T06:00:00Z', 'open', null),
          ('t3', '2026-11-01T06:00:00Z', 'done', null),
          ('t4', null, 'open', null),
          ('t5', '2026-11-06T06:00:00Z', 'proposed', null),
          ('t6', '2026-11-06T06:00:00Z', 'open', '2026-11-02T00:00:00Z'),
        ])
          _row(id, {
            'matter_id': 'm1',
            'title': 'Task $id',
            'due_at': due,
            'status': status,
            'assignee_id': id == 't2' ? 'user-3' : null,
            'deleted_at': deleted,
          }),
      ]);
      await insertRows(db, 'deadlines', [
        for (final (id, due, status) in [
          ('dl1', '2026-11-12', 'active'),
          ('dl2', '2026-11-08', 'done'),
          ('dl3', '2026-11-09', 'active'),
          ('dl4', '2026-11-07', 'dismissed'),
        ])
          _row(id, {
            'matter_id': 'm1',
            'kind': 'filing',
            'due_date': due,
            'status': status,
          }),
      ]);
      await insertRows(db, 'clients', [
        _row('cl1', {
          'name': 'Suresh Patel',
          'search_key': 'sures ptl',
          'phone': '9876543210',
          'language': 'hi',
        }),
        _row('cl2', {'name': 'नेहा वर्मा'}),
        _row('cl3', {'name': 'Gone', 'deleted_at': '2026-11-01T00:00:00Z'}),
      ]);
      await insertRows(db, 'matter_clients', [
        for (final (id, client, at) in [
          ('mc1', 'cl1', '2026-10-01T00:00:00Z'),
          ('mc2', 'cl2', '2026-10-02T00:00:00Z'),
          ('mc3', 'cl3', '2026-10-03T00:00:00Z'),
        ])
          _row(id, {'matter_id': 'm1', 'client_id': client, 'created_at': at}),
      ]);
      await insertRows(db, 'found_cases', [
        for (final (id, org, decision) in [
          ('f1', 'org-1', 'pending'),
          ('f2', 'org-1', 'skipped'),
          ('f3', 'org-2', 'pending'),
          ('f4', 'org-1', 'pending'),
        ])
          {
            'id': id,
            'org_id': org,
            'cnr': 'MPHC0100000$id',
            'decision': decision,
          },
      ]);
    });

    test(
      "the org's live cases with next dates, courts, assignees and clients",
      () async {
        final c = dbContainer(db);
        final cases = {
          for (final x in await firstValue(c, casesProvider)) x.id: x,
        };
        expect(cases.keys.toSet(), {'m1', 'm2', 'm3', 'm6'});

        final m1 = cases['m1']!;
        expect(m1.caseLabel, 'WP 1/2024');
        expect(m1.court?.shortNameHi, 'MPHC इंदौर');
        expect(m1.nextDate, DateTime.utc(2026, 11, 5));
        expect(m1.courtFetchedAt, DateTime.utc(2026, 11, 4, 14, 12));
        expect(
          (m1.judge, m1.stage, m1.courtNo),
          ('Justice A. B.', 'Admission', '12'),
        );
        expect((m1.assigneeId, m1.assigneeName), ('user-2', 'Rakesh Jain'));
        expect(m1.clients.map((x) => x.name), ['Suresh Patel', 'नेहा वर्मा']);

        final m2 =
            cases['m2']!; // manual: the earliest live hearing today or later
        expect(m2.nextDate, DateTime.utc(2026, 11, 8));
        expect((m2.caseLabel, m2.numbered), ('Demo v. State', false));
        expect((m2.court, m2.courtName), (null, 'Family Court, Dewas'));
        expect(m2.assigneeName, isNull);
        expect(m2.clients, isEmpty);

        expect(cases['m3']!.archived && cases['m3']!.disposed, isTrue);
        // Off: the court's date, which has passed, so no next date (the court hasn't published one).
        expect(cases['m6']!.nextDate, isNull);

        expect(
          (await firstValue(c, caseProvider('m1')))?.title,
          'Sharma v. State of MP',
        );
        expect(await firstValue(c, caseProvider('m4')), isNull); // deleted
        expect(await firstValue(c, caseProvider('m5')), isNull); // another org
        expect(await firstValue(c, pendingFoundCountProvider), 2);
      },
    );

    test('timeline: hearings and orders, with my read state', () async {
      final c = dbContainer(db);
      final hearings = await firstValue(c, caseHearingsProvider('m2'));
      expect(hearings.map((h) => h.id), ['h2c', 'h2d', 'h2a']);
      expect(hearings.every((h) => h.manual), isTrue);

      final h1 = (await firstValue(c, caseHearingsProvider('m1'))).single;
      expect((h1.manual, h1.courtNo, h1.itemNo), (false, '12', '23'));
      expect(courtWins(h1.purpose, h1.userPurpose), (
        value: 'Admission',
        noted: 'Final hearing',
      ));
      expect(
        (h1.outcome, h1.nextDate),
        ('Adjourned', DateTime.utc(2026, 11, 5)),
      );
      expect(h1.userNote, 'Bring the paper book');

      final orders = await firstValue(c, caseOrdersProvider('m1'));
      expect(orders.map((o) => (o.id, o.read, o.hasCourtCopy)), [
        ('o1', false, true), // read by someone else only
        ('o2', true, false),
      ]);
      final timeline = await firstValue(c, caseTimelineProvider('m1'));
      expect(
        timeline.map(
          (e) => switch (e) {
            CaseHearing(:final id) => id,
            CaseOrder(:final id) => id,
          },
        ),
        ['o1', 'h1a', 'o2'],
      );
    });

    test('documents, notes, tasks, deadlines and clients of a case', () async {
      final c = dbContainer(db);
      final docs = await firstValue(c, caseDocumentsProvider('m1'));
      expect(docs.map((d) => (d.id, d.kind, d.sizeBytes, d.uploadStatus)), [
        ('d1', 'pleading', 120000, 'ready'),
      ]);

      final notes = await firstValue(c, caseNotesProvider('m1'));
      expect(notes.map((n) => (n.id, n.private, n.authorName)), [
        ('n2', true, 'Ramesh Sharma'),
        ('n1', false, 'Neha Verma'),
      ]);

      final tasks = await firstValue(c, caseTasksProvider('m1'));
      expect(tasks.map((t) => t.id), ['t2', 't1', 't4', 't3']);
      expect((tasks.first.assigneeName, tasks.last.done), ('Neha Verma', true));
      expect(tasks.first.dueAt, DateTime.utc(2026, 11, 6, 6));

      final deadlines = await firstValue(c, caseDeadlinesProvider('m1'));
      expect(deadlines.map((d) => d.id), ['dl3', 'dl1', 'dl2']);
      expect(deadlines.first.dueDate, DateTime.utc(2026, 11, 9));

      final linked = await firstValue(c, caseClientsProvider('m1'));
      expect(linked.map((l) => (l.linkId, l.client.name)), [
        ('mc1', 'Suresh Patel'),
        ('mc2', 'नेहा वर्मा'),
      ]);
      expect(linked.first.client.phone, '9876543210');

      final clients = await firstValue(c, clientsProvider);
      expect(clients.map((x) => x.id), ['cl1', 'cl2']);
      expect(clients.last.searchKeys, isNotEmpty); // computed when not stored
      expect(searchClients(clients, 'verma').map((x) => x.id), ['cl2']);
    });
  });

  group('writes', () {
    late PowerSyncDatabase db;

    setUp(() async {
      db = await openTestDb();
      await insertRows(db, 'matters', [
        _matter('m1'),
        _matter('m2', {'tracking': 'manual', 'source': 'manual'}),
      ]);
      await insertRows(db, 'hearings', [
        _row('h1', {
          'matter_id': 'm1',
          'date': '2026-10-20',
          'source': 'court',
        }),
      ]);
      await insertRows(db, 'orders', [
        _row('o1', {'matter_id': 'm1', 'order_date': '2026-10-20'}),
      ]);
      await insertRows(db, 'clients', [
        _row('cl1', {'name': 'Suresh Patel'}),
      ]);
      await clearPendingWrites(db); // the rows above stand for synced data
    });

    /// The columns a device may send per table (spec §9.3; the server's device_columns, guards and RLS).
    const allowed = {
      'matters': {'assigned_to', 'status'},
      'hearings': {
        'org_id',
        'matter_id',
        'date',
        'source',
        'court_no',
        'item_no',
        'purpose',
        'outcome',
        'user_note',
        'deleted_at',
        'created_at',
      },
      'notes': {
        'org_id',
        'matter_id',
        'author_id',
        'body',
        'visibility',
        'deleted_at',
        'created_at',
      },
      'tasks': {
        'org_id',
        'matter_id',
        'title',
        'due_at',
        'assignee_id',
        'status',
        'source',
        'deleted_at',
        'created_at',
      },
      'deadlines': {
        'org_id',
        'matter_id',
        'kind',
        'due_date',
        'status',
        'deleted_at',
        'created_at',
      },
      'clients': {
        'org_id',
        'name',
        'search_key',
        'phone',
        'language',
        'created_at',
      },
      'matter_clients': {'org_id', 'matter_id', 'client_id', 'created_at'},
      'order_reads': {'org_id', 'user_id', 'order_id', 'read_at'},
    };

    test('every write sends only the columns a device may change', () async {
      final c = dbContainer(db);
      final w = c.read(caseWriterProvider);

      await w.assignCase('m1', 'user-3');
      await w.setArchived('m1', archived: true);
      final h = await w.addHearing(
        'm2',
        date: DateTime.utc(2026, 11, 9),
        courtNo: '3',
        purpose: ' Final hearing ',
      );
      await w.editHearing(
        h,
        date: DateTime.utc(2026, 11, 10),
        outcome: 'Heard',
      );
      await w.setHearingNote('h1', 'Bring the paper book');
      await w.deleteHearing(h);
      final n = await w.addNote('m1', 'Call the client', private: true);
      await w.editNote(n, 'Called', private: false);
      await w.deleteNote(n);
      final t = await w.addTask(
        title: 'File reply',
        matterId: 'm1',
        dueAt: DateTime.utc(2026, 11, 6, 6),
        assigneeId: 'user-3',
      );
      await w.editTask(t, title: 'File the reply');
      await w.setTaskDone(t, done: true);
      await w.deleteTask(t);
      await w.addTask(title: 'Pay the clerk'); // no case
      final d = await w.addDeadline(
        'm1',
        kind: 'limitation',
        dueDate: DateTime.utc(2026, 12, 2),
      );
      await w.setDeadlineDone(d, done: true);
      await w.deleteDeadline(d);
      final cl = await w.createClient(name: ' Neha Verma ', language: 'en');
      final link = await w.linkClient('m1', cl);
      await w.unlinkClient(link);
      await w.markOrderRead('o1');
      await w.markOrderRead('o1'); // once per order

      final writes = await pendingWrites(db);
      for (final [op, table, id, data] in writes) {
        final keys = ((data as Map?) ?? const {}).keys.toSet();
        expect(
          keys.difference(allowed[table]!),
          isEmpty,
          reason: '$op $table $id',
        );
      }
      expect(writes.map((w) => '${(w[0]! as UpdateType).name} ${w[1]}'), [
        'patch matters',
        'patch matters',
        'put hearings',
        'patch hearings',
        'patch hearings',
        'patch hearings',
        'put notes',
        'patch notes',
        'patch notes',
        'put tasks',
        'patch tasks',
        'patch tasks',
        'patch tasks',
        'put tasks',
        'put deadlines',
        'patch deadlines',
        'patch deadlines',
        'put clients',
        'put matter_clients',
        'delete matter_clients',
        'put order_reads',
      ]);
      Map<String, Object?> data(int i) => writes[i][3]! as Map<String, Object?>;
      expect(data(0), {'assigned_to': 'user-3'});
      expect(data(1), {'status': 'archived'});
      expect(data(2), {
        'org_id': 'org-1',
        'matter_id': 'm2',
        'date': '2026-11-09',
        'source': 'manual',
        'court_no': '3',
        'purpose': 'Final hearing',
        'created_at': testNow.toIso8601String(),
      });
      expect(data(4), {'user_note': 'Bring the paper book'});
      expect(data(6)['author_id'], 'user-1');
      expect(data(6)['visibility'], 'private');
      expect(data(9)['due_at'], '2026-11-06T06:00:00.000Z');
      expect(data(13).containsKey('matter_id'), isFalse);
      expect(data(17)['name'], 'Neha Verma');
      expect(data(17)['search_key'], isNotEmpty);
      expect(data(20)['user_id'], 'user-1');
    });

    test('local writes show at once in the reads', () async {
      final c = dbContainer(db);
      final w = c.read(caseWriterProvider);
      await firstValue(c, caseProvider('m2'));

      await w.addHearing('m2', date: DateTime.utc(2026, 11, 9));
      expect(
        (await firstValue(
          c,
          caseProvider('m2'),
          (x) => x?.nextDate != null,
        ))!.nextDate,
        DateTime.utc(2026, 11, 9),
      );

      await w.markOrderRead('o1');
      await firstValue(c, caseOrdersProvider('m1'), (o) => o.single.read);

      final cl = await w.createClient(name: 'Neha Verma');
      await w.linkClient('m1', cl);
      final m1 = await firstValue(
        c,
        caseProvider('m1'),
        (x) => x?.clients.isNotEmpty ?? false,
      );
      expect(m1!.clients.single.name, 'Neha Verma');

      await w.setArchived('m1', archived: true);
      await firstValue(c, casesProvider, (all) => all.any((x) => x.archived));
    });
  });
}
