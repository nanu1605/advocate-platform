import 'dart:async';

import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/features/case_page/case_page_text.dart';
import 'package:advocate_app/features/case_page/links.dart';
import 'package:advocate_app/features/case_page/sheet_form.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:advocate_app/ui/tiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Documents (spec §4.3): the case's files with kind and size; one still being checked, or quarantined, says so
/// instead of opening. A file opens outside the app from a short-lived link (the viewer, upload and "Keep offline"
/// are task 10, so "Add document" says it's coming). A sliver for the case page.
class DocumentsTab extends ConsumerWidget {
  const DocumentsTab(this.c, {super.key});

  final CaseInfo c;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final async = ref.watch(caseDocumentsProvider(c.id));
    void soon() => showMessage(context, l.comingSoon);
    final waiting = tabWaiting(context, [
      async,
    ], onRetry: () => ref.invalidate(caseDocumentsProvider(c.id)));
    if (waiting != null) return waiting;
    final docs = async.requireValue;
    if (docs.isEmpty) {
      return SliverToBoxAdapter(
        child: EmptyState(
          icon: AppIcons.files,
          message: l.casePageDocumentsEmpty,
          actionLabel: l.addDocument,
          onAction: soon,
        ),
      );
    }
    return SliverList.list(
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            onPressed: soon,
            icon: const Icon(AppIcons.filePlus),
            label: Text(l.addDocument),
          ),
        ),
        for (final d in docs)
          DocumentTile(
            title: d.title,
            kind: documentLine(l, d),
            pages: d.pages,
            onTap: () => unawaited(_open(context, ref, d)),
          ),
      ],
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref, CaseDocument d) {
    final code = switch (d.uploadStatus) {
      'pending' => 'DOCUMENT_NOT_READY',
      'quarantined' => 'DOCUMENT_QUARANTINED',
      _ => null,
    };
    if (code != null) {
      showMessage(context, errorText(context.l10n, code));
      return Future.value();
    }
    return openFromApi(
      context,
      ref,
      (api, org) => api.documentUrl(orgId: org, documentId: d.id),
    );
  }
}
