import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/router.dart';
import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/jobs.dart';
import 'package:advocate_app/features/found_cases/found_cases_screen.dart';
import 'package:advocate_app/features/onboarding/notifications_screen.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

/// Onboarding steps 5–10 (spec §4.1): role, join, details, Finding your cases, notifications.
void main() {
  setUpAll(loadAppFonts);

  // The Finding screen's turning ring loops; reduce motion stills it so frames settle (and covers §5.5).
  void reduceMotion(WidgetTester tester) {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  }

  Future<void> tap(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text).last);
    await tester.tap(find.text(text).last);
    await tester.pumpAndSettle();
  }

  Future<void> a11y(WidgetTester tester) async {
    expect(tester.takeException(), isNull);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  }

  Finder field(String label) => find.widgetWithText(TextField, label);

  for (final locale in ['en', 'hi']) {
    final l = lookupAppLocalizations(Locale(locale));

    testWidgets(
      'advocate in $locale: role → details → finding → found cases → notifications → today',
      (tester) async {
        reduceMotion(tester);
        final permission = FakePermission();
        final api = await pumpApp(
          tester,
          account: newAccount,
          locale: locale,
          overrides: [...syncedData(), permission.asOverride],
        );
        api.jobs['job-1'] = _job(JobStatus.running);

        await tap(tester, l.onboardingRoleAdvocate);
        expect(find.text(l.detailsTitle), findsOneWidget);
        expect(find.text(l.onboardingDetailsChamber), findsNothing);
        await tester.enterText(
          field(l.onboardingDetailsName),
          ' Ramesh Sharma ',
        );
        await tester.enterText(
          field(l.onboardingDetailsEnrolment),
          'MP/1234/2010',
        );
        await tap(tester, locale == 'hi' ? 'MPHC इंदौर' : 'MPHC Indore');
        await tap(tester, l.onboardingDetailsCourtOther);
        await tap(tester, l.onboardingDetailsSubmit);

        expect(api.calls.firstWhere((c) => c.name == 'patchMe').args, {
          'full_name': 'Ramesh Sharma',
          'enrolment_no': 'MP/1234/2010',
          'bar_council_state': 'MP',
          'practice_court_ids': ['c0000000-0000-0000-0000-000000000003'],
        });
        expect(api.calls.firstWhere((c) => c.name == 'createOrg').args, {
          'name': 'Ramesh Sharma',
          'kind': 'solo',
        });
        expect(api.callNames.where((n) => n == 'findCases'), hasLength(1));

        // Finding: real progress by court group.
        expect(find.text(l.findingTitle), findsOneWidget);
        expect(find.text(l.findingGroupHc), findsOneWidget);
        expect(find.text(l.findingGroupFound(12)), findsOneWidget);
        expect(find.text(l.findingSearching), findsOneWidget);
        expect(find.text(l.findingFound(12)), findsOneWidget);

        // Done → Found cases.
        api.jobs['job-1'] = _job(JobStatus.done);
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(find.byType(FoundCasesScreen), findsOneWidget);

        // Found cases leads on to notifications (its own tests cover how).
        container(tester).read(routerProvider).go('/onboarding/notifications');
        await tester.pumpAndSettle();
        expect(find.text(l.notificationsTitle), findsOneWidget);
        await tap(tester, l.notifyExplainerAllow);
        expect(permission.requests, 1);
        expect(find.text(l.todayEmpty), findsOneWidget);
        expect(container(tester).read(settingsProvider).onboardingDone, isTrue);
      },
    );

    for (final scale in [1.0, 2.0]) {
      testWidgets('role and details read well ($locale ${scale}x)', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        final api = await pumpApp(
          tester,
          account: newAccount,
          locale: locale,
          textScale: scale,
          overrides: syncedData(),
        );
        for (final role in [
          l.onboardingRoleAdvocate,
          l.onboardingRoleJunior,
          l.onboardingRoleClerk,
          l.onboardingRoleChamber,
        ]) {
          await tester.scrollUntilVisible(
            find.text(role),
            100,
            scrollable: find.byType(Scrollable).first,
          );
        }
        await a11y(tester);

        // Empty details: inline errors, nothing sent.
        await tap(tester, l.onboardingRoleChamber);
        expect(find.text(l.onboardingDetailsChamber), findsOneWidget);
        await tap(tester, l.onboardingDetailsSubmit);
        expect(find.text(l.onboardingDetailsNameError), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text(l.onboardingDetailsEnrolmentError),
          100,
          scrollable: find.byType(Scrollable).first,
        );
        expect(api.callNames, isNot(contains('patchMe')));
        await a11y(tester);
        handle.dispose();
      });

      testWidgets('Finding a11y and layout ($locale ${scale}x)', (
        tester,
      ) async {
        reduceMotion(tester);
        final handle = tester.ensureSemantics();
        await _pumpFinding(
          tester,
          _job(JobStatus.running),
          locale: locale,
          scale: scale,
        );
        expect(find.text(l.findingBackground), findsOneWidget);
        expect(find.text(l.findingStop), findsOneWidget);
        // Each court group is read as one item: its name and what was found.
        await tester.scrollUntilVisible(
          find.text(l.findingGroupHc),
          100,
          scrollable: find.byType(Scrollable).first,
        );
        expect(
          find.bySemanticsLabel(
            RegExp(
              '${l.findingGroupHc}.*${l.findingGroupFound(12)}',
              dotAll: true,
            ),
          ),
          findsWidgets,
        );
        await a11y(tester);
        handle.dispose();
      });

      testWidgets('notifications a11y and layout ($locale ${scale}x)', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await pumpApp(
          tester,
          account: juniorAccount,
          onboardingDone: false,
          locale: locale,
          textScale: scale,
          overrides: [FakePermission(granted: false).asOverride],
        );
        await tap(tester, l.notifyExplainerAllow);
        await tester.scrollUntilVisible(
          find.text(l.notifyExplainerOpenSettings),
          100,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text(l.notifyExplainerDenied), findsOneWidget);
        await a11y(tester);
        handle.dispose();
      });
    }
  }

  final l = lookupAppLocalizations(const Locale('en'));

  group('role and join', () {
    testWidgets('a chamber owner may name the chamber', (tester) async {
      reduceMotion(tester);
      final api = await pumpApp(
        tester,
        account: newAccount,
        overrides: syncedData(),
      );
      api.jobs['job-1'] = _job(JobStatus.running);
      await tap(tester, l.onboardingRoleChamber);
      await tester.enterText(field(l.onboardingDetailsName), 'Ramesh Sharma');
      await tester.enterText(
        field(l.onboardingDetailsChamber),
        'Sharma Chambers',
      );
      await tester.enterText(field(l.onboardingDetailsEnrolment), 'MP/1/2010');
      await tap(tester, l.onboardingDetailsSubmit);
      expect(api.calls.firstWhere((c) => c.name == 'createOrg').args, {
        'name': 'Sharma Chambers',
        'kind': 'chamber',
      });
      // No practice courts chosen: every court in the state is searched.
      expect(
        (api.calls.firstWhere((c) => c.name == 'patchMe').args!
            as Map)['practice_court_ids'],
        isEmpty,
      );
      expect(find.text(l.findingTitle), findsOneWidget);
    });

    testWidgets(
      'a clerk joins with a code and skips to notifications (Windows: nothing to ask)',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        final permission = FakePermission();
        final api =
            await pumpApp(
                tester,
                account: newAccount,
                overrides: [permission.asOverride],
              )
              ..inviteRole = 'clerk';
        await tap(tester, l.onboardingRoleClerk);
        expect(find.text(l.joinTitle), findsOneWidget);
        expect(find.text(l.onboardingJoinOnMyOwn), findsNothing);

        // Empty: an inline hint, nothing sent.
        await tap(tester, l.onboardingJoinSubmit);
        expect(find.text(l.onboardingJoinCodeEmpty), findsOneWidget);
        expect(api.callNames, isNot(contains('acceptInvite')));

        await tester.enterText(field(l.onboardingJoinCode), ' abcd-2345 ');
        await tap(tester, l.onboardingJoinSubmit);
        expect(
          api.calls.firstWhere((c) => c.name == 'acceptInvite').args,
          'ABCD2345',
        );
        expect(find.text(l.notificationsTitle), findsOneWidget);
        expect(find.text(l.notifyExplainerNotNow), findsNothing);
        await tap(tester, l.continueButton);
        expect(permission.requests, 0);
        expect(find.text(l.todayEmpty), findsOneWidget);
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets('a junior without an invite may use the app on their own', (
      tester,
    ) async {
      await pumpApp(tester, account: newAccount, overrides: syncedData());
      await tap(tester, l.onboardingRoleJunior);
      await tap(tester, l.onboardingJoinOnMyOwn);
      expect(find.text(l.detailsTitle), findsOneWidget);
    });

    testWidgets('join errors are explained and keep the code', (tester) async {
      final api = await pumpApp(tester, account: newAccount);
      await tap(tester, l.onboardingRoleClerk);
      await tester.enterText(field(l.onboardingJoinCode), 'ABCD2345');

      api.fail['acceptInvite'] = const ApiException('INVITE_INVALID');
      await tap(tester, l.onboardingJoinSubmit);
      expect(find.text(l.errorInviteInvalid), findsOneWidget);

      api.fail['acceptInvite'] = const ApiException(
        'TEAM_LIMIT',
        details: {'limit': 10},
      );
      await tap(tester, l.onboardingJoinSubmit);
      expect(find.text(l.errorTeamLimit(10)), findsOneWidget);

      api.offline = true;
      await tap(tester, l.onboardingJoinSubmit);
      expect(find.text(l.errorNeedsNetwork), findsOneWidget);
      expect(find.text('ABCD2345'), findsOneWidget);

      // Already in the team: carries on.
      api
        ..offline = false
        ..fail['acceptInvite'] = const ApiException('ALREADY_MEMBER')
        ..account = juniorAccount;
      await tap(tester, l.onboardingJoinSubmit);
      expect(find.text(l.notificationsTitle), findsOneWidget);
    });

    testWidgets(
      'an invite link opened after onboarding confirms the join and goes to Today',
      (tester) async {
        final api = await pumpApp(
          tester,
          onboardingDone: true,
          location: '/join/ABCD2345',
        );
        expect(find.text(l.joinTitle), findsOneWidget);
        await tap(tester, l.onboardingJoinSubmit);
        expect(api.callNames, ['me', 'acceptInvite', 'me']);
        // The app still works in the first team; it says so rather than pretend.
        expect(
          find.text(l.onboardingJoinDoneLater('Sharma Chambers')),
          findsOneWidget,
        );
        expect(find.text(l.todayEmpty), findsOneWidget);
      },
    );

    testWidgets(
      'the join link prefills the code and offers another role (nothing to go back to)',
      (tester) async {
        await pumpApp(tester, account: newAccount, location: '/join/abcd2345');
        expect(find.text('ABCD2345'), findsOneWidget);
        await tap(tester, l.onboardingJoinOtherRole);
        expect(find.text(l.roleTitle), findsOneWidget);
      },
    );
  });

  group('details', () {
    for (final locale in ['en', 'hi']) {
      testWidgets(
        'at 200% text a failed search says why above the button ($locale)',
        (tester) async {
          final l = lookupAppLocalizations(Locale(locale));
          final api = await pumpApp(
            tester,
            account: newAccount,
            locale: locale,
            textScale: 2,
            overrides: syncedData(),
          );
          api.fail['findCases'] = const ApiException('RATE_LIMITED');
          await tap(tester, l.onboardingRoleAdvocate);
          await tester.enterText(field(l.onboardingDetailsName), 'R Sharma');
          await tester.enterText(field(l.onboardingDetailsEnrolment), 'MP/1');
          await tester.tap(find.text(l.onboardingDetailsSubmit));
          await tester.pumpAndSettle();
          final notice = find.text(l.errorTooMany);
          expect(notice, findsOneWidget);
          final screen = Offset.zero & tester.view.physicalSize;
          expect(screen.contains(tester.getRect(notice).topLeft), isTrue);
          expect(screen.contains(tester.getRect(notice).bottomRight), isTrue);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      "createOrg's reply is lost: the retry uses the organisation it made",
      (tester) async {
        reduceMotion(tester);
        final api = await pumpApp(
          tester,
          account: newAccount,
          overrides: syncedData(),
        );
        api
          ..jobs['job-1'] = _job(JobStatus.running)
          ..failAfter['createOrg'] = const ApiException('NETWORK');
        await tap(tester, l.onboardingRoleAdvocate);
        await tester.enterText(field(l.onboardingDetailsName), 'Ramesh Sharma');
        await tester.enterText(
          field(l.onboardingDetailsEnrolment),
          'MP/1/2010',
        );
        await tap(tester, l.onboardingDetailsSubmit);
        expect(find.text(l.errorNeedsNetwork), findsOneWidget);
        expect(api.account.memberships, hasLength(1)); // made, reply lost

        api.failAfter.clear();
        await tap(tester, l.onboardingDetailsSubmit);
        expect(api.callNames.where((n) => n == 'createOrg'), hasLength(1));
        expect(
          (api.calls.lastWhere((c) => c.name == 'findCases').args!
              as Map)['orgId'],
          'org-1',
        );
        expect(find.text(l.findingTitle), findsOneWidget);
      },
    );

    testWidgets('reduce motion: steps cross-fade in 100 ms', (tester) async {
      reduceMotion(tester);
      await pumpApp(tester, account: newAccount, overrides: syncedData());
      await tap(tester, l.onboardingRoleAdvocate);
      final route = ModalRoute.of(tester.element(find.text(l.detailsTitle)))!;
      expect(route.transitionDuration, const Duration(milliseconds: 100));
      expect(
        route.reverseTransitionDuration,
        const Duration(milliseconds: 100),
      );
    });

    testWidgets('offline: says so, keeps what was typed', (tester) async {
      final api = await pumpApp(
        tester,
        account: newAccount,
        overrides: syncedData(offline: true),
      );
      await tap(tester, l.onboardingRoleAdvocate);
      expect(find.byType(OfflineBanner), findsOneWidget);
      await tester.enterText(field(l.onboardingDetailsName), 'Ramesh Sharma');
      await tester.enterText(field(l.onboardingDetailsEnrolment), 'MP/1/2010');
      api.offline = true;
      await tap(tester, l.onboardingDetailsSubmit);
      expect(find.text(l.errorNeedsNetwork), findsOneWidget);
      expect(find.text('Ramesh Sharma'), findsOneWidget);
      expect(find.text(l.detailsTitle), findsOneWidget);
    });

    testWidgets(
      'a retry after a failed search reuses the organisation and the key',
      (tester) async {
        reduceMotion(tester);
        final api = await pumpApp(
          tester,
          account: newAccount,
          overrides: syncedData(),
        );
        api
          ..jobs['job-1'] = _job(JobStatus.running)
          ..fail['findCases'] = const ApiException('RATE_LIMITED');
        await tap(tester, l.onboardingRoleAdvocate);
        await tester.enterText(field(l.onboardingDetailsName), 'Ramesh Sharma');
        await tester.enterText(
          field(l.onboardingDetailsEnrolment),
          'MP/1/2010',
        );
        await tap(tester, l.onboardingDetailsSubmit);
        expect(find.text(l.errorTooMany), findsOneWidget);

        api.fail.clear();
        await tap(tester, l.onboardingDetailsSubmit);
        expect(find.text(l.findingTitle), findsOneWidget);
        expect(api.callNames.where((n) => n == 'createOrg'), hasLength(1));
        final keys = api.calls
            .where((c) => c.name == 'findCases')
            .map((c) => (c.args! as Map)['key'])
            .toList();
        expect(keys, hasLength(2));
        expect(keys.toSet(), hasLength(1));
      },
    );
  });

  group('finding', () {
    testWidgets(
      'not started (resumed after a restart): starts only when asked',
      (tester) async {
        final api = await pumpApp(tester, onboardingDone: false);
        expect(find.text(l.findingNotStarted), findsOneWidget);
        expect(api.callNames, isNot(contains('findCases')));
        await tap(tester, l.findingSkip);
        expect(find.text(l.notificationsTitle), findsOneWidget);
      },
    );

    testWidgets('stop keeps what was found and opens Found cases', (
      tester,
    ) async {
      reduceMotion(tester);
      final api = await _pumpFinding(tester, _job(JobStatus.running));
      await tap(tester, l.findingStop);
      expect(api.callNames, contains('cancelJob'));
      expect(find.byType(FoundCasesScreen), findsOneWidget);
    });

    testWidgets('stop after it finished still opens Found cases', (
      tester,
    ) async {
      reduceMotion(tester);
      final api = await _pumpFinding(tester, _job(JobStatus.running));
      api.fail['cancelJob'] = const ApiException('JOB_FINISHED');
      await tap(tester, l.findingStop);
      expect(find.byType(FoundCasesScreen), findsOneWidget);
    });

    testWidgets('continue in the background opens Found cases', (tester) async {
      reduceMotion(tester);
      final api = await _pumpFinding(tester, _job(JobStatus.running));
      await tap(tester, l.findingBackground);
      expect(find.byType(FoundCasesScreen), findsOneWidget);
      expect(api.callNames, isNot(contains('cancelJob')));
    });

    testWidgets('court records down: we keep looking, the user carries on', (
      tester,
    ) async {
      reduceMotion(tester);
      await _pumpFinding(
        tester,
        _job(JobStatus.failed, error: 'COURT_PROVIDER_UNAVAILABLE'),
      );
      expect(find.text(l.errorProviderDown), findsOneWidget);
      expect(find.text(l.foundAddByCnr), findsNothing);
      await tap(tester, l.continueButton);
      expect(find.byType(FoundCasesScreen), findsOneWidget);
    });

    for (final code in [
      'NO_SEARCHABLE_COURTS',
      'COURT_DATA_PAUSED',
      'COURT_DATA_BUDGET_REACHED',
    ]) {
      testWidgets('$code: plain message, Add by CNR, carry on', (tester) async {
        reduceMotion(tester);
        await _pumpFinding(
          tester,
          _job(JobStatus.failed, error: code, found: 0),
        );
        expect(find.text(code), findsNothing);
        expect(find.text(l.errorGeneric), findsNothing);
        await tap(tester, l.foundAddByCnr);
        expect(find.text(l.foundCnrLabel), findsOneWidget);
        await tester.tapAt(const Offset(200, 20)); // the scrim closes the sheet
        await tester.pumpAndSettle();
        await tap(tester, l.continueButton);
        expect(find.text(l.notificationsTitle), findsOneWidget);
      });
    }

    testWidgets('offline: progress so far, the offline banner and a note', (
      tester,
    ) async {
      reduceMotion(tester);
      final api = await _pumpFinding(tester, _job(JobStatus.running));
      api.offline = true;
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.byType(OfflineBanner), findsOneWidget);
      expect(find.text(l.findingOffline), findsOneWidget);
      expect(find.text(l.findingGroupFound(12)), findsOneWidget);

      api.offline = false;
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.byType(OfflineBanner), findsNothing);
    });
  });

  group('notifications', () {
    testWidgets('denied: explains, opens OS settings, carries on', (
      tester,
    ) async {
      final permission = FakePermission(granted: false);
      await pumpApp(
        tester,
        account: juniorAccount,
        onboardingDone: false,
        overrides: [permission.asOverride],
      );
      await tap(tester, l.notifyExplainerAllow);
      expect(find.text(l.notifyExplainerDenied), findsOneWidget);
      await tap(tester, l.notifyExplainerOpenSettings);
      expect(permission.settingsOpened, 1);
      await tap(tester, l.continueButton);
      expect(find.text(l.todayEmpty), findsOneWidget);
    });

    testWidgets('"Not now" finishes without asking', (tester) async {
      final permission = FakePermission();
      await pumpApp(
        tester,
        account: juniorAccount,
        onboardingDone: false,
        overrides: [permission.asOverride],
      );
      await tap(tester, l.notifyExplainerNotNow);
      expect(permission.requests, 0);
      expect(find.text(l.todayEmpty), findsOneWidget);
    });
  });
}

