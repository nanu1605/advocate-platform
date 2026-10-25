import 'dart:math';

import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/case_label.dart';
import 'package:advocate_app/data/diary.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart'
    show ProviderFamily, StreamProviderFamily;

/// IST days from `from` to `to`, both included (see [istDay]): what a calendar view shows.
typedef CalendarRange = ({DateTime from, DateTime to});

/// The Monday of [day]'s week (courts list Monday to Saturday).
DateTime weekStart(DateTime day) =>
    DateTime.utc(day.year, day.month, day.day - (day.weekday - 1));

/// Monday to Sunday of [day]'s week.
CalendarRange weekRange(DateTime day) {
  final start = weekStart(day);
  return (from: start, to: start.add(const Duration(days: 6)));
}

/// The 1st to the last day of [day]'s month (an agenda page).
CalendarRange monthRange(DateTime day) => (
  from: DateTime.utc(day.year, day.month),
  to: DateTime.utc(day.year, day.month + 1, 0),
);

/// The month view's grid for [day]'s month: whole Monday-to-Sunday weeks from the one holding the 1st to the one
/// holding the last day (4 to 6 weeks), so the first and last rows show days of the next and previous months.
CalendarRange monthGridRange(DateTime day) {
  final first = weekStart(DateTime.utc(day.year, day.month));
  final last = weekStart(DateTime.utc(day.year, day.month + 1, 0));
  return (from: first, to: last.add(const Duration(days: 6)));
}

/// Every day of [range], in order.
List<DateTime> daysOf(CalendarRange range) => [
  for (
    var d = range.from;
    !d.isAfter(range.to);
    d = DateTime.utc(d.year, d.month, d.day + 1)
  )
    d,
];

/// [day] moved by [months], on the same day of the month or that month's last (31 Jan + 1 month = 28 Feb).
DateTime addMonths(DateTime day, int months) {
  final lastDay = DateTime.utc(day.year, day.month + months + 1, 0).day;
  return DateTime.utc(day.year, day.month + months, min(day.day, lastDay));
}

/// What the calendar shows (spec §4.3 Calendar), each on an IST [day].
sealed class CalendarItem {
  const CalendarItem();

  DateTime get day;

  /// The case it opens; null for a deadline or task without one.
  String? get matterId;
}

/// A hearing: a hearings row (court or manual), or a court next date with no row for that day yet
/// ([hearingId] null). [entry] is the case as the diary shows it (case label, court, court and item number,
/// purpose), so [orderDiary], `positionText` and `diaryRowLabel` apply.
@immutable
final class CalendarHearing extends CalendarItem {
  const CalendarHearing({
    required this.day,
    required this.entry,
    this.hearingId,
  });

  factory CalendarHearing.fromRow(Map<String, dynamic> r) => CalendarHearing(
    day: parseDay(r['day'])!,
    hearingId: r['hearing_id'] as String?,
    entry: DiaryEntry.fromRow(r),
  );

  @override
  final DateTime day;
  final DiaryEntry entry;
  final String? hearingId;

  @override
  String get matterId => entry.matterId;
}

/// A deadline, active or done (done ones show struck through).
@immutable
final class CalendarDeadline extends CalendarItem {
  const CalendarDeadline({
    required this.id,
    required this.day,
    required this.kind,
    this.done = false,
    this.matterId,
    this.caseLabel,
  });

  factory CalendarDeadline.fromRow(Map<String, dynamic> r) => CalendarDeadline(
    id: r['id'] as String,
    day: parseDay(r['due_date'])!,
    kind: r['kind'] as String? ?? 'other',
    done: r['status'] == 'done',
    matterId: r['matter_id'] as String?,
    caseLabel: _labelOf(r),
  );

  final String id;
  @override
  final DateTime day;

  /// One of `deadlineKinds`.
  final String kind;
  final bool done;
  @override
  final String? matterId;
  final String? caseLabel;
}

/// A task, open or done (done ones show struck through).
@immutable
final class CalendarTask extends CalendarItem {
  const CalendarTask({
    required this.id,
    required this.title,
    required this.dueAt,
    this.done = false,
    this.matterId,
    this.caseLabel,
  });

