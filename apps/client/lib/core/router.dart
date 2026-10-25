import 'dart:async';

import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/core/theme/tokens.g.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/auth.dart';
import 'package:advocate_app/features/board/board_screen.dart';
import 'package:advocate_app/features/calendar/calendar_screen.dart';
import 'package:advocate_app/features/case_page/case_page.dart';
import 'package:advocate_app/features/cases/cases_screen.dart';
import 'package:advocate_app/features/cases/manual_case_screen.dart';
import 'package:advocate_app/features/cases/search_cases_screen.dart';
import 'package:advocate_app/features/clients/client_profile.dart';
import 'package:advocate_app/features/clients/clients_screen.dart';
import 'package:advocate_app/features/dev_kitchen_sink/kitchen_sink.dart';
import 'package:advocate_app/features/documents/documents_screen.dart';
import 'package:advocate_app/features/documents/viewer_screen.dart';
import 'package:advocate_app/features/found_cases/found_cases_screen.dart';
import 'package:advocate_app/features/lock/app_lock.dart';
import 'package:advocate_app/features/onboarding/account_loading_screen.dart';
import 'package:advocate_app/features/onboarding/consent_screen.dart';
import 'package:advocate_app/features/onboarding/details_screen.dart';
import 'package:advocate_app/features/onboarding/finding_screen.dart';
import 'package:advocate_app/features/onboarding/join_screen.dart';
import 'package:advocate_app/features/onboarding/language_screen.dart';
import 'package:advocate_app/features/onboarding/lock_setup_screen.dart';
import 'package:advocate_app/features/onboarding/notifications_screen.dart';
import 'package:advocate_app/features/onboarding/role_screen.dart';
import 'package:advocate_app/features/onboarding/sign_in_screens.dart';
import 'package:advocate_app/features/session.dart';
import 'package:advocate_app/features/settings/settings_screen.dart';
import 'package:advocate_app/features/shell/home_shell.dart';
import 'package:advocate_app/features/shell/screens.dart';
import 'package:advocate_app/features/today/today_screen.dart';
import 'package:advocate_app/ui/app_scaffold.dart';
import 'package:animations/animations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Routes before the app proper; once onboarding is done they lead to Today. (/found and /join/:code stay open.)
const _onboarding = [
  '/welcome',
  '/sign-in',
  '/consent',
  '/app-lock',
  '/loading',
  '/onboarding',
];

/// Where onboarding sends the user next (spec §4.1): language → sign-in → consent → app lock → role →
/// (advocate details → Finding your cases → Found cases) → notifications → Today. Returns null to stay on
/// [location]. Within a step's routes the user moves freely; anything else goes to the step's first route.
///
/// [onboardingDone] is the account's device flag (`AppSettings.onboardingDone`; null = not decided here yet,
/// then a set-up account counts as done). [stage] is null while the account loads, or failed to load with
/// nothing cached: /loading shows that rather than guessing a step.
String? onboardingRedirect({
  required String location,
  required bool hasLanguage,
  required bool signedIn,
  required bool consented,
  required bool lockConfigured,
  required bool? onboardingDone,
  required AccountStage? stage,
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
  } else if (onboardingDone ?? stage?.setUp ?? false) {
    target = _onboarding.any(location.startsWith) ? '/today' : location;
  } else if (stage == null) {
    target = '/loading';
  } else {
    final step = switch (stage) {
      AccountStage.noOrg => const [
        '/onboarding/role',
        '/onboarding/join',
        '/join/',
        '/onboarding/details',
      ],
      AccountStage.needsDetails => const ['/onboarding/details'],
      AccountStage.owner => const [
        '/onboarding/finding',
        '/found',
        '/onboarding/notifications',
      ],
      AccountStage.member => const ['/onboarding/notifications'],
    };
    target = step.any(location.startsWith) ? location : step.first;
  }
  return target == location ? null : target;
}

/// A page that enters with [transition] over 250 ms; under reduce motion, a 100 ms cross-fade both ways
/// (spec §5.5). The duration is fixed when the page is built, so it is read from [context] then.
Page<void> _page(
  BuildContext context,
  GoRouterState state,
  Widget child,
  Widget Function(Animation<double>, Animation<double>, Widget) transition,
) {
  final reduced = MediaQuery.disableAnimationsOf(context);
  final duration = reduced
      ? MotionTokens.instant
      : const Duration(milliseconds: 250);
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionDuration: duration,
    reverseTransitionDuration: duration,
    transitionsBuilder: (context, animation, secondary, child) =>
        MediaQuery.disableAnimationsOf(context)
        ? FadeTransition(opacity: animation, child: child)
        : transition(animation, secondary, child),
  );
}

/// Tab switches fade through.
Page<void> _tab(BuildContext context, GoRouterState state, Widget child) =>
    _page(
      context,
      state,
      child,
      (animation, secondary, child) => FadeThroughTransition(
        animation: animation,
        secondaryAnimation: secondary,
        child: child,
      ),
    );

/// A window wide enough for a list beside its item (Cases, Clients).
bool _wide(BuildContext context) =>
    sizeClassOf(MediaQuery.sizeOf(context).width) == SizeClass.expanded;

