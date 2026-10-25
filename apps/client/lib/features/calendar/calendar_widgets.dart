import 'dart:async';

import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/calendar.dart';
import 'package:advocate_app/data/case_text.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/diary_text.dart';
import 'package:advocate_app/ui/court_badge.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/sheets.dart';
import 'package:advocate_app/ui/tiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

/// What the calendar's type filter picks (spec §4.3 "filters by type").
enum CalendarType { hearing, deadline, task }

CalendarType calendarTypeOf(CalendarItem i) => switch (i) {
  CalendarHearing() => CalendarType.hearing,
  CalendarDeadline() => CalendarType.deadline,
  CalendarTask() => CalendarType.task,
};

String calendarTypeLabel(AppLocalizations l, CalendarType t) => switch (t) {
  CalendarType.hearing => l.calendarHearings,
  CalendarType.deadline => l.casePageDeadlines,
  CalendarType.task => l.casePageTasks,
};

/// A type's dot colour on the month grid and its filter chip (the chips are the legend; colour is never the only
/// signal: cells say their counts to screen readers and the day's list names each item).
Color calendarTypeColor(AppColors c, CalendarType t) => c.of(switch (t) {
  CalendarType.hearing => StatusKind.listed,
  CalendarType.deadline => StatusKind.adjourned,
  CalendarType.task => StatusKind.newOrder,
}).fg;

/// [d] in [pattern] for the UI language, as `Formats` does: "November 2026" / "नवंबर 2026".
String calendarFormat(Locale locale, String pattern, DateTime d) =>
    DateFormat(pattern, locale.languageCode == 'hi' ? 'hi' : 'en_IN').format(d);

/// "Today · Thu, 5 Nov 2026", "Tomorrow · Fri, 6 Nov 2026", else the date (spec §5.10: relative beside absolute).
String calendarDayTitle(
  AppLocalizations l,
  Locale locale,
  DateTime day,
  DateTime today,
) {
  final rel = day == today
      ? l.relToday
      : day == today.add(const Duration(days: 1))
      ? l.relTomorrow
      : null;
  return [?rel, Formats(locale).date(day)].join(' · ');
}

/// "2 hearings, 1 task"; empty for no items.
String calendarCountText(AppLocalizations l, List<CalendarItem> items) {
  int count(CalendarType t) =>
      items.where((i) => calendarTypeOf(i) == t).length;
  final (h, d, t) = (
    count(CalendarType.hearing),
    count(CalendarType.deadline),
    count(CalendarType.task),
  );
  return [
    if (h > 0) l.calendarCountHearings(h),
    if (d > 0) l.calendarCountDeadlines(d),
    if (t > 0) l.calendarCountTasks(t),
  ].join(', ');
}

/// A month cell as a screen reader says it (spec §5.9): "Thursday 5 November. Today. 2 hearings, 1 task."
String calendarDayLabel(
  AppLocalizations l,
  Locale locale,
  DateTime day,
  List<CalendarItem> items, {
  required DateTime today,
}) {
  final stop = locale.languageCode == 'hi' ? '।' : '.';
  final counts = calendarCountText(l, items);
  return [
    '${calendarFormat(locale, 'EEEE d MMMM', day)}$stop',
    if (day == today) '${l.relToday}$stop',
    if (counts.isEmpty) l.calendarEmptyDay else '$counts$stop',
  ].join(' ');
}

/// The month view's grid (spec §4.3): whole Monday-to-Sunday weeks, each day with up to three dots coloured by
/// type and "+n" for the rest; today outlined, [selected] filled. [days] are already filtered by type.
/// Cells are tap targets but not keyboard stops: on Windows the arrow keys move the selected day (the screen's).
class MonthGrid extends StatelessWidget {
  const MonthGrid({
    required this.selected,
    required this.today,
    required this.days,
    required this.onSelect,
    super.key,
  });

