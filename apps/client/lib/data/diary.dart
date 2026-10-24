import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/case_label.dart';
import 'package:advocate_app/data/clash.dart';
import 'package:advocate_app/data/courts.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show StreamProviderFamily;
import 'package:powersync/powersync.dart' hide SyncStatus;

/// One matter in the diary for a day (spec §4.2): Today's list and hero card, and Tomorrow's Board.
@immutable
class DiaryEntry {
  const DiaryEntry({
    required this.matterId,
    required this.caseLabel,
    this.title,
    this.courtId,
    this.court,
    this.courtNo,
    this.itemNo,
    this.slot,
    this.bench,
    this.purpose,
    this.client,
    this.assigneeId,
    this.assigneeName,
    this.proxyArranged = false,
    this.boardEntryId,
    this.tracking = 'auto',
    this.clashGroup,
    this.clashWith = const [],
  });

  factory DiaryEntry.fromRow(Map<String, dynamic> r) {
    final title = r['title'] as String?;
    final label = _rowLabel(r);
    final courtId = r['court_id'] as String?;
    final shortName = r['court_short_name'] as String?;
    return DiaryEntry(
      matterId: r['id'] as String,
      caseLabel: label.isEmpty ? title ?? '' : label,
      title: title,
      courtId: courtId,
      court: courtId == null || shortName == null
          ? null
          : Court(
              id: courtId,
              level: r['court_level'] as String,
              name: r['court_name'] as String? ?? shortName,
              nameHi: r['court_name_hi'] as String?,
              shortName: shortName,
              shortNameHi: r['court_short_name_hi'] as String?,
            ),
      courtNo: r['court_no'] as String?,
      itemNo: r['item_no'] as String?,
      slot: _slot(r['expected_slot']),
      bench: r['bench'] as String?,
      purpose: r['purpose'] as String?,
      client: r['client'] as String?,
      assigneeId: r['assignee_id'] as String?,
      assigneeName: r['assignee_name'] as String?,
      proxyArranged: r['proxy_arranged'] == 1,
      boardEntryId: r['board_id'] as String?,
      tracking: r['tracking'] as String? ?? 'auto',
    );
  }

  final String matterId;

  /// "WP 1234/2024", else the CNR, else (a manual case with neither) the title.
  final String caseLabel;

  /// "Petitioner v. Respondent". Party names: never log it.
  final String? title;

  /// The court complex; [court] is null until the courts table has synced it.
  final String? courtId;
  final Court? court;
  final String? courtNo;

  /// From the board entry, else the cause list, else the hearing; null until the list is out.
  final String? itemNo;

  /// Expected start after midnight IST, from the item number: an estimate (DRAFT – VERIFY), never shown as a fact.
  /// Board entries only.
  final Duration? slot;

  /// Cause-list bench, else the matter's judge.
  final String? bench;

  /// That day's hearing purpose (court, else the user's), else the matter's stage.
  final String? purpose;

  /// First client's name. Never log it.
  final String? client;

  /// The board entry's assignee, else the matter's; null = unassigned (the organisation's owner for clashes).
  final String? assigneeId;
  final String? assigneeName;
  final bool proxyArranged;

  /// Null until the worker builds the board for the day (after the evening cause-list check): Assign to and
  /// Mark proxy arranged need it.
  final String? boardEntryId;

  /// `auto`, `manual` or `off`.
  final String tracking;

  /// Clash group on this day (see [clashGroups]); null = no clash.
  final int? clashGroup;

  /// Matter ids this entry clashes with directly, for the explanation.
  final List<String> clashWith;

  bool get clash => clashGroup != null;

  ClashEntry get _clashEntry => (
    key: matterId,
    courtId: courtId,
    slot: slot?.inMinutes,
    assignee: assigneeId,
    proxy: proxyArranged,
  );

