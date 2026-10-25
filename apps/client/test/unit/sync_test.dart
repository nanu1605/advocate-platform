import 'dart:convert';
import 'dart:io';

import 'package:advocate_app/data/sync/schema.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:powersync/powersync.dart' hide SyncStatus;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('syncView', () {
    test('first connect after launch shows no banner', () {
      expect(syncView(connected: false, busy: true), (
        status: SyncStatus.syncing,
        offline: false,
      ));
    });
    test('connected and idle is synced', () {
      expect(syncView(connected: true, busy: false), (
        status: SyncStatus.synced,
        offline: false,
      ));
    });
    test('a failed connection means offline', () {
      expect(syncView(connected: false, busy: true, downloadError: 'x'), (
        status: SyncStatus.syncing,
        offline: true,
      ));
    });
    test('an upload error shows failed', () {
      expect(
        syncView(connected: true, busy: false, uploadError: 'x').status,
        SyncStatus.failed,
      );
    });
  });

  group('uploadTransaction', () {
    late List<String> applied;
    late bool completed;

    CrudTransaction tx() => CrudTransaction(
      transactionId: 1,
      crud: [
        CrudEntry(1, UpdateType.put, 'notes', 'n1', 1, {'body': 'a'}),
        CrudEntry(2, UpdateType.patch, 'notes', 'n2', 1, {'body': 'b'}),
      ],
      complete: ({writeCheckpoint}) async => completed = true,
    );

    setUp(() {
      applied = [];
      completed = false;
    });

    test('applies every change in order, then completes', () async {
      await uploadTransaction(tx(), (op) async => applied.add(op.id));
      expect(applied, ['n1', 'n2']);
      expect(completed, isTrue);
    });

    test('drops a change the server refuses for good', () async {
      await uploadTransaction(tx(), (op) async {
        throw const PostgrestException(message: 'denied', code: '42501');
      });
      expect(completed, isTrue);
    });

    test('keeps the queue when the server is unreachable', () async {
      await expectLater(
        uploadTransaction(tx(), (op) async {
          throw const SocketException('offline');
        }),
        throwsA(isA<SocketException>()),
      );
      expect(completed, isFalse);
    });

    test('keeps the queue on a server error', () async {
      await expectLater(
        uploadTransaction(tx(), (op) async {
          throw const PostgrestException(message: 'busy', code: '57014');
        }),
        throwsA(isA<PostgrestException>()),
      );
      expect(completed, isFalse);
    });
  });

  test('applyCrud maps changes to PostgREST calls', () async {
    final requests = <http.Request>[];
    final client = SupabaseClient(
      'http://supabase.test',
      'anon',
      httpClient: MockClient((r) async {
        requests.add(r);
        return http.Response('', 204, request: r);
      }),
    );
    await applyCrud(
      client,
      CrudEntry(1, UpdateType.put, 'notes', 'n1', 1, {'body': 'a'}),
    );
    await applyCrud(
      client,
      CrudEntry(2, UpdateType.patch, 'matters', 'm1', 1, {'tags': '["bail"]'}),
    );
    await applyCrud(
      client,
      CrudEntry(3, UpdateType.delete, 'matter_clients', 'mc1', 1, null),
    );

    expect(requests.map((r) => r.method), ['POST', 'PATCH', 'DELETE']);
    expect(
      requests[0].headers['Prefer'],
      contains('resolution=merge-duplicates'),
    );
    expect(jsonDecode(requests[0].body), {'body': 'a', 'id': 'n1'});
    expect(requests[1].url.queryParameters['id'], 'eq.m1');
    expect(jsonDecode(requests[1].body), {
      'tags': ['bail'], // array columns go up as arrays, not JSON text
    });
    expect(requests[2].url.path, endsWith('/matter_clients'));
    expect(requests[2].url.queryParameters['id'], 'eq.mc1');
  });

  test('the device schema has every table the sync config streams', () {
    final config = loadYaml(
      File('../../infra/powersync/sync-config.yaml').readAsStringSync(),
    ) as YamlMap;
    final streamed = {
      for (final m in RegExp(
        r'\bFROM (\w+)',
      ).allMatches(jsonEncode(config['streams'])))
        m[1]!,
    };
    final synced = {
      for (final t in schema.tables)
        if (!t.localOnly) t.name,
    };
    expect(synced, streamed);
    expect(schema.tables.where((t) => t.localOnly).map((t) => t.name), [
      'found_selection',
      'upload_queue',
      'offline_files',
    ]);
  });
}
