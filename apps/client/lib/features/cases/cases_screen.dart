import 'dart:async';

import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/case_text.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/diary_text.dart';
import 'package:advocate_app/features/case_page/case_page.dart';
import 'package:advocate_app/features/cases/add_case.dart';
import 'package:advocate_app/features/lock/app_lock.dart';
import 'package:advocate_app/ui/app_scaffold.dart';
import 'package:advocate_app/ui/case_card.dart';
import 'package:advocate_app/ui/fields.dart';
import 'package:advocate_app/ui/focus_ring.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/section_header.dart';
import 'package:advocate_app/ui/sheets.dart';
import 'package:advocate_app/ui/skeleton.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// The Cases list's scroll offset, shared by its pages: on a wide window `/cases` → `/cases/:id` builds a new page
/// over the first, which then opens where the list was.
final Provider<PageStorageBucket> _listStorageProvider = Provider(
  (_) => PageStorageBucket(),
);

/// The collapsed sections, shared by the list's pages like the search and filters ([caseFilterProvider]).
final _collapsedProvider = NotifierProvider<_Collapsed, Set<CaseSection>>(
  _Collapsed.new,
);

class _Collapsed extends Notifier<Set<CaseSection>> {
  @override
  Set<CaseSection> build() => const {};

  void toggle(CaseSection s) =>
      state = state.contains(s) ? ({...state}..remove(s)) : {...state, s};
}

/// `/cases` (spec §4.3): the org's cases by section (Today · This week · Later · No next date · Disposed), with
/// search (transliterated), filters and sort kept while the app runs, and Found for you. Reads the synced
/// database, so it works offline. On a window ≥ 840 dp the list sits beside the case at `/cases/:id`
/// ([selectedId]) (spec §5.3 Windows); the router shows `CasePage` alone on narrower screens. Keys (spec §5.12):
/// Ctrl+F finds, Up/Down move through the rows (from the search box too), Enter opens; Ctrl+N is the shell's.
class CasesScreen extends ConsumerStatefulWidget {
  const CasesScreen({this.selectedId, this.tab, super.key});

  /// The case open in the detail pane.
  final String? selectedId;

  /// The detail pane's tab (`?tab=`), passed to [CasePage].
  final String? tab;

  @override
  ConsumerState<CasesScreen> createState() => _CasesScreenState();
}

/// What the list shows besides headers and cases.
enum _Extra { noMatches, allArchived, foundForYou }

class _CasesScreenState extends ConsumerState<CasesScreen> {
  late final TextEditingController _search;
  final _searchFocus = FocusNode();
  late final PageStorageBucket _storage = ref.read(_listStorageProvider);

