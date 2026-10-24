import 'dart:async';
import 'dart:math';

import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/core/theme/motion.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/courts.dart';
import 'package:advocate_app/data/device.dart';
import 'package:advocate_app/data/found_cases.dart';
import 'package:advocate_app/data/jobs.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:advocate_app/features/found_cases/add_by_cnr.dart';
import 'package:advocate_app/features/found_cases/found_selection.dart';
import 'package:advocate_app/features/onboarding/onboarding_layout.dart';
import 'package:advocate_app/ui/fields.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/selectable_row.dart';
import 'package:advocate_app/ui/sheets.dart';
import 'package:advocate_app/ui/skeleton.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

const _enter = [
  SingleActivator(LogicalKeyboardKey.enter),
  SingleActivator(LogicalKeyboardKey.numpadEnter),
];

/// /found (spec §4.1 "Found cases screen", §5.3): the find-cases job's matches, to add all or a selection. Onboarding
/// step 8, and later "Found for you" from Cases. Ticks live in `found_selection`, so they survive the app being
/// killed. Windows: Shift-click selects a range, Ctrl+A selects all, Space toggles the focused row, Enter adds.
class FoundCasesScreen extends ConsumerStatefulWidget {
  const FoundCasesScreen({super.key});

  @override
  ConsumerState<FoundCasesScreen> createState() => _FoundCasesScreenState();
}

class _FoundCasesScreenState extends ConsumerState<FoundCasesScreen> {
  final _search = TextEditingController();
  final _focus = FocusNode(debugLabel: 'Found cases');
  var _filter = const FoundFilter();

  /// Collapsed or expanded by the user; otherwise court groups are open and "Disposed" is folded.
  final _expanded = <String, bool>{};
  final _pages = <String, int>{};

  /// Marked "Not mine" here; hidden until sync drops them.
  final _hidden = <String>{};

  /// The last row ticked or unticked, where a Shift-click range starts.
  String? _anchor;
  String? _error;
  bool _busy = false;
  bool _added = false;

  /// One idempotency key per add action, reused only when the same set is retried (spec §10.1): a set that has
  /// changed since (more rows synced, one marked "Not mine") is a new action, not a replay of the old one.
  ({String sig, String key})? _attempt;

