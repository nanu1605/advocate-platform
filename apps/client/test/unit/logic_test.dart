import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/router.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/device.dart';
import 'package:advocate_app/ui/fields.dart';
import 'package:advocate_app/ui/tiles.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  group('onboardingRedirect', () {
    String? go(
      String at, {
      bool lang = true,
      bool signedIn = true,
      bool consented = true,
      bool lock = true,
      bool? done = true,
      AccountStage? stage = AccountStage.owner,
    }) => onboardingRedirect(
      location: at,
      hasLanguage: lang,
      signedIn: signedIn,
      consented: consented,
      lockConfigured: lock,
      onboardingDone: done,
      stage: stage,
    );

    test('walks language → sign-in → consent → app lock → today', () {
      expect(go('/today', lang: false), '/welcome');
      expect(go('/welcome', lang: false), isNull);
      expect(go('/welcome', signedIn: false), '/sign-in');
      expect(go('/sign-in/otp', signedIn: false), isNull);
      expect(go('/cases', signedIn: false), '/sign-in');
      expect(go('/sign-in/otp', consented: false), '/consent');
      expect(go('/consent', lock: false), '/app-lock');
      expect(go('/app-lock'), '/today');
    });

    test('deep links pass once onboarding is done', () {
      expect(go('/cases'), isNull);
      expect(go('/settings'), isNull);
      expect(go('/found'), isNull);
      expect(go('/join/ABC123'), isNull);
      expect(go('/onboarding/notifications'), '/today');
      expect(go('/loading'), '/today');
    });

    test('waits on /loading for the account instead of guessing a step', () {
      expect(go('/app-lock', done: null, stage: null), '/loading');
      expect(go('/today', done: false, stage: null), '/loading');
      expect(go('/loading', done: null, stage: null), isNull);
      // A finished device needs no account to open the app (offline start).
      expect(go('/today', stage: null), isNull);
    });

    test('a new account: role → details → finding → found → notifications', () {
      for (final done in [null, false]) {
        String? at(String location, AccountStage stage) =>
            go(location, done: done, stage: stage);
        expect(at('/app-lock', AccountStage.noOrg), '/onboarding/role');
        expect(at('/loading', AccountStage.noOrg), '/onboarding/role');
        for (final free in [
          '/onboarding/role',
          '/onboarding/join',
          '/join/ABC123',
          '/onboarding/details',
        ]) {
          expect(at(free, AccountStage.noOrg), isNull, reason: free);
        }
        expect(at('/today', AccountStage.noOrg), '/onboarding/role');
        expect(at('/found', AccountStage.noOrg), '/onboarding/role');
        expect(
          at('/onboarding/role', AccountStage.needsDetails),
          '/onboarding/details',
        );
      }
      // Once this device is onboarding (false), a set-up account carries on instead of skipping to Today.
      expect(go('/onboarding/details', done: false), '/onboarding/finding');
      expect(go('/onboarding/finding', done: false), isNull);
      expect(go('/found', done: false), isNull);
      expect(go('/onboarding/notifications', done: false), isNull);
      expect(go('/today', done: false), '/onboarding/finding');
    });

    test(
      'someone who joined a team skips details, finding and found cases',
      () {
        const member = AccountStage.member;
        expect(
          go('/onboarding/join', done: false, stage: member),
          '/onboarding/notifications',
        );
        expect(
          go('/found', done: false, stage: member),
          '/onboarding/notifications',
        );
      },
    );

    test('removed from the only team: back to the role step, never an empty '
        'Today', () {
      const none = AccountStage.noOrg;
      expect(go('/today', stage: none), '/onboarding/role');
      expect(go('/cases/m-1', stage: none), '/onboarding/role');
      expect(go('/onboarding/notifications', stage: none), '/onboarding/role');
      // From there: join another team by code, or set up on their own.
      expect(go('/onboarding/role', stage: none), isNull);
      expect(go('/onboarding/join', stage: none), isNull);
      expect(go('/join/ABCD2345', stage: none), isNull);
      expect(go('/onboarding/details', stage: none), isNull);
      // Offline start (no account loaded): the finished device stays put.
      expect(go('/today', stage: null), isNull);
    });

    test(
      'a set-up account on a new device counts as done (no second search)',
      () {
        expect(go('/loading', done: null), '/today');
        expect(
          go('/loading', done: null, stage: AccountStage.member),
          '/today',
        );
        expect(
          go('/loading', done: null, stage: AccountStage.needsDetails),
          '/onboarding/details',
        );
      },
    );
  });

  group('Account.stage', () {
    Account account({String? role, bool details = true}) => Account(
      id: 'u',
      fullName: details ? 'Ramesh Sharma' : ' ',
      enrolmentNo: 'MP/1/2010',
      barCouncilState: 'MP',
      memberships: [
        if (role != null)
          Membership(orgId: 'o', orgName: 'O', orgKind: 'solo', role: role),
      ],
    );

    test('maps role and details to the onboarding step (spec §9.2)', () {
      expect(account().stage, AccountStage.noOrg);
      expect(
        account(role: 'owner', details: false).stage,
        AccountStage.needsDetails,
      );
      expect(account(role: 'owner').stage, AccountStage.owner);
      expect(
        account(role: 'junior', details: false).stage,
        AccountStage.member,
      );
      expect(account(role: 'clerk', details: false).stage, AccountStage.member);
      expect(account(role: 'advocate').stage, AccountStage.member);
    });
  });

  group('errorText', () {
    const codes = [
      'NETWORK',
      'UNAUTHENTICATED',
      'RATE_LIMITED',
      'IDEMPOTENCY_IN_PROGRESS',
      'VALIDATION_ERROR',
      'NOT_FOUND',
      'FORBIDDEN',
      'ROLE_NOT_ALLOWED',
      'PROFILE_INCOMPLETE',
      'INVITE_INVALID',
      'ALREADY_MEMBER',
      'TEAM_LIMIT',
      'NOT_A_MEMBER',
      'TRACKED_CASE_LIMIT',
      'FOUND_CASE_ADDED',
      'JOB_FINISHED',
      'INVALID_CNR',
      'COURT_PROVIDER_UNAVAILABLE',
      'NO_SEARCHABLE_COURTS',
      'COURT_DATA_PAUSED',
      'COURT_DATA_BUDGET_REACHED',
      'SEARCH_TERMS_REQUIRED',
      'SEARCH_DAILY_CAP',
      'COURT_REQUIRED',
      'UNKNOWN_COURT',
      'MANUAL_CASE',
      'TRACKING_OFF',
      'NO_CNR',
      'DOCUMENT_NOT_READY',
      'DOCUMENT_QUARANTINED',
      'ORDER_PDF_UNAVAILABLE',
      'ORDER_PDF_FETCHING',
    ];

    for (final locale in ['en', 'hi']) {
      final l = lookupAppLocalizations(Locale(locale));

      test('every known code has its own text, never the code ($locale)', () {
        for (final code in codes) {
          final text = errorText(l, ApiException(code));
          expect(text, isNot(l.errorGeneric), reason: code);
          expect(text, isNot(contains(code)), reason: code);
        }
      });

      test('unknown codes and other errors get the generic text ($locale)', () {
        expect(
          errorText(l, const ApiException('SOMETHING_NEW')),
          l.errorGeneric,
        );
        expect(errorText(l, const ApiException('INTERNAL')), l.errorGeneric);
        expect(errorText(l, StateError('x')), l.errorGeneric);
        expect(errorText(l, null), l.errorGeneric);
      });

      test('job error codes map like API codes ($locale)', () {
        expect(errorText(l, 'COURT_PROVIDER_UNAVAILABLE'), l.errorProviderDown);
        expect(errorText(l, 'NO_SEARCHABLE_COURTS'), l.errorNoSearchableCourts);
      });

      test('the allowance error says how many more cases fit ($locale)', () {
        const e = ApiException(
          'TRACKED_CASE_LIMIT',
          details: {'limit': 100, 'remaining': 3},
        );
        expect(errorText(l, e), l.errorTrackedCaseLimit(3));
        expect(errorText(l, e), contains('3'));
        const noRemaining = ApiException(
          'TRACKED_CASE_LIMIT',
          details: {'limit': 100},
        );
        expect(errorText(l, noRemaining), l.errorTrackedCaseLimit(0));
      });
    }
  });

  group('Formats', () {
    setUpAll(() async {
      await initializeDateFormatting('en');
      await initializeDateFormatting('hi');
    });
    final d = DateTime(2026, 11, 5, 19, 30);

    test('dates in English and Hindi (spec §5.10)', () {
      expect(Formats(const Locale('en')).date(d), 'Thu, 5 Nov 2026');
      expect(Formats(const Locale('hi')).date(d), 'गुरु, 5 नवंबर 2026');
    });

    test('12-hour time', () {
      expect(Formats(const Locale('en')).time(d), '7:30 pm');
      expect(Formats(const Locale('hi')).time(d), 'शाम 7:30');
    });

    test('Indian grouping, paise in', () {
      expect(Formats(const Locale('en')).money(12500000), '₹1,25,000');
      expect(Formats(const Locale('hi')).money(12550), '₹125.50');
    });

    test('DD-MM-YYYY entry round-trips and rejects impossible dates', () {
      expect(Formats.entry(d), '05-11-2026');
      expect(Formats.parseEntry('05-11-2026'), DateTime(2026, 11, 5));
      expect(Formats.parseEntry('31-02-2026'), isNull);
      expect(Formats.parseEntry('5-11-2026'), isNull);
    });
  });

  test('Indian mobile numbers', () {
    expect(isValidIndianMobile('9876543210'), isTrue);
    expect(isValidIndianMobile('5876543210'), isFalse);
    expect(isValidIndianMobile('98765'), isFalse);
  });

  test('uuidV4 shape', () {
    final id = uuidV4(Random(1));
    expect(
      id,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    expect(uuidV4(), isNot(uuidV4()));
  });

  test('avatar initials in both scripts', () {
    expect(Avatar.initials('Ramesh Kumar Sharma'), 'RK');
    expect(Avatar.initials('रमेश शर्मा'), 'रश');
    expect(Avatar.initials('  priya  '), 'P');
  });

  test(
    'every English string has a Hindi translation and vice versa (spec §16.4)',
    () {
      Set<String> keys(String f) =>
          (json.decode(File(f).readAsStringSync()) as Map<String, dynamic>).keys
              .where((k) => !k.startsWith('@'))
              .toSet();
      final en = keys('l10n/app_en.arb');
      final hi = keys('l10n/app_hi.arb');
      expect(en.difference(hi), isEmpty, reason: 'missing in app_hi.arb');
      expect(hi.difference(en), isEmpty, reason: 'missing in app_en.arb');
    },
  );

  test('Hindi =1 branches print the count, never a literal 1', () {
    // intl puts Hindi 0 in the "one" category, so =1{1 केस} would read "1 केस" for a count of 0.
    final hi = File('l10n/app_hi.arb').readAsStringSync();
    expect(RegExp(r'=1\{[^{}]*(?<![\d\w])1(?![\d\w])').hasMatch(hi), isFalse);
    expect(
      lookupAppLocalizations(const Locale('hi')).pages(0),
      isNot(contains('1')),
    );
  });
}