  @override
  void initState() {
    super.initState();
    _search = TextEditingController(text: ref.read(caseFilterProvider).query);
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Ctrl+F focuses search wherever focus is (the shell holds it until the user tabs in), while the list is the
  /// page on top and the app isn't locked.
  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent ||
        e.logicalKey != LogicalKeyboardKey.keyF ||
        !HardwareKeyboard.instance.isControlPressed ||
        !mounted ||
        ModalRoute.isCurrentOf(context) == false ||
        ref.read(appLockProvider).locked) {
      return false;
    }
    _searchFocus.requestFocus();
    _search.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _search.text.length,
    );
    return true;
  }

  void _clearAll() {
    _search.clear();
    ref.read(caseFilterProvider.notifier)
      ..setQuery('')
      ..clearFilters();
  }

  Future<void> _openFilters(List<CaseInfo> cases) async {
    final f = await showAppBottomSheet<CaseFilter>(
      context,
      builder: (_) => _FilterSheet(ref.read(caseFilterProvider), cases),
    );
    if (f != null) ref.read(caseFilterProvider.notifier).change((_) => f);
  }

  @override
  Widget build(BuildContext context) {
    final wide =
        sizeClassOf(MediaQuery.sizeOf(context).width) == SizeClass.expanded;
    final hasCases = ref.watch(casesProvider).value?.isNotEmpty ?? true;
    final list = _list(context, wide: wide);
    final id = widget.selectedId;
    if (!wide || (id == null && !hasCases)) return list;
    return Row(
      children: [
        SizedBox(width: 360, child: list),
        VerticalDivider(width: 1, color: context.colors.line),
        Expanded(
          child: id == null
              ? Scaffold(
                  body: EmptyState(
                    icon: AppIcons.briefcase,
                    message: context.l10n.casesListPickCase,
                  ),
                )
              // A fresh page per case: nothing of the last case (a refresh in flight) carries over.
              : CasePage(
                  key: ValueKey(id),
                  matterId: id,
                  tab: widget.tab,
                  pane: true,
                ),
        ),
      ],
    );
  }

  Widget _list(BuildContext context, {required bool wide}) {
    final l = context.l10n;
    final sections = ref.watch(caseSectionsProvider);
    final cases = ref.watch(casesProvider).value ?? const <CaseInfo>[];
    final filter = ref.watch(caseFilterProvider);
    final found = ref.watch(pendingFoundCountProvider).value ?? 0;
    final today = ref.watch(istTodayProvider);
    final me = ref.watch(currentUserIdProvider);
    final collapsed = ref.watch(_collapsedProvider);
    // On a wide window the page under this one (`/cases` below `/cases/:id`) keeps its own search box: keep it
    // showing the search the list is filtered by.
    ref.listen(caseFilterProvider.select((f) => f.query), (_, q) {
      if (_search.text != q) _search.text = q;
    });

    final Widget body;
    if (sections.hasError && !sections.hasValue) {
      body = ErrorState(
        message: errorText(l, sections.error),
        onRetry: () => ref.invalidate(casesProvider),
      );
    } else if (!sections.hasValue) {
      body = ListView(
        padding: const EdgeInsets.all(16),
        children: const [SkeletonCaseList()],
      );
    } else if (cases.isEmpty) {
      body = ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          EmptyState(
            icon: AppIcons.briefcase,
            message: l.casesListEmpty,
            actionLabel: l.addCase,
            onAction: () => unawaited(showAddCaseChooser(context)),
          ),
          if (found > 0) _FoundForYou(found),
        ],
      );
    } else {
      // Headers, then their cases unless collapsed. ponytail: rows appear without spec §5.5's fade-and-rise
      // stagger and open without the container transform; add both with the kit's motion helpers (off under
      // reduce motion). A case selected by a link isn't scrolled into view (rows vary in height).
      final items = <Object>[
        for (final s in sections.requireValue) ...[
          (s.section, s.cases.length),
          if (!collapsed.contains(s.section)) ...s.cases,
        ],
        // With no search or filter to clear, every case is archived.
        if (sections.requireValue.isEmpty)
          if (!filter.filtering && filter.query.trim().isEmpty)
            _Extra.allArchived
          else
            _Extra.noMatches,
        if (found > 0) _Extra.foundForYou,
      ];
      body = ListView.builder(
        key: const PageStorageKey('cases.list'),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        itemCount: items.length,
        itemBuilder: (context, i) => switch (items[i]) {
          (final CaseSection s, final int n) => SectionHeader(
            caseSectionLabel(l, s),
            key: ValueKey(s),
            count: n,
            expanded: !collapsed.contains(s),
            onToggle: () => ref.read(_collapsedProvider.notifier).toggle(s),
          ),
          final CaseInfo c => Padding(
            key: ValueKey(c.id),
            padding: const EdgeInsets.only(bottom: 8),
            child: _row(context, c, today: today, me: me),
          ),
          _Extra.foundForYou => _FoundForYou(found),
          _Extra.allArchived => _allArchived(context),
          _ => _noMatches(context),
        },
      );
    }

    final count = [
      filter.courtId,
      filter.clientId,
      filter.status,
      filter.assigneeId,
    ].nonNulls.length;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.navCases),
        // Beside a case, the case's own app bar goes back.
        automaticallyImplyLeading: !wide,
        actions: [
          if (cases.isNotEmpty)
            // Fits the 360 dp list pane at 200% text: a label too long for the bar ends in "…" (screen
            // readers still hear all of it).
            Flexible(
              child: Padding(
                padding: const EdgeInsetsDirectional.only(end: 8),
                child: TextButton.icon(
                  onPressed: () => unawaited(_openFilters(cases)),
                  icon: const Icon(AppIcons.funnel),
                  label: Text(
                    l.foundFilters(count),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The search box has the width to itself: its hint is its only label (spec §5.9). Down moves to the rows.
          if (cases.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                      _searchFocus.focusInDirection(TraversalDirection.down),
                },
                child: SearchField(
                  hint: l.casesListSearchHint,
                  controller: _search,
                  focusNode: _searchFocus,
                  onChanged: ref.read(caseFilterProvider.notifier).setQuery,
                ),
              ),
            ),
          Expanded(
            child: PageStorage(bucket: _storage, child: body),
          ),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    CaseInfo c, {
    required DateTime today,
    required String? me,
  }) {
    final l = context.l10n;
    final locale = Localizations.localeOf(context);
    final selected = c.id == widget.selectedId;
    return CaseCard(
      CaseCardData(
        caseNumber: c.caseLabel,
        // A case without a number or CNR is labelled by its title already.
        title: c.numbered ? c.title ?? '' : '',
        court: c.courtLabel(locale) ?? l.foundOtherCourt,
        courtNo: c.courtNo,
        nextDate: c.disposed ? null : c.nextDate,
        assignee: c.assigneeName,
        // A transferred case sits under Disposed but isn't decided: no pill (its row text says Transferred).
        state: c.courtStatus == 'disposed'
            ? CaseCardState.disposed
            : c.manual
            ? CaseCardState.manual
            : CaseCardState.normal,
      ),
      variant: CaseCardVariant.compact,
      today: today,
      selected: selected,
      // Keyboard focus stays on the case just opened when its page replaces the list's.
      autofocus: selected,
      semanticsLabel: caseRowLabel(l, locale, c, me: me),
      onTap: () => context.go('/cases/${c.id}'),
    );
  }

  /// Every case is archived: say so, offer Add case and the archived ones.
  Widget _allArchived(BuildContext context) {
    final l = context.l10n;
    return Column(
      children: [
        EmptyState(
          icon: AppIcons.briefcase,
          message: l.casesListAllArchived,
          actionLabel: l.addCase,
          onAction: () => unawaited(showAddCaseChooser(context)),
        ),
        TextButton(
          onPressed: () => ref
              .read(caseFilterProvider.notifier)
              .change((f) => f.copyWith(status: CaseStatusFilter.archived)),
          child: Text(l.casesListShowArchived),
        ),
      ],
    );
  }

  Widget _noMatches(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      children: [
        Text(
          context.l10n.foundNoMatches,
          textAlign: TextAlign.center,
          style: context.text.bodyLarge,
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _clearAll,
          child: Text(context.l10n.foundClearFilters),
        ),
      ],
    ),
  );
}

