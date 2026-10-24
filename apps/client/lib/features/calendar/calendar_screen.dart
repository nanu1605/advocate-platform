import 'dart:math' as math;

import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/calendar.dart';
import 'package:advocate_app/features/calendar/calendar_widgets.dart';
import 'package:advocate_app/features/lock/app_lock.dart';
import 'package:advocate_app/ui/app_scaffold.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/section_header.dart';
import 'package:advocate_app/ui/skeleton.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The calendar's views (spec §4.3).
enum CalendarView { day, week, month, agenda }

/// What the calendar shows, kept while the app runs: the view, the selected IST day (null follows today, so it
/// moves at midnight) and the types switched on.
typedef CalendarPrefs = ({
  CalendarView view,
  DateTime? day,
  Set<CalendarType> types,
});

final calendarPrefsProvider =
    NotifierProvider<CalendarPrefsNotifier, CalendarPrefs>(
      CalendarPrefsNotifier.new,
    );

class CalendarPrefsNotifier extends Notifier<CalendarPrefs> {
  @override
  CalendarPrefs build() =>
      (view: CalendarView.month, day: null, types: CalendarType.values.toSet());

  void setView(CalendarView view) =>
      state = (view: view, day: state.day, types: state.types);

  /// [day] an IST day; null = today.
  void select(DateTime? day) =>
      state = (view: state.view, day: day, types: state.types);

  void toggle(CalendarType t) => state = (
    view: state.view,
    day: state.day,
    types: state.types.contains(t)
        ? ({...state.types}..remove(t))
        : {...state.types, t},
  );

  void showAll() => state = (
    view: state.view,
    day: state.day,
    types: CalendarType.values.toSet(),
  );
}

/// [day] moved by [n] of [view]'s periods: days, weeks or months (to the same day, or the month's last).
DateTime calendarStep(CalendarView view, DateTime day, int n) => switch (view) {
  CalendarView.month => addMonths(day, n),
  CalendarView.week => DateTime.utc(day.year, day.month, day.day + 7 * n),
  CalendarView.day ||
  CalendarView.agenda => DateTime.utc(day.year, day.month, day.day + n),
};

/// Agenda page [i] (one month each): the rest of [today]'s month, then whole months.
CalendarRange agendaPage(DateTime today, int i) => i == 0
    ? (from: today, to: monthRange(today).to)
    : monthRange(addMonths(DateTime.utc(today.year, today.month), i));

/// [days] with only the items of [types]; days left empty are dropped.
CalendarDays filterDays(CalendarDays days, Set<CalendarType> types) =>
    types.length == CalendarType.values.length
    ? days
    : {
        for (final MapEntry(key: day, value: items) in days.entries)
          if ([
                for (final i in items)
                  if (types.contains(calendarTypeOf(i))) i,
              ]
              case final shown when shown.isNotEmpty)
            day: shown,
      };

void _retry(WidgetRef ref, CalendarRange r) => ref
  ..invalidate(calendarHearingsProvider(r))
  ..invalidate(calendarDeadlinesProvider(r))
  ..invalidate(calendarTasksProvider(r));

/// Arrow keys by view (spec §5.12): Month moves a day or a week; Week's days are a column, so every arrow moves a
/// day.
final Map<LogicalKeyboardKey, int> _monthKeys = {
  LogicalKeyboardKey.arrowLeft: -1,
  LogicalKeyboardKey.arrowRight: 1,
  LogicalKeyboardKey.arrowUp: -7,
  LogicalKeyboardKey.arrowDown: 7,
};
final Map<LogicalKeyboardKey, int> _weekKeys = {
  LogicalKeyboardKey.arrowLeft: -1,
  LogicalKeyboardKey.arrowRight: 1,
  LogicalKeyboardKey.arrowUp: -1,
  LogicalKeyboardKey.arrowDown: 1,
};
final Map<LogicalKeyboardKey, int> _pageKeys = {
  LogicalKeyboardKey.pageUp: -1,
  LogicalKeyboardKey.pageDown: 1,
};

