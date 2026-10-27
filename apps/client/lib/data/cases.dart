import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Locale;

import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/search_key.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/case_label.dart';
import 'package:advocate_app/data/courts.dart';
import 'package:advocate_app/data/device.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart'
    show ProviderFamily, StreamProviderFamily;
import 'package:powersync/powersync.dart' hide SyncStatus;

/// The next date of a case (ADR 0015), the one rule the Cases list, the case page and sharing use: the court's
/// next date for auto- and off-tracked cases, else (manual) the earliest live hearing dated today or later (IST),
/// which the queries pass in as [manualNext]. A date before [today] (IST) is no next date: the court hasn't
/// published the next one yet. Task 8's diary applies the same rule in SQL.
DateTime? nextDateOf({
  required String tracking,
  required DateTime today,
  DateTime? courtNext,
  DateTime? manualNext,
}) {
  final next = tracking == 'manual' ? manualNext : courtNext;
  return next == null || next.isBefore(today) ? null : next;
}

/// A case of the current org (spec §4.3): a Cases list row and the case page header.
class CaseInfo {
  CaseInfo({
    required this.id,
    this.cnr,
    this.caseType,
    this.caseNumber,
    this.caseYear,
    this.title,
    this.courtId,
    this.court,
    this.courtName,
    this.courtNo,
    this.judge,
    this.stage,
    this.status = 'active',
    this.tracking = 'auto',
    this.source = 'cnr',
    this.courtStatus,
    this.nextDate,
    this.courtFetchedAt,
    this.updatedAt,
    this.ourSide,
    this.fileNo,
    this.assigneeId,
    this.assigneeName,
    this.clients = const [],
  });

  /// A [_caseSql] row on [today] (IST day).
  factory CaseInfo.fromRow(Map<String, dynamic> r, DateTime today) {
    final courtId = r['court_id'] as String?;
    final shortName = r['court_short_name'] as String?;
    final tracking = r['tracking'] as String? ?? 'auto';
    final clients = r['clients'] as String?;
    return CaseInfo(
      id: r['id'] as String,
      cnr: r['cnr'] as String?,
      caseType: r['case_type'] as String?,
      caseNumber: r['case_number'] as String?,
      caseYear: r['case_year'] as int?,
      title: r['title'] as String?,
      courtId: courtId,
      court: courtId == null || shortName == null
          ? null
          : Court(
              id: courtId,
              level: r['court_level'] as String,
              name: r['court_full_name'] as String? ?? shortName,
              nameHi: r['court_name_hi'] as String?,
              shortName: shortName,
              shortNameHi: r['court_short_name_hi'] as String?,
            ),
      courtName: r['court_name'] as String?,
      courtNo: r['court_no'] as String?,
      judge: r['judge'] as String?,
      stage: r['stage'] as String?,
      status: r['status'] as String? ?? 'active',
      tracking: tracking,
      source: r['source'] as String? ?? 'cnr',
      courtStatus: r['court_status'] as String?,
      nextDate: nextDateOf(
        tracking: tracking,
        today: today,
        courtNext: parseDay(r['next_hearing_date']),
        manualNext: parseDay(r['manual_next']),
      ),
      courtFetchedAt: parseInstant(r['court_fetched_at']),
      updatedAt: parseInstant(r['updated_at']),
      ourSide: r['our_side'] as String?,
      fileNo: r['file_no'] as String?,
      assigneeId: r['assigned_to'] as String?,
      assigneeName: r['assignee_name'] as String?,
      clients: [
        if (clients != null)
          for (final c in jsonDecode(clients) as List)
            (id: (c as Map)['id'] as String, name: c['name'] as String),
      ],
    );
  }

  final String id;
  final String? cnr;
  final String? caseType;
  final String? caseNumber;
  final int? caseYear;

  /// "Petitioner v. Respondent". Party names: never log it, never put it in a URL.
  final String? title;

  /// A synced court; [court] is null until the courts table has it, or for a manual case's "Other court",
  /// whose typed name is [courtName].
  final String? courtId;
  final Court? court;
  final String? courtName;
  final String? courtNo;
  final String? judge;
  final String? stage;

  /// `active` or `archived` (the user's; a device column).
  final String status;

  /// `auto`, `manual` or `off`.
  final String tracking;

  /// `import`, `cnr`, `search`, `manual` or `found`.
  final String source;

  /// The court's: `pending`, `disposed`, `transferred`, `unknown`; null until fetched (always, for manual cases).
  final String? courtStatus;

  /// IST day, today or later, by [nextDateOf].
  final DateTime? nextDate;

  /// When a worker last copied the official record (instant): "Updated 7:42 pm from the official record".
  final DateTime? courtFetchedAt;

  /// Instant; "Recently updated" sorts by it.
  final DateTime? updatedAt;
  final String? ourSide;
  final String? fileNo;

  /// `matters.assigned_to`; null = no one.
  final String? assigneeId;
  final String? assigneeName;

  /// Linked clients, oldest link first. Never log or share them.
  final List<({String id, String name})> clients;

  static const _keep = Object();

  /// For fakes: what local writes and sync change. Pass null to clear a field; leave it out to keep it.
  CaseInfo copyWith({
    Object? assigneeId = _keep,
    Object? assigneeName = _keep,
    String? status,
    String? tracking,
    Object? nextDate = _keep,
    List<({String id, String name})>? clients,
  }) => CaseInfo(
    id: id,
    cnr: cnr,
    caseType: caseType,
    caseNumber: caseNumber,
    caseYear: caseYear,
    title: title,
    courtId: courtId,
    court: court,
    courtName: courtName,
    courtNo: courtNo,
    judge: judge,
    stage: stage,
    status: status ?? this.status,
    tracking: tracking ?? this.tracking,
    source: source,
    courtStatus: courtStatus,
    nextDate: nextDate == _keep ? this.nextDate : nextDate as DateTime?,
    courtFetchedAt: courtFetchedAt,
    updatedAt: updatedAt,
    ourSide: ourSide,
    fileNo: fileNo,
    assigneeId: assigneeId == _keep ? this.assigneeId : assigneeId as String?,
    assigneeName: assigneeName == _keep
        ? this.assigneeName
        : assigneeName as String?,
    clients: clients ?? this.clients,
  );

  /// "WP 1234/2024", else the CNR, else (a manual case with neither) the title, else ''.
  String get caseLabel {
    final label = caseLabelOf(
      caseType: caseType,
      caseNumber: caseNumber,
      caseYear: caseYear,
      cnr: cnr,
    );
    return label.isEmpty ? title ?? '' : label;
  }

  /// Whether [caseLabel] is a number or CNR rather than the title (party names).
  bool get numbered => (caseNumber ?? '').isNotEmpty || (cnr ?? '').isNotEmpty;

  bool get archived => status == 'archived';
  bool get manual => tracking == 'manual';
  bool get trackingOff => tracking == 'off';

  /// Decided or moved by the court (the Disposed section).
  bool get disposed =>
      courtStatus == 'disposed' || courtStatus == 'transferred';

  /// Short court name in the UI language, else the typed court name; null when neither is known.
  String? courtLabel(Locale locale) => court?.label(locale) ?? courtName;

  /// Lower-case text that search matches literally: case label, CNR, title, client names. Built once per
  /// emission (on the first search over it), never per keystroke.
  late final String searchText = [
    caseLabel,
    ?cnr,
    ?title,
    for (final c in clients) c.name,
  ].join(' ').toLowerCase();

