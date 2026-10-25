/// The upload queue and the offline cache (spec §4.3 Documents, §6.2 offline-first; ADR 0016): files on the device
/// that the network serves later. Both take the database, the API client and the app's support folder, so tests
/// give them a temporary database and folder and a fake API; widget tests replace them with fakes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/device.dart';
import 'package:advocate_app/data/diary.dart';
import 'package:advocate_app/data/documents.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' hide SyncStatus;

/// Upload progress by queue item (0–1) while it is being sent, in whole percents so a 50 MB file doesn't rebuild
/// the list thousands of times. An item without an entry is waiting.
class UploadProgress extends Notifier<Map<String, double>> {
  @override
  Map<String, double> build() => const {};

  /// [fraction] null: no longer sending.
  void set(String id, double? fraction) {
    if (fraction == null) {
      if (state.containsKey(id)) state = {...state}..remove(id);
      return;
    }
    final f = (fraction * 100).floorToDouble() / 100;
    if (state[id] != f) state = {...state, id: f};
  }
}

final uploadProgressProvider =
    NotifierProvider<UploadProgress, Map<String, double>>(UploadProgress.new);

/// Every upload goes through the local `upload_queue` (spec §4.3, ADR 0016), so one made offline waits with its file
/// on the device. [drain] sends one item at a time: POST upload-url, PUT the bytes, POST complete (Idempotency-Key =
/// the item's id, reused on retry). Each step is recorded, so a restart resumes after the last one done; an upload
/// URL near its 2 h expiry is replaced (the old attempt's documents row is deleted). A retryable failure (offline,
/// server or storage trouble) stops the queue and retries after [retryDelay]; a permanent one (wrong type, too large,
/// the case gone) marks the item failed for the user to Remove. The copy is deleted once complete succeeds. The
/// item being sent has a progress entry from its first step, so the lists show it as uploading, without Remove.
/// Without a sync database or support folder (tests, builds without sync) nothing is queued.
class Uploads {
  Uploads(this._db, this._api, this._root, this._clock, {this._onProgress});

  final PowerSyncDatabase? _db;
  final ApiClient _api;
  final Directory? _root;
  final DateTime Function() _clock;
  final void Function(String id, double? fraction)? _onProgress;

  /// An upload URL this close to expiry is replaced before sending: a slow 50 MB upload must finish inside it.
  static const urlMargin = Duration(minutes: 15);

  Future<void>? _running;
  bool _again = false;
  String? _current;
  Timer? _retry;
  CancelToken? _put;

  /// Set while [stop] runs: nothing more is sent.
  bool _halted = false;

  /// 15 s after the first retryable failure, doubling to at most 15 minutes.
  static Duration retryDelay(int attempts) =>
      Duration(seconds: min(15 << min(max(attempts - 1, 0), 6), 900));

  String get _now => _clock().toUtc().toIso8601String();

  /// Queues the file at [path] (checked with `checkUploadFile`, which gave [mime]): copies it into the app's folder,
  /// so the upload survives the picked file going away, and starts sending. Returns the queue item's id; null when
  /// nothing can be queued. SAVE_FAILED when the copy can't be made (the device is full); no partial copy is left.
  /// [title] is never logged.
  Future<String?> enqueue({
    required String orgId,
    required String path,
    required String title,
    required String kind,
    required String mime,
    String? matterId,
  }) async {
    final (db, root) = (_db, _root);
    if (db == null || root == null) return null;
    final id = uuidV4();
    final dir = filesDir(root, 'uploads');
    await dir.create(recursive: true);
    final copy = File(
      '${dir.path}${Platform.pathSeparator}$id.${extensionOf(mime)}',
    );
    try {
      await File(path).copy(copy.path);
      await db.execute(
        'insert into upload_queue (id, org_id, matter_id, title, kind, mime, size_bytes, local_path, uploaded, '
        "state, attempts, created_at) values (?, ?, ?, ?, ?, ?, ?, ?, 0, 'queued', 0, ?)",
        [
          id,
          orgId,
          matterId,
          title.trim(),
          kind,
          mime,
          await copy.length(),
          copy.path,
          _now,
        ],
      );
    } on Object catch (e) {
      deleteFile(copy);
      if (e is FileSystemException) throw const ApiException('SAVE_FAILED');
      rethrow;
    }
    unawaited(drain());
    return id;
  }

