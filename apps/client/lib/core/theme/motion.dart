import 'package:advocate_app/core/theme/tokens.g.dart';
import 'package:flutter/widgets.dart';

/// Motion tokens adjusted for "reduce motion" (spec §5.5): every transition becomes a 100 ms cross-fade,
/// no shimmer, no stagger. The app root folds the in-app toggle into `MediaQuery.disableAnimations`,
/// so this reads one place for both the OS setting and the toggle.
@immutable
class Motion {
  const Motion({required this.reduced});

  factory Motion.of(BuildContext context) =>
      Motion(reduced: MediaQuery.disableAnimationsOf(context));

  final bool reduced;

  Duration get fast => reduced ? MotionTokens.instant : MotionTokens.fast;
  Duration get base => reduced ? MotionTokens.instant : MotionTokens.base;
  Duration get slow => reduced ? MotionTokens.instant : MotionTokens.slow;
  Duration get stagger => reduced ? Duration.zero : MotionTokens.stagger;
  Curve get standard => reduced ? Curves.linear : MotionTokens.standard;
  Curve get enter => reduced ? Curves.linear : MotionTokens.enter;
  Curve get exit => reduced ? Curves.linear : MotionTokens.exit;
  bool get shimmer => !reduced;
}