  /// [searchText] without spaces or punctuation: "MPHC-0100 1234 2024" finds the CNR.
  late final String searchCompact = _compactOf(searchText);

  /// [searchKey] of the title and client names: "sharma" finds "शर्मा" and back.
  late final String searchKeys = searchKey(
    [?title, for (final c in clients) c.name].join(' '),
  );
}

String _compactOf(String s) => s.replaceAll(RegExp(r'[\s\-/.,]'), '');

/// A search as typed, normalised once per keystroke (spec §4.3): case number or label, party (title), client
/// names and CNR, with Hindi/English transliteration.
@immutable
class CaseQuery {
  CaseQuery(String input)
    : text = input.trim().toLowerCase(),
      compact = _compactOf(input.trim().toLowerCase()),
      keys = searchKey(input)
          .split(' ')
          .where((k) => k.isNotEmpty)
          .toList(growable: false);

  final String text;
  final String compact;
  final List<String> keys;

  bool get isEmpty => text.isEmpty;

  /// Literal match on the label, CNR, title or client names; or every word's key is found in the title's and
  /// clients' keys (so a Hindi query finds an English title and back).
  bool matches(CaseInfo c) =>
      isEmpty ||
      c.searchText.contains(text) ||
      (compact.length >= 3 && c.searchCompact.contains(compact)) ||
      (keys.isNotEmpty && keys.every(c.searchKeys.contains));
}

/// Cases list sections (spec §4.3), in this order. Found for you is a link, not a section of cases.
enum CaseSection {
  today,

  /// Tomorrow to today + 6.
  thisWeek,
  later,

  /// Pending with no next date, or one in the past.
  noNextDate,

  /// Court status disposed or transferred.
  disposed,

  /// Archived by the user; shown only under the status filter "Archived".
  archived,
}

/// Which section [c] belongs in on [today] (IST day).
CaseSection sectionOf(CaseInfo c, DateTime today) {
  if (c.archived) return CaseSection.archived;
  if (c.disposed) return CaseSection.disposed;
  final next = c.nextDate;
  if (next == null || next.isBefore(today)) return CaseSection.noNextDate;
  if (next == today) return CaseSection.today;
  if (next.difference(today).inDays <= 6) return CaseSection.thisWeek;
  return CaseSection.later;
}

/// Status filter: [pending] and [disposed] are live cases; [archived] shows only archived ones. No status
/// filter shows every live (unarchived) case.
enum CaseStatusFilter { pending, disposed, archived }

enum CaseSort {
  /// Soonest first, cases without a next date last.
  nextDate,
  recentlyUpdated,

  /// "WP 2/2024" before "WP 10/2024".
  caseNumber,
}

/// Search, filters and sort on the Cases list, kept while the app runs ([caseFilterProvider]).
@immutable
class CaseFilter {
  const CaseFilter({
    this.query = '',
    this.courtId,
    this.clientId,
    this.status,
    this.assigneeId,
    this.sort = CaseSort.nextDate,
  });

  final String query;
  final String? courtId;
  final String? clientId;
  final CaseStatusFilter? status;
  final String? assigneeId;
  final CaseSort sort;

  /// Any filter set (search and sort aside): "Clear filters" shows when nothing matches.
  bool get filtering =>
      courtId != null ||
      clientId != null ||
      status != null ||
      assigneeId != null;

  static const _keep = Object();

  /// Pass null to clear a filter; leave it out to keep it.
  CaseFilter copyWith({
    String? query,
    Object? courtId = _keep,
    Object? clientId = _keep,
    Object? status = _keep,
    Object? assigneeId = _keep,
    CaseSort? sort,
  }) => CaseFilter(
    query: query ?? this.query,
    courtId: courtId == _keep ? this.courtId : courtId as String?,
    clientId: clientId == _keep ? this.clientId : clientId as String?,
    status: status == _keep ? this.status : status as CaseStatusFilter?,
    assigneeId: assigneeId == _keep ? this.assigneeId : assigneeId as String?,
    sort: sort ?? this.sort,
  );

  @override
  bool operator ==(Object other) =>
      other is CaseFilter &&
      other.query == query &&
      other.courtId == courtId &&
      other.clientId == clientId &&
      other.status == status &&
      other.assigneeId == assigneeId &&
      other.sort == sort;

  @override
  int get hashCode =>
      Object.hash(query, courtId, clientId, status, assigneeId, sort);
}

/// Whether [c] passes [f]'s filters (not its search).
bool passesFilter(CaseInfo c, CaseFilter f) =>
    (f.courtId == null || c.courtId == f.courtId) &&
    (f.clientId == null || c.clients.any((x) => x.id == f.clientId)) &&
    (f.assigneeId == null || c.assigneeId == f.assigneeId) &&
    switch (f.status) {
      null => !c.archived,
      CaseStatusFilter.pending => !c.archived && !c.disposed,
      CaseStatusFilter.disposed => !c.archived && c.disposed,
      CaseStatusFilter.archived => c.archived,
    };

/// Compares strings with digit runs as numbers ("WP 2/2024" < "WP 10/2024"), case-insensitively.
int compareNatural(String a, String b) {
  final re = RegExp(r'\d+|\D+');
  final x = re.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
  final y = re.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
  for (var i = 0; i < x.length && i < y.length; i++) {
    final (p, q) = (int.tryParse(x[i]), int.tryParse(y[i]));
    final d = p != null && q != null ? p.compareTo(q) : x[i].compareTo(y[i]);
    if (d != 0) return d;
  }
  return x.length.compareTo(y.length);
}

int _byNumber(CaseInfo a, CaseInfo b) =>
    compareNatural(a.caseLabel, b.caseLabel);

/// [sort]'s order; ties fall back to the case number.
Comparator<CaseInfo> caseComparator(CaseSort sort) => switch (sort) {
  CaseSort.nextDate => (a, b) {
    final (x, y) = (a.nextDate, b.nextDate);
    final d = x == null
        ? (y == null ? 0 : 1)
        : y == null
        ? -1
        : x.compareTo(y);
    return d != 0 ? d : _byNumber(a, b);
  },
  CaseSort.recentlyUpdated => (a, b) {
    final (x, y) = (a.updatedAt, b.updatedAt);
    final d = x == null
        ? (y == null ? 0 : 1)
        : y == null
        ? -1
        : y.compareTo(x);
    return d != 0 ? d : _byNumber(a, b);
  },
  CaseSort.caseNumber => _byNumber,
};

/// The Cases list's sections in order, each with its cases sorted; empty sections are left out.
typedef CaseSections = List<({CaseSection section, List<CaseInfo> cases})>;

/// [cases] after [f]'s search and filters, by section on [today] (IST day).
CaseSections caseSections(
  Iterable<CaseInfo> cases,
  CaseFilter f,
  DateTime today,
) {
  final query = CaseQuery(f.query);
  final bySection = <CaseSection, List<CaseInfo>>{};
  for (final c in cases) {
    if (passesFilter(c, f) && query.matches(c)) {
      (bySection[sectionOf(c, today)] ??= []).add(c);
    }
  }
  final order = caseComparator(f.sort);
  return [
    for (final s in CaseSection.values)
      if (bySection[s] case final list?) (section: s, cases: list..sort(order)),
  ];
}