/// Onboarding steps 5–9 move on a shared X axis.
Page<void> _step(BuildContext context, GoRouterState state, Widget child) =>
    _page(
      context,
      state,
      child,
      (animation, secondary, child) => SharedAxisTransition(
        animation: animation,
        secondaryAnimation: secondary,
        transitionType: SharedAxisTransitionType.horizontal,
        child: child,
      ),
    );

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier(0);
  void bump(Object? _, Object? _) => refresh.value++;
  ref
    ..listen(settingsProvider, bump)
    ..listen(signedInProvider, (was, now) {
      // However the session ended (sign-out, or a revoked or expired refresh token), forget per-account state,
      // so whoever signs in next starts at consent with no onboarding flag or synced rows of the last account.
      if (was?.value == true && now.value == false) {
        unawaited(ref.read(sessionProvider).forget());
      }
      bump(was, now);
    })
    ..listen(appLockProvider.select((s) => s.configured), bump)
    // The first time an account loads on this device, decide whether it still needs onboarding here.
    ..listen(accountProvider.select((a) => a.value?.stage), (_, stage) {
      if (stage != null && ref.read(settingsProvider).onboardingDone == null) {
        unawaited(
          ref
              .read(settingsProvider.notifier)
              .setOnboardingDone(value: stage.setUp),
        );
      }
      refresh.value++;
    })
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
        onboardingDone: s.onboardingDone,
        stage: ref.read(accountProvider).value?.stage,
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
      GoRoute(
        path: '/loading',
        builder: (_, _) => const AccountLoadingScreen(),
      ),
      GoRoute(
        path: '/onboarding/role',
        pageBuilder: (c, s) => _step(c, s, const RoleScreen()),
      ),
      GoRoute(
        path: '/onboarding/join',
        pageBuilder: (c, s) => _step(
          c,
          s,
          JoinScreen(junior: s.uri.queryParameters['role'] == 'junior'),
        ),
      ),
      GoRoute(
        path: '/join/:code',
        pageBuilder: (c, s) =>
            _step(c, s, JoinScreen(code: s.pathParameters['code'])),
      ),
      GoRoute(
        path: '/onboarding/details',
        pageBuilder: (c, s) => _step(
          c,
          s,
          DetailsScreen(chamber: s.uri.queryParameters['kind'] == 'chamber'),
        ),
      ),
      GoRoute(
        path: '/onboarding/finding',
        pageBuilder: (c, s) => _step(c, s, const FindingScreen()),
      ),
      GoRoute(path: '/found', builder: (_, _) => const FoundCasesScreen()),
      GoRoute(
        path: '/onboarding/notifications',
        pageBuilder: (c, s) => _step(c, s, const NotificationsScreen()),
      ),
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
            pageBuilder: (c, s) => _tab(c, s, const TodayScreen()),
          ),
          // Tomorrow's Board (spec §4.2); the `tomorrow_board` notification links here.
          GoRoute(
            path: '/board/tomorrow',
            pageBuilder: (c, s) => _tab(c, s, const BoardScreen()),
          ),
          GoRoute(
            path: '/cases',
            pageBuilder: (c, s) => _tab(c, s, const CasesScreen()),
            routes: [
              GoRoute(
                path: 'search',
                pageBuilder: (c, s) => _tab(c, s, const SearchCasesScreen()),
              ),
              GoRoute(
                path: 'manual',
                pageBuilder: (c, s) => _tab(c, s, const ManualCaseScreen()),
              ),
              // Case notifications link to /cases/{id}; Today's Notes action adds ?tab=notes. On a wide window the
              // list stays beside the case: going to another case keeps this page (its key is the route pattern),
              // so the list keeps its scroll and only the selection changes.
              GoRoute(
                path: ':id',
                pageBuilder: (c, s) {
                  final id = s.pathParameters['id']!;
                  final tab = s.uri.queryParameters['tab'];
                  return _tab(
                    c,
                    s,
                    _wide(c)
                        ? CasesScreen(selectedId: id, tab: tab)
                        // A fresh page per case, as in the wide pane: a refresh in flight stays with its case.
                        : CasePage(key: ValueKey(id), matterId: id, tab: tab),
                  );
                },
                routes: [
                  // An order's file in the viewer (spec §5.2 routes), over the case.
                  GoRoute(
                    path: 'orders/:orderId',
                    pageBuilder: (c, s) => _tab(
                      c,
                      s,
                      ViewerScreen.order(
                        key: ValueKey(s.pathParameters['orderId']),
                        matterId: s.pathParameters['id']!,
                        orderId: s.pathParameters['orderId']!,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          GoRoute(
            path: '/more',
            pageBuilder: (c, s) => _tab(c, s, const MoreScreen()),
          ),
          GoRoute(
            path: '/settings',
            pageBuilder: (c, s) => _tab(c, s, const SettingsScreen()),
          ),
          GoRoute(
            path: '/calendar',
            pageBuilder: (c, s) => _tab(c, s, const CalendarScreen()),
          ),
          GoRoute(
            path: '/clients',
            pageBuilder: (c, s) => _tab(c, s, const ClientsScreen()),
            routes: [
              // As /cases/:id: on a wide window the list stays beside the profile (the page is keyed by the
              // route pattern); on phones a fresh profile page per client.
              GoRoute(
                path: ':id',
                pageBuilder: (c, s) {
                  final id = s.pathParameters['id']!;
                  return _tab(
                    c,
                    s,
                    _wide(c)
                        ? ClientsScreen(selectedId: id)
                        : ClientProfile(key: ValueKey(id), clientId: id),
                  );
                },
              ),
            ],
          ),
          GoRoute(
            path: '/documents',
            pageBuilder: (c, s) => _tab(c, s, const DocumentsScreen()),
            routes: [
              GoRoute(
                path: ':id',
                pageBuilder: (c, s) => _tab(
                  c,
                  s,
                  ViewerScreen.document(
                    s.pathParameters['id']!,
                    key: ValueKey(s.pathParameters['id']),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});