/// Calendar (spec §4.3, `/calendar`): Day, Week, Month and Agenda views of the org's hearings, deadlines and
/// tasks (IST days), filtered by type; the view, day and filter stay while the app runs. Reads the synced
/// database, so it works offline; ticking a task done is a local write. Month is a hand-built grid with the
/// selected day's items under it (beside it on Windows); Agenda runs from today, a month at a time. Keys on Windows
/// (spec §5.12): arrows move the selected day in Month and Week, Page Up/Down change the month, week or day, T goes
/// to today, Enter opens the focused item. Keyboard focus follows the selected day to its heading.
/// ponytail: no swipe between periods on phones (the arrows do it) and no calendar package: lists and one grid.
class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  /// Marks the screen's part of the focus tree and takes its keys; never focused itself.
  final _focus = FocusNode(canRequestFocus: false, skipTraversal: true);

  /// The selected day's heading (Month's list, Week's day): where focus goes when a key moves the day, as the row
  /// that had it may be gone. Its key keeps it one element as the selection moves, so it stays focused.
  final _dayFocus = FocusNode();
  final GlobalKey _dayKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _focus.dispose();
    _dayFocus.dispose();
    super.dispose();
  }

  /// Focus inside the calendar: its own keys come first, so the app's arrow-key focus moves don't run as well and
  /// take focus away from the day.
  KeyEventResult _onFocusKey(FocusNode _, KeyEvent e) =>
      _handle(e) ? KeyEventResult.handled : KeyEventResult.ignored;

  /// Focus above the calendar (the shell holds it until the user tabs in): the keys are still the calendar's, never
  /// while typing in a dialog or sheet over it.
  bool _onKey(KeyEvent e) {
    final p = FocusManager.instance.primaryFocus;
    final above =
        p == null || (!_focus.hasFocus && p.descendants.contains(_focus));
    return above && _handle(e);
  }

  bool _handle(KeyEvent e) {
    final kb = HardwareKeyboard.instance;
    if (e is KeyUpEvent ||
        !mounted ||
        ModalRoute.isCurrentOf(context) == false ||
        ref.read(appLockProvider).locked ||
        kb.isControlPressed ||
        kb.isAltPressed ||
        kb.isMetaPressed) {
      return false;
    }
    final prefs = ref.read(calendarPrefsProvider);
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.keyT) {
      if (e is KeyDownEvent) _select(null);
      return true;
    }
    final today = ref.read(istTodayProvider);
    final day = prefs.day ?? today;
    final days = switch (prefs.view) {
      CalendarView.month => _monthKeys[key],
      CalendarView.week => _weekKeys[key],
      _ => null,
    };
    if (days != null) {
      _select(DateTime.utc(day.year, day.month, day.day + days));
      return true;
    }
    final page = _pageKeys[key];
    if (page != null && prefs.view != CalendarView.agenda) {
      _select(calendarStep(prefs.view, day, page));
      return true;
    }
    return false;
  }

  /// A key moved the day: focus (and show) the selected day's heading where the view has one, once it is built (a
  /// new week or month may show its skeleton for a frame or two first).
  void _select(DateTime? day) {
    ref.read(calendarPrefsProvider.notifier).select(day);
    _focusDay(DateTime.now().add(const Duration(seconds: 1)));
  }

  void _focusDay(DateTime until) =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || DateTime.now().isAfter(until)) return;
        if (_dayFocus.context?.mounted ?? false) {
          FocusTraversalPolicy.defaultTraversalRequestFocusCallback(_dayFocus);
        } else {
          _focusDay(until);
        }
      });

  /// A day's heading opens it in the Day view.
  void _openDay(DateTime day) {
    ref.read(calendarPrefsProvider.notifier)
      ..select(day)
      ..setView(CalendarView.day);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final prefs = ref.watch(calendarPrefsProvider);
    final today = ref.watch(istTodayProvider);
    final notifier = ref.read(calendarPrefsProvider.notifier);
    final day = prefs.day ?? today;
    final wide =
        sizeClassOf(MediaQuery.sizeOf(context).width) == SizeClass.expanded;
    final controls = _Controls(prefs: prefs, day: day, today: today);

    final Widget body;
    if (prefs.types.isEmpty) {
      body = _Scroll(
        children: [
          controls,
          EmptyState(
            icon: AppIcons.funnel,
            message: l.calendarAllHidden,
            actionLabel: l.calendarShowAll,
            onAction: notifier.showAll,
          ),
        ],
      );
    } else if (prefs.view == CalendarView.agenda) {
      body = _Agenda(header: controls, types: prefs.types, today: today);
    } else {
      body = _Scroll(
        maxWidth: prefs.view == CalendarView.month && wide ? 1200 : 720,
        children: [
          controls,
          ..._paged(context, prefs, day: day, today: today, wide: wide),
        ],
      );
    }

    return Focus(
      focusNode: _focus,
      onKeyEvent: _onFocusKey,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l.navCalendar),
          actions: [
            if (prefs.view != CalendarView.agenda)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 8),
                child: Tooltip(
                  message: l.calendarGoToToday,
                  child: TextButton(
                    onPressed: () => notifier.select(null),
                    child: Text(l.relToday),
                  ),
                ),
              ),
          ],
        ),
        body: body,
      ),
    );
  }

  /// Day, Week or Month for [day]: the range's items, filtered by type.
  List<Widget> _paged(
    BuildContext context,
    CalendarPrefs prefs, {
    required DateTime day,
    required DateTime today,
    required bool wide,
  }) {
    final l = context.l10n;
    final notifier = ref.read(calendarPrefsProvider.notifier);
    final range = switch (prefs.view) {
      CalendarView.day => (from: day, to: day),
      CalendarView.week => weekRange(day),
      _ => monthGridRange(day),
    };
    final data = ref.watch(calendarProvider(range));
    if (data.hasError && !data.hasValue) {
      return [
        ErrorState(
          message: errorText(l, data.error),
          onRetry: () => _retry(ref, range),
        ),
      ];
    }
    final loaded = data.value;
    // Month keeps its grid while a new month loads.
    if (loaded == null && prefs.view != CalendarView.month) {
      return const [SkeletonCaseList(count: 2)];
    }
    final days = filterDays(loaded ?? const {}, prefs.types);
    List<Widget> rows(List<CalendarItem> items) => [
      for (final i in items) CalendarItemRow(i, key: calendarItemKey(i)),
    ];

    switch (prefs.view) {
      case CalendarView.day:
        final items = days[day] ?? const [];
        if (items.isEmpty) {
          return [
            EmptyState(
              icon: AppIcons.calendarBlank,
              message: l.calendarEmptyDay,
            ),
          ];
        }
        // Grouped by type; hearings in the diary's order (task 8).
        return [
          for (final t in CalendarType.values)
            if ([
                  for (final i in items)
                    if (calendarTypeOf(i) == t) i,
                ]
                case final list when list.isNotEmpty) ...[
              SectionHeader(calendarTypeLabel(l, t), count: list.length),
              ...rows(list),
            ],
        ];
      case CalendarView.week:
        if (days.isEmpty) {
          return [
            EmptyState(
              icon: AppIcons.calendarBlank,
              message: l.calendarEmptyWeek,
            ),
          ];
        }
        return [
          for (final d in daysOf(range)) ...[
            _DayHeading(
              d,
              today: today,
              selected: d == day,
              onTap: () => _openDay(d),
              focusNode: d == day ? _dayFocus : null,
              key: d == day ? _dayKey : null,
            ),
            if (days[d] case final items?) ...rows(items) else const _Nothing(),
          ],
        ];
      case CalendarView.month || CalendarView.agenda:
        final grid = MonthGrid(
          selected: day,
          today: today,
          days: days,
          onSelect: notifier.select,
        );
        final list = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DayHeading(
              day,
              today: today,
              onTap: () => _openDay(day),
              focusNode: _dayFocus,
              key: _dayKey,
            ),
            if (loaded == null)
              const SkeletonCaseList(count: 2)
            else if (days[day] case final items?)
              ...rows(items)
            else
              const _Nothing(),
          ],
        );
        return wide
            ? [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: grid),
                    const SizedBox(width: 24),
                    SizedBox(width: 360, child: list),
                  ],
                ),
              ]
            : [grid, list];
    }
  }
}

