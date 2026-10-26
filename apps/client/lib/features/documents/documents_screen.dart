import 'dart:async';

import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/case_text.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/documents.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:advocate_app/features/case_page/sheet_form.dart';
import 'package:advocate_app/features/documents/document_row.dart';
import 'package:advocate_app/features/documents/upload_flow.dart';
import 'package:advocate_app/features/lock/app_lock.dart';
import 'package:advocate_app/ui/fields.dart';
import 'package:advocate_app/ui/focus_ring.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/section_header.dart';
import 'package:advocate_app/ui/sheets.dart';
import 'package:advocate_app/ui/skeleton.dart';
import 'package:advocate_app/ui/source_chip.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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

/// The org's cases that have court orders: the case filter offers them beside the cases with documents, as
/// search inside reads orders too (F15). Empty without an org or sync.
final orderCaseIdsProvider = StreamProvider<Set<String>>((ref) {
  final db = ref.watch(syncDatabaseProvider);
  final org = ref.watch(currentOrgIdProvider);
  if (db == null || org == null) return Stream.value(const {});
  return db
      .watch(
        'select distinct matter_id from orders where org_id = ?1 and deleted_at is null',
        parameters: [org],
      )
      .map((rows) => {for (final r in rows) r['matter_id'] as String});
});

/// Documents (spec §4.3, `/documents`): every document of the org, newest first, after the uploads still waiting
/// in the queue; search by title (transliterated: "sharma" finds "शर्मा"), filter by type and case. The same words
/// can be looked for inside the pages, scans and court orders included (F06, F15): online, on a tap or Enter, as
/// the text isn't on the device; a hit opens its document at the page. Each row shows
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
  final _scroll = ScrollController();

  /// The last search inside documents: what was asked (query, case) and its answer.
  (String, String?)? _asked;
  AsyncValue<List<DocumentHit>>? _inside;

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
    _scroll.dispose();
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
        // The search box is there once the documents have loaded.
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

  /// Reads the filter now: Enter can come before the screen has rebuilt with the last keystroke.
  Future<void> _searchInside() async {
    final filter = ref.read(documentFilterProvider);
    final query = filter.query.trim();
    final org = ref.read(currentOrgIdProvider);
    if (query.length < 2 || org == null) return;
    final asked = (query, filter.matterId);
    setState(() {
      _asked = asked;
      _inside = const AsyncLoading();
    });
    // Back to the top, where the answer goes: a lazy list never builds (or reads out) a section scrolled past.
    if (_scroll.hasClients) _scroll.jumpTo(0);
    AsyncValue<List<DocumentHit>> result;
    if (ref.read(syncViewProvider).value?.offline ?? false) {
      result = AsyncError(const ApiException('NETWORK'), StackTrace.current);
    } else {
      result = await AsyncValue.guard(
        () => ref
            .read(apiClientProvider)
            .searchDocuments(
              orgId: org,
              query: query,
              matterId: filter.matterId,
            ),
      );
    }
    if (mounted && _asked == asked) setState(() => _inside = result);
  }

  /// "Search inside documents", its progress, or its hits: each opens its document at the page.
  List<Widget> _insideSection(BuildContext context, DocumentFilter filter) {
    final l = context.l10n;
    final query = filter.query.trim();
    if (query.length < 2) return const [];
    final inside = _asked == (query, filter.matterId) ? _inside : null;
    const pad = EdgeInsets.fromLTRB(16, 16, 16, 0);
    final hint = context.text.bodySmall?.copyWith(color: context.colors.ink2);
    return switch (inside) {
      null => [
        Padding(
          padding: pad,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              OutlinedButton.icon(
                onPressed: () => unawaited(_searchInside()),
                icon: const Icon(AppIcons.magnifyingGlass),
                label: Text(l.docsInsideSearch(query)),
              ),
              const SizedBox(height: 4),
              Text(l.docsInsideHint, style: hint),
            ],
          ),
        ),
      ],
      AsyncLoading() => [
        Padding(
          padding: pad,
          child: AnnouncedText(l.docsInsideSearching, style: hint),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: LinearProgressIndicator(),
        ),
      ],
      AsyncError(:final error) => [
        Padding(
          padding: pad,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnnouncedText(errorText(l, error), style: context.text.bodyLarge),
              TextButton(
                onPressed: () => unawaited(_searchInside()),
                child: Text(l.retry),
              ),
            ],
          ),
        ),
      ],
      AsyncData(value: final hits) when hits.isEmpty => [
        Padding(
          padding: pad,
          child: AnnouncedText(l.docsInsideNone, style: context.text.bodyLarge),
        ),
      ],
      AsyncData(value: final hits) => [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          // Read out like the other states (spec §5.9), and still a heading.
          child: MergeSemantics(
            child: Semantics(
              header: true,
              child: AnnouncedText(
                '${l.docsInsideTitle} (${hits.length})',
                child: SectionHeader(l.docsInsideTitle, count: hits.length),
              ),
            ),
          ),
        ),
        for (final h in hits) _hit(context, h),
      ],
    };
  }

  Widget _hit(BuildContext context, DocumentHit h) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(h.snippet, style: context.text.bodyMedium),
        const SizedBox(height: 4),
        SourceChip(
          h.title,
          page: h.page,
          paragraph: h.paras.firstOrNull,
          onTap: () => unawaited(
            context.push(
              h.documentId != null
                  ? '/documents/${h.documentId}?page=${h.page}'
                  : '/cases/${h.matterId}/orders/${h.orderId}?page=${h.page}',
            ),
          ),
        ),
      ],
    ),
  );

  /// The case filter's sheet: "All cases", then the cases that have documents or court orders.
  Future<void> _pickCase(Map<String, String> cases) async {
    final l = context.l10n;
    final current = ref.read(documentFilterProvider).matterId;
    Widget option(BuildContext sheet, String? id, String label) => FocusRing(
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        selected: id == current,
        trailing: id == current ? const Icon(AppIcons.checkCircleFill) : null,
        onTap: () => Navigator.pop(sheet, (id: id)),
      ),
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
    final ordered = ref.watch(orderCaseIdsProvider).value ?? const {};
    final cases = <String, String>{
      for (final d in docs) ?d.matterId: d.caseLabel ?? '',
      for (final q in uploads) ?q.matterId: q.caseLabel ?? '',
      for (final c in ref.watch(casesProvider).value ?? const <CaseInfo>[])
        if (ordered.contains(c.id)) c.id: c.caseLabel,
    }..removeWhere((_, label) => label.isEmpty);
    // No documents: the empty state goes under search, which still finds words inside court orders.
    final empty = docs.isEmpty && uploads.isEmpty;
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
            onSubmitted: (_) => unawaited(_searchInside()),
          ),
        ),
        if (!empty || cases.isNotEmpty)
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
                if (!empty)
                  for (final kind in [null, ...documentKinds]) ...[
                    ChoiceChip(
                      label: Text(
                        kind == null
                            ? l.docsAllTypes
                            : documentKindLabel(l, kind),
                      ),
                      selected: filter.kind == kind,
                      onSelected: (_) => _change((f) => f.copyWith(kind: kind)),
                    ),
                    const SizedBox(width: 8),
                  ],
              ],
            ),
          ),
        // What search inside found goes first, with or without documents: it was asked for, and so it's built in the
        // lazy list, in view, and read out at 200% text.
        Expanded(
          child: empty
              ? ListView(
                  children: [
                    ..._insideSection(context, filter),
                    EmptyState(
                      icon: AppIcons.files,
                      message: l.docsEmpty,
                      actionLabel: l.addDocument,
                      onAction: _add,
                    ),
                  ],
                )
              : none
              ? ListView(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        l.docsNoMatches,
                        textAlign: TextAlign.center,
                        style: context.text.bodyLarge,
                      ),
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
                    ..._insideSection(context, filter),
                  ],
                )
              // ponytail: rows appear without spec §5.5's stagger; add it with the kit's motion helpers.
              : ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    ..._insideSection(context, filter),
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