  /// Sends what is queued, one at a time, oldest first; returns when the queue is empty or a retryable failure
  /// stopped it. A call while it runs makes it go round again (at once, even after a failure) before returning.
  Future<void> drain() {
    if (_running case final running?) {
      _again = true;
      return running;
    }
    return _running = _drain().whenComplete(() => _running = null);
  }

  Future<void> _drain() async {
    final db = _db;
    if (db == null) return;
    do {
      _again = false;
      _retry?.cancel();
      while (true) {
        final item = await db.getOptional(
          "select * from upload_queue where state != 'failed' order by created_at, id limit 1",
        );
        if (item == null || _halted) break;
        // Stopped by a retryable failure: the retry is scheduled, unless a drain was asked for meanwhile.
        if (!await _send(db, item)) break;
      }
    } while (_again);
  }

  /// One item, from wherever it got to. False when a retryable failure stopped the queue.
  Future<bool> _send(PowerSyncDatabase db, Map<String, dynamic> q) async {
    final id = q['id'] as String;
    final org = q['org_id'] as String;
    final mime = q['mime'] as String;
    final file = File(q['local_path'] as String);
    var documentId = q['document_id'] as String?;
    var url = q['upload_url'] as String?;
    final expires = parseInstant(q['url_expires_at']);
    Future<void> update(Map<String, Object?> values) => db.execute(
      'update upload_queue set ${values.keys.map((k) => '$k = ?').join(', ')} where id = ?',
      [...values.values, id],
    );
    _current = id;
    _onProgress?.call(id, q['uploaded'] == 1 ? 1 : 0);
    try {
      await update({'state': 'uploading'});
      // Removed just before it was picked: nothing to send.
      final there = await db.getOptional(
        'select 1 from upload_queue where id = ?',
        [id],
      );
      if (there == null) return true;
      if (!file.existsSync()) throw const ApiException('FILE_MISSING');
      if (q['uploaded'] != 1) {
        if (documentId == null ||
            url == null ||
            expires == null ||
            !_clock().add(urlMargin).isBefore(expires)) {
          final r = await _api.uploadUrl(
            orgId: org,
            title: q['title'] as String,
            kind: q['kind'] as String,
            mime: mime,
            sizeBytes: q['size_bytes'] as int,
            matterId: q['matter_id'] as String?,
          );
          // The expired attempt's row would otherwise wait as "being checked" for ever.
          if (documentId != null) await _discard(db, documentId);
          documentId = r.documentId;
          url = r.uploadUrl;
          await update({
            'document_id': documentId,
            'upload_url': url,
            'url_expires_at': _clock()
                .add(Duration(seconds: r.expiresInS))
                .toUtc()
                .toIso8601String(),
          });
        }
        if (_halted) throw const ApiException('CANCELLED');
        await _api.putUpload(
          url,
          file,
          mime: mime,
          onProgress: (sent, total) {
            if (total > 0) _onProgress?.call(id, sent / total);
          },
          cancel: _put = CancelToken(),
        );
        await update({'uploaded': 1});
      }
      try {
        await _api.completeUpload(
          orgId: org,
          documentId: documentId!,
          idempotencyKey: id,
        );
      } on ApiException catch (e) {
        if (e.code != 'ALREADY_COMPLETE') rethrow;
      }
      await db.execute('delete from upload_queue where id = ?', [id]);
      deleteFile(file);
      return true;
    } on FileSystemException {
      await update({'state': 'failed', 'error': 'FILE_MISSING'});
      return true;
    } on ApiException catch (e) {
      // Stopped at sign-out; a restart would resume it from its last step.
      if (e.code == 'CANCELLED') return false;
      final retry =
          e.retryable ||
          e.code == 'UPLOAD_MISSING' ||
          e.code == 'UNAUTHENTICATED';
      if (!retry) {
        await update({'state': 'failed', 'error': e.code});
        return true;
      }
      final attempts = (q['attempts'] as int? ?? 0) + 1;
      await update({
        'state': 'queued',
        'error': e.code,
        'attempts': attempts,
        // The file never arrived: send it again. A refused PUT: get a new URL first.
        if (e.code == 'UPLOAD_MISSING') 'uploaded': 0,
        if (e.code == 'UPLOAD_MISSING' || e.code == 'UPLOAD_URL_EXPIRED')
          'url_expires_at': null,
      });
      _retry?.cancel();
      _retry = Timer(retryDelay(attempts), () => unawaited(drain()));
      return false;
    } finally {
      _current = null;
      _put = null;
      _onProgress?.call(id, null);
    }
  }