/// The views, the period with previous and next, and the type filter.
class _Controls extends ConsumerWidget {
  const _Controls({
    required this.prefs,
    required this.day,
    required this.today,
  });

  final CalendarPrefs prefs;
  final DateTime day;
  final DateTime today;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final locale = Localizations.localeOf(context);
    final notifier = ref.read(calendarPrefsProvider.notifier);
    final view = prefs.view;
    final hi = locale.languageCode == 'hi';
    final title = switch (view) {
      CalendarView.day => calendarDayTitle(l, locale, day, today),
      CalendarView.week =>
        '${calendarFormat(locale, hi ? 'd MMMM' : 'd MMM', weekRange(day).from)}'
            ' – '
            '${calendarFormat(locale, hi ? 'd MMMM y' : 'd MMM y', weekRange(day).to)}',
      _ => calendarFormat(locale, 'MMMM y', day),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<CalendarView>(
          showSelectedIcon: false,
          segments: [
            for (final v in CalendarView.values)
              ButtonSegment(
                value: v,
                // One line, shrunk if it must: four segments share a 360 dp phone at 200%.
                label: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(switch (v) {
                    CalendarView.day => l.calendarViewDay,
                    CalendarView.week => l.calendarViewWeek,
                    CalendarView.month => l.calendarViewMonth,
                    CalendarView.agenda => l.calendarViewAgenda,
                  }, softWrap: false),
                ),
              ),
          ],
          selected: {view},
          onSelectionChanged: (v) => notifier.setView(v.first),
        ),
        const SizedBox(height: 8),
        if (view != CalendarView.agenda)
          Row(
            children: [
              IconButton(
                tooltip: l.calendarPrevious(view.name),
                icon: const Icon(AppIcons.caretLeft),
                onPressed: () => notifier.select(calendarStep(view, day, -1)),
              ),
              Expanded(
                // Says the new period when previous, next, Today or a key changes it.
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    style: context.text.titleMedium,
                  ),
                ),
              ),
              IconButton(
                tooltip: l.calendarNext(view.name),
                icon: const Icon(AppIcons.caretRight),
                onPressed: () => notifier.select(calendarStep(view, day, 1)),
              ),
            ],
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final t in CalendarType.values)
              FilterChip(
                label: CalendarTypeLabel(t),
                selected: prefs.types.contains(t),
                onSelected: (_) => notifier.toggle(t),
              ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// A scrolling column of [children], at most [maxWidth] wide and centred (a readable column on Windows). A Column,
/// not a lazy list, so Tab reaches every row; a day, week or month is tens of rows at most.
class _Scroll extends StatelessWidget {
  const _Scroll({required this.children, this.maxWidth = 720});

  final List<Widget> children;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final side = math.max(16, (box.maxWidth - maxWidth) / 2).toDouble();
      return SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(side, 8, side, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      );
    },
  );
}

