/// Documents (spec §4.3): the org's documents, uploads waiting in the queue, the upload checks, and the app's own
/// folder for queued and offline files. The case's documents are [caseDocumentsProvider]; the writes (Keep
/// offline, rename, delete) are [CaseWriter]'s; the queue and the offline cache are `document_files.dart`.
library;

import 'dart:io';
import 'dart:math' show min;

import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/search_key.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/case_label.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show StreamProviderFamily;

const pdfMime = 'application/pdf';
const docxMime =
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document';

/// Upload types by extension (spec §4.3 "Upload sources"): the four the API takes.
const Map<String, String> uploadTypes = {
  'pdf': pdfMime,
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'docx': docxMime,
};

/// 50 MB per file (spec §4.3 "Limits"): the API's and the storage bucket's limit.
const maxUploadBytes = 52428800;

/// The file extension the app names a file of [mime] with.
String extensionOf(String? mime) => switch (mime) {
  'image/jpeg' => 'jpg',
  'image/png' => 'png',
  docxMime => 'docx',
  _ => 'pdf',
};

/// The type [head] (a file's first bytes) shows: PDF (`%PDF-` within the first 1 KB), JPEG, PNG, or DOCX (a ZIP
/// whose first entry is an Office package part, so a renamed .zip or .apk isn't one); null for anything else.
/// ponytail: any Office package passes (a renamed .xlsx too); read the ZIP's directory for `word/` if that matters.
String? _sniff(List<int> head) {
  bool starts(List<int> magic) =>
      head.length >= magic.length &&
      Iterable<int>.generate(magic.length).every((i) => head[i] == magic[i]);
  if (starts(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (starts(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return 'image/png';
  }
  if (starts(const [0x50, 0x4B, 0x03, 0x04])) {
    // The first local file header's name: its length at bytes 26–27, the name from byte 30.
    if (head.length < 30) return null;
    final end = 30 + (head[26] | head[27] << 8);
    final name = String.fromCharCodes(head.sublist(30, min(end, head.length)));
    const parts = ['[Content_Types].xml', '_rels/', 'docProps/', 'word/'];
    return parts.any(name.startsWith) ? docxMime : null;
  }
  final pdf = String.fromCharCodes(head.take(1024)).contains('%PDF-');
  return pdf ? pdfMime : null;
}

/// Whether a picked file can be uploaded (spec §4.3), checked before it is copied or sent: [name]'s extension and
/// its first bytes ([head], up to 1 KB) agree on PDF, JPG, PNG or DOCX, and it is 1 byte to 50 MB. Gives the mime
/// to declare, or an error code for `errorText`: EMPTY_FILE, UNSUPPORTED_FILE_TYPE, FILE_TOO_LARGE.
({String? mime, String? error}) uploadCheck(
  String name,
  int size,
  List<int> head,
) {
  final dot = name.lastIndexOf('.');
  final byName = dot < 0
      ? null
      : uploadTypes[name.substring(dot + 1).toLowerCase()];
  if (size <= 0) return (mime: null, error: 'EMPTY_FILE');
  if (byName == null || _sniff(head) != byName) {
    return (mime: null, error: 'UNSUPPORTED_FILE_TYPE');
  }
  if (size > maxUploadBytes) return (mime: null, error: 'FILE_TOO_LARGE');
  return (mime: byName, error: null);
}

/// [uploadCheck] on the file at [path]; [name] is the picked file's name when the path doesn't carry it. A folder
/// (dropped on Windows) is UNSUPPORTED_FILE_TYPE; a file that can't be read (gone, locked) FILE_UNREADABLE.
Future<({String? mime, String? error})> checkUploadFile(
  String path, {
  String? name,
}) async {
  if (FileSystemEntity.isDirectorySync(path)) {
    return (mime: null, error: 'UNSUPPORTED_FILE_TYPE');
  }
  try {
    final file = File(path);
    final size = await file.length();
    final head = size == 0
        ? const <int>[]
        : await file
              .openRead(0, size < 1024 ? size : 1024)
              .expand((b) => b)
              .toList();
    return uploadCheck(name ?? path, size, head);
  } on FileSystemException {
    return (mime: null, error: 'FILE_UNREADABLE');
  }
}

/// A picked file's name without folder or extension: the upload sheet's default title.
String titleFromFileName(String name) {
  final base = name.split(RegExp(r'[\\/]')).last;
  final dot = base.lastIndexOf('.');
  return (dot > 0 ? base.substring(0, dot) : base).trim();
}

/// The app's private support folder (set in main()); null in tests and builds without sync. Queued uploads live
/// in its `uploads` folder and offline copies in `offline` (spec §4.3, §15.4), both deleted at sign-out.
final appSupportDirProvider = Provider<Directory?>((_) => null);

/// [root]'s [name] folder, with the platform's separators.
Directory filesDir(Directory root, String name) =>
    Directory('${root.path}${Platform.pathSeparator}$name');

/// Sign-out (`Session.forget`, after the transfers are stopped): deletes queued uploads and offline copies, file by
/// file, so one that is locked doesn't keep the rest. Their tables go with the database.
/// ponytail: a file still held open (Windows: a viewer open as the session ended, or another app) stays until the
/// keeper's next sweep of `offline` or the next sign-out.
void clearDeviceFiles(Directory? root) {
  if (root == null) return;
  for (final name in ['uploads', 'offline']) {
    final dir = filesDir(root, name);
    if (!dir.existsSync()) continue;
    dir.listSync().whereType<File>().forEach(deleteFile);
    try {
      dir.deleteSync();
    } on FileSystemException {
      // A locked file is still in it; see above.
    }
  }
}

/// Deletes [file] if it can; false when it is still there (Windows won't delete a file another app holds open).
bool deleteFile(File file) {
  try {
    if (file.existsSync()) file.deleteSync();
    return true;
  } on FileSystemException {
    return false;
  }
}

/// Every live document of the current org, newest first (the Documents screen), with case labels, the user's Keep
/// offline and the offline state. Empty without an org or sync.
/// ponytail: one query over every document; page it in SQL if an org's list gets slow.
final orgDocumentsProvider = StreamProvider<List<CaseDocument>>((ref) {
  final db = ref.watch(syncDatabaseProvider);
  final org = ref.watch(currentOrgIdProvider);
  if (db == null || org == null) return Stream.value(const []);
  return db
      .watch(
        '$documentSql and d.org_id = ?2 order by d.created_at desc, d.id',
        parameters: [ref.watch(currentUserIdProvider), org],
      )
      .map((rows) => rows.map(CaseDocument.fromRow).toList());
});

/// One document of the current org (the viewer); null when it isn't on the device (deleted, or not this org's).
final StreamProviderFamily<CaseDocument?, String> documentProvider =
    StreamProvider.autoDispose.family<CaseDocument?, String>((ref, id) {
      final db = ref.watch(syncDatabaseProvider);
      final org = ref.watch(currentOrgIdProvider);
      if (db == null || org == null) return Stream.value(null);
      return db
          .watch(
            '$documentSql and d.org_id = ?2 and d.id = ?3',
            parameters: [ref.watch(currentUserIdProvider), org, id],
          )
          .map(
            (rows) => rows.isEmpty ? null : CaseDocument.fromRow(rows.first),
          );
    });

/// An upload in the local queue (spec §4.3; ADR 0016): "Waiting to upload", "Uploading 40%" (with
/// `uploadProgressProvider`), or failed with [error] and a Remove action. It stands for its document in the lists
/// until the server has the file; then the synced documents row takes over.
@immutable
class QueuedUpload {
  const QueuedUpload({
    required this.id,
    required this.title,
    required this.kind,
    required this.mime,
    this.sizeBytes,
    this.matterId,
    this.caseLabel,
    this.state = 'queued',
    this.error,
    this.createdAt,
  });

  factory QueuedUpload.fromRow(Map<String, dynamic> r) {
    final label = caseLabelOf(
      caseType: r['case_type'] as String?,
      caseNumber: r['case_number'] as String?,
      caseYear: r['case_year'] as int?,
      cnr: r['cnr'] as String?,
    );
    return QueuedUpload(
      id: r['id'] as String,
      title: r['title'] as String? ?? '',
      kind: r['kind'] as String? ?? 'other',
      mime: r['mime'] as String? ?? pdfMime,
      sizeBytes: r['size_bytes'] as int?,
      matterId: r['matter_id'] as String?,
      caseLabel: label.isEmpty ? r['matter_title'] as String? : label,
      state: r['state'] as String? ?? 'queued',
      error: r['error'] as String?,
      createdAt: parseInstant(r['created_at']),
    );
  }

  /// The queue item (not the document's id).
  final String id;

  /// Never log it.
  final String title;
  final String kind;
  final String mime;
  final int? sizeBytes;
  final String? matterId;
  final String? caseLabel;

  /// `queued`, `uploading` or `failed`.
  final String state;

  /// The last error's code (for `errorText`): why it failed, or why a waiting one is waiting (e.g. NETWORK).
  final String? error;
  final DateTime? createdAt;

  bool get failed => state == 'failed';
}

/// The current org's uploads in the queue, newest first; a case's are those with its [QueuedUpload.matterId].
final queuedUploadsProvider = StreamProvider<List<QueuedUpload>>((ref) {
  final db = ref.watch(syncDatabaseProvider);
  final org = ref.watch(currentOrgIdProvider);
  if (db == null || org == null) return Stream.value(const []);
  return db
      .watch(
        'select q.id, q.title, q.kind, q.mime, q.size_bytes, q.matter_id, q.state, q.error, q.created_at, '
        'm.case_type, m.case_number, m.case_year, m.cnr, m.title as matter_title from upload_queue q '
        'left join matters m on m.id = q.matter_id and m.deleted_at is null '
        'where q.org_id = ? order by q.created_at desc, q.id',
        parameters: [org],
      )
      .map((rows) => rows.map(QueuedUpload.fromRow).toList());
});

/// Ids of the files on this device (documents' and orders'): "Available offline" where a row has no
/// [CaseDocument.offline], e.g. an order on the timeline.
final offlineIdsProvider = StreamProvider<Set<String>>((ref) {
  final db = ref.watch(syncDatabaseProvider);
  if (db == null) return Stream.value(const {});
  return db
      .watch('select id from offline_files')
      .map((rows) => {for (final r in rows) r['id'] as String});
});

/// The Documents screen's search and filters (spec §4.3): type (one of [documentKinds]) and case; null = all.
@immutable
class DocumentFilter {
  const DocumentFilter({this.query = '', this.kind, this.matterId});

  final String query;
  final String? kind;
  final String? matterId;

  static const _keep = Object();

  /// Pass null to clear a filter; leave it out to keep it.
  DocumentFilter copyWith({
    String? query,
    Object? kind = _keep,
    Object? matterId = _keep,
  }) => DocumentFilter(
    query: query ?? this.query,
    kind: kind == _keep ? this.kind : kind as String?,
    matterId: matterId == _keep ? this.matterId : matterId as String?,
  );

  @override
  bool operator ==(Object other) =>
      other is DocumentFilter &&
      other.query == query &&
      other.kind == kind &&
      other.matterId == matterId;

  @override
  int get hashCode => Object.hash(query, kind, matterId);
}

/// Titles' search keys, cached per row object (one per data emission), never per keystroke.
final _titleKeys = Expando<String>();

/// Whether an item with `title` matches [query]: literally, or every word's [searchKey] is in the title's
/// ("sharma" finds "शर्मा").
bool Function(Object item, String title) _titleMatcher(String query) {
  final text = query.trim().toLowerCase();
  final keys = searchKey(query).split(' ').where((k) => k.isNotEmpty).toList();
  return (item, title) =>
      text.isEmpty ||
      title.toLowerCase().contains(text) ||
      (keys.isNotEmpty &&
          keys.every((_titleKeys[item] ??= searchKey(title)).contains));
}

/// [docs] that pass [f], in their order.
List<CaseDocument> filterDocuments(
  Iterable<CaseDocument> docs,
  DocumentFilter f,
) {
  final title = _titleMatcher(f.query);
  return [
    for (final d in docs)
      if ((f.kind == null || d.kind == f.kind) &&
          (f.matterId == null || d.matterId == f.matterId) &&
          title(d, d.title))
        d,
  ];
}

/// [uploads] that pass [f], in their order.
List<QueuedUpload> filterUploads(
  Iterable<QueuedUpload> uploads,
  DocumentFilter f,
) {
  final title = _titleMatcher(f.query);
  return [
    for (final q in uploads)
      if ((f.kind == null || q.kind == f.kind) &&
          (f.matterId == null || q.matterId == f.matterId) &&
          title(q, q.title))
        q,
  ];
}
