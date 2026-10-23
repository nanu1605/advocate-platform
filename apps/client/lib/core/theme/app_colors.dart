import 'package:flutter/material.dart';

/// Status meanings (spec §5.6). Pills always pair the colour with an icon and a label.
enum StatusKind { listed, newOrder, adjourned, urgent, disposed, success, ai }

@immutable
class StatusColors {
  const StatusColors(this.fg, this.bg);
  final Color fg;
  final Color bg;
}

@immutable
class TypeToken {
  const TypeToken({
    required this.size,
    required this.height,
    required this.weight,
  });
  final double size;
  final double height;
  final int weight;

  TextStyle style(Color color) => TextStyle(
    fontFamily: 'Mukta',
    fontSize: size,
    height: height / size,
    fontWeight: FontWeight.values[(weight ~/ 100) - 1],
    color: color,
  );
}

/// Colour tokens for one theme (light, dark or sunlight), generated from design/tokens.json.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.bg,
    required this.surface,
    required this.surfaceAlt,
    required this.line,
    required this.outline,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.primary,
    required this.primaryFill,
    required this.onPrimary,
    required this.primarySoft,
    required this.focus,
    required this.scrim,
    required this.status,
    required this.borderWidth,
    required this.isSunlight,
  });

  final Color bg;
  final Color surface;
  final Color surfaceAlt;
  final Color line;
  final Color outline;
  final Color ink;
  final Color ink2;
  final Color ink3;
  final Color primary;
  final Color primaryFill;
  final Color onPrimary;
  final Color primarySoft;
  final Color focus;
  final Color scrim;
  final Map<StatusKind, StatusColors> status;

  /// 1 px normally; 1.5 px in sunlight, where borders replace tints.
  final double borderWidth;
  final bool isSunlight;

  StatusColors of(StatusKind kind) => status[kind]!;

  BorderSide get lineSide => BorderSide(color: line, width: borderWidth);

  @override
  AppColors copyWith() => this;

  // Theme switches are instant swaps (no colour tweening between palettes).
  @override
  AppColors lerp(AppColors? other, double t) =>
      other == null || t < 0.5 ? this : other;
}

extension AppThemeContext on BuildContext {
  AppColors get colors => Theme.of(this).extension<AppColors>()!;
  TextTheme get text => Theme.of(this).textTheme;
}