/// A Cases list row for screen readers (spec §5.9): "WP 1234 of 2024. Sharma v. State of MP. MP High Court Indore,
/// Court 12. Next date Thu, 5 Nov 2026. Pending. Assignee: You."
String caseRowLabel(
  AppLocalizations l,
  Locale locale,
  CaseInfo c, {
  String? me,
}) {
  final stop = locale.languageCode == 'hi' ? '।' : '.';
  final next = c.nextDate;
  final assignee = c.assigneeId != null && c.assigneeId == me
      ? l.boardYou
      : c.assigneeName;
  return [
    spokenCaseLabel(l, c.caseLabel),
    if (c.numbered && c.title != null) c.title!,
    [
      c.court?.spokenLabel(locale, l.highCourt) ??
          c.courtName ??
          l.foundOtherCourt,
      if (c.courtNo != null) l.courtNo(c.courtNo!),
    ].join(', '),
    if (!c.disposed && next == null)
      l.casesNoNextDate
    else if (!c.disposed && next != null)
      l.casesListNextOn(Formats(locale).date(next)),
    caseStatusText(l, c),
    if (c.manual) l.casesManualCase,
    if (assignee != null) l.boardAssigneeIs(assignee),
  ].map((s) => '$s$stop').join(' ');
}

/// "Found for you (3)": the org's found cases waiting for a decision, at `/found`. Hidden at zero.
class _FoundForYou extends StatelessWidget {
  const _FoundForYou(this.count);

  final int count;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Card(
        child: FocusRing(
          child: ListTile(
            leading: const Icon(AppIcons.tray),
            title: Text(
              '${l.casesFoundForYou} ($count)',
              style: context.text.titleMedium,
            ),
            subtitle: Text(l.casesListFoundHint),
            trailing: const Icon(AppIcons.caretRight),
            onTap: () => unawaited(context.push('/found')),
          ),
        ),
      ),
    );
  }
}

/// Sort, then filter by court, client, status and assignee (spec §4.3); the choices come from the org's cases.
/// Returns the new filter on "Show cases" (the search is kept).
class _FilterSheet extends ConsumerStatefulWidget {
  const _FilterSheet(this.filter, this.cases);

  final CaseFilter filter;
  final List<CaseInfo> cases;