Job _job(JobStatus status, {String? error, int found = 12}) => Job(
  id: 'job-1',
  kind: 'find_cases',
  status: status,
  error: error,
  progress: {
    'found': found,
    'groups': [
      {'key': 'HC', 'state': 'done', 'found': found},
      {
        'key': 'DC',
        'state': status == JobStatus.running ? 'running' : 'done',
        'found': 0,
      },
      const {'key': 'SC', 'state': 'pending', 'found': 0},
    ],
  },
);

/// The Finding screen of a set-up owner who is still onboarding here, following [job] (started with
/// "Find my cases", as after a restart).
Future<FakeApi> _pumpFinding(
  WidgetTester tester,
  Job job, {
  String locale = 'en',
  double scale = 1,
}) async {
  final api = FakeApi(account: ownerAccount)..jobs['job-1'] = job;
  await pumpApp(
    tester,
    api: api,
    onboardingDone: false,
    locale: locale,
    textScale: scale,
    overrides: syncedData(),
  );
  final l = lookupAppLocalizations(Locale(locale));
  await tester.tap(find.text(l.findingStart));
  await tester.pumpAndSettle();
  return api;
}

/// The OS notification prompt, answered with [granted].
class FakePermission extends NotificationPermission {
  FakePermission({this.granted = true});

  final bool granted;
  int requests = 0;
  int settingsOpened = 0;

  Override get asOverride =>
      notificationPermissionProvider.overrideWithValue(this);

  @override
  Future<bool> request() async {
    requests++;
    return granted;
  }

  @override
  Future<void> openSettings() async => settingsOpened++;
}