  /// The Remove action: drops a waiting or failed upload (not the one being sent) with its copy, and deletes the
  /// documents row the server already made for it. Writes run in order, so an item the drainer picks meanwhile
  /// finds its row gone and sends nothing.
  /// ponytail: a row that hasn't synced to the device yet can't be deleted here and stays "being checked".
  Future<void> remove(String id) async {
    final db = _db;
    if (db == null || id == _current) return;
    final q = await db.getOptional(
      'select local_path, document_id from upload_queue where id = ?',
      [id],
    );
    if (q == null || id == _current) return;
    await db.execute('delete from upload_queue where id = ?', [id]);
    if (q['document_id'] case final String documentId) {
      await _discard(db, documentId);
    }
    deleteFile(File(q['local_path'] as String));
  }

  /// The user is in no organisation any more: drops every upload (none can be sent) with its copy.
  Future<void> clear() async {
    final db = _db;
    if (db == null) return;
    for (final q in await db.getAll('select id from upload_queue')) {
      await remove(q['id'] as String);
    }
  }

  /// Sign-out: stops sending, so the queued files can be deleted (Windows won't delete a file being read).
  Future<void> stop() async {
    _halted = true;
    _retry?.cancel();
    _again = false;
    _put?.cancel();
    await _running?.catchError((Object _) {});
    _halted = false;
  }

  Future<void> _discard(PowerSyncDatabase db, String documentId) => db.execute(
    'update documents set deleted_at = ? where id = ? and deleted_at is null',
    [_now, documentId],
  );

  void dispose() => _retry?.cancel();
}

final uploadsProvider = Provider<Uploads>((ref) {
  final uploads = Uploads(
    ref.watch(syncDatabaseProvider),
    ref.watch(apiClientProvider),
    ref.watch(appSupportDirProvider),
    ref.watch(clockProvider),
    onProgress: ref.read(uploadProgressProvider.notifier).set,
  );
  ref.onDispose(uploads.dispose);
  return uploads;
});

/// Sends queued uploads while the shell is up: at start and each time the device is back online (an enqueue and a
/// retry drain by themselves). Drops them all once the user is in no organisation. Nothing to do without a sync
/// database.
/// ponytail: uploads of an org left while another remains fail as not a member, hidden from the other org's lists.
final uploadDrainerProvider = Provider<void>((ref) {
  if (ref.watch(syncDatabaseProvider) == null) return;
  final uploads = ref.watch(uploadsProvider);
  if (ref.watch(_noOrgProvider)) {
    unawaited(uploads.clear());
    return;
  }
  final offline = ref.watch(
    syncViewProvider.select((s) => s.value?.offline ?? false),
  );
  if (!offline) unawaited(uploads.drain());
});

/// The account has loaded and is in no organisation (left or removed): its files have no place on the device.
/// False while it loads, so a slow start never empties the cache.
final _noOrgProvider = Provider<bool>(
  (ref) => ref.watch(
    accountProvider.select((a) => a.value != null && a.value!.org == null),
  ),
);

/// A file the viewer opens and the cache keeps: a document's (`kind` document, its id and mime), or the court copy
/// of an order (`kind` order, the order's id, always a PDF).
typedef FileRef = ({String kind, String id, String mime});

FileRef documentFile(CaseDocument d) =>
    (kind: 'document', id: d.id, mime: d.mime ?? pdfMime);

FileRef orderFile(String orderId) =>
    (kind: 'order', id: orderId, mime: pdfMime);

/// The offline cache (spec §4.3 "Offline"; ADR 0016): files in `<support>/offline/` indexed by `offline_files`.
/// [open] serves the viewer from it, downloading a missing file through a signed URL. [keep] keeps what should be
/// on the device: the user's Keep offline documents, the latest order of each case on today's and tomorrow's diary
/// ([keepSetProvider]), and the [recentLimit] live files opened last; it fetches missing ones one at a time and
/// deletes the rest, never a file open in the viewer. Without a sync database or support folder nothing is cached.
class OfflineFiles {
  OfflineFiles(this._db, this._api, this._root, this._clock);