  factory CalendarTask.fromRow(Map<String, dynamic> r) => CalendarTask(
    id: r['id'] as String,
    title: r['title'] as String? ?? '',
    dueAt: parseInstant(r['due_at'])!,
    done: r['status'] == 'done',
    matterId: r['matter_id'] as String?,
    caseLabel: _labelOf(r),
  );

  final String id;
  final String title;

  /// The instant it is due; a date-only task is due at midnight IST (task 9).
  final DateTime dueAt;
  final bool done;
  @override
  final String? matterId;
  final String? caseLabel;

  @override
  DateTime get day => istDay(istOf(dueAt));
}

/// The case label of a row with the matter's number fields and `matter_title`; null without a case.
String? _labelOf(Map<String, dynamic> r) {
  final label = caseLabelOf(
    caseType: r['case_type'] as String?,
    caseNumber: r['case_number'] as String?,
    caseYear: r['case_year'] as int?,
    cnr: r['cnr'] as String?,
  );
  return label.isEmpty ? r['matter_title'] as String? : label;
}

/// Hearings of the org (`?1`) from `?2` to `?3`: live hearings rows (one per case per day, the court's before a
/// manual one), plus the court next date of auto- and off-tracked unarchived cases with no hearings row that day.
/// An archived case's rows still show (its history); its court next date doesn't. Columns as [DiaryEntry.fromRow]
/// reads them.
const _hearingSql = '''
select x.day, x.hearing_id, m.id, m.cnr, m.case_type, m.case_number, m.case_year, m.title, m.tracking, m.court_id,
  coalesce(x.court_no, m.court_no) as court_no, x.item_no, m.judge as bench, coalesce(x.purpose, m.stage) as purpose,
  c.level as court_level, c.name as court_name, c.name_hi as court_name_hi, c.short_name as court_short_name,
  c.short_name_hi as court_short_name_hi
from (
  select h.date as day, h.id as hearing_id, h.matter_id, h.court_no, h.item_no,
    coalesce(h.purpose, h.user_purpose) as purpose
  from hearings h
  where h.org_id = ?1 and h.deleted_at is null and h.date between ?2 and ?3
    and h.id = (select y.id from hearings y where y.matter_id = h.matter_id and y.date = h.date
      and y.deleted_at is null order by y.source = 'manual', y.created_at, y.id limit 1)
  union all
  select m.next_hearing_date, null, m.id, null, null, null
  from matters m
  where m.org_id = ?1 and m.deleted_at is null and m.status = 'active' and m.tracking in ('auto', 'off')
    and m.next_hearing_date between ?2 and ?3
    and not exists (select 1 from hearings h where h.matter_id = m.id and h.date = m.next_hearing_date
      and h.deleted_at is null)
) x
join matters m on m.id = x.matter_id and m.deleted_at is null
left join courts c on c.id = m.court_id
''';

const _deadlineSql = '''
select d.id, d.kind, d.due_date, d.status, d.matter_id,
  m.case_type, m.case_number, m.case_year, m.cnr, m.title as matter_title
from deadlines d
left join matters m on m.id = d.matter_id and m.deleted_at is null
where d.org_id = ?1 and d.deleted_at is null and d.status in ('active', 'done') and d.due_date between ?2 and ?3
''';

/// Tasks whose UTC date is within a day of the range (`?2` to `?3` here are already widened by a day each side);
/// [_tasksIn] keeps those due on the range's IST days.
const _taskSql = '''
select t.id, t.title, t.due_at, t.status, t.matter_id,
  m.case_type, m.case_number, m.case_year, m.cnr, m.title as matter_title
from tasks t
left join matters m on m.id = t.matter_id and m.deleted_at is null
where t.org_id = ?1 and t.deleted_at is null and t.status in ('open', 'done') and t.due_at is not null
  and substr(t.due_at, 1, 10) between ?2 and ?3
''';

/// Rows of [sql] for the current org and [from]..[to] (`YYYY-MM-DD`) as [T]s; empty without an org or sync.
Stream<List<T>> _range<T>(
  Ref ref,
  String sql,
  DateTime from,
  DateTime to,
  T Function(Map<String, dynamic>) fromRow,
) {
  final db = ref.watch(syncDatabaseProvider);
  final org = ref.watch(currentOrgIdProvider);
  if (db == null || org == null) return Stream.value(const []);
  return db
      .watch(sql, parameters: [org, isoDate(from), isoDate(to)])
      .map((rows) => rows.map(fromRow).toList());
}