const _caseSql = '''
select m.id, m.cnr, m.case_type, m.case_number, m.case_year, m.title, m.court_id, m.court_name, m.court_no,
  m.judge, m.stage, m.status, m.tracking, m.source, m.court_status, m.next_hearing_date, m.court_fetched_at,
  m.updated_at, m.our_side, m.file_no, m.assigned_to, ms.display_name as assignee_name,
  c.level as court_level, c.name as court_full_name, c.name_hi as court_name_hi, c.short_name as court_short_name,
  c.short_name_hi as court_short_name_hi,
  (select min(h.date) from hearings h where h.matter_id = m.id and h.deleted_at is null and h.date >= ?2)
    as manual_next,
  (select json_group_array(json_object('id', x.id, 'name', x.name)) from (select cl.id, cl.name
    from matter_clients mc join clients cl on cl.id = mc.client_id and cl.deleted_at is null
    where mc.matter_id = m.id order by mc.created_at, cl.name) x) as clients
from matters m
left join courts c on c.id = m.court_id
left join memberships ms on ms.org_id = m.org_id and ms.user_id = m.assigned_to and ms.status = 'active'
where m.org_id = ?1 and m.deleted_at is null
''';

/// Every live case of the current org, archived ones included (the Cases list, the task sheet's case picker).
/// Re-read at midnight IST, when manual next dates move on. Empty without an org or sync.
/// ponytail: one query over every case (orgs reach ~1,200); page it in SQL if emissions get slow.
final casesProvider = StreamProvider<List<CaseInfo>>((ref) {
  final db = ref.watch(syncDatabaseProvider);
  final org = ref.watch(currentOrgIdProvider);
  final today = ref.watch(istTodayProvider);
  if (db == null || org == null) return Stream.value(const []);
  return db
      .watch(_caseSql, parameters: [org, isoDate(today)])
      .map((rows) => [for (final r in rows) CaseInfo.fromRow(r, today)]);
});

/// One case of the current org; null when it isn't on the device (deleted, or not this org's).
final StreamProviderFamily<CaseInfo?, String>
caseProvider = StreamProvider.autoDispose.family<CaseInfo?, String>((ref, id) {
  final db = ref.watch(syncDatabaseProvider);
  final org = ref.watch(currentOrgIdProvider);
  final today = ref.watch(istTodayProvider);
  if (db == null || org == null) return Stream.value(null);
  return db
      .watch('$_caseSql and m.id = ?3', parameters: [org, isoDate(today), id])
      .map((rows) => rows.isEmpty ? null : CaseInfo.fromRow(rows.first, today));
});

/// Cases this device has just added through the API (by CNR, search or by hand), for a minute: a new case's row
/// reaches the device with the next sync, so until then the case page shows it loading, not "removed" (spec §5.4).
/// ponytail: a fixed minute, then "removed"; watch the sync status if slow links need longer.
class AddedCases extends Notifier<Set<String>> {
  final _timers = <Timer>[];

  @override
  Set<String> build() {
    ref.onDispose(() {
      for (final t in _timers) {
        t.cancel();
      }
    });
    return const {};
  }

  void add(String id) {
    state = {...state, id};
    _timers.add(
      Timer(const Duration(minutes: 1), () => state = {...state}..remove(id)),
    );
  }
}

final addedCasesProvider = NotifierProvider<AddedCases, Set<String>>(
  AddedCases.new,
);

/// Holds [CaseFilter] while the app runs (spec §4.3); not persisted.
class CaseFilterController extends Notifier<CaseFilter> {
  @override
  CaseFilter build() => const CaseFilter();

  /// e.g. `change((f) => f.copyWith(courtId: id))`.
  void change(CaseFilter Function(CaseFilter) f) => state = f(state);

  void setQuery(String query) => state = state.copyWith(query: query);

  /// Back to no filters; search and sort stay.
  void clearFilters() =>
      state = CaseFilter(query: state.query, sort: state.sort);
}

final caseFilterProvider = NotifierProvider<CaseFilterController, CaseFilter>(
  CaseFilterController.new,
);

/// The Cases list: [casesProvider] through [caseFilterProvider] on today (IST), by [caseSections].
final caseSectionsProvider = Provider<AsyncValue<CaseSections>>((ref) {
  final filter = ref.watch(caseFilterProvider);
  final today = ref.watch(istTodayProvider);
  return ref
      .watch(casesProvider)
      .whenData((cases) => caseSections(cases, filter, today));
});

/// How many found cases are waiting for a decision (decision `pending`): "Found for you (n)", hidden at zero.
final pendingFoundCountProvider = StreamProvider<int>((ref) {
  final db = ref.watch(syncDatabaseProvider);
  final org = ref.watch(currentOrgIdProvider);
  if (db == null || org == null) return Stream.value(0);
  return db
      .watch(
        "select count(*) as n from found_cases where org_id = ? and decision = 'pending'",
        parameters: [org],
      )
      .map((rows) => rows.first['n'] as int);
});

/// A hearing or an order on the case timeline.
sealed class TimelineEntry {
  const TimelineEntry();

  /// IST day; null for an order without a date.
  DateTime? get date;
  DateTime? get createdAt;
}

/// A hearing (spec §4.3 Timeline). Court rows: the court fields are the worker's and the `user*` fields the
/// user's ("you noted"); manual rows ([manual]) keep everything in the court fields and are edited whole.
@immutable
final class CaseHearing extends TimelineEntry {
  const CaseHearing({
    required this.id,
    required this.date,
    this.source = 'court',
    this.courtNo,
    this.itemNo,
    this.purpose,
    this.outcome,
    this.nextDate,
    this.userPurpose,
    this.userOutcome,
    this.userNextDate,
    this.userNote,
    this.createdAt,
  });

  factory CaseHearing.fromRow(Map<String, dynamic> r) => CaseHearing(
    id: r['id'] as String,
    date: parseDay(r['date'])!,
    source: r['source'] as String? ?? 'manual',
    courtNo: r['court_no'] as String?,
    itemNo: r['item_no'] as String?,
    purpose: r['purpose'] as String?,
    outcome: r['outcome'] as String?,
    nextDate: parseDay(r['next_date']),
    userPurpose: r['user_purpose'] as String?,
    userOutcome: r['user_outcome'] as String?,
    userNextDate: parseDay(r['user_next_date']),
    userNote: r['user_note'] as String?,
    createdAt: parseInstant(r['created_at']),
  );

  final String id;
  @override
  final DateTime date;

  /// `court`, `manual` or `voice`.
  final String source;
  final String? courtNo;
  final String? itemNo;
  final String? purpose;
  final String? outcome;
  final DateTime? nextDate;
  final String? userPurpose;
  final String? userOutcome;
  final DateTime? userNextDate;

  /// The hearing note, editable on every hearing.
  final String? userNote;
  @override
  final DateTime? createdAt;

  /// Added by hand on a manual case: editable and deletable.
  bool get manual => source == 'manual';
}

/// What a hearing shows (spec §4.3): the court's value wins; the user's shows as "you noted" (`noted`) where it
/// differs, or as the value when the court has none.
({T? value, T? noted}) courtWins<T>(T? court, T? user) => (
  value: court ?? user,
  noted: court != null && user != null && user != court ? user : null,
);

