import 'dart:async';
import 'dart:io';

import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/document_files.dart';
import 'package:advocate_app/data/documents.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderContainer;
import 'package:flutter_test/flutter_test.dart';
import 'package:powersync/powersync.dart' hide SyncStatus;

import '../helpers.dart';
import 'sync_db.dart';

/// A fresh support folder, deleted after the test.
Directory _tempRoot() {
  final dir = Directory.systemTemp.createTempSync('pairavi_files');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows may hold a file a moment longer; it's in the temp folder.
    }
  });
  return dir;
}

/// Waits until [done], on real time: the database answers from another isolate.
Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 500 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue);
}

/// The upload queue's drainer and the offline keeper against a real database, a temporary folder and a fake API
/// (spec §4.3 Documents; ADR 0016).
void main() {
  // IST now listens for the app resuming.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('upload queue', () {
    late PowerSyncDatabase db;
    late FakeApi api;
    late Directory root;
    late Uploads uploads;
    late DateTime now;
    late Map<String, double?> progress;

    setUp(() async {
      db = await openTestDb();
      api = FakeApi();
      root = _tempRoot();
      now = testNow;
      progress = {};
      uploads = Uploads(
        db,
        api,
        root,
        () => now,
        onProgress: (id, f) => progress[id] = f,
      );
      addTearDown(uploads.dispose);
    });

    /// A picked file outside the app's folder.
    File picked([List<int> bytes = const [0x25, 0x50, 0x44, 0x46, 0x2D]]) =>
        File('${root.path}/picked.pdf')..writeAsBytesSync(bytes);

    Future<Map<String, dynamic>?> item(String id) =>
        db.getOptional('select * from upload_queue where id = ?', [id]);

    /// Queues the picked file while offline (one failed drain), then forgets that attempt: what an upload made
    /// without the network looks like when the device comes back.
    Future<String> enqueue({String? matterId}) async {
      api.offline = true;
      final id = (await uploads.enqueue(
        orgId: 'org-1',
        path: picked().path,
        title: ' Writ petition ',
        kind: 'pleading',
        mime: pdfMime,
        matterId: matterId,
      ))!;
      await uploads.drain();
      await db.execute(
        'update upload_queue set attempts = 0, error = null where id = ?',
        [id],
      );
      api
        ..offline = false
        ..calls.clear();
      return id;
    }

    test(
      'upload-url, PUT, complete; the copy goes once the server has it',
      () async {
        final id = await enqueue(matterId: 'm1');
        final q = (await item(id))!;
        expect(
          (q['state'], q['size_bytes'], q['title']),
          ('queued', 5, 'Writ petition'),
        );
        final copy = File(q['local_path'] as String);
        expect(copy.existsSync(), isTrue);
        expect(copy.parent.path, filesDir(root, 'uploads').path);

        await uploads.drain();
        expect(api.callNames, ['uploadUrl', 'putUpload', 'completeUpload']);
        expect(api.calls.map((c) => c.args).toList(), [
          {
            'title': 'Writ petition',
            'kind': 'pleading',
            'mime': pdfMime,
            'size': 5,
            'matterId': 'm1',
          },
          {'url': 'https://files.test/upload/1', 'mime': pdfMime},
          {'documentId': 'doc-up-1', 'key': id},
        ]);
        expect(api.uploaded['https://files.test/upload/1'], hasLength(5));
        expect(await item(id), isNull);
        expect(copy.existsSync(), isFalse);
        // Progress was shown, then cleared.
        expect(progress, {id: null});
      },
    );

    test('resumes after upload-url, and after the PUT', () async {
      final a = await enqueue();
      await db.execute(
        "update upload_queue set document_id = 'doc-a', upload_url = 'https://files.test/upload/a', "
        "url_expires_at = ?, state = 'uploading' where id = ?",
        [now.add(const Duration(hours: 1)).toIso8601String(), a],
      );
      final b = await enqueue();
      await db.execute(
        "update upload_queue set document_id = 'doc-b', uploaded = 1, created_at = '2030-01-01' where id = ?",
        [b],
      );
      await uploads.drain();
      expect(api.callNames, ['putUpload', 'completeUpload', 'completeUpload']);
      expect(api.calls.map((c) => c.args).toList(), [
        {'url': 'https://files.test/upload/a', 'mime': pdfMime},
        {'documentId': 'doc-a', 'key': a},
        {'documentId': 'doc-b', 'key': b},
      ]);
      expect(await db.getAll('select id from upload_queue'), isEmpty);
    });

    test(
      'an upload URL near expiry is replaced; its documents row is deleted',
      () async {
        await insertRows(db, 'documents', [
          {
            'id': 'doc-old',
            'org_id': 'org-1',
            'title': 'x',
            'upload_status': 'pending',
          },
        ]);
        await clearPendingWrites(db);
        final id = await enqueue();
        await db.execute(
          "update upload_queue set document_id = 'doc-old', upload_url = 'https://files.test/old', "
          'url_expires_at = ? where id = ?',
          [now.add(const Duration(minutes: 10)).toIso8601String(), id],
        );
        await uploads.drain();
        expect(api.callNames, ['uploadUrl', 'putUpload', 'completeUpload']);
        expect(api.calls.last.args, {'documentId': 'doc-up-1', 'key': id});
        expect(await lastWrite(db), [
          UpdateType.patch,
          'documents',
          'doc-old',
          {'deleted_at': testNow.toIso8601String()},
        ]);
      },
    );

    test(
      'offline: the item waits with its file, and is retried later',
      () async {
        final id = await enqueue();
        api.offline = true;
        await uploads.drain();
        final q = (await item(id))!;
        expect(
          (q['state'], q['error'], q['attempts']),
          ('queued', 'NETWORK', 1),
        );
        expect(File(q['local_path'] as String).existsSync(), isTrue);
        expect(Uploads.retryDelay(1), const Duration(seconds: 15));
        expect(Uploads.retryDelay(2), const Duration(seconds: 30));
        expect(Uploads.retryDelay(20), const Duration(minutes: 15));

        api.offline = false;
        await uploads.drain();
        expect(await item(id), isNull);
      },
    );

    test(
      'a refused PUT gets a new URL next time; a missing upload is sent again',
      () async {
        final id = await enqueue();
        api.fail['putUpload'] = const ApiException(
          'UPLOAD_URL_EXPIRED',
          retryable: true,
          status: 400,
        );
        await uploads.drain();
        expect((await item(id))!['url_expires_at'], isNull);

        api.fail
          ..clear()
          ..['completeUpload'] = const ApiException(
            'UPLOAD_MISSING',
            status: 409,
          );
        api.calls.clear();
        await uploads.drain();
        expect(api.callNames, ['uploadUrl', 'putUpload', 'completeUpload']);
        final q = (await item(id))!;
        expect(
          (q['state'], q['uploaded'], q['error']),
          ('queued', 0, 'UPLOAD_MISSING'),
        );

        api.fail.clear();
        api.calls.clear();
        await uploads.drain();
        expect(api.callNames, ['uploadUrl', 'putUpload', 'completeUpload']);
        expect(await item(id), isNull);
      },
    );

    test('a permanent failure marks the item failed; the queue goes on; Remove '
        'cleans up', () async {
      await insertRows(db, 'documents', [
        {
          'id': 'doc-up-1',
          'org_id': 'org-1',
          'title': 'x',
          'upload_status': 'pending',
        },
      ]);
      await clearPendingWrites(db);
      final bad = await enqueue();
      final good = await enqueue();
      await db.execute(
        "update upload_queue set created_at = '2030-01-01' where id = ?",
        [good],
      );
      api.fail['completeUpload'] = const ApiException(
        'UNSUPPORTED_FILE_TYPE',
        status: 415,
      );
      await uploads.drain();
      final q = (await item(bad))!;
      expect((q['state'], q['error']), ('failed', 'UNSUPPORTED_FILE_TYPE'));
      // The next item was tried too (and failed the same way here).
      expect(api.callNames.where((n) => n == 'uploadUrl'), hasLength(2));

      // Failed items aren't retried.
      api
        ..fail.clear()
        ..calls.clear();
      await uploads.drain();
      expect(api.callNames, isEmpty);

      final copy = File(q['local_path'] as String);
      await uploads.remove(bad);
      expect(await item(bad), isNull);
      expect(copy.existsSync(), isFalse);
      expect(await lastWrite(db), [
        UpdateType.patch,
        'documents',
        'doc-up-1',
        {'deleted_at': testNow.toIso8601String()},
      ]);
    });

    test(
      'ALREADY_COMPLETE counts as done; a lost copy fails with FILE_MISSING',
      () async {
        final a = await enqueue();
        api.fail['completeUpload'] = const ApiException(
          'ALREADY_COMPLETE',
          status: 409,
        );
        await uploads.drain();
        expect(await item(a), isNull);

        final b = await enqueue();
        File((await item(b))!['local_path'] as String).deleteSync();
        await uploads.drain();
        final q = (await item(b))!;
        expect((q['state'], q['error']), ('failed', 'FILE_MISSING'));
      },
    );

    test('the item being sent shows as uploading from its first step, and '
        'Remove leaves it alone', () async {
      final id = await enqueue();
      final gate = api.gates['uploadUrl'] = Completer<void>();
      final draining = uploads.drain();
      await _until(() => api.callNames.isNotEmpty);
      // Asking for its upload URL: no bytes yet, but it is the one being sent.
      expect(api.callNames, ['uploadUrl']);
      expect(progress[id], 0);
      await uploads.remove(id);
      expect(await item(id), isNotNull);
      gate.complete();
      await draining;
      expect(api.callNames, ['uploadUrl', 'putUpload', 'completeUpload']);
      expect(progress, {id: null});
    });

    test(
      "a copy that can't be made says SAVE_FAILED and leaves nothing",
      () async {
        await expectLater(
          uploads.enqueue(
            orgId: 'org-1',
            path: '${root.path}/gone.pdf',
            title: 'Writ petition',
            kind: 'pleading',
            mime: pdfMime,
          ),
          throwsA(
            isA<ApiException>().having((e) => e.code, 'code', 'SAVE_FAILED'),
          ),
        );
        expect(await db.getAll('select id from upload_queue'), isEmpty);
        expect(filesDir(root, 'uploads').listSync(), isEmpty);
      },
    );

    test('sign-out stops the upload being sent, so its file can go', () async {
      final id = await enqueue();
      final gate = api.gates['putUpload'] = Completer<void>();
      final draining = uploads.drain();
      await _until(() => api.callNames.contains('putUpload'));
      final stopping = uploads.stop();
      gate.complete();
      await stopping;
      await draining;
      // Not completed, not failed: a restart would resume it.
      expect(api.callNames, isNot(contains('completeUpload')));
      expect((await item(id))!['state'], 'uploading');
      clearDeviceFiles(root);
      expect(filesDir(root, 'uploads').existsSync(), isFalse);
    });

    test(
      'no organisation any more: every upload goes, with its copy',
      () async {
        final a = await enqueue();
        final b = await enqueue();
        final copies = [
          for (final id in [a, b])
            File((await item(id))!['local_path'] as String),
        ];
        await uploads.clear();
        expect(await db.getAll('select id from upload_queue'), isEmpty);
        expect(copies.where((f) => f.existsSync()), isEmpty);
      },
    );

    test('sign-out deletes queued and offline files', () async {
      await enqueue();
      filesDir(root, 'offline').createSync();
      File('${filesDir(root, 'offline').path}/d1.pdf').writeAsStringSync('x');
      clearDeviceFiles(root);
      expect(filesDir(root, 'uploads').existsSync(), isFalse);
      expect(filesDir(root, 'offline').existsSync(), isFalse);
      // The folder itself (it holds the database) stays.
      expect(root.existsSync(), isTrue);
      clearDeviceFiles(null);
    });
  });

  group('offline cache', () {
    late PowerSyncDatabase db;
    late FakeApi api;
    late Directory root;
    late OfflineFiles files;
    late DateTime now;

    setUp(() async {
      db = await openTestDb();
      api = FakeApi();
      root = _tempRoot();
      now = testNow;
      files = OfflineFiles(db, api, root, () => now);
    });

    FileRef doc(String id) => (kind: 'document', id: id, mime: pdfMime);

    Future<List<String>> cachedIds() async => [
      for (final r in await db.getAll(
        'select id from offline_files order by id',
      ))
        r['id'] as String,
    ];

    test(
      'opening downloads into the cache once, then opens from it, offline too',
      () async {
        final progress = <double>[];
        final file = await files.open(
          doc('d1'),
          orgId: 'org-1',
          onProgress: progress.add,
        );
        expect(api.callNames, ['documentUrl', 'download']);
        expect(
          file.path,
          '${filesDir(root, 'offline').path}${Platform.pathSeparator}d1.pdf',
        );
        expect(file.readAsStringSync(), startsWith('%PDF'));
        expect(progress.last, 1);
        final row = (await db.getOptional(
          'select * from offline_files where id = ?',
          ['d1'],
        ))!;
        expect(
          (row['kind'], row['org_id'], row['opened_at']),
          ('document', 'org-1', testNow.toIso8601String()),
        );

        api
          ..calls.clear()
          ..offline = true;
        now = testNow.add(const Duration(hours: 1));
        expect((await files.open(doc('d1'), orgId: 'org-1')).path, file.path);
        expect(api.callNames, isEmpty);
        expect(
          (await db.getOptional(
            'select opened_at from offline_files',
          ))!['opened_at'],
          now.toIso8601String(),
        );
      },
    );

    test(
      'offline without a copy says NETWORK; an order comes from its PDF link',
      () async {
        api.offline = true;
        await expectLater(
          files.open(doc('d2'), orgId: 'org-1'),
          throwsA(isA<ApiException>().having((e) => e.code, 'code', 'NETWORK')),
        );
        expect(await cachedIds(), isEmpty);
        api.offline = false;
        final order = await files.open(orderFile('o1'), orgId: 'org-1');
        expect(api.calls.last.args, 'https://files.test/orders/o1');
        expect(order.path, endsWith('o1.pdf'));
      },
    );

    test('the keeper fetches kept files, keeps the last 10 opened, and deletes the '
        'rest, never one that is open', () async {
      await insertRows(db, 'documents', [
        for (var i = 0; i < 12; i++)
          {
            'id': 'o$i',
            'org_id': 'org-1',
            'title': 'x',
            'upload_status': 'ready',
          },
      ]);
      // Twelve files opened one after another (o0 first).
      for (var i = 0; i < 12; i++) {
        now = testNow.add(Duration(minutes: i));
        await files.open(doc('o$i'), orgId: 'org-1');
        files.close('o$i');
      }
      // o1 is still in the viewer; o0 isn't.
      await files.open(doc('o1'), orgId: 'org-1');
      // Re-opening o1 made it recent; date it back to minute 1, so only being open keeps it.
      await db.execute(
        "update offline_files set opened_at = ? where id = 'o1'",
        [testNow.add(const Duration(minutes: 1)).toIso8601String()],
      );
      // A file the index lost (a crash mid-download) is swept.
      File('${filesDir(root, 'offline').path}/lost.pdf.part')
          .writeAsStringSync('x');
      api.calls.clear();

      await files.keep(orgId: 'org-1', kept: [doc('k1'), orderFile('o-court')]);
      expect(api.callNames, [
        'documentUrl',
        'download',
        'orderPdfUrl',
        'download',
      ]);
      expect(
        await cachedIds(),
        [
          'k1',
          'o-court',
          'o1', // open in the viewer
          for (var i = 2; i < 12; i++) 'o$i',
        ]..sort(),
      );
      expect(
        File('${filesDir(root, 'offline').path}/o0.pdf').existsSync(),
        isFalse,
      );
      expect(
        File('${filesDir(root, 'offline').path}/lost.pdf.part').existsSync(),
        isFalse,
      );
      final kept = (await db.getOptional(
        "select opened_at from offline_files where id = 'k1'",
      ))!;
      expect(kept['opened_at'], isNull);

      // Closed now, and neither kept nor recent: it goes on the next run.
      files.close('o1');
      await files.keep(orgId: 'org-1', kept: [doc('k1'), orderFile('o-court')]);
      expect(await cachedIds(), isNot(contains('o1')));
    });

    test(
      'a deleted document is not kept for having been opened; a deleted order '
      'neither',
      () async {
        await insertRows(db, 'documents', [
          for (final id in ['d1', 'd2'])
            {
              'id': id,
              'org_id': 'org-1',
              'title': 'x',
              'upload_status': 'ready',
            },
        ]);
        await insertRows(db, 'orders', [
          {'id': 'o1', 'org_id': 'org-1', 'matter_id': 'm1'},
        ]);
        for (final ref in [doc('d1'), doc('d2'), orderFile('o1')]) {
          await files.open(ref, orgId: 'org-1');
          files.close(ref.id);
        }
        await db.execute(
          "update documents set deleted_at = '2026-10-25' where id = 'd2'",
        );
        await db.execute(
          "update orders set deleted_at = '2026-10-25' where id = 'o1'",
        );
        await files.keep(orgId: 'org-1', kept: const []);
        expect(await cachedIds(), ['d1']);
        expect(
          File('${filesDir(root, 'offline').path}/d2.pdf').existsSync(),
          isFalse,
        );
      },
    );

    test("the viewer joining the keeper's download follows its progress and "
        'can drop out without stopping it', () async {
      final gate = api.gates['download'] = Completer<void>();
      final keeping = files.keep(orgId: 'org-1', kept: [doc('big')]);
      await _until(() => api.callNames.contains('download'));

      // A viewer joins, then is cancelled: it drops out; the keeper's download goes on.
      final cancel = CancelToken();
      final viewer = files.open(doc('big'), orgId: 'org-1', cancel: cancel);
      cancel.cancel();
      await expectLater(
        viewer,
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'CANCELLED')),
      );
      // Another joins and gets the progress.
      final progress = <double>[];
      final second = files.open(
        doc('big'),
        orgId: 'org-1',
        onProgress: progress.add,
        cancel: CancelToken(),
      );
      gate.complete();
      await keeping;
      expect((await second).path, endsWith('big.pdf'));
      expect(progress, [1]);
      // One download for all three.
      expect(api.callNames, ['documentUrl', 'download']);
      expect(await cachedIds(), ['big']);
    });

    test("a viewer's own download stops when it is cancelled", () async {
      final gate = api.gates['download'] = Completer<void>();
      final cancel = CancelToken();
      final viewer = files.open(doc('d1'), orgId: 'org-1', cancel: cancel);
      await _until(() => api.callNames.contains('download'));
      cancel.cancel();
      gate.complete();
      await expectLater(
        viewer,
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'CANCELLED')),
      );
      await pumpEventQueue();
      expect(await cachedIds(), isEmpty);
      expect(filesDir(root, 'offline').listSync(), isEmpty);
    });

    test('sign-out stops the keeper and its download', () async {
      final gate = api.gates['download'] = Completer<void>();
      final keeping = files.keep(orgId: 'org-1', kept: [doc('a'), doc('b')]);
      await _until(() => api.callNames.contains('download'));
      final stopping = files.stop();
      gate.complete();
      await stopping;
      await keeping;
      // Neither the one in flight nor the next was fetched.
      expect(api.callNames, ['documentUrl', 'download']);
      expect(await cachedIds(), isEmpty);
    });

    test('the keeper stops when offline and skips what is not ready', () async {
      api.fail['documentUrl'] = const ApiException(
        'DOCUMENT_NOT_READY',
        retryable: true,
      );
      await files.keep(orgId: 'org-1', kept: [doc('pending'), orderFile('o1')]);
      expect(await cachedIds(), ['o1']);
      api
        ..fail.clear()
        ..offline = true
        ..calls.clear();
      await files.keep(orgId: 'org-1', kept: [doc('a'), doc('b')]);
      expect(api.callNames, ['documentUrl']);
      expect(await cachedIds(), isEmpty);

      // A full device stops it too: the next file wouldn't fit either.
      api
        ..offline = false
        ..fail['download'] = const ApiException('SAVE_FAILED')
        ..calls.clear();
      await files.keep(orgId: 'org-1', kept: [doc('a'), doc('b')]);
      expect(api.callNames, ['documentUrl', 'download']);
    });

    test('a start before the account has loaded keeps what is kept, offline '
        'too', () async {
      await insertRows(db, 'matters', [
        {
          'id': 'm1',
          'org_id': 'org-1',
          'case_type': 'WP',
          'case_number': '1',
          'case_year': 2024,
          'status': 'active',
          'tracking': 'auto',
          // On tomorrow's diary: its latest order is kept.
          'next_hearing_date': testTomorrow,
        },
      ]);
      await insertRows(db, 'orders', [
        {
          'id': 'o1',
          'org_id': 'org-1',
          'matter_id': 'm1',
          'order_date': '2026-10-20',
          'court_order_id': 'co-1',
        },
      ]);
      await insertRows(db, 'documents', [
        {'id': 'd1', 'org_id': 'org-1', 'title': 'x', 'upload_status': 'ready'},
      ]);
      await insertRows(db, 'document_offline_prefs', [
        {
          'id': 'p1',
          'org_id': 'org-1',
          'user_id': 'user-1',
          'document_id': 'd1',
          'keep_offline': 1,
        },
      ]);
      // Fetched by an earlier run, never opened.
      await files.keep(orgId: 'org-1', kept: [doc('d1'), orderFile('o1')]);
      expect(await cachedIds(), ['d1', 'o1']);
      api
        ..offline = true
        ..calls.clear();
      // The shell is up while /v1/me is still on its way (a returning user skips /loading).
      final account = Completer<Account?>();
      final container = ProviderContainer(
        overrides: [
          syncDatabaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(() => testNow),
          apiClientProvider.overrideWithValue(api),
          appSupportDirProvider.overrideWithValue(root),
          offlineFilesProvider.overrideWithValue(files),
          accountProvider.overrideWith(() => _Later(account.future)),
        ],
      );
      addTearDown(container.dispose);
      container.listen(offlineKeeperProvider, (_, _) {});
      await pumpEventQueue();
      account.complete(
        const Account(
          id: 'user-1',
          memberships: [
            Membership(
              orgId: 'org-1',
              orgName: 'Chamber',
              orgKind: 'solo',
              role: 'owner',
            ),
          ],
        ),
      );
      await firstValue(container, keepSetProvider, (k) => k.length == 2);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await cachedIds(), ['d1', 'o1']);
      expect(api.callNames, isEmpty);
    });

    test('no organisation any more: the cache empties, offline too', () async {
      await insertRows(db, 'documents', [
        {'id': 'd1', 'org_id': 'org-1', 'title': 'x', 'upload_status': 'ready'},
      ]);
      await files.open(doc('d1'), orgId: 'org-1');
      files.close('d1');
      api.offline = true;
      final container = dbContainer(
        db,
        overrides: [
          apiClientProvider.overrideWithValue(api),
          appSupportDirProvider.overrideWithValue(root),
          offlineFilesProvider.overrideWithValue(files),
          accountProvider.overrideWith(_NoOrg.new),
        ],
      );
      await container.read(accountProvider.future);
      container.listen(offlineKeeperProvider, (_, _) {});
      for (var i = 0; i < 500 && (await cachedIds()).isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await cachedIds(), isEmpty);
      expect(filesDir(root, 'offline').listSync(), isEmpty);
    });

    test(
      'AC: a document marked Keep offline opens with the network off',
      () async {
        await insertRows(db, 'documents', [
          {
            'id': 'd1',
            'org_id': 'org-1',
            'title': 'Writ petition',
            'kind': 'pleading',
            'mime': pdfMime,
            'upload_status': 'ready',
          },
        ]);
        final container = dbContainer(
          db,
          overrides: [
            apiClientProvider.overrideWithValue(api),
            appSupportDirProvider.overrideWithValue(root),
          ],
        );
        await container
            .read(caseWriterProvider)
            .setKeepOffline('d1', keep: true);
        // The keeper runs from the shell; here it is listened to directly.
        container.listen(offlineKeeperProvider, (_, _) {});
        expect(
          await firstValue(
            container,
            offlineIdsProvider,
            (ids) => ids.contains('d1'),
          ),
          contains('d1'),
        );
        expect(
          (await firstValue(container, documentProvider('d1')))?.offline,
          isTrue,
        );

        api
          ..offline = true
          ..calls.clear();
        final file = await container
            .read(offlineFilesProvider)
            .open(
              documentFile(
                (await firstValue(container, documentProvider('d1')))!,
              ),
              orgId: 'org-1',
            );
        expect(file.readAsStringSync(), startsWith('%PDF'));
        expect(api.callNames, isEmpty);
      },
    );
  });
}

/// An account that loads when [_account] completes.
class _Later extends AccountController {
  _Later(this._account);

  final Future<Account?> _account;

  @override
  Future<Account?> build() => _account;
}

/// An account that has loaded with no organisation (left or removed).
class _NoOrg extends AccountController {
  @override
  Future<Account?> build() async => const Account(id: 'user-1');
}