  /// For local updates (and fakes): what Assign to (and its Undo, back to no one: `id` null) and Mark proxy
  /// arranged change.
  DiaryEntry copyWith({
    ({String? id, String? name})? assignee,
    bool? proxyArranged,
  }) => _copy(
    assigneeId: assignee == null ? assigneeId : assignee.id,
    assigneeName: assignee == null ? assigneeName : assignee.name,
    proxyArranged: proxyArranged ?? this.proxyArranged,
    clashGroup: clashGroup,
    clashWith: clashWith,
  );

  DiaryEntry _copy({
    required String? assigneeId,
    required String? assigneeName,
    required bool proxyArranged,
    required int? clashGroup,
    required List<String> clashWith,
  }) => DiaryEntry(
    matterId: matterId,
    caseLabel: caseLabel,
    title: title,
    courtId: courtId,
    court: court,
    courtNo: courtNo,
    itemNo: itemNo,
    slot: slot,
    bench: bench,
    purpose: purpose,
    client: client,
    assigneeId: assigneeId,
    assigneeName: assigneeName,
    proxyArranged: proxyArranged,
    boardEntryId: boardEntryId,
    tracking: tracking,
    clashGroup: clashGroup,
    clashWith: clashWith,
  );
}

/// [caseLabelOf] for a row with `case_type`, `case_number`, `case_year` and `cnr`.
String _rowLabel(Map<String, dynamic> r) => caseLabelOf(
  caseType: r['case_type'] as String?,
  caseNumber: r['case_number'] as String?,
  caseYear: r['case_year'] as int?,
  cnr: r['cnr'] as String?,
);

/// "11:58:00" (a Postgres time) as time after midnight.
Duration? _slot(Object? v) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch('${v ?? ''}');
  return m == null
      ? null
      : Duration(hours: int.parse(m[1]!), minutes: int.parse(m[2]!));
}

/// The day's clashes from its current rows (spec §4.2), so Assign to and proxy changes re-apply the rule at once
/// and offline; the worker's `clash_group` column isn't read. Unassigned rows are [ownerId]'s.
List<DiaryEntry> withClashes(List<DiaryEntry> entries, String? ownerId) {
  final rows = [for (final e in entries) e._clashEntry];
  final groups = clashGroups(rows, ownerId);
  return [
    for (final (i, e) in entries.indexed)
      e._copy(
        assigneeId: e.assigneeId,
        assigneeName: e.assigneeName,
        proxyArranged: e.proxyArranged,
        clashGroup: groups[e.matterId],
        clashWith: [
          for (final (j, o) in rows.indexed)
            if (i != j && clashes(rows[i], o, ownerId)) o.key,
        ],
      ),
  ];
}

/// Diary order (spec §4.2): by court complex, complexes by their earliest expected slot (none last) then name;
/// inside one, by court number then item number, numerically ("Court 7" before "Court 12"; non-numeric last).
List<DiaryEntry> orderDiary(Iterable<DiaryEntry> entries) {
  final byCourt = <String?, List<DiaryEntry>>{};
  for (final e in entries) {
    (byCourt[e.courtId] ??= []).add(e);
  }
  int? earliest(List<DiaryEntry> g) {
    final slots = [for (final e in g) ?e.slot?.inMinutes];
    return slots.isEmpty ? null : slots.reduce((a, b) => a < b ? a : b);
  }

  final groups = byCourt.values.toList()
    ..sort(
      (a, b) =>
          _nullsLast(earliest(a), earliest(b)) ??
          _nullsLast(a.first.court?.shortName, b.first.court?.shortName) ??
          0,
    );
  for (final g in groups) {
    g.sort(
      (a, b) =>
          _nullsLast(_number(a.courtNo), _number(b.courtNo)) ??
          _nullsLast(_number(a.itemNo), _number(b.itemNo)) ??
          _nullsLast(a.courtNo, b.courtNo) ??
          _nullsLast(a.itemNo, b.itemNo) ??
          a.caseLabel.compareTo(b.caseLabel),
    );
  }
  return [for (final g in groups) ...g];
}