/// An order (spec §4.3 Timeline): "New" until the user opens it ([read]: an order_reads row of theirs).
@immutable
final class CaseOrder extends TimelineEntry {
  const CaseOrder({
    required this.id,
    this.date,
    this.title,
    this.documentId,
    this.hasCourtCopy = true,
    this.read = false,
    this.createdAt,
    this.summaryEn,
    this.summaryHi,
  });

  factory CaseOrder.fromRow(Map<String, dynamic> r) => CaseOrder(
    id: r['id'] as String,
    date: parseDay(r['order_date']),
    title: r['title'] as String?,
    documentId: r['document_id'] as String?,
    hasCourtCopy: r['court_order_id'] != null,
    read: r['is_read'] == 1,
    createdAt: parseInstant(r['created_at']),
    summaryEn: _object(r['summary_en']),
    summaryHi: _object(r['summary_hi']),
  );

  final String id;
  @override
  final DateTime? date;
  final String? title;
  final String? documentId;

  /// Linked to the court's order (GET /v1/orders/{id}/pdf-url can fetch it); else ORDER_PDF_UNAVAILABLE.
  final bool hasCourtCopy;
  final bool read;
  @override
  final DateTime? createdAt;

  /// The AI summary (spec F07) in English and in Hindi as the pipeline stored it (`OrderSummaryView.fromJson`
  /// reads it); null until made.
  final Map<String, Object?>? summaryEn;
  final Map<String, Object?>? summaryHi;

  /// The summary in [language] (`en` or `hi`).
  Map<String, Object?>? summary(String language) =>
      language == 'hi' ? summaryHi : summaryEn;
}

/// A synced JSON column (JSON text on the device) as a map.
Map<String, Object?>? _object(Object? v) =>
    ((v is String ? jsonDecode(v) : v) as Map?)?.cast();

/// Newest first; on the same day an order comes before the hearing it followed, then the newer row first.
List<TimelineEntry> timelineOf(
  Iterable<CaseHearing> hearings,
  Iterable<CaseOrder> orders,
) {
  int rank(TimelineEntry e) => e is CaseOrder ? 0 : 1;
  return [...orders, ...hearings]..sort((a, b) {
    final (x, y) = (a.date, b.date);
    var d = x == null
        ? (y == null ? 0 : 1)
        : y == null
        ? -1
        : y.compareTo(x);
    if (d == 0) d = rank(a).compareTo(rank(b));
    if (d == 0) {
      d = (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0));
    }
    return d;
  });
}

/// The case page header's purpose for the next date: the hearing on [CaseInfo.nextDate] (court value first),
/// else the case's stage.
String? nextPurposeOf(CaseInfo c, Iterable<CaseHearing> hearings) {
  final next = c.nextDate;
  final h = next == null
      ? null
      : hearings.where((h) => h.date == next).firstOrNull;
  return h?.purpose ?? h?.userPurpose ?? c.stage;
}

/// Rows of [sql] with [parameters] as [T]s; empty without sync.
Stream<List<T>> _rows<T>(
  Ref ref,
  String sql,
  List<Object?> parameters,
  T Function(Map<String, dynamic>) fromRow,
) {
  final db = ref.watch(syncDatabaseProvider);
  if (db == null) return Stream.value(const []);
  return db
      .watch(sql, parameters: parameters)
      .map((rows) => rows.map(fromRow).toList());
}

/// A case's live hearings, newest first.
final StreamProviderFamily<List<CaseHearing>, String> caseHearingsProvider =
    StreamProvider.autoDispose.family<List<CaseHearing>, String>(
      (ref, id) => _rows(
        ref,
        'select id, date, source, court_no, item_no, purpose, outcome, next_date, user_purpose, user_outcome, '
        'user_next_date, user_note, created_at from hearings where matter_id = ?1 and deleted_at is null '
        'order by date desc, created_at desc',
        [id],
        CaseHearing.fromRow,
      ),
    );

/// A case's orders, newest first, with whether the user has read each.
final StreamProviderFamily<List<CaseOrder>, String> caseOrdersProvider =
    StreamProvider.autoDispose.family<List<CaseOrder>, String>(
      (ref, id) => _rows(
        ref,
        'select o.id, o.order_date, o.title, o.document_id, o.court_order_id, o.created_at, o.summary_en, '
        'o.summary_hi, exists(select 1 from order_reads r where r.order_id = o.id and r.user_id = ?2) as is_read '
        'from orders o where o.matter_id = ?1 and o.deleted_at is null order by o.order_date desc, o.created_at desc',
        [id, ref.watch(currentUserIdProvider)],
        CaseOrder.fromRow,
      ),
    );

/// The Timeline tab: [timelineOf] the case's hearings and orders.
final ProviderFamily<AsyncValue<List<TimelineEntry>>, String>
caseTimelineProvider = Provider.autoDispose
    .family<AsyncValue<List<TimelineEntry>>, String>((ref, id) {
      final hearings = ref.watch(caseHearingsProvider(id));
      final orders = ref.watch(caseOrdersProvider(id));
      final (h, o) = (hearings.value, orders.value);
      if (h != null && o != null) return AsyncData(timelineOf(h, o));
      final failed = hearings.hasError ? hearings : orders;
      return failed.hasError
          ? AsyncError(failed.error!, failed.stackTrace ?? StackTrace.current)
          : const AsyncLoading();
    });

/// A document of the org (spec §4.3 Documents), filed under a case or not: the case's Documents tab and the
/// Documents screen.
@immutable
class CaseDocument {
  const CaseDocument({
    required this.id,
    required this.title,
    this.kind = 'other',
    this.mime,
    this.sizeBytes,
    this.pages,
    this.uploadStatus = 'ready',
    this.createdAt,
    this.matterId,
    this.caseLabel,
    this.keepOffline = false,
    this.offline = false,
  });

  /// A [documentSql] row.
  factory CaseDocument.fromRow(Map<String, dynamic> r) {
    final label = caseLabelOf(
      caseType: r['case_type'] as String?,
      caseNumber: r['case_number'] as String?,
      caseYear: r['case_year'] as int?,
      cnr: r['cnr'] as String?,
    );
    return CaseDocument(
      id: r['id'] as String,
      title: r['title'] as String? ?? '',
      kind: r['kind'] as String? ?? 'other',
      mime: r['mime'] as String?,
      sizeBytes: r['size_bytes'] as int?,
      pages: r['pages'] as int?,
      uploadStatus: r['upload_status'] as String? ?? 'pending',
      createdAt: parseInstant(r['created_at']),
      matterId: r['matter_id'] as String?,
      caseLabel: label.isEmpty ? r['matter_title'] as String? : label,
      keepOffline: r['keep_offline'] == 1,
      offline: r['offline'] == 1,
    );
  }

  final String id;

  /// Never log it or put it in a URL.
  final String title;

  /// `pleading`, `order`, `evidence`, `annexure`, `correspondence` or `other` ([documentKinds]).
  final String kind;
  final String? mime;
  final int? sizeBytes;
  final int? pages;

  /// `pending` (being checked; DOCUMENT_NOT_READY), `ready` or `quarantined` (failed the safety check).
  final String uploadStatus;
  final DateTime? createdAt;

  /// The case it is filed under (null = none) and that case's label.
  final String? matterId;
  final String? caseLabel;

  /// The user's "Keep offline" (`document_offline_prefs`).
  final bool keepOffline;

