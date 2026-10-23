import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/data/auth.dart';
import 'package:advocate_app/features/dev_kitchen_sink/kitchen_sink.dart';
import 'package:advocate_app/features/lock/app_lock.dart';
import 'package:advocate_app/features/onboarding/consent_screen.dart';
import 'package:advocate_app/features/onboarding/language_screen.dart';
import 'package:advocate_app/features/onboarding/lock_setup_screen.dart';
import 'package:advocate_app/features/onboarding/sign_in_screens.dart';
import 'package:advocate_app/features/settings/settings_screen.dart';
import 'package:advocate_app/features/shell/home_shell.dart';
import 'package:advocate_app/features/shell/screens.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:animations/animations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

const _onboarding = ['/welcome', '/sign-in', '/consent', '/app-lock'];

/// Where onboarding sends the user next (spec §4.1): language → sign-in → consent → app lock → Today.
/// Returns null to stay on [location].
String? onboardingRedirect({
  required String location,
  required bool hasLanguage,
  required bool signedIn,
  required bool consented,
  required bool lockConfigured,
}) {
  final String? target;
  if (!hasLanguage) {
    target = '/welcome';
  } else if (!signedIn) {
    target = location.startsWith('/sign-in') ? location : '/sign-in';
  } else if (!consented) {
    target = '/consent';
  } else if (!lockConfigured) {
    target = '/app-lock';
  } else {
    target = _onboarding.any(location.startsWith) ? '/today' : location;
  }
  return target == location ? null : target;
}

/// Tab switches fade through (250 ms); reduce motion makes it a 100 ms cross-fade (spec §5.5).
Page<void> _tab(GoRouterState state, Widget child) =>
    CustomTransitionPage<void>(
      key: state.pageKey,
      child: child,
      transitionDuration: const Duration(milliseconds: 250),
      transitionsBuilder: (context, animation, secondary, child) =>
          MediaQuery.disableAnimationsOf(context)
          ? FadeTransition(opacity: animation, child: child)
          : FadeThroughTransition(
              animation: animation,
              secondaryAnimation: secondary,
              child: child,
            ),
    );

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier(0);
  void bump(Object? _, Object? _) => refresh.value++;
  ref
    ..listen(settingsProvider, bump)
    ..listen(signedInProvider, bump)
    ..listen(appLockProvider.select((s) => s.configured), bump)
    ..onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: '/today',
    refreshListenable: refresh,
    redirect: (context, state) {
      final s = ref.read(settingsProvider);
      return onboardingRedirect(
        location: state.matchedLocation,
        hasLanguage: s.locale != null,
        signedIn:
            ref.read(signedInProvider).value ??
            ref.read(authRepositoryProvider).isSignedIn,
        consented: s.consentVersion != null,
        lockConfigured: ref.read(appLockProvider).configured,
      );
    },
    routes: [
      GoRoute(path: '/welcome', builder: (_, _) => const LanguageScreen()),
      GoRoute(
        path: '/sign-in',
        builder: (_, _) => const PhoneScreen(),
        routes: [
          GoRoute(
            path: 'otp',
            redirect: (_, state) => state.extra is String ? null : '/sign-in',
            builder: (_, state) => OtpScreen(phone: state.extra! as String),
          ),
        ],
      ),
      GoRoute(path: '/consent', builder: (_, _) => const ConsentScreen()),
      GoRoute(path: '/app-lock', builder: (_, _) => const LockSetupScreen()),
      if (kDebugMode)
        GoRoute(
          path: '/dev/kitchen-sink',
          builder: (_, _) => const KitchenSinkScreen(),
        ),
      ShellRoute(
        builder: (_, state, child) =>
            HomeShell(location: state.matchedLocation, child: child),
        routes: [
          GoRoute(
            path: '/today',
            pageBuilder: (_, s) => _tab(s, const TodayScreen()),
          ),
          GoRoute(
            path: '/cases',
            pageBuilder: (_, s) => _tab(s, const CasesScreen()),
          ),
          GoRoute(
            path: '/more',
            pageBuilder: (_, s) => _tab(s, const MoreScreen()),
          ),
          GoRoute(
            path: '/settings',
            pageBuilder: (_, s) => _tab(s, const SettingsScreen()),
          ),
          GoRoute(
            path: '/calendar',
            pageBuilder: (c, s) => _tab(
              s,
              PlaceholderScreen(
                title: c.l10n.navCalendar,
                icon: AppIcons.calendarBlank,
              ),
            ),
          ),
          GoRoute(
            path: '/clients',
            pageBuilder: (c, s) => _tab(
              s,
              PlaceholderScreen(title: c.l10n.navClients, icon: AppIcons.users),
            ),
          ),
          GoRoute(
            path: '/documents',
            pageBuilder: (c, s) => _tab(
              s,
              PlaceholderScreen(
                title: c.l10n.navDocuments,
                icon: AppIcons.files,
              ),
            ),
          ),
        ],
      ),
    ],
  );
});
