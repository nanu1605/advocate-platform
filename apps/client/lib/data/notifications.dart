import 'dart:convert';

import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/device.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' hide SyncStatus;

/// The kinds the P1 workers write (spec §13.1), plus `deadline_due`, in the order preferences list them.
const notificationKinds = [
  'tomorrow_board',
  'today_morning',
  'listed_unexpectedly',
  'new_order',
  'next_date_set',
  'status_changed',
  'deadline_due',
  'sync_issue',
];

/// [kind]'s name in preferences and filters.
String notificationKindLabel(AppLocalizations l, String kind) => switch (kind) {
  'tomorrow_board' => l.notifDataKindTomorrowBoard,
  'today_morning' => l.notifDataKindTodayMorning,
  'listed_unexpectedly' => l.notifDataKindListedEarly,
  'new_order' => l.notifDataKindNewOrder,
  'next_date_set' => l.notifDataKindNextDate,
  'status_changed' => l.notifDataKindStatus,
  'deadline_due' => l.notifDataKindDeadline,
  'sync_issue' => l.notifDataKindSyncIssue,
  _ => l.notifDataKindOther,
};

/// [link] when it is one of the routes notifications open (`data.link`: /today, /board/tomorrow, /cases/{id},
/// /found), else null: anything else is only marked read.
String? appLink(Object? link) =>
    link is String &&
        RegExp(r'^/(today|board/tomorrow|found|cases/[\w-]+)$').hasMatch(link)
    ? link
    : null;

/// One of the user's notifications (spec §13): the row's title and body as the server wrote them (localised, with
/// case titles only when the user allowed them). Never log [title] or [body].
@immutable
class AppNotification {
  const AppNotification({
    required this.id,
    required this.kind,
    this.title,
    this.body,
    this.data = const {},
    this.readAt,
    this.createdAt,
    this.earlier = const [],
  });

  factory AppNotification.fromRow(Map<String, dynamic> r) {
    final data = r['data'];
    return AppNotification(
      id: r['id'] as String,
      kind: r['kind'] as String,
      title: r['title'] as String?,
      body: r['body'] as String?,
      data: data is String ? (jsonDecode(data) as Map).cast() : const {},
      readAt: parseInstant(r['read_at']),
      createdAt: parseInstant(r['created_at']),
    );
  }

  final String id;
  final String kind;
  final String? title;
  final String? body;

  /// `link`, `collapse_key`, `matter_id`, and the event's facts.
  final Map<String, dynamic> data;
  final DateTime? readAt;
  final DateTime? createdAt;

  /// Older notifications with the same [collapseKey], newest first, folded under this one ("+2 earlier") by
  /// [collapseNotifications]; empty on a raw row.
  final List<AppNotification> earlier;

  /// Rows sharing it show only the newest; the OS notification's tag, so an update replaces instead of stacking.
  String get collapseKey => data['collapse_key'] as String? ?? id;

  /// The validated route to open ([appLink]); null = just mark it read.
  String? get link => appLink(data['link']);

  /// Unread, or with an unread notification folded under it.
  bool get unread => readAt == null || earlier.any((e) => e.unread);

  /// This and the folded ids, for marking the whole group read.
  List<String> get ids => [id, for (final e in earlier) ...e.ids];

  AppNotification _withEarlier(List<AppNotification> earlier) =>
      AppNotification(
        id: id,
        kind: kind,
        title: title,
        body: body,
        data: data,
        readAt: readAt,
        createdAt: createdAt,
        earlier: earlier,
      );
}

/// [rows] (newest first) with rows sharing a collapse key folded under the newest of them (spec §13.2), in order.
List<AppNotification> collapseNotifications(List<AppNotification> rows) {
  final byKey = <String, List<AppNotification>>{};
  for (final r in rows) {
    (byKey[r.collapseKey] ??= []).add(r);
  }
  return [for (final g in byKey.values) g.first._withEarlier(g.sublist(1))];
}

/// The notification centre's groups.
enum NotificationDay { today, yesterday, earlier }

/// [items] (newest first) by the IST day they arrived, relative to [todayIst]; empty groups left out.
List<({NotificationDay day, List<AppNotification> items})> notificationSections(
  List<AppNotification> items,
  DateTime todayIst,
) {
  final byDay = <NotificationDay, List<AppNotification>>{};
  for (final n in items) {
    final at = n.createdAt;
    final day = at == null ? null : istDay(istOf(at));
    final group = day == todayIst
        ? NotificationDay.today
        : day == todayIst.subtract(const Duration(days: 1))
        ? NotificationDay.yesterday
        : NotificationDay.earlier;
    (byDay[group] ??= []).add(n);
  }
  return [
    for (final d in NotificationDay.values)
      if (byDay[d] case final list?) (day: d, items: list),
  ];
}