/// Compares with nulls last; null when equal, so comparisons chain with `??`.
int? _nullsLast<T extends Comparable<Object>>(T? a, T? b) {
  final d = a == null
      ? (b == null ? 0 : 1)
      : b == null
      ? -1
      : a.compareTo(b);
  return d == 0 ? null : d;
}

/// The digits of "12", "Room 5" or "S-12", as the worker orders them; null when there are none.
int? _number(String? s) => int.tryParse(s?.replaceAll(RegExp(r'\D'), '') ?? '');

/// Today's hero card (spec §4.2 "the next matter"): of the entries whose estimated window (slot + 60 minutes)
/// hasn't ended at [nowIst], the earliest slot, so a matter that is on now beats a later one in a complex listed
/// first; entries without a slot never count as ended and come last; ties keep diary order. Null when none is left.
DiaryEntry? heroEntry(List<DiaryEntry> ordered, DateTime nowIst) {
  final minute = nowIst.hour * 60 + nowIst.minute;
  DiaryEntry? next;
  for (final e in ordered) {
    final slot = e.slot?.inMinutes;
    if (slot != null && slot + clashWindowMinutes <= minute) continue;
    final best = next?.slot?.inMinutes;
    if (next == null || (slot != null && (best == null || slot < best))) {
      next = e;
    }
  }
  return next;
}

extension DiaryDay on List<DiaryEntry> {
  /// Court complexes in the day; entries without a court count as one (the worker's count).
  int get courtCount => {for (final e in this) e.courtId}.length;

  /// Whether the worker has built this day's board yet (after the evening cause-list check, spec §11.5).
  bool get boardBuilt => any((e) => e.boardEntryId != null);
}

const _diarySql = '''
select m.id, m.cnr, m.case_type, m.case_number, m.case_year, m.title, m.tracking,
  b.id as board_id, b.expected_slot, b.proxy_arranged,
  coalesce(b.court_id, o.court_id, m.court_id) as court_id,
  coalesce(b.court_no, o.court_no, h.court_no, m.court_no) as court_no,
  coalesce(b.item_no, o.item_no, h.item_no) as item_no,
  coalesce(o.bench, m.judge) as bench,
  coalesce(h.purpose, h.user_purpose, m.stage) as purpose,
  case when b.id is null then m.assigned_to else b.assignee_id end as assignee_id,
  ms.display_name as assignee_name,
  c.level as court_level, c.name as court_name, c.name_hi as court_name_hi, c.short_name as court_short_name,
  c.short_name_hi as court_short_name_hi,
  (select cl.name from matter_clients mc join clients cl on cl.id = mc.client_id and cl.deleted_at is null
   where mc.matter_id = m.id order by mc.created_at, cl.name limit 1) as client,
  (select owner_id from organizations where id = m.org_id) as owner_id
from matters m
left join board_entries b on b.id = (select id from board_entries
  where matter_id = m.id and board_date = ?1 and is_current = 1 limit 1)
left join org_cause_list_entries o on o.id = (select id from org_cause_list_entries
  where matter_id = m.id and list_date = ?1 and is_current = 1 order by created_at desc limit 1)
left join hearings h on h.id = (select id from hearings
  where matter_id = m.id and date = ?1 and deleted_at is null order by created_at limit 1)
left join courts c on c.id = coalesce(b.court_id, o.court_id, m.court_id)
left join memberships ms on ms.org_id = m.org_id and ms.status = 'active'
  and ms.user_id = (case when b.id is null then m.assigned_to else b.assignee_id end)
where m.org_id = ?2 and m.deleted_at is null and m.status = 'active'
  and (b.id is not null or o.id is not null
    or (m.tracking = 'auto' and m.next_hearing_date = ?1)
    or (m.tracking = 'manual' and h.id is not null))
''';

