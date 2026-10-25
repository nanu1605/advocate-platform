import 'dart:async';
import 'dart:convert';

import 'package:advocate_app/core/config.dart';
import 'package:advocate_app/data/auth.dart';
import 'package:advocate_app/data/sync/schema.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:powersync/powersync.dart' hide SyncStatus;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Opens the on-device database, or returns null when the build has no sync URL (spec §6.2: reads are local).
Future<PowerSyncDatabase?> openSyncDatabase() async {
  if (Config.powersyncUrl.isEmpty) return null;
  final dir = await getApplicationSupportDirectory();
  final db = PowerSyncDatabase(schema: schema, path: '${dir.path}/pairavi.db');
  await db.initialize();
  return db;
}

/// Overridden in main(); null in tests and in builds without sync.
final syncDatabaseProvider = Provider<PowerSyncDatabase?>((_) => null);

/// Keeps the device connected while someone is signed in. Sign-out clears local data (`Session.signOut`).
final syncConnectionProvider = Provider<void>((ref) {
  final db = ref.watch(syncDatabaseProvider);
  if (db == null) return;
  final connector = SupabaseConnector(Supabase.instance.client);
  ref.listen(signedInProvider, (_, signedIn) {
    if (signedIn.value ?? false) {
      unawaited(db.connect(connector: connector));
    } else {
      unawaited(db.disconnect());
    }
  }, fireImmediately: true);
});

/// The kit's sync indicator state, and whether to show the offline banner.
typedef SyncView = ({SyncStatus status, bool offline});

final syncViewProvider = StreamProvider<SyncView>((ref) {
  final db = ref.watch(syncDatabaseProvider);
  if (db == null) {
    return Stream.value((status: SyncStatus.synced, offline: false));
  }
  return db.statusStream.map(
    (s) => syncView(
      connected: s.connected,
      busy: s.connecting || s.uploading || s.downloading,
      downloadError: s.downloadError,
      uploadError: s.uploadError,
    ),
  );
});

@visibleForTesting
SyncView syncView({
  required bool connected,
  required bool busy,
  Object? downloadError,
  Object? uploadError,
}) {
  // Offline once a connection attempt has failed; the first connect after launch shows no banner.
  final offline = !connected && downloadError != null;
  final status = uploadError != null
      ? SyncStatus.failed
      : offline || busy
      ? SyncStatus.syncing
      : SyncStatus.synced;
  return (status: status, offline: offline);
}

/// What a sign-out would lose (ADR 0013 follow-up): `changes` are local writes waiting to upload (PowerSync's CRUD
/// queue, one per change), `uploads` are documents still in task 10's upload queue (failed ones included: their file
/// is only on this device).
typedef PendingChanges = ({int changes, int uploads});

/// Reads [PendingChanges] now (Settings' sign-out confirm); none without sync.
final pendingChangesProvider = Provider<Future<PendingChanges> Function()>((
  ref,
) {
  final db = ref.watch(syncDatabaseProvider);
  return () async {
    if (db == null) return (changes: 0, uploads: 0);
    final queued = await db.get('select count(*) as n from upload_queue');
    return (
      changes: (await db.getUploadQueueStats()).count,
      uploads: queued['n'] as int,
    );
  };
});

/// Device writes go straight to Supabase as the signed-in user, so row-level security and the §9.3 column
/// triggers decide what is accepted (ADR 0003, 0009).
class SupabaseConnector extends PowerSyncBackendConnector {
  SupabaseConnector(this._client);

  final SupabaseClient _client;

  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    final session = _client.auth.currentSession;
    if (session == null) return null;
    return PowerSyncCredentials(
      endpoint: Config.powersyncUrl,
      token: session.accessToken,
      userId: session.user.id,
    );
  }

  @override
  void invalidateCredentials() => unawaited(_client.auth.refreshSession());

  @override
  Future<void> uploadData(PowerSyncDatabase database) async {
    final tx = await database.getNextCrudTransaction();
    if (tx != null) await uploadTransaction(tx, (op) => applyCrud(_client, op));
  }
}

/// Uploads one local transaction in order. A write the server refuses for good (bad data, a constraint, or
/// permission) is dropped so the queue never blocks; the next sync then restores the server's row on the device.
/// Anything else (offline, server down) is rethrown and retried.
Future<void> uploadTransaction(
  CrudTransaction tx,
  Future<void> Function(CrudEntry op) apply,
) async {
  try {
    for (final op in tx.crud) {
      await apply(op);
    }
  } on PostgrestException catch (e) {
    if (!_permanent.hasMatch(e.code ?? '')) rethrow;
    debugPrint('Sync upload rejected (${e.code}): ${e.message}');
  }
  await tx.complete();
}

// Postgres data exceptions, integrity violations, and insufficient privilege (RLS and column triggers).
final _permanent = RegExp(r'^(22...|23...|42501)$');

Future<void> applyCrud(SupabaseClient client, CrudEntry op) async {
  final table = client.from(op.table);
  final json = jsonColumns[op.table] ?? const {};
  final data = {
    for (final MapEntry(:key, :value) in (op.opData ?? const {}).entries)
      key: json.contains(key) && value is String ? jsonDecode(value) : value,
  };
  switch (op.op) {
    case UpdateType.put:
      await table.upsert({...data, 'id': op.id});
    case UpdateType.patch:
      await table.update(data).eq('id', op.id);
    case UpdateType.delete:
      await table.delete().eq('id', op.id);
  }
}
