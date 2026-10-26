import 'dart:async';

import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/core/theme/tokens.g.dart';
import 'package:advocate_app/data/calendar.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/dashboard.dart';
import 'package:advocate_app/data/diary.dart';
import 'package:advocate_app/data/team.dart';
import 'package:advocate_app/features/calendar/calendar_screen.dart';
import 'package:advocate_app/features/cases/add_case.dart';
import 'package:advocate_app/features/today/today_screen.dart';
import 'package:advocate_app/ui/focus_ring.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/section_header.dart';
import 'package:advocate_app/ui/skeleton.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:advocate_app/ui/tiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// /dashboard (spec §4.4 F18 P1): four counts, each opening its view, then today's matters; a chamber's owner also
/// sees each member's cases heard this week. Reads the synced database, so it works offline.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final counts = ref.watch(dashboardProvider);
    final today = ref.watch(
      diaryProvider(isoDate(ref.watch(istTodayProvider))),
    );

    final Widget body;
    if (counts.hasError && !counts.hasValue) {
      body = ErrorState(
        message: errorText(l, counts.error),
        onRetry: () => ref
          ..invalidate(casesProvider)
          ..invalidate(calendarHearingsProvider)
          ..invalidate(tasksDueProvider)
          ..invalidate(newOrdersProvider)
          ..invalidate(orgMembersProvider),
      );
    } else if (counts.value case final c?) {
      final entries = today.value ?? const <DiaryEntry>[];
      body = c.empty && entries.isEmpty
          ? EmptyState(
              icon: AppIcons.chartBar,
              message: l.dashEmpty,
              actionLabel: l.addFirstCase,
              onAction: () => unawaited(showAddCaseChooser(context)),
            )
          : _list([
              _Tiles([
                _CountTile(
                  icon: AppIcons.briefcase,
                  label: l.dashActiveCases,
                  count: c.activeCases,
                  // The list showing exactly these: live, unarchived, not disposed.
                  onTap: () {
                    ref
                        .read(caseFilterProvider.notifier)
                        .change(
                          (f) => CaseFilter(
                            sort: f.sort,
                            status: CaseStatusFilter.pending,
                          ),
                        );
                    context.go('/cases');
                  },
                ),
                _CountTile(
                  icon: AppIcons.calendarBlank,
                  label: l.dashHearingsThisWeek,
                  count: c.hearingsThisWeek,
                  // This week, with hearings shown whatever the calendar's filters were.
                  onTap: () {
                    ref.read(calendarPrefsProvider.notifier)
                      ..setView(CalendarView.week)
                      ..select(null)
                      ..showAll();
                    context.go('/calendar');
                  },
                ),
                _CountTile(
                  icon: AppIcons.checkSquare,
                  label: l.dashOverdueTasks,
                  count: c.overdueTasks,
                  tone: StatusKind.urgent,
                  onTap: () => context.go('/today'),
                ),
                _CountTile(
                  icon: AppIcons.fileText,
                  label: l.todayNewOrders,
                  count: c.newOrders,
                  tone: StatusKind.newOrder,
                  onTap: () => context.go('/notifications?kind=new_order'),
                ),
              ]),
              _Today(today),
              if (c.team.isNotEmpty) ...[
                SectionHeader(l.dashTeam),
                for (final t in c.team)
                  MergeSemantics(
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Avatar(
                        t.member.name ?? roleLabel(l, t.member.role),
                      ),
                      title: Text(t.member.name ?? roleLabel(l, t.member.role)),
                      subtitle: Text(l.dashMemberCases(t.cases)),
                    ),
                  ),
              ],
            ]);
    } else {
      const tile = Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Skeleton(width: 24, height: 24),
              SizedBox(height: 8),
              Skeleton(width: 48, height: 32),
              SizedBox(height: 8),
              Skeleton(width: 96),
            ],
          ),
        ),
      );
      body = _list(const [
        _Tiles([tile, tile, tile, tile]),
        SizedBox(height: 16),
        SkeletonCaseList(count: 2),
      ]);
    }

    return Scaffold(
      appBar: AppBar(title: Text(l.navDashboard)),
      body: body,
    );
  }

  /// A readable column on Windows (tiles in one row), scrolling as a Column so Tab reaches every tile and row.
  static Widget _list(List<Widget> children) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    ),
  );
}

/// The tiles in rows of four, two or one: as many as fit at the current text size, rows of equal height.
class _Tiles extends StatelessWidget {
  const _Tiles(this.tiles);

  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final fit =
          box.maxWidth ~/ (160 * MediaQuery.textScalerOf(context).scale(1));
      final cols = fit >= 4 ? 4 : (fit >= 2 ? 2 : 1);
      return Column(
        children: [
          for (var i = 0; i < tiles.length; i += cols)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var j = i; j < i + cols; j++) ...[
                      if (j > i) const SizedBox(width: 12),
                      Expanded(child: tiles[j]),
                    ],
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );
}

/// A count and what it counts; opens the matching view. [tone] colours a count above zero (overdue, new orders).
class _CountTile extends StatelessWidget {
  const _CountTile({
    required this.icon,
    required this.label,
    required this.count,
    required this.onTap,
    this.tone,
  });

  final IconData icon;
  final String label;
  final int count;
  final VoidCallback onTap;
  final StatusKind? tone;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = tone != null && count > 0 ? c.of(tone!).fg : c.ink;
    final shown = Formats(Localizations.localeOf(context)).number(count);
    return Semantics(
      container: true,
      button: true,
      label: '$shown $label',
      excludeSemantics: true,
      onTap: onTap,
      child: FocusRing(
        radius: Radii.card,
        child: Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, color: tone != null && count > 0 ? color : c.ink2),
                  const SizedBox(height: 8),
                  Text(
                    shown,
                    style: context.text.headlineMedium?.copyWith(color: color),
                  ),
                  Text(label, style: context.text.bodyMedium),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Today's matters as Today lists them ([TodayMatters]), each opening its case.
class _Today extends StatelessWidget {
  const _Today(this.today);

  final AsyncValue<List<DiaryEntry>> today;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final entries = today.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(l.navToday, count: entries?.length),
        if (entries == null && today.hasError)
          Text(errorText(l, today.error), style: context.text.bodyLarge)
        else if (entries == null)
          const SkeletonCaseList(count: 2)
        else if (entries.isEmpty)
          Text(l.todayEmpty, style: context.text.bodyLarge)
        else
          TodayMatters(entries),
      ],
    );
  }
}