/// The current org's diary for an IST date (`YYYY-MM-DD`, see [isoDate]): live matters on the board that day,
/// on its cause list, auto-tracked with that court next date, or manual with a hearing that day (the worker's
/// `build_board` rule, so tomorrow's matters show before the evening build, without item numbers). Ordered by
/// [orderDiary], with clashes. Empty without an org or sync.
/// ponytail: no court-holiday check (the worker skips non-court days); add one if a next date lands on one.
final StreamProviderFamily<List<DiaryEntry>, String> diaryProvider =
    StreamProvider.autoDispose.family<List<DiaryEntry>, String>((ref, day) {
      final db = ref.watch(syncDatabaseProvider);
      final org = ref.watch(currentOrgIdProvider);
      if (db == null || org == null) return Stream.value(const []);
      return db
          .watch(_diarySql, parameters: [day, org])
          .map(
            (rows) => orderDiary(
              withClashes(
                rows.map(DiaryEntry.fromRow).toList(),
                rows.firstOrNull?['owner_id'] as String?,
              ),
            ),
          );
    });

/// The default evening switch (spec §4.2): from 18:30 IST Today leads with tomorrow.
const defaultEveningSwitch = Duration(hours: 18, minutes: 30);

/// "18:30" as time after midnight; [defaultEveningSwitch] when missing or malformed.
Duration parseEveningSwitch(Object? value) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch('${value ?? ''}'.trim());
  final (h, min) = m == null ? (24, 0) : (int.parse(m[1]!), int.parse(m[2]!));
  return h < 24 && min < 60
      ? Duration(hours: h, minutes: min)
      : defaultEveningSwitch;
}

/// When the evening switch happens: `app_config` key `today_evening_switch` ("HH:MM", IST), else 18:30.
final eveningSwitchProvider = StreamProvider<Duration>((ref) {
  final db = ref.watch(syncDatabaseProvider);
  if (db == null) return Stream.value(defaultEveningSwitch);
  return db
      .watch(
        r"select json_extract(value, '$') as v from app_config where key = 'today_evening_switch'",
      )
      .map((rows) => parseEveningSwitch(rows.firstOrNull?['v']));
});

/// From the switch time until midnight IST.
bool isEvening(DateTime nowIst, Duration switchAt) =>
    Duration(hours: nowIst.hour, minutes: nowIst.minute) >= switchAt;

/// Whether Today leads with the Tomorrow banner now (spec §4.2 "Evening switch").
final eveningProvider = Provider<bool>(
  (ref) => isEvening(
    ref.watch(istNowProvider),
    ref.watch(eveningSwitchProvider).value ?? defaultEveningSwitch,
  ),
);

/// An open task due by the end of today (IST).
@immutable
class DueTask {
  const DueTask({
    required this.id,
    required this.title,
    required this.dueAt,
    this.matterId,
    this.caseLabel,
    this.overdue = false,
  });

  final String id;
  final String title;

  /// The instant it is due (UTC); show it with [istOf].
  final DateTime dueAt;
  final String? matterId;
  final String? caseLabel;

  /// Due before today (IST).
  final bool overdue;
}

/// Tasks due by the end of [todayIst] (overdue ones included and marked), soonest first.
List<DueTask> dueTasks(Iterable<Map<String, dynamic>> rows, DateTime todayIst) {
  final start = istInstant(todayIst);
  final end = start.add(const Duration(days: 1));
  final due = <DueTask>[];
  for (final r in rows) {
    final at = parseInstant(r['due_at']);
    if (at == null || !at.isBefore(end)) continue;
    final label = _rowLabel(r);
    due.add(
      DueTask(
        id: r['id'] as String,
        title: r['title'] as String? ?? '',
        dueAt: at,
        matterId: r['matter_id'] as String?,
        caseLabel: label.isEmpty ? r['matter_title'] as String? : label,
        overdue: at.isBefore(start),
      ),
    );
  }
  return due..sort((a, b) => a.dueAt.compareTo(b.dueAt));
}