  /// A copy is on this device (the offline cache): it opens without the network.
  final bool offline;

  bool get ready => uploadStatus == 'ready';

  static const _keep = Object();

  /// For fakes: what local writes and the cache change. Pass null to clear [matterId]; leave it out to keep it.
  CaseDocument copyWith({
    String? title,
    String? kind,
    Object? matterId = _keep,
    String? caseLabel,
    String? uploadStatus,
    bool? keepOffline,
    bool? offline,
  }) => CaseDocument(
    id: id,
    title: title ?? this.title,
    kind: kind ?? this.kind,
    mime: mime,
    sizeBytes: sizeBytes,
    pages: pages,
    uploadStatus: uploadStatus ?? this.uploadStatus,
    createdAt: createdAt,
    matterId: matterId == _keep ? this.matterId : matterId as String?,
    caseLabel: matterId == _keep ? caseLabel ?? this.caseLabel : caseLabel,
    keepOffline: keepOffline ?? this.keepOffline,
    offline: offline ?? this.offline,
  );
}

/// Live documents with what lists show: the case label, the user's (`?1`) Keep offline and whether a copy is on
/// the device. A document still in the upload queue is left out: the queue item stands for it until complete.
/// Callers add their own `and …` and order.
const documentSql = '''
select d.id, d.title, d.kind, d.mime, d.size_bytes, d.pages, d.upload_status, d.created_at, d.matter_id,
  m.case_type, m.case_number, m.case_year, m.cnr, m.title as matter_title,
  exists(select 1 from document_offline_prefs p where p.document_id = d.id and p.user_id = ?1
    and p.keep_offline = 1) as keep_offline,
  exists(select 1 from offline_files f where f.id = d.id) as offline
from documents d
left join matters m on m.id = d.matter_id and m.deleted_at is null
where d.deleted_at is null and not exists (select 1 from upload_queue q where q.document_id = d.id)
''';

/// Document kinds (spec §4.3 "Types"), in the order pickers list them.
const documentKinds = [
  'pleading',
  'order',
  'evidence',
  'annexure',
  'correspondence',
  'other',
];

/// A case's documents, newest first.
final StreamProviderFamily<List<CaseDocument>, String> caseDocumentsProvider =
    StreamProvider.autoDispose.family<List<CaseDocument>, String>(
      (ref, id) => _rows(
        ref,
        '$documentSql and d.matter_id = ?2 order by d.created_at desc',
        [ref.watch(currentUserIdProvider), id],
        CaseDocument.fromRow,
      ),
    );

/// A note on a case: team (every member) or private (its author only; other members' never reach the device).
/// Members may edit and delete any note they can see (RLS `notes_update`).
@immutable
class CaseNote {
  const CaseNote({
    required this.id,
    required this.body,
    required this.authorId,
    this.visibility = 'team',
    this.authorName,
    this.createdAt,
  });

  factory CaseNote.fromRow(Map<String, dynamic> r) => CaseNote(
    id: r['id'] as String,
    body: r['body'] as String? ?? '',
    authorId: r['author_id'] as String? ?? '',
    visibility: r['visibility'] as String? ?? 'team',
    authorName: r['author_name'] as String?,
    createdAt: parseInstant(r['created_at']),
  );

  final String id;

  /// Never log it.
  final String body;
  final String authorId;

  /// `team` or `private`.
  final String visibility;
  final String? authorName;
  final DateTime? createdAt;

  bool get private => visibility == 'private';
}

final StreamProviderFamily<List<CaseNote>, String> caseNotesProvider =
    StreamProvider.autoDispose.family<List<CaseNote>, String>(
      (ref, id) => _rows(
        ref,
        'select n.id, n.body, n.author_id, n.visibility, n.created_at, ms.display_name as author_name '
        'from notes n left join memberships ms on ms.org_id = n.org_id and ms.user_id = n.author_id '
        "where n.matter_id = ?1 and n.deleted_at is null and (n.visibility = 'team' or n.author_id = ?2) "
        'order by n.created_at desc',
        [id, ref.watch(currentUserIdProvider)],
        CaseNote.fromRow,
      ),
    );

/// A task on a case (open or done; proposals and dismissed ones aren't listed).
@immutable
class CaseTask {
  const CaseTask({
    required this.id,
    required this.title,
    this.dueAt,
    this.assigneeId,
    this.assigneeName,
    this.status = 'open',
  });

  factory CaseTask.fromRow(Map<String, dynamic> r) => CaseTask(
    id: r['id'] as String,
    title: r['title'] as String? ?? '',
    dueAt: parseInstant(r['due_at']),
    assigneeId: r['assignee_id'] as String?,
    assigneeName: r['assignee_name'] as String?,
    status: r['status'] as String? ?? 'open',
  );

  final String id;
  final String title;

  /// Instant; show it with [istOf].
  final DateTime? dueAt;
  final String? assigneeId;
  final String? assigneeName;

  /// `open` or `done`.
  final String status;

  bool get done => status == 'done';
}

/// Open tasks first (soonest due, undated last), then done ones.
final StreamProviderFamily<List<CaseTask>, String> caseTasksProvider =
    StreamProvider.autoDispose.family<List<CaseTask>, String>(
      (ref, id) => _rows(
        ref,
        'select t.id, t.title, t.due_at, t.assignee_id, t.status, ms.display_name as assignee_name from tasks t '
        "left join memberships ms on ms.org_id = t.org_id and ms.user_id = t.assignee_id and ms.status = 'active' "
        "where t.matter_id = ?1 and t.deleted_at is null and t.status in ('open', 'done') "
        "order by t.status = 'done', t.due_at is null, t.due_at, t.created_at",
        [id],
        CaseTask.fromRow,
      ),
    );

/// Deadline kinds (spec §9.2), in the order pickers list them.
const deadlineKinds = ['limitation', 'compliance', 'filing', 'other'];

/// A manual deadline on a case (spec §17 P1); calendar views are task 10.
@immutable
class CaseDeadline {
  const CaseDeadline({
    required this.id,
    required this.kind,
    required this.dueDate,
    this.status = 'active',
    this.title,
  });

  factory CaseDeadline.fromRow(Map<String, dynamic> r) => CaseDeadline(
    id: r['id'] as String,
    kind: r['kind'] as String? ?? 'other',
    dueDate: parseDay(r['due_date'])!,
    status: r['status'] as String? ?? 'active',
    title: r['title'] as String?,
  );

  final String id;

  /// One of [deadlineKinds].
  final String kind;

  /// IST day.
  final DateTime dueDate;

  /// `active` or `done`.
  final String status;

  /// What a deadline confirmed from an order says (`basis.title`); others show their kind.
  final String? title;

  bool get done => status == 'done';
}

/// Active deadlines first (soonest first), then done ones.
final StreamProviderFamily<List<CaseDeadline>, String> caseDeadlinesProvider =
    StreamProvider.autoDispose.family<List<CaseDeadline>, String>(
      (ref, id) => _rows(
        ref,
        r"select id, kind, due_date, status, json_extract(basis, '$.title') as title from deadlines "
        "where matter_id = ?1 and deleted_at is null and status in ('active', 'done') "
        "order by status = 'done', due_date, created_at",
        [id],
        CaseDeadline.fromRow,
      ),
    );

