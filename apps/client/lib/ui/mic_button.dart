import 'dart:math' as math;

import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/core/theme/motion.dart';
import 'package:advocate_app/ui/focus_ring.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:flutter/material.dart';

enum MicState { idle, recording, processing, error }

/// The voice button (spec §5.2, §5.11 #9): tap for quick add, press and hold to record at once. Recording shows the
/// live waveform and the time; processing a "reading" pulse (still with reduce motion); an error asks to try again.
/// Holding has no screen-reader gesture: quick add (the tap) offers a voice note too.
class MicButton extends StatefulWidget {
  const MicButton({
    required this.state,
    this.levels = const [],
    this.elapsed = Duration.zero,
    this.onTap,
    this.onHoldStart,
    this.onHoldEnd,
    super.key,
  });

  final MicState state;

  /// Recent input levels from 0 to 1, oldest first: the waveform while recording.
  final List<double> levels;
  final Duration elapsed;

  /// Quick add when idle; in other states the caller decides (stop, try again).
  final VoidCallback? onTap;
  final VoidCallback? onHoldStart;

  /// Letting go after a hold: stop recording.
  final VoidCallback? onHoldEnd;

  @override
  State<MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<MicButton>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  late final Animation<double> _opacity = Tween<double>(
    begin: 1,
    end: 0.4,
  ).animate(_pulse);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(MicButton old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final run =
        widget.state == MicState.processing && !Motion.of(context).reduced;
    if (run && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!run) {
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l = context.l10n;
    final urgent = c.of(StatusKind.urgent);
    final e = widget.elapsed;
    final time =
        '${e.inMinutes}:${(e.inSeconds % 60).toString().padLeft(2, '0')}';
    // Recording is red; an error is the urgent tint with a red edge.
    final (fill, fg, label) = switch (widget.state) {
      MicState.idle => (c.primaryFill, c.onPrimary, l.micIdle),
      MicState.recording => (urgent.fg, urgent.bg, l.micRecording(time)),
      MicState.processing => (c.primaryFill, c.onPrimary, l.micProcessing),
      MicState.error => (urgent.bg, urgent.fg, l.micError),
    };
    final shape = StadiumBorder(
      side: widget.state == MicState.error
          ? BorderSide(color: urgent.fg, width: 2)
          : BorderSide.none,
    );
    final content = switch (widget.state) {
      MicState.idle => Icon(AppIcons.microphone, size: 28, color: fg),
      MicState.recording => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(AppIcons.microphone, size: 24, color: fg),
          const SizedBox(width: 8),
          CustomPaint(
            size: const Size(46, 24),
            painter: _Waveform(widget.levels, fg),
          ),
          const SizedBox(width: 8),
          Text(
            time,
            style: context.text.titleSmall?.copyWith(
              color: fg,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
      MicState.processing => FadeTransition(
        opacity: _opacity,
        child: Icon(AppIcons.waveform, size: 28, color: fg),
      ),
      MicState.error => Icon(AppIcons.warning, size: 28, color: fg),
    };
    return Semantics(
      button: true,
      label: label,
      onTap: widget.onTap,
      excludeSemantics: true,
      child: GestureDetector(
        onLongPressStart: widget.onHoldStart == null
            ? null
            : (_) => widget.onHoldStart!(),
        onLongPressEnd: widget.onHoldEnd == null
            ? null
            : (_) => widget.onHoldEnd!(),
        child: FocusRing(
          radius: 28,
          child: Material(
            color: fill,
            shape: shape,
            child: InkWell(
              onTap: widget.onTap,
              customBorder: shape,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 56, minHeight: 56),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Center(
                    widthFactor: 1,
                    heightFactor: 1,
                    child: content,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Bars for the last [bars] levels, newest on the right; silence is a dot.
class _Waveform extends CustomPainter {
  _Waveform(this.levels, this.color);

  final List<double> levels;
  final Color color;
  static const bars = 8;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width / (bars * 2 - 1);
    final paint = Paint()
      ..color = color
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round;
    final recent = levels.skip(math.max(0, levels.length - bars)).toList();
    final pad = bars - recent.length;
    for (var i = 0; i < bars; i++) {
      final v = i < pad ? 0.0 : recent[i - pad].clamp(0.0, 1.0);
      final half = math.max(0, v * size.height - w) / 2;
      final x = w / 2 + i * 2 * w;
      final mid = size.height / 2;
      canvas.drawLine(Offset(x, mid - half), Offset(x, mid + half), paint);
    }
  }

  @override
  bool shouldRepaint(_Waveform old) =>
      old.color != color || !identical(old.levels, levels);
}