/// Open tasks due by the end of today (IST), assigned to the user or to no one, in the current org (spec §4.2
/// "Tasks due"); overdue ones are included and marked.
final tasksDueProvider = StreamProvider<List<DueTask>>((ref) {
  final db = ref.watch(syncDatabaseProvider);
  final org = ref.watch(currentOrgIdProvider);
  final me = ref.watch(currentUserIdProvider);
  final today = ref.watch(istTodayProvider);
  if (db == null || org == null) return Stream.value(const []);
  return db
      .watch(
        'select t.id, t.title, t.due_at, t.matter_id, m.case_type, m.case_number, m.case_year, '
        'm.cnr, m.title as matter_title from tasks t '
        'left join matters m on m.id = t.matter_id and m.deleted_at is null '
        "where t.org_id = ? and t.status = 'open' and t.deleted_at is null and t.due_at is not null "
        'and (t.assignee_id is null or t.assignee_id = ?)',
        parameters: [org, me],
      )
      .map((rows) => dueTasks(rows, today));
});

/// One of the user's notifications that Today lists (unread `new_order`, or a `sync_issue`).
@immutable
class DiaryNotice {
  const DiaryNotice({
    required this.id,
    required this.kind,
    this.matterId,
    this.link,
    this.caseLabel,
    this.createdAt,
  });

  factory DiaryNotice.fromRow(Map<String, dynamic> r) {
    final label = _rowLabel(r);
    return DiaryNotice(
      id: r['id'] as String,
      kind: r['kind'] as String,
      matterId: r['matter_id'] as String?,
      link: r['link'] as String?,
      caseLabel: label.isEmpty ? r['matter_title'] as String? : label,
      createdAt: parseInstant(r['created_at']),
    );
  }

  final String id;
  final String kind;
  final String? matterId;

  /// The route to open (`data.link`, e.g. `/cases/{id}`).
  final String? link;
  final String? caseLabel;
  final DateTime? createdAt;
}

const _noticeSql = r'''
select n.id, n.kind, n.created_at, json_extract(n.data, '$.matter_id') as matter_id,
  json_extract(n.data, '$.link') as link, m.case_type, m.case_number, m.case_year, m.cnr, m.title as matter_title
from notifications n
left join matters m on m.id = json_extract(n.data, '$.matter_id')
where n.org_id = ? and n.user_id = ? and n.kind = ? and n.read_at is null
  and (m.id is null or m.deleted_at is null)
order by n.created_at desc
''';

/// The user's unread notifications of [kind] in the current org, newest first.
Stream<List<DiaryNotice>> _notices(Ref ref, String kind) {
  final db = ref.watch(syncDatabaseProvider);
  final org = ref.watch(currentOrgIdProvider);
  final me = ref.watch(currentUserIdProvider);
  if (db == null || org == null || me == null) return Stream.value(const []);
  return db
      .watch(_noticeSql, parameters: [org, me, kind])
      .map((rows) => rows.map(DiaryNotice.fromRow).toList());
}

/// "New orders (n)" on Today: the user's unread `new_order` notifications in the current org. (No heuristics
/// over `orders`: the worker writes no event for orders it saw on a case's first fetch.)
final newOrdersProvider = StreamProvider<List<DiaryNotice>>(
  (ref) => _notices(ref, 'new_order'),
);

final _syncIssuesProvider = StreamProvider<List<DiaryNotice>>(
  (ref) => _notices(ref, 'sync_issue'),
);

/// Needs attention (spec §4.2, §11.6), in this order.
enum AttentionKind {
  /// Auto-tracked, pending, fetched at least once, and the court next date is missing or past: "No next date".
  noNextDate,

  /// Auto-tracked, never fetched, added over an hour ago: "Couldn't get court data yet".
  courtDataPending,

  /// An unread `sync_issue` from the last 2 days (one item, no case): "Court data is delayed".
  courtDataDelayed,

  /// Manual, with no hearing today or later: "Add the next date".
  addNextDate,

  /// Auto-tracked, and the user noted a next date (today or later) that differs from the court's: "Court record
  /// says 12 Nov; you noted 14 Nov". The court date is the one shown elsewhere.
  dateMismatch,
}

@immutable
class AttentionItem {
  const AttentionItem(
    this.kind, {
    this.matterId,
    this.caseLabel,
    this.courtDate,
    this.userDate,
    this.notificationId,
  });