/// A task or deadline the AI read in one of the case's orders (spec F13), waiting for one tap: Confirm (a task
/// opens, a deadline becomes active) or Dismiss. Nothing is added until then (hard rule 2).
@immutable
class CaseProposal {
  const CaseProposal({
    required this.id,
    required this.table,
    required this.matterId,
    required this.orderId,
    required this.title,
    this.due,
    this.orderTitle,
    this.orderDate,
    this.page,
  });

  /// A [caseProposalsProvider] row: a task's due instant is an IST midnight (see `taskDueAt`).
  factory CaseProposal.fromRow(Map<String, dynamic> r) {
    final table = r['tbl'] as String;
    final due = r['due'];
    return CaseProposal(
      id: r['id'] as String,
      table: table,
      matterId: r['matter_id'] as String,
      orderId: r['order_id'] as String? ?? '',
      title: r['title'] as String? ?? '',
      due: table == 'tasks'
          ? switch (parseInstant(due)) {
              final at? => istDay(istOf(at)),
              null => null,
            }
          : parseDay(due),
      orderTitle: r['order_title'] as String?,
      orderDate: parseDay(r['order_date']),
      page: r['page'] as int?,
    );
  }

  final String id;

  /// `tasks` or `deadlines`.
  final String table;

  final String matterId;

  /// The order (`orders.id`) it was read in: its source (spec F13), named by its title or date.
  final String orderId;
  final String? orderTitle;
  final DateTime? orderDate;

  /// A deadline's first page in that order (`basis.pages`); a task has none.
  final int? page;
  final String title;

  /// IST day.
  final DateTime? due;

  bool get task => table == 'tasks';

  /// A date the AI counted from the order is marked "verify" (spec F13).
  bool get verify => due != null;
}

/// The case's proposals from orders, soonest due first (undated last). Deadlines keep their title in `basis`.
final StreamProviderFamily<List<CaseProposal>, String> caseProposalsProvider =
    StreamProvider.autoDispose.family<List<CaseProposal>, String>(
      (ref, id) =>
          _rows(
            ref,
            "select t.id, 'tasks' as tbl, t.matter_id, t.source_ref as order_id, t.title, t.due_at as due, "
            'null as page, o.title as order_title, o.order_date from tasks t left join orders o on o.id = t.source_ref '
            "where t.matter_id = ?1 and t.deleted_at is null and t.status = 'proposed' and t.source = 'order' "
            r"union all select d.id, 'deadlines', d.matter_id, d.source_order_id, json_extract(d.basis, '$.title'), "
            r"d.due_date, json_extract(d.basis, '$.pages[0]'), o.title, o.order_date from deadlines d "
            'left join orders o on o.id = d.source_order_id where d.matter_id = ?1 and d.deleted_at is null '
            "and d.status = 'proposed' and d.source_order_id is not null",
            [id],
            CaseProposal.fromRow,
          ).map(
            (ps) => ps
              ..sort(
                (a, b) => switch ((a.due, b.due)) {
                  (final x?, final y?) when x != y => x.compareTo(y),
                  (null, _?) => 1,
                  (_?, null) => -1,
                  _ => a.title.compareTo(b.title),
                },
              ),
          ),
    );

/// A client of the org (spec §4.3 Clients): the Clients list, the profile and Link client. Never log any of it.
@immutable
class ClientInfo {
  const ClientInfo({
    required this.id,
    required this.name,
    this.phone,
    this.language,
    String? searchKey,
    this.email,
    this.address,
    this.notes,
    this.whatsappOptIn = false,
    this.whatsappOptInAt,
    this.caseCount = 0,
  }) : _key = searchKey;

  /// A client row; [_clientSql]'s also carry the profile fields and `case_count`.
  factory ClientInfo.fromRow(Map<String, dynamic> r) => ClientInfo(
    id: r['id'] as String,
    name: r['name'] as String? ?? '',
    phone: r['phone'] as String?,
    language: r['language'] as String?,
    searchKey: r['search_key'] as String?,
    email: r['email'] as String?,
    address: r['address'] as String?,
    notes: r['notes'] as String?,
    whatsappOptIn: r['whatsapp_opt_in'] == 1,
    whatsappOptInAt: parseInstant(r['whatsapp_opt_in_at']),
    caseCount: r['case_count'] as int? ?? 0,
  );

  final String id;
  final String name;
  final String? phone;

  /// `hi`, `en` or null.
  final String? language;
  final String? _key;
  final String? email;
  final String? address;
  final String? notes;

  /// Agreed to case updates on WhatsApp (sent from P2), and when.
  final bool whatsappOptIn;
  final DateTime? whatsappOptInAt;

  /// Live cases linked to the client (archived ones included).
  final int caseCount;

  /// The stored `clients.search_key`, else computed from the name.
  String get searchKeys => _key ?? searchKey(name);

  static const _keep = Object();

  /// For fakes: what local writes change. Pass null to clear a field; leave it out to keep it.
  ClientInfo copyWith({
    String? name,
    Object? phone = _keep,
    Object? email = _keep,
    Object? address = _keep,
    Object? language = _keep,
    Object? notes = _keep,
    bool? whatsappOptIn,
    Object? whatsappOptInAt = _keep,
    int? caseCount,
  }) => ClientInfo(
    id: id,
    name: name ?? this.name,
    phone: phone == _keep ? this.phone : phone as String?,
    language: language == _keep ? this.language : language as String?,
    searchKey: name == null ? _key : null,
    email: email == _keep ? this.email : email as String?,
    address: address == _keep ? this.address : address as String?,
    notes: notes == _keep ? this.notes : notes as String?,
    whatsappOptIn: whatsappOptIn ?? this.whatsappOptIn,
    whatsappOptInAt: whatsappOptInAt == _keep
        ? this.whatsappOptInAt
        : whatsappOptInAt as DateTime?,
    caseCount: caseCount ?? this.caseCount,
  );
}

/// Live clients of the org (`?1`) with their profile fields and how many live cases each is linked to.
const _clientSql = '''
select cl.id, cl.name, cl.phone, cl.language, cl.search_key, cl.email, cl.address, cl.notes, cl.whatsapp_opt_in,
  cl.whatsapp_opt_in_at,
  (select count(*) from matter_clients mc join matters m on m.id = mc.matter_id and m.deleted_at is null
   where mc.client_id = cl.id) as case_count
from clients cl
where cl.org_id = ?1 and cl.deleted_at is null
''';

/// A client linked to a case: `linkId` is the `matter_clients` row (unlinking deletes it).
typedef LinkedClient = ({String linkId, ClientInfo client});

final StreamProviderFamily<List<LinkedClient>, String> caseClientsProvider =
    StreamProvider.autoDispose.family<List<LinkedClient>, String>(
      (ref, id) => _rows(
        ref,
        'select mc.id as link_id, cl.id, cl.name, cl.phone, cl.language, cl.search_key from matter_clients mc '
        'join clients cl on cl.id = mc.client_id and cl.deleted_at is null where mc.matter_id = ?1 '
        'order by mc.created_at, cl.name',
        [id],
        (r) => (linkId: r['link_id'] as String, client: ClientInfo.fromRow(r)),
      ),
    );

/// Every live client of the current org, by name (the Clients list, Link client, the client filter).
final clientsProvider = StreamProvider<List<ClientInfo>>((ref) {
  final db = ref.watch(syncDatabaseProvider);
  final org = ref.watch(currentOrgIdProvider);
  if (db == null || org == null) return Stream.value(const []);
  return db
      .watch('$_clientSql order by lower(cl.name), cl.id', parameters: [org])
      .map((rows) => rows.map(ClientInfo.fromRow).toList());
});

