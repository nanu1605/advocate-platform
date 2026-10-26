import 'package:advocate_app/core/brand/brand.g.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/router.dart';
import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/core/theme/app_theme.dart';
import 'package:advocate_app/core/theme/tokens.g.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:advocate_app/features/lock/lock_screen.dart';
import 'package:advocate_app/ui/focus_ring.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class App extends ConsumerWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    ref.watch(syncConnectionProvider);
    // The view's MediaQuery, so the theme follows the OS flag when it changes while the app runs.
    final reduce = s.reduceMotion || MediaQuery.disableAnimationsOf(context);
    ThemeData theme(AppThemeMode m) => buildTheme(
      colorsFor(m, Brightness.light),
      reduceMotion: reduce,
      haptics: s.haptics,
    );

    return MaterialApp.router(
      title: Brand.appName,
      debugShowCheckedModeBanner: false,
      routerConfig: ref.watch(routerProvider),
      locale: s.locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // Sunlight is a light theme with its own palette; System follows the OS light/dark setting.
      theme: theme(
        s.theme == AppThemeMode.sunlight
            ? AppThemeMode.sunlight
            : AppThemeMode.light,
      ),
      darkTheme: buildTheme(
        darkColors,
        reduceMotion: reduce,
        haptics: s.haptics,
      ),
      themeMode: switch (s.theme) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.dark => ThemeMode.dark,
        AppThemeMode.light || AppThemeMode.sunlight => ThemeMode.light,
      },
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        return MediaQuery(
          // Text follows the OS up to 200% (spec §5.7); the in-app toggle joins the OS reduce-motion flag.
          data: mq.copyWith(
            textScaler: mq.textScaler.clamp(maxScaleFactor: 2),
            disableAnimations: mq.disableAnimations || s.reduceMotion,
          ),
          child: AppLockGate(child: DestinationFocusRing(child: child!)),
        );
      },
    );
  }
}
