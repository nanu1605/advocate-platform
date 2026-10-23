import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/router.dart';
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
    }) => onboardingRedirect(
      location: at,
      hasLanguage: lang,
      signedIn: signedIn,
      consented: consented,
      lockConfigured: lock,
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
    });
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
}