  @override
  void dispose() {
    _search.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _onboarding => ref.read(settingsProvider).onboardingDone != true;

  /// Onboarding goes on to notifications; from Cases, back.
  void _onward() {
    if (_onboarding) {
      context.go('/onboarding/notifications');
    } else if (context.canPop()) {
      context.pop();
    } else {
      context.go('/cases');
    }
  }

  void _write(Map<String, bool> ticks) {
    final org = ref.read(currentOrgIdProvider);
    if (org == null) return;
    if (_error != null) setState(() => _error = null);
    unawaited(ref.read(foundSelectionStoreProvider).set(org, ticks));
  }

  void _toggle(FoundCase c, FoundSelection sel, List<FoundCase> visible) {
    _write(
      HardwareKeyboard.instance.isShiftPressed
          ? sel.range(visible, _anchor, c)
          : {c.id: !sel.ticked(c)},
    );
    _anchor = c.id;
  }

  Future<void> _add(({bool all, List<String> ids}) request) async {
    final org = ref.read(currentOrgIdProvider);
    if (org == null) return;
    final l = context.l10n;
    final api = ref.read(apiClientProvider);
    final store = ref.read(foundSelectionStoreProvider);
    final sig = '${request.all}:${request.ids.join(',')}';
    final key = _attempt?.sig == sig ? _attempt!.key : uuidV4();
    _attempt = (sig: sig, key: key);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = request.all
          ? await api.addAllFoundCases(orgId: org, idempotencyKey: key)
          : await api.addFoundCases(
              orgId: org,
              idempotencyKey: key,
              ids: request.ids,
            );
      _attempt = null;
      await store.remove(org, request.ids);
      if (mounted) await _celebrate(result.added);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = errorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A short success check (none under reduce motion), then onward. The snackbar carries the count.
  Future<void> _celebrate(int added) async {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.l10n.foundAdded(added))));
    if (!Motion.of(context).reduced) {
      setState(() => _added = true);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;
    }
    _onward();
  }

  /// "Add all (N)": every pending match. Low-confidence ones are confirmed first, or reviewed instead.
  Future<void> _addAll(FoundSelection sel, int? remaining) async {
    final l = context.l10n;
    if (remaining != null && sel.pending.length > remaining) {
      setState(() => _error = l.foundAllowance(remaining));
      return;
    }
    if (sel.lowPending > 0) {
      final addAll = await showAppBottomSheet<bool>(
        context,
        builder: (ctx) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(
                l.foundLowTitle(sel.lowPending),
                style: ctx.text.titleLarge,
              ),
            ),
            const SizedBox(height: 8),
            Text(l.foundLowBody, style: ctx.text.bodyLarge),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l.foundLowAddAll(sel.pending.length)),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l.foundLowReview(sel.lowPending)),
            ),
          ],
        ),
      );
      if (addAll == null || !mounted) return;
      if (!addAll) {
        setState(
          () => _filter = FoundFilter(query: _filter.query, confidence: 'low'),
        );
        return;
      }
    }
    // `{all: true}` only once the search has finished and synced, so the server's pending set is the one on
    // screen; until then, the ids the user saw (spec §4.1 AC).
    await _add((
      all: ref.read(findSettledProvider),
      ids: [for (final c in sel.pending) c.id],
    ));
  }

  /// "Not mine" stores an exclusion so the case isn't suggested again (spec §4.1); Undo puts it back, even after
  /// the screen has closed (the snackbar outlives it).
  Future<void> _notMine(FoundCase c) async {
    final org = ref.read(currentOrgIdProvider);
    if (org == null) return;
    final api = ref.read(apiClientProvider);
    final store = ref.read(foundSelectionStoreProvider);
    final messenger = ScaffoldMessenger.of(context);
    final l = context.l10n;
    Future<bool> decide(String decision) async {
      try {
        await api.decideFoundCase(orgId: org, id: c.id, decision: decision);
        return true;
      } on ApiException catch (e) {
        messenger.showSnackBar(SnackBar(content: Text(errorText(l, e))));
        return false;
      }
    }

    Future<void> undo() async {
      if (await decide('pending') && mounted) {
        setState(() => _hidden.remove(c.id));
      }
    }

    if (!await decide('not_mine') || !mounted) return;
    setState(() => _hidden.add(c.id));
    unawaited(store.remove(org, [c.id]));
    showUndoSnackbar(
      context,
      message: l.foundNotMineDone,
      onUndo: () => unawaited(undo()),
    );
  }

  Future<void> _openFilters(List<FoundCase> cases, List<Court> courts) async {
    final f = await showAppBottomSheet<FoundFilter>(
      context,
      builder: (_) => _FilterSheet(_filter, cases, courts),
    );
    if (f != null && mounted) setState(() => _filter = f);
  }

  void _clearFilters() => setState(() {
    _filter = const FoundFilter();
    _search.clear();
  });

  KeyEventResult _onKey(KeyEvent e, FoundSelection sel, VoidCallback? add) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final focus = FocusManager.instance.primaryFocus;
    final typing =
        focus?.context?.findAncestorStateOfType<EditableTextState>() != null;
    if (!typing &&
        e.logicalKey == LogicalKeyboardKey.keyA &&
        HardwareKeyboard.instance.isControlPressed) {
      _write(sel.selectAll(on: true));
      return KeyEventResult.handled;
    }
    // Rows handle Enter themselves; this is for when nothing else on the screen has focus.
    if (focus == _focus &&
        _enter.any((k) => k.accepts(e, HardwareKeyboard.instance))) {
      add?.call();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final locale = Localizations.localeOf(context);
    final found = ref.watch(foundCasesProvider);
    final courtList = ref.watch(courtsProvider).value ?? const <Court>[];
    final courts = {for (final c in courtList) c.id: c};
    final remaining = ref.watch(remainingAllowanceProvider).value;
    final offline = ref.watch(syncViewProvider).value?.offline ?? false;
    final cases = [
      for (final c in found.value ?? const <FoundCase>[])
        if (!_hidden.contains(c.id)) c,
    ];
    final sel = FoundSelection(
      cases,
      ref.watch(foundSelectionProvider).value ?? const {},
    );
    final ids = sel.selectedIds;
    final over = sel.overAllowance(remaining);
    final add = _busy || over || ids.isEmpty
        ? null
        : () => unawaited(_add((all: false, ids: ids)));

    // The list: one header per group, its rows (paginated over 300 results) and "Show more".
    final filtered = _filter.apply(cases);
    final visible = <FoundCase>[];
    final items = <WidgetBuilder>[];
    for (final g in groupFound(filtered, courtList)) {
      final open = _expanded[g.key] ?? g.key != disposedGroup;
      items.add(
        (_) => GroupHeader(
          title: g.key == disposedGroup
              ? l.statusDisposed
              : g.court?.spokenLabel(locale, l.highCourt) ?? l.foundOtherCourt,
          selectedCount: g.cases.where(sel.ticked).length,
          total: g.cases.length,
          expanded: open,
          onToggleExpanded: () => setState(() => _expanded[g.key] = !open),
          onSelectAll: (on) => _write({for (final c in g.cases) c.id: on}),
        ),
      );
      if (!open) continue;
      final shown = shownInGroup(
        total: filtered.length,
        groupSize: g.cases.length,
        pages: _pages[g.key] ?? 1,
      );
      for (final c in g.cases.take(shown)) {
        visible.add(c);
        items.add(
          (context) => _FoundRow(
            key: ValueKey(c.id),
            found: c,
            court: courts[c.courtId],
            showCourt: g.key == disposedGroup,
            selected: sel.ticked(c),
            onChanged: () => _toggle(c, sel, visible),
            onAdd: add,
            onNotMine: () => unawaited(_notMine(c)),
          ),
        );
      }
      final rest = g.cases.length - shown;
      if (rest > 0) {
        items.add(
          (_) => Align(
            child: TextButton(
              onPressed: () =>
                  setState(() => _pages[g.key] = (_pages[g.key] ?? 1) + 1),
              child: Text(l.foundShowMore(min(rest, foundPageSize))),
            ),
          ),
        );
      }
    }

    final account = ref.watch(accountProvider);
    final Widget content;
    if (ref.watch(currentOrgIdProvider) == null && account.hasError) {
      // The account didn't load (offline or the API down, nothing cached): no org, so nothing can be shown or
      // added. Say so rather than "nothing found".
      content = ListView(
        children: [
          ErrorState(
            message: errorText(l, account.error),
            onRetry: () => ref.invalidate(accountProvider),
          ),
        ],
      );
    } else if (found.hasError && !found.hasValue) {
      content = ListView(
        children: [
          ErrorState(
            message: errorText(l, found.error),
            onRetry: () => ref.invalidate(foundCasesProvider),
          ),
          Center(
            child: TextButton(
              onPressed: () => unawaited(showAddByCnrSheet(context)),
              child: Text(l.foundAddByCnr),
            ),
          ),
        ],
      );
    } else if (!found.hasValue) {
      content = ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          Skeleton(width: 240, height: 28),
          SizedBox(height: 12),
          Skeleton(width: 200),
          SizedBox(height: 24),
          SkeletonCaseList(count: 4),
        ],
      );
    } else if (cases.isEmpty) {
      // Scrolls, so the message never overflows at 200% text in a short window.
      content = ListView(
        children: [
          EmptyState(
            icon: AppIcons.magnifyingGlass,
            message: l.foundEmpty,
            actionLabel: l.foundAddByCnr,
            onAction: () => unawaited(showAddByCnrSheet(context)),
          ),
        ],
      );
    } else {
      content = ListView.builder(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
        itemCount: items.length + (filtered.isEmpty ? 2 : 1),
        itemBuilder: (context, i) => i == 0
            ? _header(context, sel, remaining, courtList)
            : i <= items.length
            ? items[i - 1](context)
            : _noMatches(context),
      );
    }

    final notice = over ? l.foundAllowance(remaining!) : _error;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: (_, e) => _onKey(e, sel, add),
      child: Scaffold(
        appBar: AppBar(title: Text(l.foundTitle)),
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              if (offline) const OfflineBanner(),
              Expanded(
                child: Stack(
                  children: [
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 840),
                        child: content,
                      ),
                    ),
                    if (_added) const _AddedCheck(),
                  ],
                ),
              ),
            ],
          ),
        ),
        // In the bottom bar slot, so snackbars rise above it rather than cover "Add".
        bottomNavigationBar: _BottomBar(
          notice: notice,
          selectToggle: sel.pending.isEmpty
              ? null
              : (
                  label: sel.isAllPending ? l.selectNone : l.selectAll,
                  onPressed: _busy
                      ? null
                      : () => _write(sel.selectAll(on: !sel.isAllPending)),
                ),
          primary: ids.isEmpty
              ? l.foundSkip
              : sel.isAllPending
              ? l.foundAddAllCount(ids.length)
              : l.foundAddCount(ids.length),
          busy: _busy,
          onPrimary: ids.isEmpty ? _onward : add,
        ),
      ),
    );
  }

  /// "We found 37 matters", "33 pending · 4 disposed", Add all (N), search and filters.
  Widget _header(
    BuildContext context,
    FoundSelection sel,
    int? remaining,
    List<Court> courts,
  ) {
    final l = context.l10n;
    final search = SearchField(
      hint: l.searchCasesHint,
      controller: _search,
      onChanged: (q) => setState(() => _filter = _filter.withQuery(q)),
    );
    final filters = OutlinedButton.icon(
      onPressed: () => unawaited(_openFilters(sel.cases, courts)),
      icon: const Icon(AppIcons.funnel),
      label: Text(l.foundFilters(_filter.count)),
    );
    // Large text: Filters goes under the search box, so its hint (the field's only label) isn't cut off (§5.9).
    final stacked = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              l.foundHeading(sel.cases.length),
              style: context.text.titleLarge,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l.foundSummary(
              sel.pending.length,
              sel.cases.length - sel.pending.length,
            ),
            style: context.text.bodyLarge?.copyWith(color: context.colors.ink2),
          ),
          if (sel.pending.isNotEmpty)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => unawaited(_addAll(sel, remaining)),
              child: Text(l.foundAddAll(sel.pending.length)),
            ),
          const SizedBox(height: 8),
          if (stacked) ...[
            search,
            const SizedBox(height: 8),
            Align(alignment: AlignmentDirectional.centerStart, child: filters),
          ] else
            Row(
              children: [
                Expanded(child: search),
                const SizedBox(width: 8),
                filters,
              ],
            ),
        ],
      ),
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
          onPressed: _clearFilters,
          child: Text(context.l10n.foundClearFilters),
        ),
      ],
    ),
  );
}