/// The user's notifications in the current org (and org-less ones), newest first, one per row. Empty without an
/// org or sync. The synced rows are the last 90 days (`in_window`).
/// ponytail: every synced row in one query (90 days, tens a day at most); page it if a chamber's count grows.
final notificationRowsProvider = StreamProvider<List<AppNotification>>((ref) {
  final db = ref.watch(syncDatabaseProvider);
  final org = ref.watch(currentOrgIdProvider);
  final me = ref.watch(currentUserIdProvider);
  if (db == null || org == null || me == null) return Stream.value(const []);
  return db
      .watch(
        'select id, kind, title, body, data, read_at, created_at from notifications '
        'where user_id = ? and (org_id = ? or org_id is null) order by created_at desc, id desc',
        parameters: [me, org],
      )
      .map((rows) => rows.map(AppNotification.fromRow).toList());
});

/// The notification centre (spec §13): [notificationRowsProvider] with collapse keys folded
/// ([collapseNotifications]). Group with [notificationSections].
final notificationCentreProvider = Provider<AsyncValue<List<AppNotification>>>(
  (ref) => ref.watch(notificationRowsProvider).whenData(collapseNotifications),
);

/// The bell's badge: centre items that are unread (a folded group counts once).
final unreadNotificationCountProvider = Provider<int>(
  (ref) =>
      ref
          .watch(notificationCentreProvider)
          .value
          ?.where((n) => n.unread)
          .length ??
      0,
);

/// Quiet hours default (spec §13.2): 22:00–07:00 IST.
const defaultQuietStart = Duration(hours: 22);
const defaultQuietEnd = Duration(hours: 7);

/// The user's notification preferences (spec §13.2), from their `notification_prefs` rows (one per kind, created
/// on demand). A kind without a row is on, with the defaults. Quiet hours and "Include case titles" are written to
/// every row together, so the newest row speaks for all.
@immutable
class NotificationPrefs {
  const NotificationPrefs({
    this.off = const {},
    this.includeTitles = false,
    this.quietStart = defaultQuietStart,
    this.quietEnd = defaultQuietEnd,
  });

  /// [rows] newest `updated_at` first.
  factory NotificationPrefs.fromRows(List<Map<String, dynamic>> rows) {
    final latest = rows.firstOrNull;
    return NotificationPrefs(
      off: {
        for (final r in rows)
          if ((jsonDecode(
            r['channels'] as String? ?? '["push"]',
          ) as List).isEmpty)
            r['kind'] as String,
      },
      includeTitles: latest?['include_titles'] == 1,
      quietStart: _time(latest?['quiet_start']) ?? defaultQuietStart,
      quietEnd: _time(latest?['quiet_end']) ?? defaultQuietEnd,
    );
  }

  /// Kinds turned off (their row's channels are `{}`).
  final Set<String> off;

  /// Case titles (party names) in notifications; push and WhatsApp pass through Google, Apple and Meta.
  final bool includeTitles;

  /// Times of day (IST) after midnight; the window may cross midnight. Equal = no quiet hours.
  final Duration quietStart;
  final Duration quietEnd;

  bool enabled(String kind) => !off.contains(kind);
}

/// A Postgres time ("22:00:00") as time after midnight.
Duration? _time(Object? v) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch('${v ?? ''}');
  return m == null
      ? null
      : Duration(hours: int.parse(m[1]!), minutes: int.parse(m[2]!));
}

/// Time after midnight as a Postgres time.
String _pgTime(Duration d) =>
    '${d.inHours.toString().padLeft(2, '0')}:'
    '${(d.inMinutes % 60).toString().padLeft(2, '0')}:00';

/// The user's preferences; the defaults without sync.
final notificationPrefsProvider = StreamProvider<NotificationPrefs>((ref) {
  final db = ref.watch(syncDatabaseProvider);
  final me = ref.watch(currentUserIdProvider);
  if (db == null || me == null) return Stream.value(const NotificationPrefs());
  return db
      .watch(_prefsSql, parameters: [me])
      .map((rows) => NotificationPrefs.fromRows(rows.toList()));
});

const _prefsSql =
    'select id, kind, channels, quiet_start, quiet_end, include_titles from notification_prefs '
    'where user_id = ? order by updated_at desc, id';

/// Namespace of [prefsRowId]'s v5 ids.
const _prefsNamespace = '24cc73e1-d649-4f6f-bab6-8c3662d30cb6';

/// The id of [userId]'s row for [kind]: the same on every device, so two devices never create two rows for one
/// kind (unique `(user_id, kind)`); the server can derive it as `uuid5(namespace, "<user>:<kind>")`.
String prefsRowId(String userId, String kind) =>
    uuidV5(_prefsNamespace, '$userId:$kind');

/// Whether [nowIst]'s time of day falls in quiet hours from [start] to [end] (IST, end excluded); a window across
/// midnight (22:00–07:00) wraps. Equal times mean none.
bool inQuietHours(DateTime nowIst, Duration start, Duration end) {
  final t = Duration(hours: nowIst.hour, minutes: nowIst.minute);
  if (start == end) return false;
  return start < end ? t >= start && t < end : t >= start || t < end;
}

