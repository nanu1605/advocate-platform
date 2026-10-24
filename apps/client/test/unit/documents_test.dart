import 'dart:io';
import 'dart:ui' show Locale;

import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/document_files.dart';
import 'package:advocate_app/data/documents.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:powersync/powersync.dart' hide SyncStatus;

import '../helpers.dart';
import 'sync_db.dart';

const _pdf = [0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37]; // %PDF-1.7
const _jpg = [0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46];
const _png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// A ZIP's first local file header, naming its first entry [name] (a DOCX's is an Office package part).
List<int> _zip(String name) => [
  ...[0x50, 0x4B, 0x03, 0x04, 0x14, 0, 0x06, 0],
  ...List.filled(18, 0),
  name.length,
  0,
  0,
  0,
  ...name.codeUnits,
];

/// Documents: the upload checks, the lists' search, and the document reads and writes (spec §4.3, §9.3; ADR 0016).
void main() {
  // IST now listens for the app resuming.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('upload checks', () {
    test(
      'the extension and the first bytes must agree on one of four types',
      () {
        expect(uploadCheck('Writ petition.pdf', 1000, _pdf), (
          mime: pdfMime,
          error: null,
        ));
        expect(uploadCheck('scan.JPG', 1000, _jpg).mime, 'image/jpeg');
        expect(uploadCheck('scan.jpeg', 1000, _jpg).mime, 'image/jpeg');
        expect(uploadCheck('photo.png', 1000, _png).mime, 'image/png');
        for (final first in [
          '[Content_Types].xml',
          '_rels/.rels',
          'docProps/app.xml',
          'word/document.xml',
        ]) {
          expect(uploadCheck('reply.docx', 1000, _zip(first)).mime, docxMime);
        }
        // A PDF with a few bytes before its header still is one.
        expect(
          uploadCheck('old.pdf', 1000, [0xEF, 0xBB, 0xBF, ..._pdf]).mime,
          pdfMime,
        );
        for (final (name, head) in [
          ('renamed.pdf', _png),
          ('photo.png', _jpg),
          ('setup.exe', [0x4D, 0x5A, 0x90, 0]),
          // A program renamed as a PDF.
          ('order.pdf', [0x4D, 0x5A, 0x90, 0, ...List.filled(1100, 0)]),
          ('notes.txt', 'hello'.codeUnits),
          ('reply.doc', [0xD0, 0xCF, 0x11, 0xE0]),
          ('no-extension', _pdf),
          // Any other ZIP renamed: an archive, an Android app; a header cut short.
          ('photos.docx', _zip('photos/IMG_1.jpg')),
          ('app.docx', _zip('AndroidManifest.xml')),
          ('short.docx', [0x50, 0x4B, 0x03, 0x04, 0x14, 0]),
        ]) {
          expect(
            uploadCheck(name, 1000, head).error,
            'UNSUPPORTED_FILE_TYPE',
            reason: name,
          );
        }
      },
    );

    test('1 byte to 50 MB', () {
      expect(uploadCheck('a.pdf', 0, const []).error, 'EMPTY_FILE');
      expect(uploadCheck('a.pdf', maxUploadBytes, _pdf).error, isNull);
      expect(
        uploadCheck('a.pdf', maxUploadBytes + 1, _pdf).error,
        'FILE_TOO_LARGE',
      );
      expect(uploadCheck('a.pdf', 60 << 20, _pdf).error, 'FILE_TOO_LARGE');
    });

    test('a file on disk is checked by its name and first bytes', () async {
      final dir = Directory.systemTemp.createTempSync('pairavi_check');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/picked.tmp')
        ..writeAsBytesSync([..._png, 1, 2]);
      expect(
        (await checkUploadFile(file.path, name: 'Photo.PNG')).mime,
        'image/png',
      );
      expect((await checkUploadFile(file.path)).error, 'UNSUPPORTED_FILE_TYPE');
      final empty = File('${dir.path}/empty.pdf')..writeAsBytesSync([]);
      expect((await checkUploadFile(empty.path)).error, 'EMPTY_FILE');
      // Windows drops folders too; a file can go before it is checked.
      final folder = Directory('${dir.path}/Case papers.pdf')..createSync();
      expect(
        (await checkUploadFile(folder.path)).error,
        'UNSUPPORTED_FILE_TYPE',
      );
      expect(
        (await checkUploadFile('${dir.path}/gone.pdf')).error,
        'FILE_UNREADABLE',
      );
    });

    test('the default title is the file name without its extension', () {
      expect(
        titleFromFileName('Writ petition.final.pdf'),
        'Writ petition.final',
      );
      expect(titleFromFileName(r'C:\Users\a\Scan 12.jpg'), 'Scan 12');
      expect(titleFromFileName('/storage/emulated/0/reply.docx'), 'reply');
      expect(titleFromFileName('.hidden'), '.hidden');
    });

    test('every check and queue failure has words in both languages', () {
      for (final lang in ['en', 'hi']) {
        final l = lookupAppLocalizations(Locale(lang));
        for (final code in [
          'EMPTY_FILE',
          'UNSUPPORTED_FILE_TYPE',
          'FILE_TOO_LARGE',
          'FILE_MISSING',
        ]) {
          expect(errorText(l, code), isNot(l.errorGeneric), reason: code);
        }
      }
    });
  });

  test('search and filters: type, case and the title across scripts', () {
    const docs = [
      CaseDocument(
        id: 'a',
        title: 'शर्मा का शपथ पत्र',
        kind: 'evidence',
        matterId: 'm1',
      ),
      CaseDocument(
        id: 'b',
        title: 'Writ petition',
        kind: 'pleading',
        matterId: 'm1',
      ),
      CaseDocument(id: 'c', title: 'Sharma reply', kind: 'pleading'),
    ];
    List<String> ids(DocumentFilter f) =>
        filterDocuments(docs, f).map((d) => d.id).toList();
    expect(ids(const DocumentFilter()), ['a', 'b', 'c']);
    expect(ids(const DocumentFilter(query: 'sharma')), ['a', 'c']);
    expect(ids(const DocumentFilter(query: 'WRIT')), ['b']);
    expect(ids(const DocumentFilter(kind: 'pleading')), ['b', 'c']);
    expect(ids(const DocumentFilter(matterId: 'm1', query: 'sharma')), ['a']);
    const queued = [
      QueuedUpload(id: 'q', title: 'शर्मा', kind: 'other', mime: pdfMime),
    ];
    expect(
      filterUploads(queued, const DocumentFilter(query: 'sharma')),
      hasLength(1),
    );
    expect(filterUploads(queued, const DocumentFilter(kind: 'order')), isEmpty);
    expect(
      const DocumentFilter(kind: 'order').copyWith(kind: null),
      const DocumentFilter(),
    );
  });

  group('database', () {
    late PowerSyncDatabase db;

    Map<String, Object?> doc(String id, [Map<String, Object?> f = const {}]) =>
        {
          'id': id,
          'org_id': 'org-1',
          'title': 'Document $id',
          'kind': 'pleading',
          'mime': pdfMime,
          'size_bytes': 1024,
          'upload_status': 'ready',
          ...f,
        };

    setUp(() async {
      db = await openTestDb();
      await insertRows(db, 'matters', [
        for (final id in ['m1', 'm2', 'm3'])
          {
            'id': id,
            'org_id': 'org-1',
            'case_type': 'WP',
            'case_number': id.substring(1),
            'case_year': 2024,
            'status': 'active',
            'tracking': 'auto',
            'title': 'Sharma v. State of MP',
          },
        {
          'id': 'm-manual',
          'org_id': 'org-1',
          'status': 'active',
          'tracking': 'manual',
          'title': 'Patel v. Patel',
        },
      ]);
      await insertRows(db, 'documents', [
        doc('d1', {'matter_id': 'm1', 'created_at': '2026-11-01T10:00:00Z'}),
        doc('d2', {
          'created_at': '2026-11-03T10:00:00Z',
          'upload_status': 'pending',
        }),
        doc('d3', {
          'matter_id': 'm-manual',
          'created_at': '2026-11-02T10:00:00Z',
        }),
        doc('d-gone', {'deleted_at': '2026-11-02T00:00:00Z'}),
        doc('d-queued', {'upload_status': 'pending'}),
        {...doc('d-other'), 'org_id': 'org-2'},
      ]);
      await insertRows(db, 'document_offline_prefs', [
        {
          'id': 'p1',
          'org_id': 'org-1',
          'user_id': 'user-1',
          'document_id': 'd1',
          'keep_offline': 1,
        },
        {
          'id': 'p2',
          'org_id': 'org-1',
          'user_id': 'user-2',
          'document_id': 'd3',
          'keep_offline': 1,
        },
      ]);
      await clearPendingWrites(db);
      await db.execute(
        "insert into offline_files (id, kind, org_id, path, size) values ('d3', 'document', 'org-1', 'x', 1)",
      );
      await db.execute(
        'insert into upload_queue (id, org_id, title, kind, mime, document_id, state) '
        "values ('q1', 'org-1', 'Scan', 'other', 'application/pdf', 'd-queued', 'uploading')",
      );
    });

    test(
      'the org list: live documents newest first, with case, Keep offline and '
      'offline copy; a queued one shows as its queue item',
      () async {
        final c = dbContainer(db);
        final docs = await firstValue(c, orgDocumentsProvider);
        expect(docs.map((d) => d.id), ['d2', 'd3', 'd1']);
        final byId = {for (final d in docs) d.id: d};
        expect(
          (byId['d1']!.caseLabel, byId['d1']!.matterId),
          ('WP 1/2024', 'm1'),
        );
        // A manual case without a number is labelled by its title; no case, no label.
        expect(byId['d3']!.caseLabel, 'Patel v. Patel');
        expect(byId['d2']!.caseLabel, isNull);
        // Keep offline is the user's own; offline is what the device holds.
        expect([for (final d in docs) d.keepOffline], [false, false, true]);
        expect([for (final d in docs) d.offline], [false, true, false]);
        expect(byId['d2']!.ready, isFalse);

        final queue = await firstValue(c, queuedUploadsProvider);
        expect(queue.single.id, 'q1');
        expect(queue.single.state, 'uploading');

        expect(
          (await firstValue(c, caseDocumentsProvider('m1'))).single.keepOffline,
          isTrue,
        );
        expect((await firstValue(c, documentProvider('d3')))?.offline, isTrue);
        expect(await firstValue(c, documentProvider('d-other')), isNull);
        expect(await firstValue(c, offlineIdsProvider), {'d3'});
      },
    );

    test(
      'Keep offline writes the user own row; rename, re-file and delete send '
      'only device columns',
      () async {
        final c = dbContainer(db);
        final w = c.read(caseWriterProvider);

        await w.setKeepOffline('d2', keep: true);
        final put = await lastWrite(db);
        expect(put.sublist(0, 2), [UpdateType.put, 'document_offline_prefs']);
        expect(put[3], {
          'org_id': 'org-1',
          'user_id': 'user-1',
          'document_id': 'd2',
          'keep_offline': 1,
        });
        // On again changes nothing; off deletes the row.
        await w.setKeepOffline('d2', keep: true);
        expect(await pendingWrites(db), hasLength(1));
        await w.setKeepOffline('d1', keep: false);
        expect(await lastWrite(db), [
          UpdateType.delete,
          'document_offline_prefs',
          'p1',
          null,
        ]);
        await db.execute(
          "update document_offline_prefs set keep_offline = 0 where id = 'p2'",
        );
        await clearPendingWrites(db);

        await w.editDocument(
          'd2',
          title: ' Reply ',
          kind: 'correspondence',
          matterId: 'm2',
        );
        expect(await lastWrite(db), [
          UpdateType.patch,
          'documents',
          'd2',
          {'title': 'Reply', 'kind': 'correspondence', 'matter_id': 'm2'},
        ]);
        await w.deleteDocument('d2');
        expect(await lastWrite(db), [
          UpdateType.patch,
          'documents',
          'd2',
          {'deleted_at': testNow.toIso8601String()},
        ]);
      },
    );

    test("the keeper keeps the user's ready Keep offline documents and the latest "
        "order of each case on today's and tomorrow's diary", () async {
      await insertRows(db, 'document_offline_prefs', [
        // Still being checked: nothing to fetch yet.
        {
          'id': 'p3',
          'org_id': 'org-1',
          'user_id': 'user-1',
          'document_id': 'd2',
          'keep_offline': 1,
        },
      ]);
      await db.execute(
        "update matters set next_hearing_date = '$testToday' where id in ('m1', 'm2')",
      );
      await db.execute(
        "update matters set next_hearing_date = '$testTomorrow' where id = 'm3'",
      );
      await insertRows(db, 'orders', [
        for (final (id, matter, date, court, docId) in [
          ('o1-old', 'm1', '2026-09-01', 'co-1', null),
          ('o1', 'm1', '2026-10-28', 'co-2', null),
          // No court copy, but an uploaded document: that document.
          ('o2', 'm2', '2026-10-20', null, 'd3'),
          // Neither: nothing to keep.
          ('o3', 'm3', '2026-10-21', null, null),
        ])
          {
            'id': id,
            'org_id': 'org-1',
            'matter_id': matter,
            'order_date': date,
            'court_order_id': court,
            'document_id': docId,
          },
      ]);
      final c = dbContainer(db);
      // The very first set already has the diary's orders: one without them would have the keeper delete the
      // cached orders, then fetch them again.
      final kept = await firstValue(c, keepSetProvider);
      expect(kept.toSet(), {
        (kind: 'document', id: 'd1', mime: pdfMime),
        (kind: 'order', id: 'o1', mime: pdfMime),
        (kind: 'document', id: 'd3', mime: pdfMime),
      });
    });
  });
}
