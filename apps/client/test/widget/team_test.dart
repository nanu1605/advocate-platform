import 'dart:async';

import 'package:advocate_app/core/brand/brand.g.dart';
import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/router.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/diary.dart';
import 'package:advocate_app/features/board/board_share.dart';
import 'package:advocate_app/features/team/team_screen.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';

import '../helpers.dart';

/// A clerk in Sharma Chambers (testMembers' Mohan Lal).
const _clerkAccount = Account(
  id: 'user-4',
  memberships: [
    Membership(
      orgId: 'org-1',
      orgName: 'Sharma Chambers',
      orgKind: 'chamber',
      role: 'clerk',
    ),
  ],
);

/// An open invite for a clerk, bound to one number.
final _oldInvite = Invite(
  id: 'inv-old',
  code: 'QWER7890',
  role: 'clerk',
  phone: '919876543210',
  expiresAt: testNow.add(const Duration(days: 5)),
);

/// Neha Verma has two live cases (and an archived one, not counted), Rakesh Jain one, the others none.
final List<CaseInfo> _cases = [
  caseInfo(1, assigneeId: 'user-3'),
  caseInfo(2, assigneeId: 'user-3'),
  caseInfo(3, assigneeId: 'user-2'),
  caseInfo(4, assigneeId: 'user-3', status: 'archived'),
  caseInfo(5),
];

String _at(WidgetTester tester) =>
    container(tester)
        .read(routerProvider)
        .routerDelegate
        .currentConfiguration
        .uri
        .toString();

Future<FakeApi> _open(
  WidgetTester tester, {
  String locale = 'en',
  double scale = 1,
  Account account = ownerAccount,
  List<Invite> invites = const [],
  List<OrgMember> members = testMembers,
  List<Override> overrides = const [],
  bool offline = false,
}) async {
  final api = FakeApi(account: account);
  api.invites.addAll(invites);
  if (offline) {
    api.fail['listInvites'] = const ApiException('NETWORK', retryable: true);
  }
  await pumpApp(
    tester,
    location: '/team',
    api: api,
    locale: locale,
    textScale: scale,
    onboardingDone: true,
    overrides: [
      ...FakeCases(cases: _cases, members: members).overrides,
      ...overrides,
    ],
  );
  // Signed in and synced, then the connection went.
  api.offline = offline;
  return api;
}

/// Scrolls the Team list until [f] is on screen.
Future<void> _show(WidgetTester tester, Finder f) => tester.scrollUntilVisible(
  f,
  200,
  scrollable: find
      .descendant(
        of: find.byType(TeamScreen),
        matching: find.byType(Scrollable),
      )
      .first,
);

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Finder _inSheet(Finder f) =>
    find.descendant(of: find.byType(BottomSheet), matching: f);