  final AttentionKind kind;

  /// The case it opens; null for [AttentionKind.courtDataDelayed].
  final String? matterId;
  final String? caseLabel;

  /// [AttentionKind.dateMismatch]: the court's and the user's next dates (IST days); [AttentionKind.noNextDate]:
  /// the past court date, if any.
  final DateTime? courtDate;
  final DateTime? userDate;

  /// [AttentionKind.courtDataDelayed]: the notification to mark read when opened.
  final String? notificationId;
}

/// The rules over the attention query's [matters] rows and the unread sync issues, at [nowIst]: at most one
/// item per case (a date mismatch wins over "No next date"), by kind then case.
List<AttentionItem> needsAttention(
  Iterable<Map<String, dynamic>> matters,
  Iterable<DiaryNotice> syncIssues,
  DateTime nowIst,
) {
  final now = istInstant(nowIst);
  final today = istDay(nowIst);
  final items = <AttentionItem>[];
  for (final r in matters) {
    final label = _rowLabel(r);
    AttentionItem item(
      AttentionKind kind, {
      DateTime? courtDate,
      DateTime? userDate,
    }) => AttentionItem(
      kind,
      matterId: r['id'] as String,
      caseLabel: label.isEmpty ? r['title'] as String? : label,
      courtDate: courtDate,
      userDate: userDate,
    );
    final next = parseDay(r['next_hearing_date']);
    if (r['tracking'] == 'manual') {
      final last = parseDay(r['last_hearing_date']);
      if (last == null || last.isBefore(today)) {
        items.add(item(AttentionKind.addNextDate));
      }
    } else if (r['court_fetched_at'] == null) {
      final added = parseInstant(r['created_at']);
      if (added != null && now.difference(added) >= const Duration(hours: 1)) {
        items.add(item(AttentionKind.courtDataPending));
      }
    } else {
      final noted = parseDay(r['user_next_date']);
      if (noted != null &&
          !noted.isBefore(today) &&
          next != null &&
          noted != next) {
        items.add(
          item(AttentionKind.dateMismatch, courtDate: next, userDate: noted),
        );
      } else if (r['court_status'] == 'pending' &&
          (next == null || next.isBefore(today))) {
        items.add(item(AttentionKind.noNextDate, courtDate: next));
      }
    }
  }
  final delayed = syncIssues.where((n) {
    final at = n.createdAt;
    return at != null && now.difference(at) <= const Duration(days: 2);
  }).firstOrNull;
  if (delayed != null) {
    items.add(
      AttentionItem(AttentionKind.courtDataDelayed, notificationId: delayed.id),
    );
  }
  return items..sort(
    (a, b) => a.kind != b.kind
        ? a.kind.index.compareTo(b.kind.index)
        : (a.caseLabel ?? '').compareTo(b.caseLabel ?? ''),
  );
}

const _attentionSql = '''
select m.id, m.case_type, m.case_number, m.case_year, m.cnr, m.title, m.tracking, m.court_status,
  m.court_fetched_at, m.next_hearing_date, m.created_at,
  (select max(h.date) from hearings h where h.matter_id = m.id and h.deleted_at is null) as last_hearing_date,
  (select h.user_next_date from hearings h where h.matter_id = m.id and h.deleted_at is null
   and h.user_next_date is not null order by h.date desc, h.created_at desc limit 1) as user_next_date
from matters m
where m.org_id = ? and m.deleted_at is null and m.status = 'active' and m.tracking in ('auto', 'manual')
''';

/// ponytail: scans every live matter of the org (hundreds at most in beta); move the rules into SQL if that grows.
final _attentionRowsProvider = StreamProvider<List<Map<String, dynamic>>>((
  ref,
) {
  final db = ref.watch(syncDatabaseProvider);
  final org = ref.watch(currentOrgIdProvider);
  if (db == null || org == null) return Stream.value(const []);
  return db
      .watch(_attentionSql, parameters: [org])
      .map((rows) => [for (final r in rows) Map<String, dynamic>.of(r)]);
});

