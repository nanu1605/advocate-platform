@Tags(['golden'])
library;

import 'package:advocate_app/app.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

/// Team goldens (spec §4.4 F16): the owner's list (members, assigned cases, a pending invite) and the invite sheet's
/// code, × light/dark/sunlight × en/hi × text scale 1.0/2.0. Reference images are rendered on Windows; CI runs this
/// file on windows-latest.
void main() {
  setUpAll(loadAppFonts);
  final cases = [
    caseInfo(1, assigneeId: 'user-3'),
    caseInfo(2, assigneeId: 'user-3'),
    caseInfo(3, assigneeId: 'user-2'),
  ];

  for (final screen in ['owner_phone', 'invite_ready']) {
    for (final MapEntry(key: name, value: theme) in themes.entries) {
      for (final locale in ['en', 'hi']) {
        for (final scale in [1.0, 2.0]) {
          testWidgets('team $screen $name $locale ${scale}x', (tester) async {
            final l = lookupAppLocalizations(Locale(locale));
            final api = FakeApi(account: ownerAccount);
            api.invites.add(
              Invite(
                id: 'inv-old',
                code: 'QWER7890',
                role: 'clerk',
                phone: '919876543210',
                expiresAt: testNow.add(const Duration(days: 5)),
              ),
            );
            await pumpApp(
              tester,
              location: '/team',
              api: api,
              locale: locale,
              theme: theme,
              textScale: scale,
              onboardingDone: true,
              overrides: FakeCases(cases: cases).overrides,
            );
            if (screen == 'invite_ready') {
              await tester.tap(find.text(l.teamInvite));
              await tester.pumpAndSettle();
              await tester.enterText(
                find.widgetWithText(TextField, l.teamInvitePhone),
                '9876543210',
              );
              final create = find.text(l.teamInviteCreate);
              await tester.ensureVisible(create);
              await tester.pumpAndSettle();
              await tester.tap(create);
              await tester.pumpAndSettle();
            }
            await expectLater(
              find.byType(App),
              matchesGoldenFile(
                'goldens/team/${screen}_${name}_${locale}_${scale}x.png',
              ),
            );
          });
        }
      }
    }
  }
}