/// The kinds that may break quiet hours (spec §13.2): listed earlier than expected, and a deadline due today (IST;
/// the row's `data.due_date`).
bool isUrgent(AppNotification n, DateTime todayIst) =>
    n.kind == 'listed_unexpectedly' ||
    (n.kind == 'deadline_due' && parseDay(n.data['due_date']) == todayIst);

/// Whether [n] may alert at [nowIst]: its kind is on, and it is not quiet hours, or it is urgent and the user lets
/// urgent alerts break quiet hours ([urgentBreaksQuiet], a device setting: the schema has no column for it).
bool mayAlert(
  AppNotification n, {
  required NotificationPrefs prefs,
  required bool urgentBreaksQuiet,
  required DateTime nowIst,
}) =>
    prefs.enabled(n.kind) &&
    (!inQuietHours(nowIst, prefs.quietStart, prefs.quietEnd) ||
        (urgentBreaksQuiet && isUrgent(n, istDay(nowIst))));

/// Notification writes (spec §9.3): `read_at` on the user's own notifications (the one column a device may
/// change) and the user's own `notification_prefs` rows. Local, uploaded when online. Without a sync database or
/// a signed-in user they do nothing.
class NotificationWriter {
  NotificationWriter(this._db, this._clock, {this.userId, this.orgId});

  final PowerSyncDatabase? _db;
  final DateTime Function() _clock;
  final String? userId;
  final String? orgId;

  String get _now => _clock().toUtc().toIso8601String();

  /// Marks [ids] read (a collapsed group's [AppNotification.ids]).
  Future<void> markRead(Iterable<String> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    await _db?.execute(
      'update notifications set read_at = ? where read_at is null '
      'and id in (${List.filled(list.length, '?').join(', ')})',
      [_now, ...list],
    );
  }

  /// Marks every unread notification of the current org (and org-less ones) read.
  Future<void> markAllRead() async {
    if (userId == null) return;
    await _db?.execute(
      'update notifications set read_at = ? where read_at is null and user_id = ? '
      'and (org_id = ? or org_id is null)',
      [_now, userId, orgId],
    );
  }

  /// A kind on (`{push}`) or off (`{}`, so the workers skip it for the user).
  Future<void> setKindEnabled(String kind, {required bool enabled}) => _write(
    [kind],
    {
      'channels': jsonEncode([if (enabled) 'push']),
    },
  );

  /// "Include case titles", on every kind's row.
  Future<void> setIncludeTitles({required bool include}) =>
      _write(null, {'include_titles': include ? 1 : 0});

  /// Quiet hours (IST), on every kind's row.
  Future<void> setQuietHours(Duration start, Duration end) =>
      _write(null, {'quiet_start': _pgTime(start), 'quiet_end': _pgTime(end)});

  /// Sets [fields] on the rows of [kinds] (null: every kind in [notificationKinds] and any other with a row),
  /// creating a missing row with [prefsRowId] and the current preferences.
  Future<void> _write(List<String>? kinds, Map<String, Object?> fields) async {
    final db = _db;
    final me = userId;
    if (db == null || me == null) return;
    await db.writeTransaction((tx) async {
      final rows = await tx.getAll(_prefsSql, [me]);
      final p = NotificationPrefs.fromRows(rows.toList());
      final set = {...fields, 'updated_at': _now};
      for (final kind
          in kinds ??
              {...notificationKinds, ...rows.map((r) => r['kind'] as String)}) {
        final existing = [
          for (final r in rows)
            if (r['kind'] == kind) r['id'] as String,
        ];
        if (existing.isEmpty) {
          final row = {
            'id': prefsRowId(me, kind),
            'user_id': me,
            'kind': kind,
            'channels': jsonEncode([if (p.enabled(kind)) 'push']),
            'quiet_start': _pgTime(p.quietStart),
            'quiet_end': _pgTime(p.quietEnd),
            'include_titles': p.includeTitles ? 1 : 0,
            ...set,
          };
          await tx.execute(
            'insert into notification_prefs (${row.keys.join(', ')}) '
            'values (${List.filled(row.length, '?').join(', ')})',
            row.values.toList(),
          );
        }
        for (final id in existing) {
          await tx.execute(
            'update notification_prefs set ${set.keys.map((k) => '$k = ?').join(', ')} where id = ?',
            [...set.values, id],
          );
        }
      }
    });
  }
}

final notificationWriterProvider = Provider<NotificationWriter>(
  (ref) => NotificationWriter(
    ref.watch(syncDatabaseProvider),
    ref.watch(clockProvider),
    userId: ref.watch(currentUserIdProvider),
    orgId: ref.watch(currentOrgIdProvider),
  ),
);