List<CalendarTask> _tasksIn(List<CalendarTask> tasks, CalendarRange range) => [
  for (final t in tasks)
    if (!t.day.isBefore(range.from) && !t.day.isAfter(range.to)) t,
];

final StreamProviderFamily<List<CalendarHearing>, CalendarRange>
calendarHearingsProvider = StreamProvider.autoDispose
    .family<List<CalendarHearing>, CalendarRange>(
      (ref, r) =>
          _range(ref, _hearingSql, r.from, r.to, CalendarHearing.fromRow),
    );

final StreamProviderFamily<List<CalendarDeadline>, CalendarRange>
calendarDeadlinesProvider = StreamProvider.autoDispose
    .family<List<CalendarDeadline>, CalendarRange>(
      (ref, r) =>
          _range(ref, _deadlineSql, r.from, r.to, CalendarDeadline.fromRow),
    );

final StreamProviderFamily<List<CalendarTask>, CalendarRange>
calendarTasksProvider = StreamProvider.autoDispose
    .family<List<CalendarTask>, CalendarRange>(
      (ref, r) => _range(
        ref,
        _taskSql,
        r.from.subtract(const Duration(days: 1)),
        r.to.add(const Duration(days: 1)),
        CalendarTask.fromRow,
      ).map((tasks) => _tasksIn(tasks, r)),
    );

/// A range's items by IST day, days in order (days without items left out). In a day: hearings in diary order
/// ([orderDiary]), then deadlines (active first, by kind), then tasks (open first, by due time, then title).
typedef CalendarDays = Map<DateTime, List<CalendarItem>>;

/// [calendarDays] of [hearings], [deadlines] and [tasks].
CalendarDays calendarDays(
  Iterable<CalendarHearing> hearings,
  Iterable<CalendarDeadline> deadlines,
  Iterable<CalendarTask> tasks,
) {
  final byDay = <DateTime, List<CalendarItem>>{};
  for (final i in <CalendarItem>[...hearings, ...deadlines, ...tasks]) {
    (byDay[i.day] ??= []).add(i);
  }
  return {
    for (final day in byDay.keys.toList()..sort()) day: _dayOrder(byDay[day]!),
  };
}

List<CalendarItem> _dayOrder(List<CalendarItem> items) {
  final hearings = {
    for (final h in items.whereType<CalendarHearing>()) h.matterId: h,
  };
  return [
    for (final e in orderDiary(hearings.values.map((h) => h.entry)))
      hearings[e.matterId]!,
    ...items.whereType<CalendarDeadline>().toList()..sort(
      (a, b) => a.done != b.done ? (a.done ? 1 : -1) : a.kind.compareTo(b.kind),
    ),
    ...items.whereType<CalendarTask>().toList()..sort(
      (a, b) => a.done != b.done
          ? (a.done ? 1 : -1)
          : a.dueAt != b.dueAt
          ? a.dueAt.compareTo(b.dueAt)
          : a.title.compareTo(b.title),
    ),
  ];
}

/// The calendar for [CalendarRange] (spec §4.3): hearings, deadlines and tasks of the current org by day
/// ([calendarDays]). Views filter by type themselves. Live: a task marked done moves to its day's end at once.
final ProviderFamily<AsyncValue<CalendarDays>, CalendarRange> calendarProvider =
    Provider.autoDispose.family<AsyncValue<CalendarDays>, CalendarRange>((
      ref,
      range,
    ) {
      final h = ref.watch(calendarHearingsProvider(range));
      final d = ref.watch(calendarDeadlinesProvider(range));
      final t = ref.watch(calendarTasksProvider(range));
      if ((h.value, d.value, t.value) case (final hs?, final ds?, final ts?)) {
        return AsyncData(calendarDays(hs, ds, ts));
      }
      final failed = [h, d, t].where((p) => p.hasError).firstOrNull;
      return failed == null
          ? const AsyncLoading()
          : AsyncError(failed.error!, failed.stackTrace ?? StackTrace.current);
    });