/// One client of the current org (the profile); null when it isn't on the device (deleted, or not this org's).
final StreamProviderFamily<ClientInfo?, String> clientProvider = StreamProvider
    .autoDispose
    .family<ClientInfo?, String>((ref, id) {
      final db = ref.watch(syncDatabaseProvider);
      final org = ref.watch(currentOrgIdProvider);
      if (db == null || org == null) return Stream.value(null);
      return db
          .watch('$_clientSql and cl.id = ?2', parameters: [org, id])
          .map((rows) => rows.isEmpty ? null : ClientInfo.fromRow(rows.first));
    });

/// A client's links to cases (`matter_clients` rows; unlinking deletes one), oldest first.
final StreamProviderFamily<List<({String linkId, String matterId})>, String>
clientLinksProvider = StreamProvider.autoDispose
    .family<List<({String linkId, String matterId})>, String>(
      (ref, id) => _rows(
        ref,
        'select id, matter_id from matter_clients where client_id = ?1 order by created_at',
        [id],
        (r) => (linkId: r['id'] as String, matterId: r['matter_id'] as String),
      ),
    );

/// A case linked to a client: `linkId` is the `matter_clients` row (unlinking deletes it).
typedef ClientCase = ({String linkId, CaseInfo c});

/// The profile's linked cases (spec §4.3): [clientLinksProvider] over [casesProvider] (live cases, archived ones
/// included), by next date.
final ProviderFamily<AsyncValue<List<ClientCase>>, String> clientCasesProvider =
    Provider.autoDispose.family<AsyncValue<List<ClientCase>>, String>((
      ref,
      id,
    ) {
      final links = ref.watch(clientLinksProvider(id));
      final cases = ref.watch(casesProvider);
      final (l, c) = (links.value, cases.value);
      if (l == null || c == null) {
        final failed = links.hasError ? links : cases;
        return failed.hasError
            ? AsyncError(failed.error!, failed.stackTrace ?? StackTrace.current)
            : const AsyncLoading();
      }
      final byId = {for (final x in c) x.id: x};
      final order = caseComparator(CaseSort.nextDate);
      return AsyncData(
        [
          for (final x in l)
            if (byId[x.matterId] case final matter?)
              (linkId: x.linkId, c: matter),
        ]..sort((a, b) => order(a.c, b.c)),
      );
    });

/// [clients] matching [query] by name (with transliteration) or phone; all of them for an empty query.
List<ClientInfo> searchClients(Iterable<ClientInfo> clients, String query) {
  final text = query.trim().toLowerCase();
  if (text.isEmpty) return clients.toList();
  final keys = searchKey(query).split(' ').where((k) => k.isNotEmpty).toList();
  final digits = text.replaceAll(RegExp(r'\D'), '');
  return [
    for (final c in clients)
      if (c.name.toLowerCase().contains(text) ||
          (keys.isNotEmpty && keys.every(c.searchKeys.contains)) ||
          (digits.length >= 3 &&
              (c.phone ?? '').replaceAll(RegExp(r'\D'), '').contains(digits)))
        c,
  ];
}

/// The case page's, the add sheets', the client profile's and the documents' local writes (spec §9.3 device write
/// paths), uploaded by sync. Each changes only the columns the server accepts from a device: matters `assigned_to`
/// and `status`; hearings inserted as `manual` (on manual-tracked cases), edited whole when manual, and only
/// `user_note` on court rows; notes, tasks, deadlines and clients inserted and updated, deleted by `deleted_at`;
/// `matter_clients` rows deleted; documents' `title`, `kind`, `matter_id` and `deleted_at`; the user's own
/// `order_reads` and `document_offline_prefs`. A refused write is dropped and the server's row comes back. Inserts
/// return the new row's id. Without a sync database or an org they do nothing (fakes override them).
class CaseWriter {
  CaseWriter(this._db, this._clock, {this.orgId, this.userId});

  final PowerSyncDatabase? _db;
  final DateTime Function() _clock;
  final String? orgId;
  final String? userId;

  String get _now => _clock().toUtc().toIso8601String();

  /// Assign to; null = no one.
  Future<void> assignCase(String matterId, String? assigneeId) => _run(
    'update matters set assigned_to = ? where id = ?',
    [assigneeId, matterId],
  );

  /// Archive, or Unarchive (its Undo).
  Future<void> setArchived(String matterId, {required bool archived}) => _run(
    'update matters set status = ? where id = ?',
    [if (archived) 'archived' else 'active', matterId],
  );

  /// A hearing on a manual case ("Add next date" adds one); [date] is an IST day.
  Future<String> addHearing(
    String matterId, {
    required DateTime date,
    String? courtNo,
    String? itemNo,
    String? purpose,
    String? outcome,
  }) => _insert('hearings', {
    'matter_id': matterId,
    'date': isoDate(date),
    'source': 'manual',
    'court_no': _text(courtNo),
    'item_no': _text(itemNo),
    'purpose': _text(purpose),
    'outcome': _text(outcome),
    'created_at': _now,
  });

  /// Edits a manual hearing whole (court rows refuse it).
  Future<void> editHearing(
    String hearingId, {
    required DateTime date,
    String? courtNo,
    String? itemNo,
    String? purpose,
    String? outcome,
  }) => _run(
    'update hearings set date = ?, court_no = ?, item_no = ?, purpose = ?, outcome = ? where id = ?',
    [
      isoDate(date),
      _text(courtNo),
      _text(itemNo),
      _text(purpose),
      _text(outcome),
      hearingId,
    ],
  );

  /// The hearing note, on any hearing; empty clears it.
  Future<void> setHearingNote(String hearingId, String? note) => _run(
    'update hearings set user_note = ? where id = ?',
    [_text(note), hearingId],
  );

  /// Deletes a manual hearing (court rows refuse it).
  Future<void> deleteHearing(String hearingId) =>
      _softDelete('hearings', hearingId);

  Future<String> addNote(
    String matterId,
    String body, {
    required bool private,
  }) => _insert('notes', {
    'matter_id': matterId,
    'author_id': userId,
    'body': body.trim(),
    'visibility': private ? 'private' : 'team',
    'created_at': _now,
  });

  Future<void> editNote(String noteId, String body, {required bool private}) =>
      _run('update notes set body = ?, visibility = ? where id = ?', [
        body.trim(),
        if (private) 'private' else 'team',
        noteId,
      ]);

  Future<void> deleteNote(String noteId) => _softDelete('notes', noteId);

  /// [dueAt] is an instant (an IST date and optional time through [istInstant]); [matterId] null = no case.
  Future<String> addTask({
    required String title,
    String? matterId,
    DateTime? dueAt,
    String? assigneeId,
  }) => _insert('tasks', {
    'matter_id': matterId,
    'title': title.trim(),
    'due_at': dueAt?.toUtc().toIso8601String(),
    'assignee_id': assigneeId,
    'status': 'open',
    'source': 'manual',
    'created_at': _now,
  });

  Future<void> editTask(
    String taskId, {
    required String title,
    DateTime? dueAt,
    String? assigneeId,
  }) => _run(
    'update tasks set title = ?, due_at = ?, assignee_id = ? where id = ?',
    [title.trim(), dueAt?.toUtc().toIso8601String(), assigneeId, taskId],
  );