/// Team (spec §4.4 F16, §15.3; ADR 0017): members, the owner's actions and invites, at 1.0 and 2.0 in English and
/// Hindi.
void main() {
  setUpAll(loadAppFonts);

  for (final locale in ['en', 'hi']) {
    final l = lookupAppLocalizations(Locale(locale));
    for (final scale in [1.0, 2.0]) {
      group('$locale ${scale}x', () {
        testWidgets(
          'the owner sees members with role, "you" and assigned cases, and pending invites',
          (tester) async {
            final api = await _open(
              tester,
              locale: locale,
              scale: scale,
              invites: [_oldInvite],
            );
            expect(find.text(l.teamMemberMe('Ramesh Sharma')), findsOneWidget);
            expect(
              find.text('${l.teamDataRoleOwner} · ${l.teamAssignedCases(0)}'),
              findsOneWidget,
            );
            expect(
              find.text(
                '${l.teamDataRoleAdvocate} · ${l.teamAssignedCases(2)}',
              ),
              findsOneWidget,
            );
            // Screen readers hear the role and the count as one phrase.
            final semantics = tester.ensureSemantics();
            await tester.pump();
            expect(
              find.bySemanticsLabel(
                RegExp('${l.teamDataRoleAdvocate}, ${l.teamAssignedCases(2)}'),
              ),
              findsOneWidget,
            );
            await _show(tester, find.text('Mohan Lal'));
            expect(
              find.text('${l.teamDataRoleJunior} · ${l.teamAssignedCases(1)}'),
              findsOneWidget,
            );
            // A clerk with nothing assigned shows only the role.
            expect(find.text(l.teamDataRoleClerk), findsOneWidget);
            // The owner's own row has no actions; the others do.
            expect(
              find.byTooltip(l.boardMoreActions('Ramesh Sharma')),
              findsNothing,
            );
            expect(find.byTooltip(l.boardMoreActions('Mohan Lal')), findsOne);
            await _show(tester, find.text('QWER7890'));
            expect(
              find.textContaining(l.teamInviteOnlyShort('+91 98765 43210')),
              findsOneWidget,
            );
            expect(api.callNames, contains('listInvites'));
            // Screen readers hear the code letter by letter, and pauses for the dots.
            expect(
              find.bySemanticsLabel(RegExp('^Q W E R 7 8 9 0')),
              findsOneWidget,
            );
            semantics.dispose();
            expect(tester.takeException(), isNull);
          },
        );

        testWidgets('a clerk sees the list only', (tester) async {
          final api = await _open(
            tester,
            locale: locale,
            scale: scale,
            account: _clerkAccount,
          );
          await _show(tester, find.text(l.teamOwnerOnly));
          expect(find.text(l.teamMemberMe('Mohan Lal')), findsOneWidget);
          expect(find.text(l.teamInvite), findsNothing);
          expect(find.byIcon(AppIcons.dotsThreeVertical), findsNothing);
          expect(api.callNames, isNot(contains('listInvites')));
          expect(tester.takeException(), isNull);
        });

        testWidgets(
          'invite: role and number, then the code to share or copy; it joins the pending list',
          (tester) async {
            final shared = <ShareParams>[];
            String? copied;
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
              SystemChannels.platform,
              (call) async {
                if (call.method == 'Clipboard.setData') {
                  copied = (call.arguments as Map)['text'] as String?;
                }
                return null;
              },
            );
            addTearDown(
              () => tester.binding.defaultBinaryMessenger
                  .setMockMethodCallHandler(SystemChannels.platform, null),
            );
            final api = await _open(
              tester,
              locale: locale,
              scale: scale,
              overrides: [
                shareProvider.overrideWithValue((p) async => shared.add(p)),
              ],
            );
            await _tap(tester, find.text(l.teamInvite));
            expect(find.text(l.teamInviteTitle), findsOneWidget);
            await _tap(tester, _inSheet(find.text(l.teamDataRoleClerk)));
            await tester.enterText(
              find.widgetWithText(TextField, l.teamInvitePhone),
              '9876543210',
            );
            await _tap(tester, find.text(l.teamInviteCreate));
            expect(api.calls.last.args, {
              'role': 'clerk',
              'phone': '9876543210',
            });
            expect(find.text('ABCD2345'), findsOneWidget);
            expect(
              find.text(l.teamInviteOnly('+91 98765 43210')),
              findsOneWidget,
            );
            expect(find.text(l.teamInviteNotSent), findsOneWidget);
            expect(tester.takeException(), isNull);

            await _tap(tester, find.text(l.teamShareInvite));
            // In the app's language (the exact wording is checked in test/unit/team_dashboard_test.dart).
            expect(
              shared.single.text,
              l.teamShareText(Brand.appName, 'ABCD2345'),
            );
            // Never the number it is bound to.
            expect(shared.single.text, isNot(contains('9876543210')));

            await _tap(tester, find.text(l.teamCopyCode));
            expect(copied, 'ABCD2345');
            expect(find.text(l.teamCopied), findsOneWidget);

            await _tap(tester, find.text(l.close));
            expect(find.byType(BottomSheet), findsNothing);
            await _show(tester, find.text('ABCD2345'));
            expect(find.text('ABCD2345'), findsOneWidget);
          },
        );

        testWidgets(
          'invite: a bad number is caught before sending; a full team says how to make room and keeps the input',
          (tester) async {
            final api = await _open(tester, locale: locale, scale: scale);
            await _tap(tester, find.text(l.teamInvite));
            final phone = find.widgetWithText(TextField, l.teamInvitePhone);
            await tester.enterText(phone, '12345');
            await _tap(tester, find.text(l.teamInviteCreate));
            expect(find.text(l.phoneInvalid), findsOneWidget);
            expect(api.callNames, isNot(contains('createInvite')));

            api.fail['createInvite'] = const ApiException(
              'TEAM_LIMIT',
              details: {'limit': 10},
            );
            await tester.enterText(phone, '9876543210');
            await _tap(tester, find.text(l.teamInviteCreate));
            expect(find.text(l.teamLimit(10)), findsOneWidget);
            expect(find.text('9876543210'), findsOneWidget);
            expect(find.text(l.teamInviteCreate), findsOneWidget);
            expect(tester.takeException(), isNull);
          },
        );

        testWidgets(
          'offline: invites say they need a connection; the sheet keeps the input until it can send',
          (tester) async {
            final api = await _open(
              tester,
              locale: locale,
              scale: scale,
              offline: true,
            );
            await _show(tester, find.text(l.errorNeedsNetwork));
            await _show(tester, find.text(l.retry));
            expect(find.text(l.retry), findsOneWidget);
            await _tap(tester, find.text(l.teamInvite));
            await tester.enterText(
              find.widgetWithText(TextField, l.teamInvitePhone),
              '9876543210',
            );
            await _tap(tester, find.text(l.teamInviteCreate));
            expect(_inSheet(find.text(l.errorNeedsNetwork)), findsOneWidget);
            expect(find.text('9876543210'), findsOneWidget);
            expect(tester.takeException(), isNull);

            api.offline = false;
            await _tap(tester, find.text(l.teamInviteCreate));
            expect(find.text('ABCD2345'), findsOneWidget);
          },
        );

        testWidgets('revoke asks first, then the code is gone', (tester) async {
          final api = await _open(
            tester,
            locale: locale,
            scale: scale,
            invites: [_oldInvite],
          );
          final revoke = find.byTooltip(l.teamRevokeTooltip('QWER7890'));
          await _show(tester, revoke);
          await _tap(tester, revoke);
          expect(find.text(l.teamRevokeBody('QWER7890')), findsOneWidget);
          await _tap(tester, find.text(l.cancel));
          expect(api.callNames, isNot(contains('revokeInvite')));
          await _tap(tester, revoke);
          await _tap(tester, find.text(l.teamRevoke));
          expect(api.calls.last.name, 'listInvites');
          expect(
            api.calls.where((c) => c.name == 'revokeInvite').single.args,
            'inv-old',
          );
          expect(find.text('QWER7890'), findsNothing);
          expect(find.text(l.teamRevoked), findsOneWidget);
        });

        testWidgets('change role: the owner picks another role', (
          tester,
        ) async {
          final api = await _open(tester, locale: locale, scale: scale);
          await _tap(tester, find.byTooltip(l.boardMoreActions('Neha Verma')));
          await _tap(tester, find.text(l.teamChangeRole));
          expect(find.text(l.teamRoleTitle('Neha Verma')), findsOneWidget);
          await _tap(tester, _inSheet(find.text(l.teamDataRoleJunior)));
          expect(api.calls.last.args, {'userId': 'user-3', 'role': 'junior'});
          expect(
            find.text(l.teamRoleChanged('Neha Verma', l.teamDataRoleJunior)),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        });

        testWidgets(
          'edit name: kept in the dialog when it fails, saved when it can',
          (tester) async {
            final api = await _open(tester, locale: locale, scale: scale);
            await _tap(
              tester,
              find.byTooltip(l.boardMoreActions('Neha Verma')),
            );
            await _tap(tester, find.text(l.teamEditName));
            final field = find.widgetWithText(TextField, l.teamNameLabel);
            await tester.enterText(field, 'Neha V.');
            api.offline = true;
            await _tap(tester, find.text(l.casePageSave));
            expect(find.byType(AlertDialog), findsOneWidget);
            expect(find.text(l.errorNeedsNetwork), findsOneWidget);
            expect(find.text('Neha V.'), findsOneWidget);
            expect(tester.takeException(), isNull);
            api.offline = false;
            await _tap(tester, find.text(l.casePageSave));
            expect(find.byType(AlertDialog), findsNothing);
            expect(api.calls.last.args, {
              'userId': 'user-3',
              'displayName': 'Neha V.',
            });
            expect(find.text(l.teamNameSaved), findsOneWidget);
          },
        );

        testWidgets(
          'remove asks first (naming their assigned cases); the member leaves the list',
          (tester) async {
            final api = await _open(tester, locale: locale, scale: scale);
            final menu = find.byTooltip(l.boardMoreActions('Neha Verma'));
            await _tap(tester, menu);
            await _tap(tester, find.text(l.teamRemove));
            expect(find.text(l.teamRemoveTitle('Neha Verma')), findsOneWidget);
            expect(
              find.text('${l.teamRemoveBody} ${l.teamRemoveAssigned(2)}'),
              findsOneWidget,
            );
            expect(tester.takeException(), isNull);
            await _tap(tester, find.text(l.cancel));
            expect(api.callNames, isNot(contains('updateMember')));
            await _tap(tester, menu);
            await _tap(tester, find.text(l.teamRemove));
            await _tap(tester, find.text(l.teamRemoveConfirm));
            expect(api.calls.last.args, {
              'userId': 'user-3',
              'status': 'removed',
            });
            expect(find.text('Neha Verma'), findsNothing);
            expect(find.text(l.teamRemoved('Neha Verma')), findsOneWidget);
          },
        );

        testWidgets(
          "a member's assigned cases open the Cases list filtered to them",
          (tester) async {
            await _open(tester, locale: locale, scale: scale);
            await _show(tester, find.text('Mohan Lal'));
            // Nothing assigned: not a link.
            await tester.ensureVisible(find.text('Mohan Lal'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Mohan Lal'));
            await tester.pumpAndSettle();
            expect(_at(tester), '/team');
            await _show(tester, find.text('Neha Verma'));
            await _tap(tester, find.text('Neha Verma'));
            expect(_at(tester), '/cases');
            expect(
              container(tester).read(caseFilterProvider).assigneeId,
              'user-3',
            );
          },
        );
      });
    }
  }

  final en = lookupAppLocalizations(const Locale('en'));

  testWidgets('an owner on their own is asked to invite someone', (
    tester,
  ) async {
    await _open(tester, members: [testMembers.first]);
    expect(find.text(en.teamAloneHint), findsOneWidget);
    await _tap(tester, find.text(en.teamInviteSomeone));
    expect(find.text(en.teamInviteTitle), findsOneWidget);
  });

  testWidgets('an invite already used or revoked elsewhere: said, and the list '
      'refreshed', (tester) async {
    final api = await _open(tester, invites: [_oldInvite]);
    api.fail['revokeInvite'] = const ApiException('NOT_FOUND', status: 404);
    final revoke = find.byTooltip(en.teamRevokeTooltip('QWER7890'));
    await _show(tester, revoke);
    await _tap(tester, revoke);
    await _tap(tester, find.text(en.teamRevoke));
    expect(find.text(en.teamInviteGone), findsOneWidget);
    expect(api.calls.last.name, 'listInvites');
  });

  testWidgets('someone joining with the code takes their invite off the list', (
    tester,
  ) async {
    final members = StreamController<List<OrgMember>>()..add(testMembers);
    addTearDown(members.close);
    final api = FakeApi(account: ownerAccount)..invites.add(_oldInvite);
    await pumpApp(
      tester,
      location: '/team',
      api: api,
      onboardingDone: true,
      overrides: [
        clockProvider.overrideWithValue(() => testNow),
        orgMembersProvider.overrideWith((_) => members.stream),
        ...FakeCases(cases: _cases).caseOverrides,
      ],
    );
    await _show(tester, find.text('QWER7890'));
    // The clerk accepts the invite (task 7's join), and their membership syncs while the owner looks on.
    api.invites.clear();
    members.add([
      ...testMembers,
      const OrgMember(userId: 'user-9', role: 'clerk', name: 'Sunil Kumar'),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('Sunil Kumar'), findsOneWidget);
    expect(find.text('QWER7890'), findsNothing);
  });

  testWidgets('leaving while a revoke is still sending is fine', (
    tester,
  ) async {
    final api = await _open(tester, invites: [_oldInvite]);
    final gate = api.gates['revokeInvite'] = Completer<void>();
    final revoke = find.byTooltip(en.teamRevokeTooltip('QWER7890'));
    await _show(tester, revoke);
    await _tap(tester, revoke);
    await tester.tap(find.text(en.teamRevoke));
    await tester.pump();
    container(tester).read(routerProvider).go('/today');
    await tester.pumpAndSettle();
    expect(find.byType(TeamScreen), findsNothing);
    gate.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text(en.teamRevoked), findsNothing);
  });
}
