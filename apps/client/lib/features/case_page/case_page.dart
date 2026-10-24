import 'dart:async';

import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/diary_text.dart';
import 'package:advocate_app/features/board/assign_sheet.dart';
import 'package:advocate_app/features/case_page/case_page_text.dart';
import 'package:advocate_app/features/case_page/case_share.dart';
import 'package:advocate_app/features/case_page/client_tab.dart';
import 'package:advocate_app/features/case_page/documents_tab.dart';
import 'package:advocate_app/features/case_page/links.dart';
import 'package:advocate_app/features/case_page/notes_tab.dart';
import 'package:advocate_app/features/case_page/timeline_tab.dart';
import 'package:advocate_app/features/lock/app_lock.dart';
import 'package:advocate_app/features/today/today_refresh.dart';
import 'package:advocate_app/ui/court_badge.dart';
import 'package:advocate_app/ui/hearing_chip.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/sheets.dart';
import 'package:advocate_app/ui/skeleton.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:advocate_app/ui/status_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// `/cases/:id` (spec §4.3 Case page, §5.3): full screen on phones, the detail pane of `CasesScreen` on wide windows.
/// The header (number, title, court, bench, stage, pills, next date, where the data comes from, assignee), actions
/// (Refresh, Share case status, the official portal, tracking on/off, archive, delete) and the tabs Timeline ·
/// Documents · Notes & tasks · Client (the AI tab waits for P2's `ask`/`brief_me`). Reads come from the synced
/// database, so it works offline; Refresh, the portal, tracking, delete and opening files need the network and say
/// so. F5 refreshes on Windows (spec §5.12). Notification links (`data.link`) open it; `?tab=notes` opens a tab.
class CasePage extends ConsumerStatefulWidget {
  const CasePage({
    required this.matterId,
    this.tab,
    this.pane = false,
    super.key,
  });

  final String matterId;

  /// The tab a link asked for: `timeline` (the default), `documents`, `notes` or `client`.
  final String? tab;

  /// The detail pane beside the Cases list (spec §5.3 Windows): no back arrow, the list is right there.
  final bool pane;

  @override
  ConsumerState<CasePage> createState() => _CasePageState();
}

enum _Action { portal, trackingOn, trackingOff, archive, delete }