  /// Done, or open again (its Undo).
  Future<void> setTaskDone(String taskId, {required bool done}) => _run(
    'update tasks set status = ? where id = ?',
    [if (done) 'done' else 'open', taskId],
  );

  Future<void> deleteTask(String taskId) => _softDelete('tasks', taskId);

  /// [kind] is one of [deadlineKinds]; [dueDate] an IST day.
  Future<String> addDeadline(
    String matterId, {
    required String kind,
    required DateTime dueDate,
  }) => _insert('deadlines', {
    'matter_id': matterId,
    'kind': kind,
    'due_date': isoDate(dueDate),
    'status': 'active',
    'created_at': _now,
  });

  Future<void> setDeadlineDone(String deadlineId, {required bool done}) => _run(
    'update deadlines set status = ? where id = ?',
    [if (done) 'done' else 'active', deadlineId],
  );

  Future<void> deleteDeadline(String deadlineId) =>
      _softDelete('deadlines', deadlineId);

  /// Confirm proposals from orders (spec F13: one tap, or Confirm all): a task opens, a deadline becomes active.
  Future<void> confirmProposals(Iterable<CaseProposal> ps) =>
      _setProposals(ps, (p) => p.task ? 'open' : 'active');

  Future<void> dismissProposal(CaseProposal p) =>
      _setProposals([p], (_) => 'dismissed');

  /// Undo of [confirmProposals] and [dismissProposal]: proposed again.
  Future<void> restoreProposals(Iterable<CaseProposal> ps) =>
      _setProposals(ps, (_) => 'proposed');

  Future<void> _setProposals(
    Iterable<CaseProposal> ps,
    String Function(CaseProposal p) status,
  ) async {
    for (final p in ps) {
      await _run('update ${p.table} set status = ? where id = ?', [
        status(p),
        p.id,
      ]);
    }
  }

  /// A new client, with `search_key` from [searchKey] so the server's search matches the app's. [language] is
  /// `hi`, `en` or null; [phone] as `normalizePhone` (clients.dart) gives it.
  Future<String> createClient({
    required String name,
    String? phone,
    String? language,
    String? email,
    String? address,
    String? notes,
  }) => _insert('clients', {
    'name': name.trim(),
    'search_key': searchKey(name),
    'phone': _text(phone),
    'language': language,
    'email': _text(email),
    'address': _text(address),
    'notes': _text(notes),
    'created_at': _now,
  });

  /// The profile's Edit, whole: empty fields clear; `search_key` follows the name.
  Future<void> updateClient(
    String clientId, {
    required String name,
    String? phone,
    String? language,
    String? email,
    String? address,
    String? notes,
  }) => _run(
    'update clients set name = ?, search_key = ?, phone = ?, language = ?, email = ?, address = ?, notes = ? '
    'where id = ?',
    [
      name.trim(),
      searchKey(name),
      _text(phone),
      language,
      _text(email),
      _text(address),
      _text(notes),
      clientId,
    ],
  );

  /// WhatsApp opt-in (spec §4.3): on records when; off clears both.
  Future<void> setClientWhatsapp(String clientId, {required bool optIn}) =>
      _run(
        'update clients set whatsapp_opt_in = ?, whatsapp_opt_in_at = ? where id = ?',
        [if (optIn) 1 else 0, if (optIn) _now else null, clientId],
      );

  /// Soft delete; its case links stay (the cases stop showing a deleted client).
  Future<void> deleteClient(String clientId) =>
      _softDelete('clients', clientId);

  /// Links a client to a case; returns the link's id (for [unlinkClient]).
  Future<String> linkClient(String matterId, String clientId) => _insert(
    'matter_clients',
    {'matter_id': matterId, 'client_id': clientId, 'created_at': _now},
  );

  Future<void> unlinkClient(String linkId) =>
      _run('delete from matter_clients where id = ?', [linkId]);

  /// The user opened the order: it stops showing "New". Once per order.
  Future<void> markOrderRead(String orderId) async {
    final (db, org, me) = (_db, orgId, userId);
    if (db == null || org == null || me == null) return;
    await db.writeTransaction((tx) async {
      final seen = await tx.getOptional(
        'select 1 from order_reads where order_id = ? and user_id = ?',
        [orderId, me],
      );
      if (seen != null) return;
      await tx.execute(
        'insert into order_reads (id, org_id, user_id, order_id, read_at) values (?, ?, ?, ?, ?)',
        [uuidV4(), org, me, orderId, _now],
      );
    });
  }

  /// The user's own "Keep offline" (spec §4.3, `document_offline_prefs`): on inserts or updates their row, off
  /// deletes it. The offline keeper then fetches or drops the file.
  Future<void> setKeepOffline(String documentId, {required bool keep}) async {
    final (db, org, me) = (_db, orgId, userId);
    if (db == null || org == null || me == null) return;
    await db.writeTransaction((tx) async {
      final row = await tx.getOptional(
        'select id, keep_offline from document_offline_prefs where document_id = ? and user_id = ?',
        [documentId, me],
      );
      if (row == null && keep) {
        await tx.execute(
          'insert into document_offline_prefs (id, org_id, user_id, document_id, keep_offline) '
          'values (?, ?, ?, ?, 1)',
          [uuidV4(), org, me, documentId],
        );
      } else if (row != null && keep && row['keep_offline'] != 1) {
        await tx.execute(
          'update document_offline_prefs set keep_offline = 1 where id = ?',
          [row['id']],
        );
      } else if (row != null && !keep) {
        await tx.execute('delete from document_offline_prefs where id = ?', [
          row['id'],
        ]);
      }
    });
  }

  /// Rename, change type or re-file a document (the columns §9.3 lets a device change); [matterId] null = no case.
  Future<void> editDocument(
    String documentId, {
    required String title,
    required String kind,
    String? matterId,
  }) => _run(
    'update documents set title = ?, kind = ?, matter_id = ? where id = ?',
    [title.trim(), kind, matterId, documentId],
  );

  Future<void> deleteDocument(String documentId) =>
      _softDelete('documents', documentId);

  static String? _text(String? s) =>
      (s ?? '').trim().isEmpty ? null : s!.trim();

  Future<void> _softDelete(String table, String id) =>
      _run('update $table set deleted_at = ? where id = ?', [_now, id]);

  /// Inserts [row] with a new id and the org; null values are left out (the server fills its defaults).
  Future<String> _insert(String table, Map<String, Object?> row) async {
    final id = uuidV4();
    final org = orgId;
    if (_db == null || org == null) return id;
    final values = {
      'id': id,
      'org_id': org,
      for (final MapEntry(:key, :value) in row.entries) key: ?value,
    };
    await _run(
      'insert into $table (${values.keys.join(', ')}) '
      'values (${List.filled(values.length, '?').join(', ')})',
      values.values.toList(),
    );
    return id;
  }

  Future<void> _run(String sql, List<Object?> parameters) async {
    await _db?.execute(sql, parameters);
  }
}

final caseWriterProvider = Provider<CaseWriter>(
  (ref) => CaseWriter(
    ref.watch(syncDatabaseProvider),
    ref.watch(clockProvider),
    orgId: ref.watch(currentOrgIdProvider),
    userId: ref.watch(currentUserIdProvider),
  ),
);
