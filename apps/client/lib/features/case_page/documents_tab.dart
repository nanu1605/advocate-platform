import 'dart:async';

import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/documents.dart';
import 'package:advocate_app/features/case_page/sheet_form.dart';
import 'package:advocate_app/features/documents/document_row.dart';
import 'package:advocate_app/features/documents/upload_flow.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Documents (spec §4.3): the case's uploads still waiting in the queue, then its files with type, size, the
/// safety check and Keep offline (the Documents screen's rows). A ready file opens in the viewer; "Add document"
/// uploads into this case. A sliver for the case page.
class DocumentsTab extends ConsumerWidget {
  const DocumentsTab(this.c, {super.key});

  final CaseInfo c;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final async = ref.watch(caseDocumentsProvider(c.id));
    final uploads = [
      for (final q
          in ref.watch(queuedUploadsProvider).value ?? const <QueuedUpload>[])
        if (q.matterId == c.id) q,
    ];
    void add() => unawaited(startUpload(context, matterId: c.id));
    final waiting = tabWaiting(context, [
      async,
    ], onRetry: () => ref.invalidate(caseDocumentsProvider(c.id)));
    if (waiting != null) return waiting;
    final hidden = ref.watch(hiddenRowsProvider);
    final docs = [
      for (final d in async.requireValue)
        if (!hidden.contains(d.id)) d,
    ];
    if (docs.isEmpty && uploads.isEmpty) {
      return SliverToBoxAdapter(
        child: EmptyState(
          icon: AppIcons.files,
          message: l.casePageDocumentsEmpty,
          actionLabel: l.addDocument,
          onAction: add,
        ),
      );
    }
    return SliverList.list(
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            onPressed: add,
            icon: const Icon(AppIcons.filePlus),
            label: Text(l.addDocument),
          ),
        ),
        for (final q in uploads)
          UploadRow(q, showCase: false, key: ValueKey('up-${q.id}')),
        for (final d in docs)
          DocumentRow(d, showCase: false, key: ValueKey(d.id)),
      ],
    );
  }
}