  final PowerSyncDatabase? _db;
  final ApiClient _api;
  final Directory? _root;
  final DateTime Function() _clock;

  static const recentLimit = 10;

  /// Files open in the viewer, by id (how many viewers): never deleted.
  final _open = <String, int>{};

  /// Downloads in flight by id; the viewer and the keeper share one.
  final _downloads = <String, _Download>{};
  Future<void>? _keeping;
  ({String orgId, List<FileRef> kept})? _next;

  /// Set while [stop] runs: the keeper fetches nothing more.
  bool _halted = false;

  Directory? get _dir => _root == null ? null : filesDir(_root, 'offline');

  /// The file of [ref] for the viewer: the cached copy, else downloaded into the cache (with [onProgress], 0–1,
  /// also when it joins the keeper's download; [cancel] drops out with CANCELLED). Either way it is now one of the
  /// files opened last. NETWORK when offline without a copy; SAVE_FAILED when the device can't store it; the API's
  /// codes (DOCUMENT_NOT_READY, ORDER_PDF_UNAVAILABLE…) otherwise. Call [close] when the viewer closes.
  Future<File> open(
    FileRef ref, {
    required String orgId,
    void Function(double fraction)? onProgress,
    CancelToken? cancel,
  }) async {
    final (db, dir) = (_db, _dir);
    if (db == null || dir == null) throw const ApiException('NOT_AVAILABLE');
    _open.update(ref.id, (n) => n + 1, ifAbsent: () => 1);
    var opened = false;
    try {
      final file =
          await _cached(db, ref.id) ??
          await _fetch(db, dir, ref, orgId, onProgress, cancel);
      await db.execute('update offline_files set opened_at = ? where id = ?', [
        _clock().toUtc().toIso8601String(),
        ref.id,
      ]);
      opened = true;
      return file;
    } finally {
      if (!opened) close(ref.id);
    }
  }

  /// The viewer of [id] closed; the keeper may delete it again.
  void close(String id) {
    final n = (_open[id] ?? 1) - 1;
    if (n > 0) {
      _open[id] = n;
    } else {
      _open.remove(id);
    }
  }

  Future<File?> _cached(PowerSyncDatabase db, String id) async {
    final row = await db.getOptional(
      'select path from offline_files where id = ?',
      [id],
    );
    if (row == null) return null;
    final file = File(row['path'] as String);
    if (file.existsSync()) return file;
    await db.execute('delete from offline_files where id = ?', [id]);
    return null;
  }

  /// Downloads [ref] into the cache, or joins its download in flight: every caller gets its progress, and [cancel]
  /// drops this caller out; the download itself stops when no one is left waiting for it.
  Future<File> _fetch(
    PowerSyncDatabase db,
    Directory dir,
    FileRef ref,
    String orgId,
    void Function(double)? onProgress,
    CancelToken? cancel,
  ) async {
    final d = _downloads[ref.id] ??= _Download();
    d.file ??= _download(db, dir, ref, orgId, d).whenComplete(() {
      if (_downloads[ref.id] == d) _downloads.remove(ref.id);
    });
    d.callers++;
    if (onProgress != null) {
      d.listeners.add(onProgress);
      if (d.last case final last?) onProgress(last);
    }
    try {
      if (cancel == null) return await d.file!;
      return await Future.any([
        d.file!,
        cancel.whenCancel.then<File>(
          (_) => throw const ApiException('CANCELLED'),
        ),
      ]);
    } finally {
      d.callers--;
      d.listeners.remove(onProgress);
      if (d.callers == 0 && (cancel?.isCancelled ?? false)) d.cancel.cancel();
    }
  }

