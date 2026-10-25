import 'dart:async';
import 'dart:convert';

import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/auth.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show StreamProviderFamily;
import 'package:powersync/powersync.dart' hide SyncStatus;

enum JobStatus { queued, running, done, failed, cancelled }

/// One court group of the find_cases progress, in the order the Finding screen animates them.
/// `key` is HC, DC, SC or TRIBUNAL; `state` is pending, running, done or failed.
typedef FindGroup = ({String key, String state, int found});

/// A background job (spec §10.2), from the synced `jobs` row or GET /v1/jobs/{id}.
@immutable
class Job {
  const Job({
    required this.id,
    required this.kind,
    required this.status,
    this.progress = const {},
    this.result,
    this.error,
  });

  /// Accepts the API's JSON and the synced row, where progress and result are JSON text.
  factory Job.fromJson(Map<String, dynamic> j) {
    Map<String, dynamic>? obj(Object? v) =>
        ((v is String ? jsonDecode(v) : v) as Map?)?.cast();
    return Job(
      id: j['id'] as String,
      kind: j['kind'] as String,
      status: JobStatus.values.asNameMap()[j['status']] ?? JobStatus.queued,
      progress: obj(j['progress']) ?? const {},
      result: obj(j['result']),
      error: j['error'] as String?,
    );
  }

  final String id;
  final String kind;
  final JobStatus status;
  final Map<String, dynamic> progress;

  /// find_cases: `{found, pending, disposed, low}`.
  final Map<String, dynamic>? result;

  /// An error code for `lib/core/errors.dart`, e.g. COURT_PROVIDER_UNAVAILABLE, NO_SEARCHABLE_COURTS,
  /// COURT_DATA_PAUSED, COURT_DATA_BUDGET_REACHED.
  final String? error;

  bool get finished => switch (status) {
    JobStatus.done || JobStatus.failed || JobStatus.cancelled => true,
    JobStatus.queued || JobStatus.running => false,
  };

  /// find_cases progress groups (spec §11.4 step 6).
  List<FindGroup> get groups => [
    for (final g in progress['groups'] as List? ?? const [])
      (
        key: (g as Map)['key'] as String,
        state: g['state'] as String,
        found: g['found'] as int? ?? 0,
      ),
  ];

  /// Cases found so far.
  int get found => progress['found'] as int? ?? 0;
}

const _jobColumns = 'id, kind, status, progress, result, error';

/// A job by id until it finishes: the synced row while sync is connected, else GET /v1/jobs/{id}.
/// Errors (offline) arrive as error events and polling carries on. Auto-disposed with its screen.
final StreamProviderFamily<Job, String> jobProvider = StreamProvider.autoDispose
    .family<Job, String>(
      (ref, id) => watchJob(
        id,
        api: ref.watch(apiClientProvider),
        db: ref.watch(syncDatabaseProvider),
      ),
      retry: (_, _) => null,
    );

// ponytail: polls every [every] (the local row too, so one loop covers both sources); switch to db.watch if
// progress needs to move more smoothly than every 2 s.
@visibleForTesting
Stream<Job> watchJob(
  String id, {
  required ApiClient api,
  PowerSyncDatabase? db,
  Duration every = const Duration(seconds: 2),
}) {
  late final StreamController<Job> out;
  Timer? timer;
  var cancelled = false;
  Future<void> poll() async {
    try {
      final row = db != null && db.currentStatus.connected
          ? await db.getOptional('select $_jobColumns from jobs where id = ?', [
              id,
            ])
          : null;
      final job = row != null ? Job.fromJson(row) : await api.job(id);
      if (cancelled) return;
      out.add(job);
      if (job.finished) return await out.close();
    } on ApiException catch (e, s) {
      if (cancelled) return;
      out.addError(e, s);
    }
    timer = Timer(every, () => unawaited(poll()));
  }

  // A Timer rather than Future.delayed, so cancelling (leaving the screen) leaves no timer behind.
  out = StreamController<Job>(
    onListen: () => unawaited(poll()),
    onCancel: () {
      cancelled = true;
      timer?.cancel();
    },
  );
  return out.stream;
}

/// The find_cases job the Finding screen follows (spec §4.1 step 7): the one this device started (known before
/// it syncs down), else the current org's newest synced one; null when no search has started.
class FindJobController extends Notifier<String?> {
  String? _started;

  @override
  String? build() {
    final signedIn = ref.watch(signedInProvider.select((s) => s.value));
    if (signedIn == false) _started = null;
    return _started ??
        ref.watch(latestFindJobProvider.select((j) => j.value?.id));
  }

  /// POST /v1/onboarding/find-cases (returns the running search if there is one). Pass the same
  /// [idempotencyKey] when retrying the same submit.
  Future<String> start({
    required String orgId,
    required String idempotencyKey,
  }) async {
    final id = await ref
        .read(apiClientProvider)
        .findCases(orgId: orgId, idempotencyKey: idempotencyKey);
    return state = _started = id;
  }
}

final findJobIdProvider = NotifierProvider<FindJobController, String?>(
  FindJobController.new,
);

/// The current org's newest synced find_cases job (synced jobs are the user's own); null without sync or before
/// any search.
final latestFindJobProvider = StreamProvider<Job?>((ref) {
  final db = ref.watch(syncDatabaseProvider);
  final org = ref.watch(currentOrgIdProvider);
  if (db == null || org == null) return Stream.value(null);
  return db
      .watch(
        "select $_jobColumns from jobs where kind = 'find_cases' and org_id = ? "
        'order by created_at desc limit 1',
        parameters: [org],
      )
      .map((rows) => rows.isEmpty ? null : Job.fromJson(rows.first));
});

/// Whether the org's newest search has finished, by its synced row. Sync applies whole checkpoints, so once that
/// row says so, every case the search wrote is on the device too: only then may "Add all" go as `{all: true}`,
/// the server's pending set being the one on screen (spec §4.1 AC). False without sync.
// ponytail: a case auto-match (§11.5) writes in the seconds before it syncs would still be added unseen; send
// ids always if that window ever matters.
final findSettledProvider = Provider<bool>(
  (ref) =>
      ref.watch(latestFindJobProvider.select((j) => j.value?.finished)) ??
      false,
);
