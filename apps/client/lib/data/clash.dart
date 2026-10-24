/// The board's clash rule (spec §4.2, ADR 0012), ported from `advocate_workers.board` with the same rule and
/// constants so the app can re-apply it at once, offline, after Assign to or Mark proxy arranged. Both are tested
/// against config/fixtures/board_clash.yaml; change them together.
library;

/// A hearing plus the walk or drive between complexes. DRAFT – VERIFY (docs/legal-verification.md).
const clashWindowMinutes = 60;

/// One board row: `key` is the matter id, `courtId` the court complex, `slot` the expected start in minutes
/// after midnight (an estimate from the item number), `assignee` null = unassigned.
typedef ClashEntry = ({
  String key,
  String? courtId,
  int? slot,
  String? assignee,
  bool proxy,
});

/// Two entries clash when they are in different complexes, their windows overlap, the same person appears
/// (unassigned = [advocate], the organisation's owner) and neither has a proxy arranged.
bool clashes(ClashEntry a, ClashEntry b, [String? advocate]) {
  final (sa, sb, ca, cb) = (a.slot, b.slot, a.courtId, b.courtId);
  return sa != null &&
      sb != null &&
      ca != null &&
      cb != null &&
      ca != cb &&
      (a.assignee ?? advocate) == (b.assignee ?? advocate) &&
      !(a.proxy || b.proxy) &&
      (sa - sb).abs() < clashWindowMinutes;
}

/// Entries that clash, directly or through each other, numbered 1..n by their earliest slot; entries without a
/// clash are left out.
/// ponytail: compares every pair, fine for a day's board (tens of rows).
Map<String, int> clashGroups(List<ClashEntry> entries, [String? advocate]) {
  final links = {
    for (final (i, e) in entries.indexed)
      e.key: [
        for (final (j, o) in entries.indexed)
          if (i != j && clashes(e, o, advocate)) o.key,
      ],
  };
  final groups = <String, int>{};
  // Python's `sorted(key=(slot or time.max, key))`.
  final bySlot = [...entries]
    ..sort((a, b) {
      final d = (a.slot ?? 1 << 30).compareTo(b.slot ?? 1 << 30);
      return d != 0 ? d : a.key.compareTo(b.key);
    });
  for (final e in bySlot) {
    if (groups.containsKey(e.key) || links[e.key]!.isEmpty) continue;
    final n = groups.values.toSet().length + 1;
    final todo = [e.key];
    while (todo.isNotEmpty) {
      final key = todo.removeLast();
      if (groups.containsKey(key)) continue;
      groups[key] = n;
      todo.addAll(links[key]!);
    }
  }
  return groups;
}
