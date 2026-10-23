import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Entry points for later-phase features stay hidden until their phase (spec §5.2).
/// Values come from the synced `feature_flags` table once PowerSync lands; until then all are off.
enum FeatureFlag {
  ask,
  voice,
  scanToCase,
  briefMe,
  drafting,
  research,
  strategy,
}

final featureFlagsProvider = Provider<Set<FeatureFlag>>((_) => const {});

extension FeatureFlagsX on Set<FeatureFlag> {
  bool on(FeatureFlag f) => contains(f);
}