  Future<File> _download(
    PowerSyncDatabase db,
    Directory dir,
    FileRef ref,
    String orgId,
    _Download d,
  ) async {
    final url = ref.kind == 'order'
        ? await _api.orderPdfUrl(orgId: orgId, orderId: ref.id)
        : await _api.documentUrl(orgId: orgId, documentId: ref.id);
    await dir.create(recursive: true);
    final file = File(
      '${dir.path}${Platform.pathSeparator}${ref.id}.${extensionOf(ref.mime)}',
    );
    await _api.download(
      url,
      file.path,
      onProgress: (received, total) {
        if (total > 0) d.progress(received / total);
      },
      cancel: d.cancel,
    );
    final size = await file.length();
    await db.writeTransaction((tx) async {
      await tx.execute('delete from offline_files where id = ?', [ref.id]);
      await tx.execute(
        'insert into offline_files (id, kind, org_id, path, size) values (?, ?, ?, ?, ?)',
        [ref.id, ref.kind, orgId, file.path, size],
      );
    });
    return file;
  }

  /// The keeper's run for [orgId] with [kept] (the Keep offline documents and the diary's orders): drops cached
  /// files that are neither kept, nor among the [recentLimit] live files opened last, nor open; sweeps files the
  /// index lost (a crash mid-download, a file that was locked); then fetches missing kept files one at a time,
  /// stopping when offline (or the device is full) and skipping one that can't be fetched yet (still being
  /// checked, no court copy). A call while it runs replaces the next run. `orgId: ''` with nothing kept empties
  /// the cache (no organisation).
  Future<void> keep({required String orgId, required List<FileRef> kept}) {
    _next = (orgId: orgId, kept: kept);
    return _keeping ??= () async {
      for (var next = _next; next != null; next = _next) {
        _next = null;
        try {
          await _keepOnce(next.orgId, next.kept);
        } on Object {
          // A database error: the next run tries again.
        }
      }
    }().whenComplete(() => _keeping = null);
  }

  Future<void> _keepOnce(String orgId, List<FileRef> kept) async {
    final (db, dir) = (_db, _dir);
    if (db == null || dir == null) return;
    final recent = await db.getAll(_recentSql, [orgId]);
    final wanted = {
      for (final r in kept) r.id,
      for (final r in recent) r['id'] as String,
    };
    for (final r in await db.getAll('select id, path from offline_files')) {
      final id = r['id'] as String;
      if (wanted.contains(id) || _open.containsKey(id)) continue;
      // A file another app holds open keeps its row, so the viewer still finds it and a later run deletes it.
      if (deleteFile(File(r['path'] as String))) {
        await db.execute('delete from offline_files where id = ?', [id]);
      }
    }
    final cached = {
      for (final r in await db.getAll('select id from offline_files'))
        r['id'] as String,
    };
    if (dir.existsSync()) {
      for (final f in dir.listSync().whereType<File>()) {
        final id = f.uri.pathSegments.last.split('.').first;
        if (!cached.contains(id) &&
            !_open.containsKey(id) &&
            !_downloads.containsKey(id)) {
          deleteFile(f);
        }
      }
    }
    for (final ref in kept) {
      if (_halted) return;
      if (cached.contains(ref.id)) continue;
      try {
        await _fetch(db, dir, ref, orgId, null, null);
      } on ApiException catch (e) {
        if (e.code case 'NETWORK' || 'SAVE_FAILED' || 'CANCELLED') return;
      } on Object {
        // This file only; the rest go on.
      }
    }
  }

  /// Sign-out: stops the keeper and every download, so the cached files can be deleted (Windows won't delete a
  /// file being written).
  Future<void> stop() async {
    _halted = true;
    _next = null;
    for (final d in [..._downloads.values]) {
      d.cancel.cancel();
      await d.file?.then((_) {}, onError: (Object _) {});
    }
    await _keeping?.catchError((Object _) {});
    _halted = false;
  }
}

/// The [OfflineFiles.recentLimit] files opened last in org `?`, of live documents and orders only: a deleted one
/// isn't kept just for having been opened.
const _recentSql =
    '''
select f.id from offline_files f
where f.org_id = ? and f.opened_at is not null
  and (exists (select 1 from documents d where d.id = f.id and d.deleted_at is null and d.upload_status = 'ready')
    or exists (select 1 from orders o where o.id = f.id and o.deleted_at is null))
order by f.opened_at desc limit ${OfflineFiles.recentLimit}
''';

/// A download in flight: its file, its progress for whoever waits on it, and how many do.
class _Download {
  final cancel = CancelToken();
  final listeners = <void Function(double)>{};
  Future<File>? file;
  double? last;
  int callers = 0;

  void progress(double fraction) {
    last = fraction;
    for (final l in [...listeners]) {
      l(fraction);
    }
  }
}

