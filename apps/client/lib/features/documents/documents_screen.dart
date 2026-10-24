import 'dart:async';

import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/case_text.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/documents.dart';
import 'package:advocate_app/features/case_page/sheet_form.dart';
import 'package:advocate_app/features/documents/document_row.dart';
import 'package:advocate_app/features/documents/upload_flow.dart';
import 'package:advocate_app/features/lock/app_lock.dart';
import 'package:advocate_app/ui/fields.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/sheets.dart';
import 'package:advocate_app/ui/skeleton.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The Documents screen's search and filters, kept while the app runs (like the Cases list's).
final documentFilterProvider =
    NotifierProvider<DocumentFilterController, DocumentFilter>(
      DocumentFilterController.new,
    );

class DocumentFilterController extends Notifier<DocumentFilter> {
  @override
  DocumentFilter build() => const DocumentFilter();

  void change(DocumentFilter Function(DocumentFilter) f) => state = f(state);
}

/// Documents (spec §4.3, `/documents`): every document of the org, newest first, after the uploads still waiting
/// in the queue; search by title (transliterated: "sharma" finds "शर्मा"), filter by type and case. Each row shows
/// its type, size, case, the safety check or upload progress, and the Keep offline toggle. Reads the synced
/// database, so it works offline; an upload made offline waits on the device. On Windows files dropped on the
/// screen start an upload and Ctrl+F finds (spec §5.12).
class DocumentsScreen extends ConsumerStatefulWidget {
  const DocumentsScreen({super.key});

  @override
  ConsumerState<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends ConsumerState<DocumentsScreen> {
  late final TextEditingController _search;
  final _searchFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _search = TextEditingController(
      text: ref.read(documentFilterProvider).query,
    );
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Ctrl+F focuses search while the list is the page on top and the app isn't locked (as on Cases and Clients).
  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent ||
        e.logicalKey != LogicalKeyboardKey.keyF ||
        !HardwareKeyboard.instance.isControlPressed ||
        !mounted ||
        ModalRoute.isCurrentOf(context) == false ||
        ref.read(appLockProvider).locked ||
        // The search box is there once the list has documents.
        _searchFocus.context == null) {
      return false;
    }
    _searchFocus.requestFocus();
    _search.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _search.text.length,
    );
    return true;
  }

  void _change(DocumentFilter Function(DocumentFilter) f) =>
      ref.read(documentFilterProvider.notifier).change(f);

  void _add() => unawaited(startUpload(context));

  /// The case filter's sheet: "All cases", then the cases that have documents.
  Future<void> _pickCase(Map<String, String> cases) async {
    final l = context.l10n;
    final current = ref.read(documentFilterProvider).matterId;
    Widget option(BuildContext sheet, String? id, String label) => ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      selected: id == current,
      trailing: id == current ? const Icon(AppIcons.checkCircleFill) : null,
      onTap: () => Navigator.pop(sheet, (id: id)),
    );
    final picked = await showAppBottomSheet<({String? id})>(
      context,
      builder: (sheet) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(l.docsCaseFilterTitle, style: sheet.text.titleLarge),
          ),
          const SizedBox(height: 8),
          option(sheet, null, l.docsAllCases),
          for (final MapEntry(:key, :value) in cases.entries)
            option(sheet, key, value),
        ],
      ),
    );
    if (picked != null) _change((f) => f.copyWith(matterId: picked.id));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final async = ref.watch(orgDocumentsProvider);
    final uploads = ref.watch(queuedUploadsProvider).value ?? const [];
    final hidden = ref.watch(hiddenRowsProvider);
    final filter = ref.watch(documentFilterProvider);
    final docs = [
      for (final d in async.value ?? const <CaseDocument>[])
        if (!hidden.contains(d.id)) d,
    ];

    final Widget body;
    if (async.hasError && !async.hasValue) {
      body = ErrorState(
        message: errorText(l, async.error),
        onRetry: () => ref.invalidate(orgDocumentsProvider),
      );
    } else if (!async.hasValue) {
      body = ListView(
        padding: const EdgeInsets.all(16),
        children: const [SkeletonCaseList()],
      );
    } else if (docs.isEmpty && uploads.isEmpty) {
      body = EmptyState(
        icon: AppIcons.files,
        message: l.docsEmpty,
        actionLabel: l.addDocument,
        onAction: _add,
      );
    } else {
      body = _list(context, docs, uploads, filter);
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(l.navDocuments),
        actions: [
          IconButton(
            onPressed: _add,
            tooltip: l.addDocument,
            icon: const Icon(AppIcons.filePlus),
          ),
        ],
      ),
      body: UploadDropTarget(child: body),
    );
  }

  Widget _list(
    BuildContext context,
    List<CaseDocument> docs,
    List<QueuedUpload> uploads,
    DocumentFilter filter,
  ) {
    final l = context.l10n;
    final cases = <String, String>{
      for (final d in docs) ?d.matterId: d.caseLabel ?? '',
      for (final q in uploads) ?q.matterId: q.caseLabel ?? '',
    }..removeWhere((_, label) => label.isEmpty);
    final shownUploads = filterUploads(uploads, filter);
    final shown = filterDocuments(docs, filter);
    final none = shownUploads.isEmpty && shown.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: SearchField(
            hint: l.docsSearchHint,
            controller: _search,
            focusNode: _searchFocus,
            onChanged: (q) => _change((f) => f.copyWith(query: q)),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              if (cases.isNotEmpty) ...[
                ActionChip(
                  avatar: const Icon(AppIcons.funnel),
                  label: Text(cases[filter.matterId] ?? l.docsAllCases),
                  onPressed: () => unawaited(_pickCase(cases)),
                ),
                const SizedBox(width: 16),
              ],
              for (final kind in [null, ...documentKinds]) ...[
                ChoiceChip(
                  label: Text(
                    kind == null ? l.docsAllTypes : documentKindLabel(l, kind),
                  ),
                  selected: filter.kind == kind,
                  onSelected: (_) => _change((f) => f.copyWith(kind: kind)),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
        Expanded(
          child: none
              ? ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    Text(
                      l.docsNoMatches,
                      textAlign: TextAlign.center,
                      style: context.text.bodyLarge,
                    ),
                    const SizedBox(height: 8),
                    Center(
                      child: TextButton(
                        onPressed: () {
                          _search.clear();
                          _change((_) => const DocumentFilter());
                        },
                        child: Text(l.foundClearFilters),
                      ),
                    ),
                  ],
                )
              // ponytail: rows appear without spec §5.5's stagger; add it with the kit's motion helpers.
              : ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    for (final q in shownUploads)
                      UploadRow(q, key: ValueKey('up-${q.id}')),
                    for (final d in shown) DocumentRow(d, key: ValueKey(d.id)),
                  ],
                ),
        ),
      ],
    );
  }
}