  final DateTime selected;
  final DateTime today;
  final CalendarDays days;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final locale = Localizations.localeOf(context);
    final dates = daysOf(monthGridRange(selected));
    // "M T W…" on a phone; "Mon Tue…" where there's room.
    final weekday = MediaQuery.sizeOf(context).width >= 840 ? 'EEE' : 'EEEEE';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Each cell says its weekday; the initials are for the eye.
        ExcludeSemantics(
          child: Row(
            children: [
              for (final d in dates.take(7))
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      calendarFormat(locale, weekday, d),
                      textAlign: TextAlign.center,
                      style: context.text.labelMedium?.copyWith(color: c.ink2),
                    ),
                  ),
                ),
            ],
          ),
        ),
        for (var w = 0; w < dates.length; w += 7)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final d in dates.skip(w).take(7))
                  Expanded(
                    child: _Cell(
                      day: d,
                      items: days[d] ?? const [],
                      inMonth: d.month == selected.month,
                      selected: d == selected,
                      today: today,
                      onTap: () => onSelect(d),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.day,
    required this.items,
    required this.inMonth,
    required this.selected,
    required this.today,
    required this.onTap,
  });

  final DateTime day;
  final List<CalendarItem> items;
  final bool inMonth;
  final bool selected;
  final DateTime today;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l = context.l10n;
    final isToday = day == today;
    final more = items.length - 3;
    // The day number in a pill: filled when selected, outlined when today (both: filled). The whole pill shrinks
    // rather than wrapping a digit per line in a narrow cell at 200% (a 360 dp phone).
    final number = FittedBox(
      fit: BoxFit.scaleDown,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        constraints: const BoxConstraints(minWidth: 32),
        decoration: ShapeDecoration(
          color: selected ? c.primaryFill : null,
          shape: StadiumBorder(
            side: isToday && !selected
                ? BorderSide(color: c.primary, width: 2)
                : BorderSide.none,
          ),
        ),
        child: Text(
          '${day.day}',
          textAlign: TextAlign.center,
          softWrap: false,
          style: context.text.titleSmall?.copyWith(
            color: selected
                ? c.onPrimary
                : inMonth
                ? c.ink
                : c.ink3,
          ),
        ),
      ),
    );
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      label: calendarDayLabel(
        l,
        Localizations.localeOf(context),
        day,
        items,
        today: today,
      ),
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        canRequestFocus: false,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                number,
                const SizedBox(height: 4),
                // Shrinks rather than overflowing a narrow cell at 200% text; the label above says the counts.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final i in items.take(3))
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 1.5),
                          child: _Dot(calendarTypeColor(c, calendarTypeOf(i))),
                        ),
                      if (more > 0)
                        Text(
                          '+$more',
                          style: context.text.labelSmall?.copyWith(
                            color: c.ink2,
                          ),
                        ),
                      // Keeps an empty day as tall as its row.
                      if (items.isEmpty) const SizedBox(height: 7),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot(this.color);

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 7,
    height: 7,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// A type filter chip's label with its dot: the grid's legend.
class CalendarTypeLabel extends StatelessWidget {
  const CalendarTypeLabel(this.type, {super.key});

  final CalendarType type;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _Dot(calendarTypeColor(context.colors, type)),
      const SizedBox(width: 6),
      Flexible(child: Text(calendarTypeLabel(context.l10n, type))),
    ],
  );
}

/// A row's key: a hearing is one per case per day.
Key calendarItemKey(CalendarItem i) => ValueKey(switch (i) {
  CalendarHearing(:final matterId, :final day) => 'h-$matterId-${isoDate(day)}',
  CalendarDeadline(:final id) => 'd-$id',
  CalendarTask(:final id) => 't-$id',
});

/// A calendar item as a row (spec §4.3): a hearing or a deadline opens its case; a task is ticked done (with
/// Undo, like the case page) and opens its case from the arrow beside it. Done deadlines and tasks are struck
/// through.
class CalendarItemRow extends ConsumerWidget {
  const CalendarItemRow(this.item, {super.key});