final offlineFilesProvider = Provider<OfflineFiles>(
  (ref) => OfflineFiles(
    ref.watch(syncDatabaseProvider),
    ref.watch(apiClientProvider),
    ref.watch(appSupportDirProvider),
    ref.watch(clockProvider),
  ),
);

/// The user's ready Keep offline documents (`?1` user, `?2` org), then the latest order of each case in `?3` (a
/// JSON list of matter ids): its court copy, else its ready document.
const _keepSql = '''
select 'document' as kind, d.id, d.mime
from document_offline_prefs p join documents d on d.id = p.document_id
where p.user_id = ?1 and p.keep_offline = 1 and d.org_id = ?2 and d.deleted_at is null and d.upload_status = 'ready'
union all
select case when o.court_order_id is not null then 'order' else 'document' end,
  case when o.court_order_id is not null then o.id else o.document_id end,
  case when o.court_order_id is not null then 'application/pdf' else d.mime end
from orders o
left join documents d on d.id = o.document_id and d.deleted_at is null and d.upload_status = 'ready'
where o.id in (select (select x.id from orders x where x.matter_id = j.value and x.deleted_at is null
    order by x.order_date desc, x.created_at desc limit 1) from json_each(?3) j)
  and (o.court_order_id is not null or d.id is not null)
''';

/// What the keeper keeps besides the files opened last: the user's Keep offline documents and the latest order of
/// each case on today's and tomorrow's diary (IST, task 8's [diaryProvider]). Empty without an org or sync. It
/// waits for both days' diaries: a set without their orders would make the keeper delete those cached orders, then
/// fetch them again.
final keepSetProvider = StreamProvider<List<FileRef>>((ref) {
  final db = ref.watch(syncDatabaseProvider);
  final org = ref.watch(currentOrgIdProvider);
  final me = ref.watch(currentUserIdProvider);
  final today = ref.watch(istTodayProvider);
  final days = [
    for (final day in [today, today.add(const Duration(days: 1))])
      ref.watch(
        diaryProvider(isoDate(day)).select(
          // A diary that can't be read keeps no orders rather than holding up the Keep offline documents. One
          // that is reloading (the org just loaded, the day changed) still holds the old list: wait for the new.
          (d) => d.isLoading
              ? null
              : d.hasError && !d.hasValue
              ? ''
              : d.value?.map((e) => e.matterId).join(' '),
        ),
      ),
  ];
  if (db == null || org == null || me == null) return Stream.value(const []);
  if (days.contains(null)) return const Stream.empty();
  final matters = [
    for (final d in days) ...d!.split(' ').where((id) => id.isNotEmpty),
  ];
  return db
      .watch(_keepSql, parameters: [me, org, jsonEncode(matters)])
      .map(
        (rows) => {
          for (final r in rows)
            (
              kind: r['kind'] as String,
              id: r['id'] as String,
              mime: r['mime'] as String? ?? pdfMime,
            ),
        }.toList(),
      );
});

/// Runs the keeper while the shell is up and the device is online: at start, on reconnect, at the IST day change
/// (the diary moves on) and whenever the kept set changes (a Keep offline toggle, a document becoming ready, a new
/// order). Once the user is in no organisation it empties the cache, online or not. Nothing to do without a sync
/// database.
final offlineKeeperProvider = Provider<void>((ref) {
  if (ref.watch(syncDatabaseProvider) == null) return;
  final files = ref.watch(offlineFilesProvider);
  if (ref.watch(_noOrgProvider)) {
    unawaited(files.keep(orgId: '', kept: const []));
    return;
  }
  final org = ref.watch(currentOrgIdProvider);
  final offline = ref.watch(
    syncViewProvider.select((s) => s.value?.offline ?? false),
  );
  // A kept set that is reloading still holds the old one (at start, the empty set from before the account
  // loaded): acting on it would delete the kept files. Wait for the new one.
  ref.watch(
    keepSetProvider.select(
      (k) => k.isLoading
          ? null
          : k.value?.map((r) => '${r.kind}:${r.id}').join(' '),
    ),
  );
  final keep = ref.read(keepSetProvider);
  final kept = keep.isLoading ? null : keep.value;
  if (offline || org == null || kept == null) return;
  unawaited(files.keep(orgId: org, kept: kept));
});
