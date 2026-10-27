import 'dart:async';

import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/document_files.dart';
import 'package:advocate_app/data/documents.dart';
import 'package:advocate_app/features/case_page/case_page_text.dart';
import 'package:advocate_app/features/case_page/links.dart';
import 'package:advocate_app/features/case_page/sheet_form.dart';
import 'package:advocate_app/features/case_page/summary_sheet.dart';
import 'package:advocate_app/features/documents/upload_flow.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/sheets.dart';
import 'package:advocate_app/ui/tiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// A document on the Documents screen or a case's Documents tab (spec §4.3): type, size, case ([showCase]), the
/// safety check, "Available offline", and the user's Keep offline toggle; the menu edits its details or deletes it
/// with Undo, and has a ready order's Summary (spec F07). A ready file opens in the viewer (over the list, so Back
/// returns to it); one being checked or blocked says why it can't open.
class DocumentRow extends ConsumerWidget {
  const DocumentRow(this.doc, {this.showCase = true, super.key});

  final CaseDocument doc;
  final bool showCase;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final d = doc;
    return DocumentTile(
      title: d.title,
      kind: documentLine(
        l,
        kind: d.kind,
        sizeBytes: d.sizeBytes,
        caseLabel: showCase ? d.caseLabel : null,
      ),
      mime: d.mime,
      pages: d.pages,
      offline: d.offline,
      state: switch (d.uploadStatus) {
        'pending' => DocState.checking,
        'quarantined' => DocState.blocked,
        _ => null,
      },
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (d.ready)
            IconButton(
              isSelected: d.keepOffline,
              tooltip: l.docsKeepOffline,
              icon: const Icon(AppIcons.downloadSimple),
              selectedIcon: Icon(
                AppIcons.downloadSimpleFill,
                color: context.colors.of(StatusKind.success).fg,
              ),
              onPressed: () => unawaited(
                ref
                    .read(caseWriterProvider)
                    .setKeepOffline(d.id, keep: !d.keepOffline),
              ),
            ),
          PopupMenuButton<VoidCallback>(
            tooltip: l.docsMoreActions,
            icon: const Icon(AppIcons.dotsThreeVertical),
            onSelected: (run) => run(),
            itemBuilder: (_) => [
              if (d.ready && d.kind == 'order')
                PopupMenuItem(
                  value: () => unawaited(
                    showOrderSummarySheet(context, d.matterId, document: d),
                  ),
                  child: Text(l.summaryButton),
                ),
              PopupMenuItem(
                value: () =>
                    unawaited(showDocumentDetailsSheet(context, document: d)),
                child: Text(l.docsEditDetails),
              ),
              PopupMenuItem(
                value: () => deleteWithUndo(
                  context,
                  ref,
                  d.id,
                  (w) => w.deleteDocument(d.id),
                ),
                child: Text(l.delete),
              ),
            ],
          ),
        ],
      ),
      onTap: d.ready
          ? () => unawaited(context.push('/documents/${d.id}'))
          : () => showMessage(
              context,
              errorText(
                l,
                d.uploadStatus == 'pending'
                    ? 'DOCUMENT_NOT_READY'
                    : 'DOCUMENT_QUARANTINED',
              ),
            ),
    );
  }
}

/// An upload in the queue (spec §4.3; ADR 0016), standing for its document until the server has the file:
/// "Waiting to upload", "Uploading 40%", or why it failed. One that isn't being sent can be removed (asked first:
/// its file is deleted from the device).
class UploadRow extends ConsumerWidget {
  const UploadRow(this.item, {this.showCase = true, super.key});

  final QueuedUpload item;
  final bool showCase;

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final l = context.l10n;
    final uploads = ref.read(uploadsProvider);
    final ok = await showConfirmDialog(
      context,
      title: l.docsRemoveTitle,
      body: l.docsRemoveBody,
      confirmLabel: l.docsRemove,
    );
    if (ok) await uploads.remove(item.id);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final q = item;
    final progress = ref.watch(uploadProgressProvider.select((p) => p[q.id]));
    final state = q.failed
        ? DocState.failed
        : progress != null
        ? DocState.uploading
        : DocState.waiting;
    return DocumentTile(
      title: q.title,
      kind: documentLine(
        l,
        kind: q.kind,
        sizeBytes: q.sizeBytes,
        caseLabel: showCase ? q.caseLabel : null,
      ),
      mime: q.mime,
      state: state,
      progress: progress,
      error: q.failed ? errorText(l, q.error) : null,
      trailing: state == DocState.uploading
          ? null
          : IconButton(
              tooltip: l.docsRemoveUpload,
              icon: const Icon(AppIcons.trash),
              onPressed: () => unawaited(_remove(context, ref)),
            ),
    );
  }
}