/// One found case: checkbox, case number and type, short title, court and court number, next date, status, and an
/// overflow with "Not mine". The screen reader hears it whole: "Selected. WP 1234 of 2024. MP High Court Indore,
/// Court 12. Next date 5 November. Pending. Sharma v. State of MP." (spec §4.1 AC).
class _FoundRow extends StatelessWidget {
  const _FoundRow({
    required this.found,
    required this.court,
    required this.showCourt,
    required this.selected,
    required this.onChanged,
    required this.onAdd,
    required this.onNotMine,
    super.key,
  });

  final FoundCase found;
  final Court? court;

  /// The "Disposed" group mixes courts, so its rows name theirs.
  final bool showCourt;
  final bool selected;
  final VoidCallback onChanged;
  final VoidCallback? onAdd;
  final VoidCallback onNotMine;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final locale = Localizations.localeOf(context);
    final c = found;
    final courtName = court?.label(locale) ?? l.foundOtherCourt;
    final spokenCourt =
        court?.spokenLabel(locale, l.highCourt) ?? l.foundOtherCourt;
    final caseNo = c.caseLabel;
    final next = c.nextDate;
    final status = switch (c.caseStatus) {
      'pending' => l.foundPending,
      'disposed' => l.statusDisposed,
      'transferred' => l.foundTransferred,
      _ => l.foundStatusUnknown,
    };
    final title = c.title?.characters;
    final shortTitle = title == null || title.length <= 60
        ? c.title
        : '${title.take(59).toString().trimRight()}…';
    final spoken = [
      if (c.caseNumber.isEmpty || c.caseYear == null)
        caseNo
      else
        l.foundCaseSpoken(c.caseType, c.caseNumber, '${c.caseYear}'),
      [spokenCourt, if (c.courtNo != null) l.courtNo(c.courtNo!)].join(', '),
      if (next == null)
        l.noDate
      else
        '${l.nextDate} ${DateFormat('d MMMM', locale.languageCode == 'hi' ? 'hi' : 'en_IN').format(next)}',
      status,
      ?c.title,
      if (c.lowConfidence) l.foundCheck,
    ].join('. ');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: CallbackShortcuts(
            bindings: {for (final k in _enter) k: () => onAdd?.call()},
            child: SelectableRow(
              selected: selected,
              onChanged: (_) => onChanged(),
              title: shortTitle == null ? caseNo : '$caseNo  $shortTitle',
              subtitle: [
                if (showCourt) courtName,
                if (c.courtNo != null) l.courtNo(c.courtNo!),
                if (next == null)
                  l.noDate
                else
                  '${l.nextDate} ${Formats(locale).shortDate(next)}',
                status,
              ].join(' · '),
              warning: c.lowConfidence ? l.foundCheck : null,
              semanticsLabel: spoken,
            ),
          ),
        ),
        PopupMenuButton<void>(
          tooltip: l.foundRowActions(caseNo),
          icon: const Icon(AppIcons.dotsThreeVertical),
          itemBuilder: (_) => [
            PopupMenuItem(onTap: onNotMine, child: Text(l.foundNotMine)),
          ],
        ),
      ],
    );
  }
}

