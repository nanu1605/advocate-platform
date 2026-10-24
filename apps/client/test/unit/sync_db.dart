import 'dart:async';
import 'dart:io';

import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/sync/schema.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override, ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:powersync/powersync.dart' hide SyncStatus;

import '../helpers.dart';

/// Helpers for testing the data layer's SQL against a real on-device database (ADR 0014).

/// A fresh on-device database with the app's schema, deleted after the test.
Future<PowerSyncDatabase> openTestDb() async {
  final dir = Directory.systemTemp.createTempSync('pairavi_db');
  final db = PowerSyncDatabase(schema: schema, path: '${dir.path}/test.db');
  await db.initialize();
  addTearDown(() async {
    await db.close();
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows may hold the file a moment longer; it's in the temp folder.
    }
  });
  return db;
}

/// Inserts [rows] as synced rows would arrive (each its own statement).
Future<void> insertRows(
  PowerSyncDatabase db,
  String table,
  List<Map<String, Object?>> rows,
) async {
  for (final r in rows) {
    await db.execute(
      'insert into $table (${r.keys.join(', ')}) '
      'values (${List.filled(r.length, '?').join(', ')})',
      r.values.toList(),
    );
  }
}

/// A container on [db] for org [org] and user-1, at [testNow], with any further [overrides] (e.g. a FakeApi).
ProviderContainer dbContainer(
  PowerSyncDatabase db, {
  String org = 'org-1',
  List<Override> overrides = const [],
}) {
  final c = ProviderContainer(
    overrides: [
      syncDatabaseProvider.overrideWithValue(db),
      currentOrgIdProvider.overrideWithValue(org),
      currentUserIdProvider.overrideWithValue('user-1'),
      clockProvider.overrideWithValue(() => testNow),
      ...overrides,
    ],
  );
  addTearDown(c.dispose);
  return c;
}

/// The first value of [p] that passes [until], listening as a screen does (Riverpod pauses unlistened providers).
Future<T> firstValue<T>(
  ProviderContainer c,
  ProviderListenable<AsyncValue<T>> p, [
  bool Function(T)? until,
]) {
  final done = Completer<T>();
  final sub = c.listen<AsyncValue<T>>(p, (_, next) {
    if (done.isCompleted) return;
    if (next.hasError) return done.completeError(next.error!);
    if (!next.hasValue) return;
    final v = next.value as T;
    if (until?.call(v) ?? true) done.complete(v);
  }, fireImmediately: true);
  return done.future
      .timeout(const Duration(seconds: 10))
      .whenComplete(sub.close);
}

/// Forgets the local changes waiting to upload, as an upload would (e.g. after inserting rows that stand for
/// synced data).
Future<void> clearPendingWrites(PowerSyncDatabase db) async {
  await (await db.getCrudBatch(limit: 10000))?.complete();
}

/// The local changes waiting to upload, oldest first: `[op, table, id, data]`.
Future<List<List<Object?>>> pendingWrites(PowerSyncDatabase db) async => [
  for (final op in (await db.getCrudBatch(limit: 1000))?.crud ?? <CrudEntry>[])
    [op.op, op.table, op.id, op.opData],
];

/// The latest local change waiting to upload: `[op, table, id, data]`.
Future<List<Object?>> lastWrite(PowerSyncDatabase db) async =>
    (await pendingWrites(db)).last;