  @override
  ConsumerState<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends ConsumerState<_FilterSheet> {
  late CaseSort _sort = widget.filter.sort;
  late String? _court = widget.filter.courtId;
  late String? _client = widget.filter.clientId;
  late CaseStatusFilter? _status = widget.filter.status;
  late String? _assignee = widget.filter.assigneeId;
  var _clientQuery = '';

  /// A heading and its chips; [any] adds "All" (null).
  Widget _choices<T>(
    String label,
    List<(T, String)> options,
    T? value,
    ValueChanged<T?> onSelected, {
    bool any = true,
    Widget? above,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 4),
        child: Semantics(
          header: true,
          child: Text(label, style: context.text.titleSmall),
        ),
      ),
      if (above != null)
        Padding(padding: const EdgeInsets.only(bottom: 8), child: above),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (any)
            ChoiceChip(
              label: Text(context.l10n.foundFilterAny),
              selected: value == null,
              onSelected: (_) => onSelected(null),
            ),
          for (final (v, text) in options)
            ChoiceChip(
              label: Text(text),
              selected: value == v,
              onSelected: (_) => onSelected(v),
            ),
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final locale = Localizations.localeOf(context);
    final me = ref.watch(currentUserIdProvider);
    final cases = widget.cases;
    int byLabel((String, String) a, (String, String) b) =>
        a.$2.toLowerCase().compareTo(b.$2.toLowerCase());
    final courts = {
      for (final c in cases)
        if (c.courtId != null)
          c.courtId!: c.courtLabel(locale) ?? l.foundOtherCourt,
    }.entries.map((e) => (e.key, e.value)).toList()..sort(byLabel);
    // The synced clients carry their stored search keys, so typing doesn't transliterate every name again.
    final known = {
      for (final x in ref.watch(clientsProvider).value ?? const <ClientInfo>[])
        x.id: x,
    };
    final clients =
        {
          for (final c in cases)
            for (final x in c.clients)
              x.id: known[x.id] ?? ClientInfo(id: x.id, name: x.name),
        }.values.toList()..sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
    final assignees =
        {
          for (final c in cases)
            if (c.assigneeId != null)
              c.assigneeId!: c.assigneeId == me
                  ? l.boardMe
                  : c.assigneeName ?? '—',
        }.entries.map((e) => (e.key, e.value)).toList()..sort(
          (a, b) => a.$1 == me
              ? -1
              : b.$1 == me
              ? 1
              : byLabel(a, b),
        );
    // Orgs have hundreds of clients: past a dozen, a search box narrows the chips (with transliteration).
    // ponytail: shows the first 12 matches (and the chosen one); a full picker if people ask for it.
    final many = clients.length > 12;
    final shown = [
      ...clients.where((c) => c.id == _client),
      ...searchClients(
        clients,
        _clientQuery,
      ).where((c) => c.id != _client).take(12),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(l.foundFilters(0), style: context.text.titleLarge),
        ),
        _choices(
          l.casesListSortBy,
          [for (final s in CaseSort.values) (s, caseSortLabel(l, s))],
          _sort,
          (v) => setState(() => _sort = v ?? _sort),
          any: false,
        ),
        _choices(
          l.foundFilterCourt,
          courts,
          _court,
          (v) => setState(() => _court = v),
        ),
        if (clients.isNotEmpty)
          _choices(
            l.boardClient,
            [for (final c in shown) (c.id, c.name)],
            _client,
            (v) => setState(() => _client = v),
            above: many
                ? SearchField(
                    hint: l.casePageSearchClients,
                    onChanged: (q) => setState(() => _clientQuery = q),
                  )
                : null,
          ),
        _choices(
          l.foundFilterStatus,
          [
            for (final s in CaseStatusFilter.values)
              (s, caseStatusFilterLabel(l, s)),
          ],
          _status,
          (v) => setState(() => _status = v),
        ),
        if (assignees.isNotEmpty)
          _choices(
            l.boardAssignee,
            assignees,
            _assignee,
            (v) => setState(() => _assignee = v),
          ),
        const SizedBox(height: 24),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            TextButton(
              onPressed: () => setState(() {
                _court = _client = _assignee = null;
                _status = null;
              }),
              child: Text(l.foundClearFilters),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                widget.filter.copyWith(
                  sort: _sort,
                  courtId: _court,
                  clientId: _client,
                  status: _status,
                  assigneeId: _assignee,
                ),
              ),
              child: Text(l.foundShowCases),
            ),
          ],
        ),
      ],
    );
  }
}
