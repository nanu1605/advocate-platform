import 'dart:math';

import 'package:advocate_app/core/search_key.dart';
import 'package:advocate_app/data/courts.dart';
import 'package:advocate_app/data/found_cases.dart';
import 'package:flutter/foundation.dart';

/// Search and filters on the Found cases screen (spec §4.1 "Search and filters"). A null filter is "any".
@immutable
class FoundFilter {
  const FoundFilter({
    this.query = '',
    this.courtId,
    this.year,
    this.status,
    this.confidence,
  });

  /// Party or case number, matched by search key so Hindi and English spellings find each other.
  final String query;
  final String? courtId;
  final int? year;

  /// `pending` or `disposed`.
  final String? status;

  /// `high` or `low`.
  final String? confidence;

  /// Filters switched on (not counting the search), for the Filters button.
  int get count => [courtId, year, status, confidence].nonNulls.length;

  FoundFilter withQuery(String q) => FoundFilter(
    query: q,
    courtId: courtId,
    year: year,
    status: status,
    confidence: confidence,
  );

  static final _keys = Expando<String>();

  /// The cases that pass, in their order.
  List<FoundCase> apply(List<FoundCase> cases) {
    final words = searchKey(query).split(' ').where((w) => w.isNotEmpty);
    return [
      for (final c in cases)
        if ((courtId == null || c.courtId == courtId) &&
            (year == null || c.caseYear == year) &&
            // "disposed" is everything folded under Disposed: disposed, transferred, unknown.
            (status == null || (status == 'pending') == c.pending) &&
            (confidence == null || c.confidence == confidence) &&
            words.every(
              (_keys[c] ??= searchKey(
                '${c.caseType} ${c.caseNumber} ${c.caseYear ?? ''} ${c.title ?? ''} ${c.cnr}',
              )).contains,
            ))
          c,
    ];
  }
}

/// Group key for disposed cases, which are folded together (spec §4.1 "Defaults").
const disposedGroup = 'disposed';

/// A group of rows: pending cases by court (`court` null when the court hasn't synced yet), then disposed ones.
typedef FoundGroup = ({String key, Court? court, List<FoundCase> cases});

/// Pending cases by court in [courts] order (High Courts first), then one "Disposed" group (spec §4.1 "Grouping").
List<FoundGroup> groupFound(List<FoundCase> cases, List<Court> courts) {
  final byCourt = <String, List<FoundCase>>{};
  final disposed = <FoundCase>[];
  for (final c in cases) {
    if (c.pending) {
      (byCourt[c.courtId ?? ''] ??= []).add(c);
    } else {
      disposed.add(c);
    }
  }
  final rank = {for (final (i, c) in courts.indexed) c.id: i};
  int order(String id) => rank[id] ?? courts.length;
  final keys = byCourt.keys.toList()
    ..sort((a, b) {
      final r = order(a).compareTo(order(b));
      return r != 0 ? r : a.compareTo(b);
    });
  final byId = {for (final c in courts) c.id: c};
  return [
    for (final k in keys) (key: k, court: byId[k], cases: byCourt[k]!),
    if (disposed.isNotEmpty) (key: disposedGroup, court: null, cases: disposed),
  ];
}

/// Above this many results, groups show [foundPageSize] rows at a time (spec §4.1 edge cases).
const foundPaginateOver = 300;
const foundPageSize = 100;

/// How many of a group's [groupSize] rows to show after [pages] pages, when the screen has [total] results.
int shownInGroup({
  required int total,
  required int groupSize,
  required int pages,
}) => total > foundPaginateOver
    ? min(groupSize, pages * foundPageSize)
    : groupSize;

/// The ticks on the Found cases screen: [ticks] are the explicit ones from `found_selection`; any other case uses
/// its default, ticked when pending and high confidence (spec §4.1 "Defaults"). Methods return the ticks to write.
@immutable
class FoundSelection {
  FoundSelection(this.cases, this.ticks);

  final List<FoundCase> cases;
  final Map<String, bool> ticks;

  bool ticked(FoundCase c) => ticks[c.id] ?? c.tickedByDefault;

  late final List<FoundCase> selected = cases.where(ticked).toList();

  /// Every pending match: the "Add all" set. Disposed cases are never in it.
  late final List<FoundCase> pending = cases.where((c) => c.pending).toList();

  late final int lowPending = pending.where((c) => c.lowConfidence).length;

  /// The selection is exactly every pending match: the button reads "Add all 33 cases" (spec §4.1).
  bool get isAllPending =>
      pending.isNotEmpty &&
      selected.length == pending.length &&
      selected.every((c) => c.pending);

  /// "Select all" (every pending match, the same set as "Add all") or "None".
  Map<String, bool> selectAll({required bool on}) => {
    for (final c in cases) c.id: on && c.pending,
  };

  /// Shift-click: every row from [anchorId] to [to] in [visible] order takes [to]'s new state.
  Map<String, bool> range(
    List<FoundCase> visible,
    String? anchorId,
    FoundCase to,
  ) {
    final value = !ticked(to);
    final a = visible.indexWhere((c) => c.id == anchorId);
    final b = visible.indexOf(to);
    if (a < 0 || b < 0) return {to.id: value};
    return {
      for (final c in visible.sublist(min(a, b), max(a, b) + 1)) c.id: value,
    };
  }

  /// More is selected than the plan can still track ([remaining] null: no limit known).
  bool overAllowance(int? remaining) =>
      remaining != null && selected.length > remaining;

  /// What the bottom bar's "Add" sends: always the ticked ids, even when they are every pending match, so the
  /// server tracks exactly the rows on screen (spec §4.1 AC). Only the header's "Add all" may send `{all: true}`.
  late final List<String> selectedIds = [for (final c in selected) c.id];
}
