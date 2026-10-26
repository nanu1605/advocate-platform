import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/core/theme/tokens.g.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

/// The keyboard focus ring (spec §5.9): 2 dp of the focus colour, 2 dp clear of the control's edge, so it never sits
/// flush on a primary fill of the same colour. [inset] draws it 2 dp inside the edge instead, for rows whose edge
/// meets the next row or a list's clip.
BorderSide focusRingSide(AppColors c, {bool inset = false}) => BorderSide(
  color: c.focus,
  width: Radii.focusRing,
  strokeAlign: inset ? -3 : 3,
);

/// Whether a control in [states] shows the focus ring: focused from the keyboard ([focusVisible]).
// ponytail: read when the control rebuilds, so a ring can outlive a switch to touch until the control's next state
// change; a highlight-mode listener per control if that ever shows.
bool showsFocusRing(Set<WidgetState> states) =>
    states.contains(WidgetState.focused) && focusVisible;

/// Whether focus shows at all, as the web's :focus-visible: Flutter's highlight mode is traditional (a key since the
/// last touch) and no pointer went down since the last key either, which that mode ignores for a mouse on a desktop.
/// So a card that a click selected, and focused, shows no ring until a key is pressed.
bool get focusVisible =>
    FocusManager.instance.highlightMode == FocusHighlightMode.traditional &&
    !pointerSinceKey.value;

/// A pointer went down since the last key press. Kept while anything [watchPointer]s (each FocusRing does: the rows
/// a click focuses); false otherwise, so focus then shows as the highlight mode says.
final ValueNotifier<bool> pointerSinceKey = ValueNotifier(false);
var _watchers = 0;

/// Keeps [pointerSinceKey] up to date until the matching [unwatchPointer].
void watchPointer() {
  if (_watchers++ > 0) return;
  HardwareKeyboard.instance.addHandler(_keyDown);
  GestureBinding.instance.pointerRouter.addGlobalRoute(_pointerDown);
}

void unwatchPointer() {
  if (--_watchers > 0) return;
  HardwareKeyboard.instance.removeHandler(_keyDown);
  GestureBinding.instance.pointerRouter.removeGlobalRoute(_pointerDown);
  pointerSinceKey.value = false;
}

bool _keyDown(KeyEvent e) {
  if (e is KeyDownEvent) pointerSinceKey.value = false;
  return false;
}

void _pointerDown(PointerEvent e) {
  if (e is PointerDownEvent) pointerSinceKey.value = true;
}

/// [haptics] off also silences Flutter's own feedback (a tooltip's long-press buzz, a tap's click).
ThemeData buildTheme(
  AppColors c, {
  required bool reduceMotion,
  bool haptics = true,
}) {
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
  final ring = focusRingSide(c);
  WidgetStateBorderSide ringOr(BorderSide? side) =>
      WidgetStateBorderSide.resolveWith((s) => showsFocusRing(s) ? ring : side);

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
        side: ringOr(null),
        enableFeedback: haptics,
        // Shape changes are instant, so the ring follows focus rather than growing in over 200 ms.
        animationDuration: Duration.zero,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(64, 48)),
        shape: pressable,
        textStyle: WidgetStatePropertyAll(text.labelLarge),
        foregroundColor: WidgetStatePropertyAll(c.primary),
        side: ringOr(BorderSide(color: c.outline, width: c.borderWidth)),
        enableFeedback: haptics,
        animationDuration: Duration.zero,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
        shape: pressable,
        textStyle: WidgetStatePropertyAll(text.labelLarge),
        foregroundColor: WidgetStatePropertyAll(c.primary),
        side: ringOr(null),
        enableFeedback: haptics,
        animationDuration: Duration.zero,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
        foregroundColor: WidgetStatePropertyAll(c.ink),
        side: ringOr(null),
        enableFeedback: haptics,
        animationDuration: Duration.zero,
      ),
    ),
    // The desktop rail's New button: Material 3's 16 dp corners, with the ring when focused.
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      enableFeedback: haptics,
      shape: WidgetStateOutlinedBorder.resolveWith(
        (s) => RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: showsFocusRing(s) ? ring : BorderSide.none,
        ),
      ),
    ),
    listTileTheme: ListTileThemeData(enableFeedback: haptics),
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
        (s) => showsFocusRing(s)
            ? ring
            : c.isSunlight && s.contains(WidgetState.selected)
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
      enableFeedback: haptics,
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
