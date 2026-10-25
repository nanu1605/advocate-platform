import 'dart:async';
import 'dart:io';

import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/document_files.dart';
import 'package:advocate_app/data/documents.dart';
import 'package:advocate_app/features/case_page/links.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/pdf_viewer.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';

/// The pages of the PDF at a path: pdfrx in the app; tests give a stand-in, as PDFium doesn't run under flutter test.
final pdfPagesProvider = Provider<PdfPages Function(String path)>(
  (_) => PdfrxPages.new,
);

/// Opens a local file in another app, the platform's way (DOCX has no viewer here): Windows hands the file to
/// its default app; Android (and iOS) through a content URI (open_filex), as `url_launcher` can't share an app
/// file. False when nothing opened it. Tests override it.
final openFileProvider =
    Provider<Future<bool> Function(String path, String mime)>(
      (_) => (path, mime) async {
        if (defaultTargetPlatform == TargetPlatform.windows) {
          return await launchUrl(Uri.file(path));
        }
        return (await OpenFilex.open(path, type: mime)).type == ResultType.done;
      },
    );

/// What the viewer shows: a title, and the file to open or why it can't (a code for `errorText`, or MISSING).
typedef _Target = ({
  String title,
  FileRef? file,
  String? problem,
  CaseDocument? document,
  bool unread,
});

/// The document viewer (spec §4.3, §5.2): a document (`/documents/:id`) or a case's order
/// (`/cases/:id/orders/:orderId`: the court's copy, else its uploaded document). The file comes from the offline
/// cache when it is on the device, else it downloads (with progress and Cancel) into the cache, which keeps the
/// last ones opened; offline without a copy it says so. PDFs open in the kit's viewer (zoom, find, selection,
/// pages), images can be zoomed, and Word files open in another app. An order is marked read once its file is
/// here. A document's Keep offline toggle is in the app bar.
class ViewerScreen extends ConsumerStatefulWidget {
  const ViewerScreen.document(String this.documentId, {super.key})
    : matterId = null,
      orderId = null;

  const ViewerScreen.order({
    required String this.matterId,
    required String this.orderId,
    super.key,
  }) : documentId = null;

  final String? documentId;
  final String? matterId;
  final String? orderId;

  @override
  ConsumerState<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends ConsumerState<ViewerScreen> {
  FileRef? _fileRef;
  File? _file;
  double? _progress;
  ApiException? _error;
  CancelToken? _cancel;
  OfflineFiles? _files;
  PdfPages? _pages;

  @override
  void dispose() {
    _cancel?.cancel();
    if ((_fileRef, _file) case (final opened?, _?)) _files?.close(opened.id);
    _pages?.dispose();
    super.dispose();
  }

  /// Opens [file]: the cached copy, else a download into the cache. [unread]: an order to mark read once it's here.
  void _open(FileRef file, {required bool unread}) {
    final files = ref.read(offlineFilesProvider);
    _files = files;
    final writer = ref.read(caseWriterProvider);
    final org = ref.read(currentOrgIdProvider);
    final cancel = _cancel = CancelToken();
    _fileRef = file;
    _error = null;
    _progress = null;
    unawaited(() async {
      try {
        if (org == null) throw const ApiException('NOT_A_MEMBER');
        final opened = await files.open(
          file,
          orgId: org,
          cancel: cancel,
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
        );
        if (!mounted) return files.close(file.id);
        setState(() => _file = opened);
        if (widget.orderId case final id? when unread) {
          await writer.markOrderRead(id);
        }
      } on ApiException catch (e) {
        if (mounted) setState(() => _error = e);
      } on Object {
        // Not the network's (a database or file error): the generic message, with Retry.
        if (mounted) setState(() => _error = const ApiException('ERROR'));
      }
    }());
  }

  _Target? _target(AppLocalizations l) {
    final orderId = widget.orderId;
    if (orderId == null) return _document(l, widget.documentId!, null);
    final orders = ref.watch(caseOrdersProvider(widget.matterId!));
    if (orders.hasError) {
      return _problem(l.casePageOrder, 'ERROR');
    }
    final order = orders.value?.where((o) => o.id == orderId).firstOrNull;
    if (!orders.hasValue) return null;
    if (order == null) return _problem(l.casePageOrder, 'MISSING');
    final title = order.title ?? l.casePageOrder;
    if (order.hasCourtCopy) {
      return (
        title: title,
        file: orderFile(order.id),
        problem: null,
        document: null,
        unread: !order.read,
      );
    }
    return switch (order.documentId) {
      final id? => _document(l, id, (title: title, unread: !order.read)),
      null => _problem(title, 'ORDER_PDF_UNAVAILABLE'),
    };
  }

  /// A document's file, or why it can't open; [order] when it is an order's uploaded copy.
  _Target? _document(
    AppLocalizations l,
    String id,
    ({String title, bool unread})? order,
  ) {
    final async = ref.watch(documentProvider(id));
    if (async.hasError) return _problem(l.navDocuments, 'ERROR');
    if (!async.hasValue) return null;
    final d = async.value;
    if (d == null) {
      return _problem(
        order?.title ?? l.navDocuments,
        order == null ? 'MISSING' : 'ORDER_PDF_UNAVAILABLE',
      );
    }
    return (
      title: order?.title ?? d.title,
      file: d.ready ? documentFile(d) : null,
      problem: switch (d.uploadStatus) {
        'pending' => 'DOCUMENT_NOT_READY',
        'quarantined' => 'DOCUMENT_QUARANTINED',
        _ => null,
      },
      document: order == null ? d : null,
      unread: order?.unread ?? false,
    );
  }

  _Target _problem(String title, String code) =>
      (title: title, file: null, problem: code, document: null, unread: false);

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final target = _target(l);
    if (target?.file case final file? when _fileRef == null) {
      _open(file, unread: target!.unread);
    }
    final doc = target?.document;
    return Scaffold(
      appBar: AppBar(
        title: Text(target?.title ?? l.navDocuments),
        actions: [
          if (doc != null && doc.ready)
            IconButton(
              isSelected: doc.keepOffline,
              tooltip: l.docsKeepOffline,
              icon: const Icon(AppIcons.downloadSimple),
              selectedIcon: Icon(
                AppIcons.downloadSimpleFill,
                color: context.colors.of(StatusKind.success).fg,
              ),
              onPressed: () => unawaited(
                ref
                    .read(caseWriterProvider)
                    .setKeepOffline(doc.id, keep: !doc.keepOffline),
              ),
            ),
        ],
      ),
      body: _body(context, target),
    );
  }

