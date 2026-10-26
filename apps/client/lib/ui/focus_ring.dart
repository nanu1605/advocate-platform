import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/core/theme/app_theme.dart';
import 'package:advocate_app/core/theme/tokens.g.dart';
import 'package:flutter/material.dart';

/// The 2 dp keyboard focus ring (spec §5.9) for a row the theme can't reach: shown while the first focusable inside
/// [child] (its InkWell or ListTile) holds keyboard focus ([focusVisible]: not after a touch or a click), and not
/// while focus is on a button inside it. Drawn 2 dp inside the row's edge, so a list's clip never cuts it.
// ponytail: Material's own destinations (NavigationRail, NavigationBar, TabBar tabs, popup menu items) still show only
// their focus tint; a ring for them is a Phase 1 gate exception, for Track B with a focus-aware indicator.
class FocusRing extends StatefulWidget {
  const FocusRing({
    required this.child,
    this.radius = Radii.input,
    this.selected = false,
    super.key,
  });

  final Widget child;

  /// The row's corner radius, e.g. [Radii.card] round a card.
  final double radius;

  /// The row is its list's selection (the case open beside the list). When it becomes so while another row has
  /// focus, focus moves to it, so the keyboard goes on from the row just opened rather than the one left.
  final bool selected;

  @override
  State<FocusRing> createState() => _FocusRingState();
}

class _FocusRingState extends State<FocusRing> {
  /// Every ring's node, to tell when focus is on a row.
  static final _rows = <FocusNode>{};

  /// Never focused itself: the parent of the row's own focus node, which is how the ring knows it.
  final _node = FocusNode(
    debugLabel: 'FocusRing',
    canRequestFocus: false,
    skipTraversal: true,
  );
  var _shown = false;

  @override
  void initState() {
    super.initState();
    _rows.add(_node);
    FocusManager.instance
      ..addListener(_update)
      ..addHighlightModeListener(_modeChanged);
    pointerSinceKey.addListener(_update);
    watchPointer();
  }

  @override
  void didUpdateWidget(FocusRing old) {
    super.didUpdateWidget(old);
    if (widget.selected &&
        !old.selected &&
        _rows.contains(FocusManager.instance.primaryFocus?.parent)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _node.children.firstOrNull?.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _rows.remove(_node);
    FocusManager.instance
      ..removeListener(_update)
      ..removeHighlightModeListener(_modeChanged);
    pointerSinceKey.removeListener(_update);
    unwatchPointer();
    _node.dispose();
    super.dispose();
  }

  void _modeChanged(FocusHighlightMode _) => _update();

  // ponytail: every ring checks on each focus change; a list of hundreds is still nothing, a shared listener if not.
  void _update() {
    final shown =
        focusVisible && FocusManager.instance.primaryFocus?.parent == _node;
    if (shown != _shown && mounted) setState(() => _shown = shown);
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _node,
    includeSemantics: false,
    // Always the same box (a plain one when hidden), so the row below keeps its state and focus.
    child: DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: _shown
          ? BoxDecoration(
              border: Border.fromBorderSide(
                focusRingSide(context.colors, inset: true),
              ),
              borderRadius: BorderRadius.circular(widget.radius),
            )
          : const BoxDecoration(),
      child: widget.child,
    ),
  );
}