/// "Needs attention" on Today ([needsAttention] over the current org's matters and sync issues), re-checked
/// every minute.
final needsAttentionProvider = Provider<AsyncValue<List<AttentionItem>>>((ref) {
  final now = ref.watch(istNowProvider);
  final rows = ref.watch(_attentionRowsProvider);
  final issues = ref.watch(_syncIssuesProvider);
  final (r, i) = (rows.value, issues.value);
  if (r == null || i == null) {
    final failed = rows.hasError ? rows : issues;
    return failed.hasError
        ? AsyncError(failed.error!, failed.stackTrace ?? StackTrace.current)
        : const AsyncLoading();
  }
  return AsyncData(needsAttention(r, i, now));
});

/// An active member of the current org, for Assign to (spec §4.2).
@immutable
class OrgMember {
  const OrgMember({required this.userId, required this.role, this.name});

  final String userId;

  /// `owner`, `advocate`, `junior` or `clerk`. Assign to lists everyone but clerks.
  final String role;

  /// The member's display name; null when they haven't set one.
  final String? name;
}

/// The current org's active members, by name.
final orgMembersProvider = StreamProvider<List<OrgMember>>((ref) {
  final db = ref.watch(syncDatabaseProvider);
  final org = ref.watch(currentOrgIdProvider);
  if (db == null || org == null) return Stream.value(const []);
  return db
      .watch(
        'select user_id, role, display_name from memberships '
        "where org_id = ? and status = 'active' order by display_name, created_at",
        parameters: [org],
      )
      .map(
        (rows) => [
          for (final r in rows)
            OrgMember(
              userId: r['user_id'] as String,
              role: r['role'] as String,
              name: r['display_name'] as String?,
            ),
        ],
      );
});

/// Whether the current org has any live case (Today's empty state offers "Add your first case" when not).
final hasMattersProvider = StreamProvider<bool>((ref) {
  final db = ref.watch(syncDatabaseProvider);
  final org = ref.watch(currentOrgIdProvider);
  if (db == null || org == null) return Stream.value(false);
  return db
      .watch(
        'select exists(select 1 from matters where org_id = ? and deleted_at is null) as any_matter',
        parameters: [org],
      )
      .map((rows) => rows.first['any_matter'] == 1);
});

/// Today's and the board's writes (spec §4.2): local, uploaded when online. The server takes only these columns
/// from a device (`device_columns` triggers, RLS): board rows from owners and advocates, task status from members,
/// read_at on the user's own notifications. A refused write is dropped and the server's row comes back.
/// Without a sync database (builds without sync) they do nothing.
class DiaryWriter {
  DiaryWriter(this._db, this._clock);

  final PowerSyncDatabase? _db;
  final DateTime Function() _clock;

  /// Assign to (board rows only); null = no one, for Undo of a first assignment.
  Future<void> assign(String boardEntryId, String? userId) => _run(
    'update board_entries set assignee_id = ? where id = ?',
    [userId, boardEntryId],
  );

  /// Mark proxy arranged, or undo it.
  Future<void> setProxy(String boardEntryId, {required bool arranged}) => _run(
    'update board_entries set proxy_arranged = ? where id = ?',
    [if (arranged) 1 else 0, boardEntryId],
  );

  Future<void> completeTask(String taskId) =>
      _run("update tasks set status = 'done' where id = ?", [taskId]);

  /// Undo of [completeTask].
  Future<void> reopenTask(String taskId) =>
      _run("update tasks set status = 'open' where id = ?", [taskId]);

  Future<void> markNotificationRead(String notificationId) => _run(
    'update notifications set read_at = ? where id = ? and read_at is null',
    [_clock().toUtc().toIso8601String(), notificationId],
  );

  Future<void> _run(String sql, List<Object?> parameters) async {
    await _db?.execute(sql, parameters);
  }
}

final diaryWriterProvider = Provider<DiaryWriter>(
  (ref) =>
      DiaryWriter(ref.watch(syncDatabaseProvider), ref.watch(clockProvider)),
);