/// Sticky bottom bar: the allowance or error notice, Select all / None, and the primary action with a live count.
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.notice,
    required this.selectToggle,
    required this.primary,
    required this.busy,
    required this.onPrimary,
  });

  final String? notice;
  final ({String label, VoidCallback? onPressed})? selectToggle;
  final String primary;
  final bool busy;
  final VoidCallback? onPrimary;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final toggle = selectToggle;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: c.lineSide),
      ),
      child: SafeArea(
        top: false,
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (notice != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          notice!,
                          style: context.text.bodyMedium?.copyWith(
                            color: c.of(StatusKind.urgent).fg,
                          ),
                        ),
                      ),
                    ),
                  Wrap(
                    alignment: toggle == null
                        ? WrapAlignment.end
                        : WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (toggle != null)
                        TextButton(
                          onPressed: toggle.onPressed,
                          child: Text(toggle.label),
                        ),
                      BusyButton(
                        label: primary,
                        busy: busy,
                        onPressed: onPrimary,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Success check after adding: scales and fades in (spec §5.5 "Found cases → added").
class _AddedCheck extends StatelessWidget {
  const _AddedCheck();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final m = Motion.of(context);
    return Positioned.fill(
      child: ExcludeSemantics(
        child: ColoredBox(
          color: c.bg.withValues(alpha: 0.85),
          child: Center(
            child: RepaintBoundary(
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: m.slow,
                curve: m.enter,
                builder: (_, t, child) => Opacity(
                  opacity: t,
                  child: Transform.scale(scale: 0.5 + 0.5 * t, child: child),
                ),
                child: Icon(
                  AppIcons.checkCircleFill,
                  size: 96,
                  color: c.of(StatusKind.success).fg,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Filter by court, year, pending/disposed and match confidence; returns the new filter on "Show cases".
class _FilterSheet extends StatefulWidget {
  const _FilterSheet(this.filter, this.cases, this.courts);

  final FoundFilter filter;
  final List<FoundCase> cases;
  final List<Court> courts;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late String? _court = widget.filter.courtId;
  late int? _year = widget.filter.year;
  late String? _status = widget.filter.status;
  late String? _match = widget.filter.confidence;

  Widget _choices<T>(
    String label,
    List<(T, String)> options,
    T? value,
    ValueChanged<T?> onSelected,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 4),
        child: Semantics(
          header: true,
          child: Text(label, style: context.text.titleSmall),
        ),
      ),
      Wrap(
        spacing: 8,
        children: [
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
    final courtIds = {for (final c in widget.cases) c.courtId};
    final years = {for (final c in widget.cases) ?c.caseYear}.toList()
      ..sort((a, b) => b.compareTo(a));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(l.foundFilters(0), style: context.text.titleLarge),
        ),
        _choices(
          l.foundFilterCourt,
          [
            for (final c in widget.courts)
              if (courtIds.contains(c.id)) (c.id, c.label(locale)),
          ],
          _court,
          (v) => setState(() => _court = v),
        ),
        _choices(
          l.foundFilterYear,
          [for (final y in years) (y, '$y')],
          _year,
          (v) => setState(() => _year = v),
        ),
        _choices(
          l.foundFilterStatus,
          [('pending', l.foundPending), ('disposed', l.statusDisposed)],
          _status,
          (v) => setState(() => _status = v),
        ),
        _choices(
          l.foundFilterMatch,
          [('high', l.foundMatchSure), ('low', l.foundMatchCheck)],
          _match,
          (v) => setState(() => _match = v),
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
                _court = _status = _match = null;
                _year = null;
              }),
              child: Text(l.foundClearFilters),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                FoundFilter(
                  query: widget.filter.query,
                  courtId: _court,
                  year: _year,
                  status: _status,
                  confidence: _match,
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