class _CasePageState extends ConsumerState<CasePage>
    with SingleTickerProviderStateMixin {
  late final _tabs = TabController(
    length: CaseTab.values.length,
    vsync: this,
    initialIndex: CaseTab.of(widget.tab).index,
  );

  /// "Fetching from court…" while a refresh runs (spec §5.5).
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void didUpdateWidget(CasePage old) {
    super.didUpdateWidget(old);
    // A link to another tab of this case reuses the page (each case's page is keyed by its id).
    if (old.tab != widget.tab) {
      _tabs.index = CaseTab.of(widget.tab).index;
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _tabs.dispose();
    super.dispose();
  }

  CaseInfo? get _case => ref.read(caseProvider(widget.matterId)).value;

  /// F5 refreshes the case (spec §5.12) while it is the page on top and the app isn't locked.
  bool _onKey(KeyEvent e) {
    final c = _case;
    if (e is! KeyDownEvent ||
        e.logicalKey != LogicalKeyboardKey.f5 ||
        !mounted ||
        ModalRoute.isCurrentOf(context) == false ||
        ref.read(appLockProvider).locked ||
        c == null ||
        c.tracking != 'auto') {
      return false;
    }
    unawaited(_refresh(c));
    return true;
  }

  /// Asks the court about this case (spec §11.5: at most once per 6 h, so a recent one is "Already up to date").
  Future<void> _refresh(CaseInfo c) async {
    final org = ref.read(currentOrgIdProvider);
    if (_refreshing || org == null) return;
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _refreshing = true);
    final RefreshOutcome outcome;
    try {
      outcome = await refreshMatters(
        ref.read(apiClientProvider),
        orgId: org,
        matterIds: [c.id],
      );
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
    // Another case took this page's place (wide window) or the user left it: the outcome isn't theirs to read.
    if (!mounted) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(refreshSummary(l, outcome))));
  }

  /// Runs an API [call] for this case, saying what went wrong (offline, the allowance…) in a snackbar.
  Future<bool> _api(
    Future<void> Function(ApiClient api, String orgId) call,
  ) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final org = ref.read(currentOrgIdProvider);
    try {
      if (org == null) throw const ApiException('NOT_A_MEMBER');
      await call(ref.read(apiClientProvider), org);
      return true;
    } on ApiException catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(trackErrorText(l, e))));
      return false;
    }
  }

  /// The official portal (spec §4.3), outside the app. It may ask for a CAPTCHA, so this says so first and copies
  /// the CNR for pasting there.
  Future<void> _portal(CaseInfo c) async {
    final l = context.l10n;
    ({String url, String cnr, bool verified})? link;
    await _api(
      (api, org) async =>
          link = await api.officialLink(orgId: org, matterId: c.id),
    );
    if (link == null || !mounted) return;
    final (:url, :cnr, verified: _) = link!;
    await Clipboard.setData(ClipboardData(text: cnr));
    if (!mounted) return;
    final open = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l.casePagePortalTitle),
        content: Text(l.casePagePortalBody(cnr)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l.casePagePortalOpen),
          ),
        ],
      ),
    );
    if ((open ?? false) && mounted) {
      await openExternal(context, ref, Uri.parse(url));
    }
  }

  /// Tracking on/off (ADR 0015, `PATCH /v1/matters/{id}`); turning it off asks first. Sync brings the new state.
  Future<void> _tracking(CaseInfo c, {required bool on}) async {
    final l = context.l10n;
    if (!on &&
        !await showConfirmDialog(
          context,
          title: l.casePageTrackingOffTitle,
          body: l.casePageTrackingOffBody,
          confirmLabel: l.casePageTrackingOff,
        )) {
      return;
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (await _api(
      (api, org) => api.setTracking(
        orgId: org,
        matterId: c.id,
        tracking: on ? 'auto' : 'off',
      ),
    )) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              on ? l.casePageTrackingOnDone : l.casePageTrackingOffDone,
            ),
          ),
        );
    }
  }

  /// Archive or Unarchive (a device write), with Undo.
  Future<void> _archive(CaseInfo c) async {
    final l = context.l10n;
    final writer = ref.read(caseWriterProvider);
    final archived = !c.archived;
    await writer.setArchived(c.id, archived: archived);
    if (!mounted) return;
    showUndoSnackbar(
      context,
      message: archived ? l.casePageArchivedSnack : l.casePageUnarchivedSnack,
      onUndo: () => unawaited(writer.setArchived(c.id, archived: !archived)),
    );
  }

  /// Delete (owners and advocates, spec §15.3): asks, deletes through the API, then back to the list.
  Future<void> _delete(CaseInfo c) async {
    final l = context.l10n;
    if (!await showConfirmDialog(
          context,
          title: l.casePageDeleteTitle(c.caseLabel),
          body: l.casePageDeleteCaseBody,
          confirmLabel: l.casePageDelete,
        ) ||
        !mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    if (await _api(
      (api, org) => api.deleteMatter(orgId: org, matterId: c.id),
    )) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(l.casePageDeleted)));
      router.go('/cases');
    }
  }

  /// Assign to (`matters.assigned_to`, a device write), or no one, with Undo.
  Future<void> _assign(CaseInfo c) async {
    final l = context.l10n;
    final writer = ref.read(caseWriterProvider);
    final me = ref.read(currentUserIdProvider);
    final picked = await showAssignSheet(
      context,
      caseLabel: c.caseLabel,
      currentId: c.assigneeId,
      allowNone: true,
    );
    final m = picked?.member;
    if (picked == null || m?.userId == c.assigneeId) return;
    await writer.assignCase(c.id, m?.userId);
    if (!mounted) return;
    showUndoSnackbar(
      context,
      message: l.boardAssignedSnack(
        c.caseLabel,
        m == null
            ? l.casePageAssignNone
            : m.userId == me
            ? l.boardYou
            : memberName(l, m),
      ),
      onUndo: () => unawaited(writer.assignCase(c.id, c.assigneeId)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final async = ref.watch(caseProvider(widget.matterId));
    final c = async.value;
    if (c == null) {
      // A case just added waits for sync to bring its row.
      final added = ref.watch(addedCasesProvider).contains(widget.matterId);
      return Scaffold(
        appBar: AppBar(automaticallyImplyLeading: !widget.pane),
        body: async.isLoading || (added && !async.hasError)
            ? const _Loading()
            : async.hasError
            ? ErrorState(
                message: errorText(l, async.error),
                onRetry: () => ref.invalidate(caseProvider(widget.matterId)),
              )
            : EmptyState(
                icon: AppIcons.briefcase,
                message: l.casePageRemoved,
                actionLabel: l.casePageBackToCases,
                onAction: () => context.go('/cases'),
              ),
      );
    }

    final role = ref.watch(currentOrgProvider)?.role;
    final hearings = ref.watch(caseHearingsProvider(c.id)).value ?? const [];
    final purpose = nextPurposeOf(c, hearings);
    final tracked = c.cnr != null && !c.manual;
    final scale = MediaQuery.textScalerOf(context);
    // Tabs grow with the text (spec §5.9: 200% without losing labels), 48 dp at least.
    final tabBar = TabBar(
      controller: _tabs,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      tabs: [
        for (final t in CaseTab.values)
          Tab(
            height: scale.scale(26) + 22,
            text: switch (t) {
              CaseTab.timeline => l.casePageTabTimeline,
              CaseTab.documents => l.navDocuments,
              CaseTab.notes => l.casePageTabNotes,
              CaseTab.client => l.boardClient,
            },
          ),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.pane,
        // Shrinks rather than clips at 200% text.
        title: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Text(
            c.caseLabel,
            semanticsLabel: spokenCaseLabel(l, c.caseLabel),
            style: context.text.titleMedium,
          ),
        ),
        actions: [
          if (c.tracking == 'auto')
            IconButton(
              tooltip: l.casePageRefresh,
              icon: const Icon(AppIcons.arrowClockwise),
              onPressed: _refreshing ? null : () => unawaited(_refresh(c)),
            ),
          IconButton(
            tooltip: l.casePageShare,
            icon: const Icon(AppIcons.shareNetwork),
            onPressed: () =>
                unawaited(showCaseShareSheet(context, c, purpose: purpose)),
          ),
          PopupMenuButton<_Action>(
            tooltip: l.casePageMore,
            icon: const Icon(AppIcons.dotsThreeVertical),
            onSelected: (a) => unawaited(switch (a) {
              _Action.portal => _portal(c),
              _Action.trackingOn => _tracking(c, on: true),
              _Action.trackingOff => _tracking(c, on: false),
              _Action.archive => _archive(c),
              _Action.delete => _delete(c),
            }),
            itemBuilder: (_) => [
              if (c.cnr != null)
                PopupMenuItem(
                  value: _Action.portal,
                  child: Text(l.casePagePortal),
                ),
              if (tracked && c.trackingOff)
                PopupMenuItem(
                  value: _Action.trackingOn,
                  child: Text(l.casePageTrackingOn),
                )
              else if (tracked)
                PopupMenuItem(
                  value: _Action.trackingOff,
                  child: Text(l.casePageTrackingOff),
                ),
              PopupMenuItem(
                value: _Action.archive,
                child: Text(
                  c.archived ? l.casePageUnarchive : l.casePageArchive,
                ),
              ),
              if (role == 'owner' || role == 'advocate')
                PopupMenuItem(
                  value: _Action.delete,
                  child: Text(l.casePageDelete),
                ),
            ],
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            sliver: SliverToBoxAdapter(
              child: _Header(
                c,
                purpose: purpose,
                refreshing: _refreshing,
                onRefresh: () => unawaited(_refresh(c)),
                onAddDate: () =>
                    unawaited(showHearingSheet(context, matterId: c.id)),
                onAssign: () => unawaited(_assign(c)),
              ),
            ),
          ),
          SliverPersistentHeader(
            pinned: true,
            delegate: _TabBarHeader(tabBar, context.colors.bg),
          ),
          ListenableBuilder(
            listenable: _tabs,
            builder: (_, _) => SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              sliver: switch (CaseTab.values[_tabs.index]) {
                CaseTab.timeline => TimelineTab(c),
                CaseTab.documents => DocumentsTab(c),
                CaseTab.notes => NotesTab(c),
                CaseTab.client => ClientTab(c),
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The case header (spec §4.3, §5.3 wireframe).
class _Header extends ConsumerWidget {
  const _Header(
    this.c, {
    required this.purpose,
    required this.refreshing,
    required this.onRefresh,
    required this.onAddDate,
    required this.onAssign,
  });

  final CaseInfo c;
  final String? purpose;
  final bool refreshing;
  final VoidCallback onRefresh;
  final VoidCallback onAddDate;
  final VoidCallback onAssign;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final locale = Localizations.localeOf(context);
    final today = ref.watch(istTodayProvider);
    final me = ref.watch(currentUserIdProvider);
    final unread =
        ref.watch(caseOrdersProvider(c.id)).value?.any((o) => !o.read) ?? false;
    final pills = casePills(c, today, newOrder: unread);
    final next = c.nextDate;
    final bench = [
      if (c.judge != null) l.casePageBench(c.judge!),
      if (c.stage != null) l.casePageStage(c.stage!),
    ].join(' · ');
    final assignee = c.assigneeId == null
        ? null
        : c.assigneeId == me
        ? l.boardYou
        : c.assigneeName;
    final small = context.text.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // A manual case without a number already shows its title as the label.
        if (c.title != null && c.numbered) ...[
          Text(c.title!, style: context.text.titleMedium),
          const SizedBox(height: 8),
        ],
        CourtBadge(
          court: c.courtLabel(locale) ?? l.foundOtherCourt,
          courtNo: c.courtNo,
        ),
        if (bench.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(bench, style: small),
        ],
        const SizedBox(height: 12),
        if (pills.isNotEmpty || (next != null && !c.disposed))
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final p in pills) StatusPill(p),
              if (next != null && !c.disposed) ...[
                HearingChip(date: next, today: today),
                if (purpose != null) Text(purpose!, style: small),
              ],
            ],
          ),
        // Partial data says so plainly and offers the way out (spec §5.4).
        if (next == null && !c.disposed)
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(l.casesNoNextDate, style: context.text.bodyMedium),
              if (c.tracking == 'auto')
                TextButton(
                  onPressed: refreshing ? null : onRefresh,
                  child: Text(l.casePageRefresh),
                )
              else if (c.manual)
                TextButton(
                  onPressed: onAddDate,
                  child: Text(l.casePageAddDate),
                ),
            ],
          ),
        const SizedBox(height: 8),
        Text(caseStatusLine(l, locale, c, today), style: small),
        if (refreshing)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Semantics(
              liveRegion: true,
              child: Text(l.todayRefreshing, style: small),
            ),
          ),
        const SizedBox(height: 4),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            Text(
              assignee == null
                  ? l.casePageUnassigned
                  : l.boardAssigneeIs(assignee),
              style: context.text.bodyMedium,
            ),
            TextButton.icon(
              onPressed: onAssign,
              icon: const Icon(AppIcons.userSwitch),
              label: Text(l.boardAssignTo),
            ),
          ],
        ),
      ],
    );
  }
}

/// Keeps the tabs in view while the page scrolls.
class _TabBarHeader extends SliverPersistentHeaderDelegate {
  _TabBarHeader(this.tabBar, this.color);

  final TabBar tabBar;
  final Color color;

  @override
  double get minExtent => tabBar.preferredSize.height;

  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) =>
      ColoredBox(color: color, child: tabBar);

  @override
  bool shouldRebuild(_TabBarHeader old) =>
      old.tabBar != tabBar || old.color != color;
}

/// The case loading: skeleton lines shaped like the header.
class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Skeleton(width: 240, height: 22),
        SizedBox(height: 12),
        Skeleton(width: 180),
        SizedBox(height: 12),
        Skeleton(width: 140, height: 28),
        SizedBox(height: 24),
        SkeletonCaseList(count: 2),
      ],
    ),
  );
}