  final CalendarItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final matterId = item.matterId;
    final open = matterId == null
        ? null
        : () => unawaited(context.push('/cases/$matterId'));
    return switch (item) {
      final CalendarHearing h => _hearing(context, h, open!),
      final CalendarDeadline d => _deadline(context, d, open),
      final CalendarTask t => _task(context, ref, t, open),
    };
  }

  Widget _hearing(BuildContext context, CalendarHearing h, VoidCallback open) {
    final l = context.l10n;
    final locale = Localizations.localeOf(context);
    final e = h.entry;
    final stop = locale.languageCode == 'hi' ? '।' : '.';
    final court = e.court?.label(locale) ?? l.foundOtherCourt;
    final spoken = [
      l.casePageHearing,
      spokenCaseLabel(l, e.caseLabel),
      e.court?.spokenLabel(locale, l.highCourt) ?? court,
      ?positionText(l, e),
      ?e.purpose,
    ].map((s) => '$s$stop').join(' ');
    return Semantics(
      container: true,
      button: true,
      label: spoken,
      excludeSemantics: true,
      onTap: open,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        minVerticalPadding: 8,
        leading: Icon(
          AppIcons.gavel,
          color: calendarTypeColor(context.colors, CalendarType.hearing),
        ),
        title: Text(e.caseLabel, style: context.text.titleSmall),
        subtitle: Text(
          [
            CourtBadge.text(context, court, e.courtNo, e.itemNo),
            ?e.purpose,
          ].join(' · '),
          style: context.text.bodySmall,
        ),
        onTap: open,
      ),
    );
  }

  Widget _deadline(
    BuildContext context,
    CalendarDeadline d,
    VoidCallback? open,
  ) {
    final l = context.l10n;
    final c = context.colors;
    final stop = Localizations.localeOf(context).languageCode == 'hi'
        ? '।'
        : '.';
    final kind = deadlineKindLabel(l, d.kind);
    final line = [l.calendarDeadline, ?d.caseLabel, if (d.done) l.calendarDone];
    return Semantics(
      container: true,
      button: open != null,
      label: [
        l.calendarDeadline,
        kind,
        if (d.caseLabel case final label?) spokenCaseLabel(l, label),
        if (d.done) l.calendarDone,
      ].map((s) => '$s$stop').join(' '),
      excludeSemantics: true,
      onTap: open,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        minVerticalPadding: 8,
        leading: Icon(
          AppIcons.clock,
          color: calendarTypeColor(c, CalendarType.deadline),
        ),
        title: Text(
          kind,
          style: context.text.titleSmall?.copyWith(
            decoration: d.done ? TextDecoration.lineThrough : null,
            color: d.done ? c.ink3 : null,
          ),
        ),
        subtitle: Text(line.join(' · '), style: context.text.bodySmall),
        onTap: open,
      ),
    );
  }

  /// Done with a light haptic (unless switched off) and Undo; reopening needs neither (spec §5.5).
  void _toggle(
    BuildContext context,
    WidgetRef ref,
    CalendarTask t, {
    required bool done,
  }) {
    final writer = ref.read(caseWriterProvider);
    unawaited(writer.setTaskDone(t.id, done: done));
    if (!done) return;
    if (ref.read(settingsProvider).haptics) {
      unawaited(HapticFeedback.lightImpact());
    }
    showUndoSnackbar(
      context,
      message: context.l10n.todayTaskDone,
      onUndo: () => unawaited(writer.setTaskDone(t.id, done: false)),
    );
  }

  Widget _task(
    BuildContext context,
    WidgetRef ref,
    CalendarTask t,
    VoidCallback? open,
  ) {
    final ist = istOf(t.dueAt);
    final today = ref.watch(istTodayProvider);
    return Row(
      children: [
        Expanded(
          child: TaskItem(
            title: [t.title, ?t.caseLabel].join(' · '),
            done: t.done,
            // The day is the list's heading; midnight IST means no time (task 9).
            due: ist.hour == 0 && ist.minute == 0
                ? null
                : Formats(Localizations.localeOf(context)).time(ist),
            overdue: !t.done && t.dueAt.isBefore(istInstant(today)),
            onChanged: (done) => _toggle(context, ref, t, done: done),
          ),
        ),
        if (open != null)
          IconButton(
            tooltip: context.l10n.calendarOpenCase(t.caseLabel ?? ''),
            icon: const Icon(AppIcons.caretRight),
            onPressed: open,
          ),
      ],
    );
  }
}
