import 'dart:async';

import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/flags.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/core/theme/app_theme.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/diary.dart';
import 'package:advocate_app/data/diary_text.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:advocate_app/features/cases/add_case.dart';
import 'package:advocate_app/features/lock/app_lock.dart';
import 'package:advocate_app/features/today/today_refresh.dart';
import 'package:advocate_app/ui/board_table.dart';
import 'package:advocate_app/ui/case_card.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/section_header.dart';
import 'package:advocate_app/ui/sheets.dart';
import 'package:advocate_app/ui/skeleton.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:advocate_app/ui/tiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Today (spec §4.2, §5.3): where to be and when, in India time. Before the evening switch the hero card shows the
/// next matter; from the switch (18:30 IST, configurable) until midnight the Tomorrow banner leads. Then today's
/// matters by court, tasks due, new orders and what needs attention. Reads come from the synced database, so it
/// works offline. Pull down, or press F5 on Windows, to ask the court about today's tracked cases.
class TodayScreen extends ConsumerStatefulWidget {
  const TodayScreen({super.key});

  @override
  ConsumerState<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends ConsumerState<TodayScreen> {
  final _refresher = GlobalKey<RefreshIndicatorState>();

  /// Shows "Fetching from court…" while a refresh runs (spec §5.5), not only the spinner.
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  /// F5 refreshes (spec §5.12) wherever focus is (the shell holds it until the user tabs in), while Today is the
  /// page on top and the app isn't locked (the lock screen covers Today without changing its route).
  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent ||
        e.logicalKey != LogicalKeyboardKey.f5 ||
        !mounted ||
        ModalRoute.isCurrentOf(context) == false ||
        ref.read(appLockProvider).locked) {
      return false;
    }
    unawaited(_refresher.currentState?.show());
    return true;
  }

  /// One snackbar summary (spec §11.5: at most one refresh per case per 6 h; a recent one counts as up to date).
  Future<void> _refresh() async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final org = ref.read(currentOrgIdProvider);
    final offline = ref.read(syncViewProvider).value?.offline ?? false;
    final today =
        ref.read(diaryProvider(isoDate(ref.read(istTodayProvider)))).value ??
        const <DiaryEntry>[];
    final RefreshOutcome outcome;
    if (offline || org == null) {
      outcome = (checking: 0, upToDate: 0, offline: offline, error: null);
    } else {
      setState(() => _refreshing = true);
      try {
        outcome = await refreshMatters(
          ref.read(apiClientProvider),
          orgId: org,
          matterIds: [
            for (final e in today)
              if (e.tracking == 'auto') e.matterId,
          ],
        );
      } finally {
        if (mounted) setState(() => _refreshing = false);
      }
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(refreshSummary(l, outcome))));
  }

  void _open(String path) => unawaited(context.push(path));

  void _completeTask(DueTask t) {
    final writer = ref.read(diaryWriterProvider);
    unawaited(writer.completeTask(t.id));
    // Done: a light haptic unless switched off (spec §5.5, §5.9).
    if (ref.read(settingsProvider).haptics) {
      unawaited(HapticFeedback.lightImpact());
    }
    showUndoSnackbar(
      context,
      message: context.l10n.todayTaskDone,
      onUndo: () => unawaited(writer.reopenTask(t.id)),
    );
  }

  void _openNotice(DiaryNotice n) {
    unawaited(ref.read(diaryWriterProvider).markNotificationRead(n.id));
    final link = n.link ?? (n.matterId == null ? null : '/cases/${n.matterId}');
    if (link != null) _open(link);
  }

  void _openAttention(AttentionItem a) {
    if (a.notificationId case final id?) {
      unawaited(ref.read(diaryWriterProvider).markNotificationRead(id));
    }
    if (a.matterId case final id?) _open('/cases/$id');
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final locale = Localizations.localeOf(context);
    final f = Formats(locale);
    final theme = ref.watch(settingsProvider.select((s) => s.theme));
    final sunlight = theme == AppThemeMode.sunlight;
    final sync = ref.watch(syncViewProvider).value?.status ?? SyncStatus.synced;
    final day = ref.watch(istTodayProvider);
    final today = ref.watch(diaryProvider(isoDate(day)));
    final tomorrow = ref
        .watch(diaryProvider(isoDate(ref.watch(istTomorrowProvider))))
        .value;
    final evening = ref.watch(eveningProvider);
    final entries = today.value ?? const <DiaryEntry>[];
    final hero = evening ? null : heroEntry(entries, ref.watch(istNowProvider));
    final tasks = ref.watch(tasksDueProvider).value ?? const <DueTask>[];
    final orders = ref.watch(newOrdersProvider).value ?? const <DiaryNotice>[];
    final attention =
        ref.watch(needsAttentionProvider).value ?? const <AttentionItem>[];
    // Watched here so it's warm when the empty state needs it; still loading isn't "no cases".
    final noCases = ref.watch(hasMattersProvider).value == false;
    void toBoard() => _open('/board/tomorrow');

    final Widget dayList;
    if (today.hasError && !today.hasValue) {
      dayList = ErrorState(
        message: errorText(l, today.error),
        onRetry: () => ref.invalidate(diaryProvider(isoDate(day))),
      );
    } else if (!today.hasValue) {
      dayList = const SkeletonCaseList();
    } else if (entries.isEmpty) {
      // The banner already leads to tomorrow in the evening.
      final toTomorrow = !evening && (tomorrow?.isNotEmpty ?? false);
      dayList = EmptyState(
        icon: AppIcons.coffee,
        message: l.todayEmpty,
        actionLabel: toTomorrow
            ? l.todayTomorrowLink(tomorrow!.length)
            : noCases
            ? l.addFirstCase
            : null,
        onAction: toTomorrow ? toBoard : () => showAddCaseChooser(context),
      );
    } else {
      // The kit's board rows, by court: case number, court and item number, clash and why, proxy arranged.
      // ponytail: rows appear without spec §5.5's fade-and-rise stagger (and a done task without the check-mark
      // draw); add both with the kit's motion helpers, off under reduce motion.
      dayList = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(l.navToday, count: entries.length),
          BoardTable([
            for (final e in entries)
              BoardRow(
                caseNumber: e.caseLabel,
                court: e.court?.label(locale) ?? l.foundOtherCourt,
                courtNo: e.courtNo,
                itemNo: e.itemNo,
                // Partial data says so plainly (spec §5.4).
                purpose: e.itemNo == null ? l.todayNoItem : null,
                clash: e.clash,
                proxy: e.proxyArranged,
                note: clashExplanation(l, locale, e, entries),
                semanticsLabel: diaryRowLabel(l, locale, e),
                onTap: () => _open('/cases/${e.matterId}'),
              ),
          ]),
        ],
      );
    }

    final content = <Widget>[
      if (_refreshing)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          // The indicator already says it to screen readers.
          child: ExcludeSemantics(
            child: Text(
              l.todayRefreshing,
              textAlign: TextAlign.center,
              style: context.text.bodySmall,
            ),
          ),
        ),
      if (evening && tomorrow != null)
        _TomorrowBanner(tomorrow, onTap: toBoard)
      else if (hero != null) ...[
        SectionHeader(l.todayNext),
        _Hero(
          hero,
          day: day,
          briefMe: ref.watch(featureFlagsProvider).on(FeatureFlag.briefMe),
          onOpen: _open,
        ),
      ],
      dayList,
      if (tasks.isNotEmpty) ...[
        SectionHeader(l.todayTasksDue, count: tasks.length),
        for (final t in tasks)
          TaskItem(
            key: ValueKey(t.id),
            title: [t.title, ?t.caseLabel].join(' · '),
            done: false,
            overdue: t.overdue,
            due: t.overdue
                ? f.shortDate(istOf(t.dueAt))
                : f.time(istOf(t.dueAt)),
            onChanged: (_) => _completeTask(t),
          ),
      ],
      if (orders.isNotEmpty) ...[
        SectionHeader(l.todayNewOrders, count: orders.length),
        for (final n in orders)
          ListTile(
            key: ValueKey(n.id),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(AppIcons.fileText),
            title: Text(n.caseLabel ?? l.statusNewOrder),
            subtitle: n.caseLabel == null ? null : Text(l.statusNewOrder),
            onTap: () => _openNotice(n),
          ),
      ],
      if (attention.isNotEmpty) ...[
        SectionHeader(l.todayAttention, count: attention.length),
        for (final a in attention) _AttentionTile(a, onTap: _openAttention),
      ],
      // The board stays one tap away all day, once tomorrow has something on it.
      if (!evening && entries.isNotEmpty && (tomorrow?.isNotEmpty ?? false))
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(AppIcons.calendarBlank),
          title: Text(l.todayTomorrowLink(tomorrow!.length)),
          trailing: const Icon(AppIcons.caretRight),
          onTap: toBoard,
        ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text('${l.navToday} · ${f.shortDate(day)}'),
        actions: [
          SyncIndicator(sync),
          // Sunlight is one tap from Today because people need it outdoors (spec §5.6).
          IconButton(
            tooltip: l.sunlightToggle,
            isSelected: sunlight,
            icon: const Icon(AppIcons.sunDim),
            selectedIcon: const Icon(AppIcons.sunDimFill),
            onPressed: () => ref
                .read(settingsProvider.notifier)
                .setTheme(
                  sunlight ? AppThemeMode.system : AppThemeMode.sunlight,
                ),
          ),
        ],
      ),
      body: RefreshIndicator(
        key: _refresher,
        onRefresh: _refresh,
        semanticsLabel: l.todayRefreshing,
        child: SingleChildScrollView(
          // A Column, not a lazy list, so Tab reaches every row; Today is tens of rows at most.
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Align(
            alignment: Alignment.topCenter,
            // Windows: a readable column rather than lines across the whole window.
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: content,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The next matter (spec §4.2 hero card): Open and Notes; Brief me only behind its flag (P2). The item tracker is P2.
class _Hero extends StatelessWidget {
  const _Hero(
    this.entry, {
    required this.day,
    required this.briefMe,
    required this.onOpen,
  });

  final DiaryEntry entry;
  final DateTime day;
  final bool briefMe;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final e = entry;
    final path = '/cases/${e.matterId}';
    // Partial data says so plainly (spec §5.4).
    final purpose = [?e.purpose, if (e.itemNo == null) l.todayNoItem];
    return CaseCard(
      CaseCardData(
        caseNumber: e.caseLabel,
        title: e.title ?? '',
        court:
            e.court?.label(Localizations.localeOf(context)) ??
            l.foundOtherCourt,
        courtNo: e.courtNo,
        itemNo: e.itemNo,
        judge: e.bench,
        purpose: purpose.isEmpty ? null : purpose.join(' · '),
        nextDate: day,
      ),
      variant: CaseCardVariant.hero,
      today: day,
      onTap: () => onOpen(path),
      actions: [
        FilledButton(onPressed: () => onOpen(path), child: Text(l.todayOpen)),
        OutlinedButton(
          onPressed: () => onOpen('$path?tab=notes'),
          child: Text(l.caseNotes),
        ),
        if (briefMe)
          OutlinedButton(
            onPressed: () => onOpen('$path?tab=brief'),
            child: Text(l.todayBriefMe),
          ),
      ],
    );
  }
}

/// "Tomorrow: 6 matters in 3 courts" from the evening switch until midnight; opens Tomorrow's Board.
class _TomorrowBanner extends StatelessWidget {
  const _TomorrowBanner(this.entries, {required this.onTap});

  final List<DiaryEntry> entries;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = context.colors;
    return Card(
      color: c.isSunlight ? null : c.primarySoft,
      margin: const EdgeInsets.only(top: 16),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Icon(AppIcons.calendarBlank, color: c.primary),
        title: Text(
          entries.isEmpty
              ? l.todayTomorrowNone
              : l.todayTomorrowBanner(entries.length, entries.courtCount),
          style: context.text.titleMedium,
        ),
        subtitle: Text(l.boardTitle),
        trailing: const Icon(AppIcons.caretRight),
        onTap: onTap,
      ),
    );
  }
}

/// A "Needs attention" item (spec §4.2, §11.6). Case items open the case; "Court data is delayed" hides on tap.
class _AttentionTile extends StatelessWidget {
  const _AttentionTile(this.item, {required this.onTap});

  final AttentionItem item;
  final ValueChanged<AttentionItem> onTap;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final f = Formats(Localizations.localeOf(context));
    final a = item;
    final delayed = a.kind == AttentionKind.courtDataDelayed;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        AppIcons.warningCircle,
        color: context.colors.of(StatusKind.adjourned).fg,
      ),
      title: Text(delayed ? l.todayAttnDelayed : a.caseLabel ?? ''),
      subtitle: Text(switch (a.kind) {
        AttentionKind.noNextDate => l.todayAttnNoNextDate,
        AttentionKind.courtDataPending => l.todayAttnPending,
        AttentionKind.courtDataDelayed => l.todayAttnDelayedBody,
        AttentionKind.addNextDate => l.todayAttnAddDate,
        AttentionKind.dateMismatch => l.todayAttnMismatch(
          f.shortDate(a.courtDate!),
          f.shortDate(a.userDate!),
        ),
      }),
      onTap: () => onTap(a),
    );
  }
}