/// A day's heading: "Today · Thu, 5 Nov 2026", "Tomorrow · …", then the date. In Month and Week it opens its day
/// ([onTap]); in Week the selected day is marked.
class _DayHeading extends StatelessWidget {
  const _DayHeading(
    this.day, {
    required this.today,
    this.selected = false,
    this.onTap,
    this.focusNode,
    super.key,
  });

  final DateTime day;
  final DateTime today;
  final bool selected;
  final VoidCallback? onTap;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final text = Text(
      calendarDayTitle(
        context.l10n,
        Localizations.localeOf(context),
        day,
        today,
      ),
      style: context.text.titleMedium?.copyWith(
        color: selected ? c.primary : null,
      ),
    );
    final tap = onTap;
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Semantics(
        header: true,
        selected: selected ? true : null,
        child: tap == null
            ? text
            : InkWell(
                onTap: tap,
                focusNode: focusNode,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 48),
                  alignment: AlignmentDirectional.centerStart,
                  padding: const EdgeInsetsDirectional.only(start: 8),
                  // The selected day has a bar as well as its colour.
                  decoration: BoxDecoration(
                    border: BorderDirectional(
                      start: BorderSide(
                        color: selected ? c.primary : Colors.transparent,
                        width: 4,
                      ),
                    ),
                  ),
                  child: text,
                ),
              ),
      ),
    );
  }
}

