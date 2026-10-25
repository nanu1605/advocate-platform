import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/core/theme/tokens.g.dart';
import 'package:flutter/material.dart';

enum AppThemeMode { system, light, dark, sunlight }

AppColors colorsFor(AppThemeMode mode, Brightness platform) => switch (mode) {
  AppThemeMode.light => lightColors,
  AppThemeMode.dark => darkColors,
  AppThemeMode.sunlight => sunlightColors,
  AppThemeMode.system => platform == Brightness.dark ? darkColors : lightColors,
};

TextTheme _textTheme(AppColors c) => TextTheme(
  displaySmall: TypeTokens.display.style(c.ink),
  titleLarge: TypeTokens.title.style(c.ink),
  titleMedium: TypeTokens.heading.style(c.ink),
  titleSmall: TypeTokens.bodyStrong.style(c.ink),
  bodyLarge: TypeTokens.body.style(c.ink),
  bodyMedium: TypeTokens.body.style(c.ink),
  bodySmall: TypeTokens.small.style(c.ink2),
  labelLarge: TypeTokens.bodyStrong.style(c.ink),
  labelMedium: TypeTokens.label.style(c.ink),
  labelSmall: TypeTokens.caption.style(c.ink2),
);

ThemeData buildTheme(AppColors c, {required bool reduceMotion}) {
  final dark = c.bg.computeLuminance() < 0.2;
  final scheme = ColorScheme(
    brightness: dark ? Brightness.dark : Brightness.light,
    primary: c.primaryFill,
    onPrimary: c.onPrimary,
    primaryContainer: c.primarySoft,
    onPrimaryContainer: c.primary,
    secondary: c.primary,
    onSecondary: c.onPrimary,
    error: c.of(StatusKind.urgent).fg,
    onError: c.surface,
    errorContainer: c.of(StatusKind.urgent).bg,
    onErrorContainer: c.of(StatusKind.urgent).fg,
    surface: c.surface,
    onSurface: c.ink,
    onSurfaceVariant: c.ink2,
    surfaceContainerLowest: c.surface,
    surfaceContainerLow: c.surface,
    surfaceContainer: c.surfaceAlt,
    surfaceContainerHigh: c.surfaceAlt,
    surfaceContainerHighest: c.surfaceAlt,
    outline: c.outline,
    outlineVariant: c.line,
    scrim: c.scrim,
    shadow: Colors.black,
  );
  final text = _textTheme(c);
  final radius8 = BorderRadius.circular(Radii.input);
  final pressable = WidgetStatePropertyAll(
    RoundedRectangleBorder(borderRadius: radius8),
  );
  final transitions = reduceMotion
      ? const _InstantFadeTransitions()
      : const FadeForwardsPageTransitionsBuilder();

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.bg,
    fontFamily: 'Mukta',
    textTheme: text,
    extensions: [c],
    dividerTheme: DividerThemeData(
      color: c.line,
      thickness: c.borderWidth,
      space: 1,
    ),
    focusColor: c.focus.withValues(alpha: 0.16),
    materialTapTargetSize: MaterialTapTargetSize.padded,
    visualDensity: VisualDensity.standard,
    splashFactory: reduceMotion ? NoSplash.splashFactory : null,
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {for (final p in TargetPlatform.values) p: transitions},
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      foregroundColor: c.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: text.titleLarge,
      shape: Border(bottom: c.lineSide),
    ),
    cardTheme: CardThemeData(
      color: c.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.card),
        side: c.isSunlight
            ? BorderSide(color: c.line, width: c.borderWidth)
            : c.lineSide,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(64, 48)),
        shape: pressable,
        textStyle: WidgetStatePropertyAll(text.labelLarge),
        backgroundColor: WidgetStatePropertyAll(c.primaryFill),
        foregroundColor: WidgetStatePropertyAll(c.onPrimary),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(64, 48)),
        shape: pressable,
        textStyle: WidgetStatePropertyAll(text.labelLarge),
        foregroundColor: WidgetStatePropertyAll(c.primary),
        side: WidgetStatePropertyAll(
          BorderSide(color: c.outline, width: c.borderWidth),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
        shape: pressable,
        textStyle: WidgetStatePropertyAll(text.labelLarge),
        foregroundColor: WidgetStatePropertyAll(c.primary),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
        foregroundColor: WidgetStatePropertyAll(c.ink),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surface,
      labelStyle: text.bodyLarge?.copyWith(color: c.ink2),
      hintStyle: text.bodyLarge?.copyWith(color: c.ink3),
      errorStyle: text.bodySmall?.copyWith(color: c.of(StatusKind.urgent).fg),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: radius8,
        borderSide: BorderSide(color: c.outline, width: c.borderWidth),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius8,
        borderSide: BorderSide(color: c.outline, width: c.borderWidth),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius8,
        borderSide: BorderSide(color: c.focus, width: Radii.focusRing),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: radius8,
        borderSide: BorderSide(
          color: c.of(StatusKind.urgent).fg,
          width: c.borderWidth,
        ),
      ),
    ),
    // A selected chip shows a primary tick (the default is near-white); in Sunlight, where its fill is as white
    // as the rest, a primary border too, so the choice never rests on a tint.
    chipTheme: ChipThemeData(
      backgroundColor: c.surface,
      selectedColor: c.primarySoft,
      checkmarkColor: c.primary,
      labelStyle: text.bodySmall?.copyWith(color: c.ink),
      side: WidgetStateBorderSide.resolveWith(
        (s) => c.isSunlight && s.contains(WidgetState.selected)
            ? BorderSide(color: c.primary, width: 2)
            : BorderSide(color: c.outline, width: c.borderWidth),
      ),
      shape: RoundedRectangleBorder(borderRadius: radius8),
    ),
    checkboxTheme: CheckboxThemeData(
      side: BorderSide(color: c.outline, width: 2),
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? c.primaryFill : null,
      ),
      checkColor: WidgetStatePropertyAll(c.onPrimary),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: c.surface,
      // One soft shadow in light mode only (spec §5.8).
      elevation: dark || c.isSunlight ? 0 : 6,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(Radii.sheet),
        ),
        side: c.isSunlight ? c.lineSide : BorderSide.none,
      ),
      showDragHandle: true,
      dragHandleColor: c.outline,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: text.titleMedium,
      contentTextStyle: text.bodyLarge,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.sheet),
        side: c.isSunlight ? c.lineSide : BorderSide.none,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.ink,
      contentTextStyle: text.bodyLarge?.copyWith(color: c.bg),
      actionTextColor: c.isSunlight ? Colors.white : c.primarySoft,
      behavior: SnackBarBehavior.floating,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: c.primarySoft,
      height: 72,
      labelTextStyle: WidgetStatePropertyAll(text.labelMedium),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: c.surface,
      indicatorColor: c.primarySoft,
      selectedLabelTextStyle: text.labelMedium?.copyWith(color: c.primary),
      unselectedLabelTextStyle: text.labelMedium?.copyWith(color: c.ink2),
    ),
    tooltipTheme: TooltipThemeData(
      textStyle: text.bodySmall?.copyWith(color: c.bg),
      decoration: BoxDecoration(
        color: c.ink,
        borderRadius: BorderRadius.circular(Radii.input),
      ),
    ),
  );
}

/// Reduce motion: every page transition becomes a 100 ms cross-fade (spec §5.5).
class _InstantFadeTransitions extends PageTransitionsBuilder {
  const _InstantFadeTransitions();

  @override
  Duration get transitionDuration => MotionTokens.instant;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => FadeTransition(opacity: animation, child: child);
}
