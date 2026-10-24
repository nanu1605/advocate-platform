import 'package:advocate_app/data/sync/sync.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Entry points for later-phase features stay hidden until their phase (spec §5.2).
/// Values come from the synced `feature_flags` table (key `scan_to_case` → [FeatureFlag.scanToCase]); all off
/// until the first sync, and in builds without sync.
enum FeatureFlag {
  ask,
  voice,
  scanToCase,
  briefMe,
  drafting,
  research,
  strategy,
}

final featureFlagsProvider = StreamProvider<Set<FeatureFlag>>((ref) {
  final db = ref.watch(syncDatabaseProvider);
  if (db == null) return Stream.value(const {});
  final byKey = {
    for (final f in FeatureFlag.values)
      f.name.replaceAllMapped(
        RegExp('[A-Z]'),
        (m) => '_${m[0]!.toLowerCase()}',
      ): f,
  };
  return db
      .watch("select key from feature_flags where value = 'true'")
      .map((rows) => {...rows.map((r) => byKey[r['key']]).nonNulls});
});

extension FeatureFlagsX on AsyncValue<Set<FeatureFlag>> {
  bool on(FeatureFlag f) => value?.contains(f) ?? false;
}