/// "Nothing on this day." under a day's heading.
class _Nothing extends StatelessWidget {
  const _Nothing();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(
      context.l10n.calendarEmptyDay,
      style: context.text.bodyMedium?.copyWith(color: context.colors.ink2),
    ),
  );
}

/// Agenda: from today forward by day, a month at a time; the next month loads when the list's end comes into
/// view. ponytail: it stops a year ahead (`_maxMonths`); offer "Show more" if advocates need further.
class _Agenda extends ConsumerStatefulWidget {
  const _Agenda({
    required this.header,
    required this.types,
    required this.today,
  });

  final Widget header;
  final Set<CalendarType> types;
  final DateTime today;

  @override
  ConsumerState<_Agenda> createState() => _AgendaState();
}

class _AgendaState extends ConsumerState<_Agenda> {
  static const _maxMonths = 12;
  var _months = 1;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final today = widget.today;
    final pages = [for (var i = 0; i < _months; i++) agendaPage(today, i)];
    final rows = <Widget>[widget.header];
    var waiting = false;
    for (final page in pages) {
      final data = ref.watch(calendarProvider(page));
      if (data.hasError && !data.hasValue) {
        rows.add(
          ErrorState(
            message: errorText(l, data.error),
            onRetry: () => _retry(ref, page),
          ),
        );
      }
      if (!data.hasValue) {
        if (!data.hasError) rows.add(const SkeletonCaseList(count: 2));
        waiting = true;
        break;
      }
      for (final MapEntry(key: day, value: items) in filterDays(
        data.requireValue,
        widget.types,
      ).entries) {
        rows
          ..add(_DayHeading(day, today: today, key: ValueKey(day)))
          ..addAll([
            for (final i in items) CalendarItemRow(i, key: calendarItemKey(i)),
          ]);
      }
    }
    if (!waiting) {
      if (_months < _maxMonths) {
        rows.add(
          _LoadMore(
            key: ValueKey(_months),
            onShown: () => setState(() => _months++),
          ),
        );
      } else if (rows.length == 1) {
        rows.add(
          EmptyState(
            icon: AppIcons.calendarBlank,
            message: l.calendarEmptyAgenda(_maxMonths),
          ),
        );
      } else {
        rows.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              l.calendarAgendaEnd(
                Formats(Localizations.localeOf(context)).date(pages.last.to),
              ),
              textAlign: TextAlign.center,
              style: context.text.bodyMedium?.copyWith(
                color: context.colors.ink2,
              ),
            ),
          ),
        );
      }
    }
    return LayoutBuilder(
      builder: (context, box) {
        final side = math.max(16, (box.maxWidth - 720) / 2).toDouble();
        return ListView.builder(
          padding: EdgeInsets.fromLTRB(side, 8, side, 24),
          itemCount: rows.length,
          itemBuilder: (_, i) => rows[i],
        );
      },
    );
  }
}

/// Built when the agenda's end comes near the screen: asks for the next month after this frame.
class _LoadMore extends StatefulWidget {
  const _LoadMore({required this.onShown, super.key});

  final VoidCallback onShown;

  @override
  State<_LoadMore> createState() => _LoadMoreState();
}

class _LoadMoreState extends State<_LoadMore> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onShown();
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox(height: 48);
}
