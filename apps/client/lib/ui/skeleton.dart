import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/core/theme/motion.dart';
import 'package:flutter/material.dart';

/// Loading placeholder shaped like the content. Shimmer loops every 1.2 s; static under reduce motion.
class Skeleton extends StatefulWidget {
  const Skeleton({this.width, this.height = 16, this.radius = 8, super.key});

  final double? width;
  final double height;
  final double radius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.of(context).shimmer) {
      _controller.repeat();
    } else {
      _controller
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final base = c.isSunlight ? c.line.withValues(alpha: 0.12) : c.surfaceAlt;
    final highlight = c.isSunlight ? c.line.withValues(alpha: 0.04) : c.line;
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (_, _) => Container(
            width: widget.width,
            height: widget.height,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.radius),
              gradient: LinearGradient(
                begin: Alignment(-1 + 3 * _controller.value - 1, 0),
                end: Alignment(1 + 3 * _controller.value - 1, 0),
                colors: [base, highlight, base],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Skeleton shaped like a list of case cards.
class SkeletonCaseList extends StatelessWidget {
  const SkeletonCaseList({this.count = 3, super.key});

  final int count;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (var i = 0; i < count; i++)
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Skeleton(width: 140, height: 20),
                  SizedBox(height: 8),
                  Skeleton(),
                  SizedBox(height: 8),
                  Skeleton(width: 200, height: 14),
                ],
              ),
            ),
          ),
        ),
    ],
  );
}
