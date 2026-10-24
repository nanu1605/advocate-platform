import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/case_label.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' hide SyncStatus;

/// A case the find-cases job matched to the advocate (spec §4.1, §11.4): the org's pending and skipped rows.
@immutable
class FoundCase {
  const FoundCase({
    required this.id,
    required this.cnr,
    required this.courtId,
    required this.caseType,
    required this.caseNumber,
    required this.caseYear,
    this.courtNo,
    this.title,
    this.nextDate,
    this.caseStatus = 'pending',
    this.confidence = 'high',
    this.matchReason,
    this.decision = 'pending',
  });

  factory FoundCase.fromRow(Map<String, dynamic> r) => FoundCase(
    id: r['id'] as String,
    cnr: r['cnr'] as String,
    courtId: r['court_id'] as String?,
    caseType: r['case_type'] as String? ?? '',
    caseNumber: r['case_number'] as String? ?? '',
    caseYear: r['case_year'] as int?,
    courtNo: r['court_no'] as String?,
    title: r['title'] as String?,
    nextDate: DateTime.tryParse(r['next_date'] as String? ?? ''),
    caseStatus: r['case_status'] as String? ?? 'pending',
    confidence: r['confidence'] as String? ?? 'high',
    matchReason: r['match_reason'] as String?,
    decision: r['decision'] as String? ?? 'pending',
  );

  final String id;
  final String cnr;

  /// Null when the provider's court isn't one we know (shown under "Other court").
  final String? courtId;

  /// WP, CRA, MCRC… (Latin script in both languages, Appendix C). Empty for a case found only on a cause list.
  final String caseType;
  final String caseNumber;
  final int? caseYear;
  final String? courtNo;

  /// "Petitioner v. Respondent". Party names: never log it.
  final String? title;
  final DateTime? nextDate;

  /// `pending`, `disposed`, `transferred` or `unknown`.
  final String caseStatus;

  /// `high` or `low` ("Check — might not be yours").
  final String confidence;
  final String? matchReason;

  /// `pending` or `skipped`.
  final String decision;

  bool get pending => caseStatus == 'pending';

  /// "WP 1234/2024", or the CNR when the provider gave no case number.
  String get caseLabel => caseLabelOf(
    caseType: caseType,
    caseNumber: caseNumber,
    caseYear: caseYear,
    cnr: cnr,
  );

  bool get lowConfidence => confidence == 'low';

  /// Ticked when found_selection has no row for it: pending and high confidence (spec §4.1 "Defaults").
  bool get tickedByDefault => pending && !lowConfidence;
}

/// The current org's found cases, by court, newest year first. Empty without an org or sync.
final foundCasesProvider = StreamProvider<List<FoundCase>>((ref) {
  final db = ref.watch(syncDatabaseProvider);
  final org = ref.watch(currentOrgIdProvider);
  if (db == null || org == null) return Stream.value(const []);
  return db
      .watch(
        'select id, cnr, court_id, case_type, case_number, case_year, court_no, title, next_date, case_status, '
        "confidence, match_reason, decision from found_cases where org_id = ? and decision in ('pending', 'skipped') "
        'order by court_id, case_year desc, case_type, case_number',
        parameters: [org],
      )
      .map((rows) => rows.map(FoundCase.fromRow).toList());
});

/// How many more cases the current org can track: the beta allowance in `app_config` minus its live
/// auto-tracked matters (the server's TRACKED_CASE_LIMIT check, spec §4.1 "Allowance"). null = no limit known.
final remainingAllowanceProvider = StreamProvider<int?>((ref) {
  final db = ref.watch(syncDatabaseProvider);
  final org = ref.watch(currentOrgIdProvider);
  if (db == null || org == null) return Stream.value(null);
  return db
      .watch(
        r"select (select cast(json_extract(value, '$') as integer) from app_config "
        "where key = 'beta_tracked_case_allowance') as cap, (select count(*) from matters where org_id = ? "
        "and tracking = 'auto' and deleted_at is null) as used",
        parameters: [org],
      )
      .map((rows) {
        final cap = rows.first['cap'] as int?;
        return cap == null ? null : max(cap - (rows.first['used'] as int), 0);
      });
});

/// Explicit ticks and unticks on the Found cases screen, by found case id, in the local-only `found_selection`
/// table so they survive the app being killed (spec §4.1, §9.4). A case with no entry uses
/// [FoundCase.tickedByDefault]. Sign-out clears the table (`disconnectAndClear`).
///
/// Without a sync database (widget tests, builds without sync) the ticks live in memory.
class FoundSelectionStore {
  FoundSelectionStore(this._db);

  final PowerSyncDatabase? _db;
  final _memory = <String, Map<String, bool>>{};
  final _changes = StreamController<void>.broadcast();

  Stream<Map<String, bool>> watch(String orgId) {
    final db = _db;
    if (db != null) {
      return db
          .watch(
            'select id, selected from found_selection where org_id = ?',
            parameters: [orgId],
          )
          .map(
            (rows) => {
              for (final r in rows) r['id'] as String: r['selected'] == 1,
            },
          );
    }
    return Stream.multi((out) {
      void emit([_]) => out.add({...?_memory[orgId]});
      emit();
      final sub = _changes.stream.listen(emit);
      out.onCancel = sub.cancel;
    });
  }

  /// Records ticks (true) and unticks (false), e.g. one row, a group or a Shift-click range.
  Future<void> set(String orgId, Map<String, bool> ticks) async {
    if (ticks.isEmpty) return;
    final db = _db;
    if (db == null) {
      (_memory[orgId] ??= {}).addAll(ticks);
      return _changes.add(null);
    }
    // Delete then insert: PowerSync tables are views, which don't take upserts.
    await db.writeTransaction((tx) async {
      await tx.execute(
        'delete from found_selection where id in (select value from json_each(?))',
        [jsonEncode(ticks.keys.toList())],
      );
      await tx.executeBatch(
        'insert into found_selection (id, org_id, selected) values (?, ?, ?)',
        [
          for (final MapEntry(:key, :value) in ticks.entries)
            [key, orgId, if (value) 1 else 0],
        ],
      );
    });
  }

  /// Forgets entries so those cases fall back to their defaults (e.g. after they were added).
  Future<void> remove(String orgId, Iterable<String> ids) async {
    final db = _db;
    if (db == null) {
      _memory[orgId]?.removeWhere((id, _) => ids.contains(id));
      return _changes.add(null);
    }
    await db.execute(
      'delete from found_selection where org_id = ? and id in (select value from json_each(?))',
      [orgId, jsonEncode(ids.toList())],
    );
  }
}

final foundSelectionStoreProvider = Provider<FoundSelectionStore>(
  (ref) => FoundSelectionStore(ref.watch(syncDatabaseProvider)),
);

/// The current org's explicit ticks (see [FoundSelectionStore]); empty without an org.
final foundSelectionProvider = StreamProvider<Map<String, bool>>((ref) {
  final org = ref.watch(currentOrgIdProvider);
  if (org == null) return Stream.value(const {});
  return ref.watch(foundSelectionStoreProvider).watch(org);
});
