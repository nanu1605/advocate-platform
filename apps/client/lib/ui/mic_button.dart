import 'dart:async';
import 'dart:math' as math;

import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/core/theme/app_theme.dart';
import 'package:advocate_app/core/theme/motion.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:flutter/material.dart';

enum MicState { idle, recording, processing, error }

/// The voice button (spec §5.2, §5.11 #9): tap for quick add, press and hold to record at once. Recording shows the
/// live waveform; processing a "reading" pulse (still with reduce motion); an error asks to try again. It stays 56 dp
/// round in every state, so it fits the bottom bar's centre slot; the time recorded is in its spoken label, and a
/// screen that wants it shown shows it beside. Holding has no screen-reader gesture: quick add (the tap) offers a
/// voice note too.
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

  /// The hold is over: the finger lifted, the system took the touch (a call, a system gesture), or the button went.
  /// Stop recording.
  final VoidCallback? onHoldEnd;

  @override
  State<MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<MicButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  late final Animation<double> _opacity = Tween<double>(
    begin: 1,
    end: 0.4,
  ).animate(_pulse);
  var _holding = false;
  var _focused = false;

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

  void _holdStart() {
    _holding = true;
    widget.onHoldStart?.call();
  }

  /// Once per hold, however it ends. A quick tap also "cancels" a long press, but never started one.
  void _holdEnd() {
    if (!_holding) return;
    _holding = false;
    widget.onHoldEnd?.call();
  }

  @override
  void dispose() {
    // After the tree is unlocked, as the caller will likely set state.
    if (_holding) scheduleMicrotask(widget.onHoldEnd ?? () {});
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
    // The keyboard ring goes outside the fill, which can be the focus colour itself (spec §5.9).
    final shape = CircleBorder(
      side: _focused && focusVisible
          ? focusRingSide(c)
          : widget.state == MicState.error
          ? BorderSide(color: urgent.fg, width: 2)
          : BorderSide.none,
    );
    final content = switch (widget.state) {
      MicState.recording => CustomPaint(
        size: const Size(30, 24),
        painter: _Waveform(widget.levels, fg),
      ),
      MicState.processing => FadeTransition(
        opacity: _opacity,
        child: Icon(AppIcons.waveform, size: 28, color: fg),
      ),
      MicState.idle => Icon(AppIcons.microphone, size: 28, color: fg),
      MicState.error => Icon(AppIcons.warning, size: 28, color: fg),
    };
    return Semantics(
      button: true,
      label: label,
      onTap: widget.onTap,
      excludeSemantics: true,
      child: GestureDetector(
        onLongPressStart: (_) => _holdStart(),
        onLongPressEnd: (_) => _holdEnd(),
        onLongPressCancel: _holdEnd,
        child: Material(
          color: fill,
          shape: shape,
          child: InkWell(
            onTap: widget.onTap,
            onFocusChange: (f) => setState(() => _focused = f),
            customBorder: shape,
            child: SizedBox.square(
              dimension: 56,
              child: Center(child: content),
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
  static const bars = 5;

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