  Widget _body(BuildContext context, _Target? target) {
    final l = context.l10n;
    final file = _file;
    final opened = _fileRef;
    if (file != null && opened != null) {
      return switch (opened.mime) {
        pdfMime => AppPdfViewer(
          _pages ??= ref.read(pdfPagesProvider)(file.path),
        ),
        'image/jpeg' || 'image/png' => InteractiveViewer(
          maxScale: 6,
          child: Center(
            child: Image.file(
              file,
              semanticLabel: target?.title,
              errorBuilder: (context, _, _) =>
                  _message(context, l.docsCannotShow),
            ),
          ),
        ),
        _ => _OpenElsewhere(file: file, mime: opened.mime),
      };
    }
    if (_error case final e?) {
      return ErrorState(
        message: switch (e.code) {
          // Offline without a copy: what will bring it (spec §5.10: "what you can do" must be possible).
          'NETWORK' when widget.orderId != null => l.docsNoCopyOrder,
          'NETWORK' when target?.document?.keepOffline ?? false =>
            l.docsNoCopyKept,
          'NETWORK' => l.docsNoCopy,
          'CANCELLED' => l.docsCancelled,
          _ => errorText(l, e),
        },
        onRetry: () => setState(() {
          if (target?.file case final file?) {
            _open(file, unread: target!.unread);
          }
        }),
      );
    }
    if (target != null && target.file == null) {
      return ErrorState(
        message: target.problem == 'MISSING'
            ? l.docsMissing
            : errorText(l, target.problem),
      );
    }
    // Static until bytes arrive (spec §5.4: no spinner for a wait that may be long).
    final progress = _progress;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(
              value: progress ?? 0,
              color: context.colors.of(StatusKind.listed).fg,
              backgroundColor: context.colors.of(StatusKind.listed).bg,
            ),
            const SizedBox(height: 16),
            Text(
              progress == null
                  ? l.docsOpening
                  : l.docsDownloading((progress * 100).floor()),
              style: context.text.bodyLarge,
            ),
            if (progress != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () => _cancel?.cancel(),
                child: Text(l.cancel),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

Widget _message(BuildContext context, String text) => Center(
  child: Padding(
    padding: const EdgeInsets.all(32),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: context.text.bodyLarge,
    ),
  ),
);

/// A Word file: no viewer here (spec §4.3), so it opens in another app on the device.
class _OpenElsewhere extends ConsumerWidget {
  const _OpenElsewhere({required this.file, required this.mime});

  final File file;
  final String mime;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.fileDoc, size: 56, color: context.colors.ink3),
            const SizedBox(height: 16),
            Text(
              l.docsDocxNote,
              textAlign: TextAlign.center,
              style: context.text.bodyLarge,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () async {
                final opened = await ref
                    .read(openFileProvider)(file.path, mime)
                    .catchError((Object _) => false);
                if (!opened && context.mounted) {
                  showMessage(context, l.docsOpenFailed);
                }
              },
              icon: const Icon(AppIcons.arrowSquareOut),
              label: Text(l.docsOpenElsewhere),
            ),
          ],
        ),
      ),
    );
  }
}
