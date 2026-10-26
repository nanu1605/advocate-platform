import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/core/theme/app_theme.dart';
import 'package:advocate_app/core/theme/tokens.g.dart';
import 'package:flutter/material.dart';

/// The 2 dp keyboard focus ring (spec §5.9) for a row the theme can't reach: shown while the first focusable inside
/// [child] (its InkWell or ListTile) holds keyboard focus ([focusVisible]: not after a touch or a click), and not
/// while focus is on a button inside it. Drawn 2 dp inside the row's edge, so a list's clip never cuts it.
/// Material's own destinations get theirs from [DestinationFocusRing].
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

/// The 2 dp keyboard focus ring for Material's own destinations (rail, bar, tabs, popup menu items, segments), which
/// build their focusable inside and offer no focus border: one ring for the whole app, drawn over [child] 2 dp inside
/// the focused destination's box while [focusVisible]. Wraps the app's navigator, so it reaches menus too.
class DestinationFocusRing extends StatefulWidget {
  const DestinationFocusRing({required this.child, super.key});

  final Widget child;

  @override
  State<DestinationFocusRing> createState() => _DestinationFocusRingState();
}

class _DestinationFocusRingState extends State<DestinationFocusRing> {
  Rect? _rect;
  var _afterFrame = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance
      ..addListener(_update)
      ..addHighlightModeListener(_modeChanged);
    pointerSinceKey.addListener(_update);
    watchPointer();
  }

  @override
  void dispose() {
    FocusManager.instance
      ..removeListener(_update)
      ..removeHighlightModeListener(_modeChanged);
    pointerSinceKey.removeListener(_update);
    unwatchPointer();
    super.dispose();
  }

  void _modeChanged(FocusHighlightMode _) => _update();

  static bool _isDestination(BuildContext context) {
    var found = false;
    context.visitAncestorElements((e) {
      final w = e.widget;
      found =
          w is NavigationRail ||
          w is NavigationBar ||
          w is TabBar ||
          w is PopupMenuItem ||
          w is SegmentedButton;
      return !found;
    });
    return found;
  }

  void _update() {
    if (!mounted) return;
    final node = FocusManager.instance.primaryFocus;
    final at = node?.context;
    final box = context.findRenderObject() as RenderBox?;
    Rect? rect;
    if (focusVisible &&
        at != null &&
        at.mounted &&
        box != null &&
        box.hasSize &&
        _isDestination(at)) {
      rect = node!.rect.shift(-box.localToGlobal(Offset.zero));
    }
    if (rect != _rect) setState(() => _rect = rect);
    // A menu opening or a tab bar scrolling moves the destination: follow it, frame by frame, while shown.
    if (rect != null && !_afterFrame) {
      _afterFrame = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _afterFrame = false;
        _update();
      });
    }
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.passthrough,
    children: [
      widget.child,
      if (_rect case final rect?)
        Positioned.fromRect(
          rect: rect,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.fromBorderSide(
                  focusRingSide(context.colors, inset: true),
                ),
                borderRadius: BorderRadius.circular(Radii.input),
              ),
            ),
          ),
        ),
    ],
  );
}
