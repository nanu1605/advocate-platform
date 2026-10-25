import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/dashboard.dart';
import 'package:advocate_app/data/diary.dart';
import 'package:advocate_app/data/team.dart';
import 'package:advocate_app/features/team/invite_sheet.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';
import 'sync_db.dart';

const _chamberOwner = Membership(
  orgId: 'org-1',
  orgName: 'Sharma Chambers',
  orgKind: 'chamber',
  role: 'owner',
);

/// Thu 5 Nov 2026 IST is [testNow]'s day; its week runs Mon 2 to Sun 8 Nov.
DateTime _day(int d) => DateTime.utc(2026, 11, d);

/// The team list and the dashboard's counts over the queries tasks 8–10 already run (faked as in widget tests).
void main() {
  // IST now listens for the app resuming.
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer container(List<Override> overrides) {
    final c = ProviderContainer(overrides: overrides);
    addTearDown(c.dispose);
    return c;
  }

  final cases = FakeCases(
    cases: [
      caseInfo(1, nextDate: _day(5), assigneeId: 'user-3'),
      caseInfo(2, nextDate: _day(7), assigneeId: 'user-2'),
      caseInfo(3, nextDate: _day(12), assigneeId: 'user-3'),
      caseInfo(4, courtStatus: 'disposed', assigneeId: 'user-3'),
      caseInfo(5, status: 'archived', assigneeId: 'user-2'),
      caseInfo(6, tracking: 'manual'),
    ],
    hearings: {
      // The same day as m-1's next date: counted once.
      'm-1': [CaseHearing(id: 'h-1', date: _day(5))],
      'm-6': [CaseHearing(id: 'h-6', date: _day(3), source: 'manual')],
    },
  );

  group('team', () {
    test(
      'active members, owner first, with their unarchived assigned cases',
      () async {
        final c = container([
          ...cases.overrides,
          currentUserIdProvider.overrideWithValue('user-2'),
        ]);
        final team = await firstValue(c, teamProvider);
        expect(team.map((m) => m.userId), [
          'user-1',
          'user-3',
          'user-2',
          'user-4',
        ]);
        expect(team.map((m) => m.assignedCases), [0, 3, 1, 0]);
        expect(team.where((m) => m.me).single.userId, 'user-2');
        expect(team.first.owner, isTrue);
      },
    );

    test('only the owner manages the team', () {
      for (final (role, manages) in [
        ('owner', true),
        ('advocate', false),
        ('junior', false),
        ('clerk', false),
      ]) {
        final c = container([
          currentOrgProvider.overrideWithValue(
            Membership(
              orgId: 'o',
              orgName: 'O',
              orgKind: 'chamber',
              role: role,
            ),
          ),
        ]);
        expect(c.read(managesTeamProvider), manages, reason: role);
      }
    });

    test('role names in both languages (Appendix C)', () {
      final hi = lookupAppLocalizations(const Locale('hi'));
      expect(
        [
          for (final r in ['owner', ...memberRoles]) roleLabel(hi, r),
        ],
        ['मालिक', 'अधिवक्ता', 'जूनियर अधिवक्ता', 'मुंशी'],
      );
    });

    // Widget tests also run under the pseudo-locale, so the exact wording is checked here.
    test('the invite message as it reads, with the link once there is one', () {
      final en = lookupAppLocalizations(const Locale('en'));
      final hi = lookupAppLocalizations(const Locale('hi'));
      final invite = Invite(
        id: 'inv-1',
        code: 'ABCD2345',
        role: 'junior',
        expiresAt: testNow,
      );
      expect(
        inviteShareText(en, invite),
        'Join my chamber on Pairavi. Code: ABCD2345. '
        'The code works for 7 days.',
      );
      expect(
        inviteShareText(hi, invite),
        'Pairavi पर मेरे चैंबर से जुड़ें। कोड: ABCD2345। यह कोड 7 दिन तक चलेगा।',
      );
      final linked = Invite(
        id: 'inv-1',
        code: 'ABCD2345',
        role: 'junior',
        expiresAt: testNow,
        link: 'https://pairavi.in/join/ABCD2345',
      );
      expect(
        inviteShareText(en, linked),
        'Join my chamber on Pairavi. Code: ABCD2345. '
        'https://pairavi.in/join/ABCD2345 The code works for 7 days.',
      );
      expect(
        inviteShareText(hi, linked),
        contains('https://pairavi.in/join/ABCD2345'),
      );
    });
  });

  group('dashboard', () {
    List<Override> overrides(Membership org) {
      final diary = FakeDiary(
        tasks: [
          DueTask(
            id: 't1',
            title: 'Reply',
            dueAt: DateTime.utc(2026, 11, 4, 6),
            overdue: true,
          ),
          // 09:00 IST today: before 10:00 IST now.
          DueTask(
            id: 't2',
            title: 'Vakalatnama',
            dueAt: DateTime.utc(2026, 11, 5, 3, 30),
          ),
          DueTask(
            id: 't3',
            title: 'Brief',
            dueAt: DateTime.utc(2026, 11, 5, 11, 30),
          ),
        ],
        orders: const [
          DiaryNotice(id: 'n1', kind: 'new_order', matterId: 'm-1'),
          DiaryNotice(id: 'n2', kind: 'new_order', matterId: 'm-2'),
        ],
      );
      return [
        ...diary.overrides,
        ...cases.caseOverrides,
        currentOrgProvider.overrideWithValue(org),
        currentUserIdProvider.overrideWithValue('user-1'),
      ];
    }

    test(
      'counts: active cases, hearings this week, overdue tasks, new orders',
      () async {
        final c = container(overrides(_chamberOwner));
        final d = await firstValue(c, dashboardProvider);
        expect(d.activeCases, 4); // not disposed m-4, not archived m-5
        // m-1 (5 Nov, once), m-2 (7 Nov), m-6 (3 Nov); m-3 is next week.
        expect(d.hearingsThisWeek, 3);
        expect(d.overdueTasks, 2);
        expect(d.newOrders, 2);
        expect(d.empty, isFalse);
      },
    );

    test("a chamber owner sees each member's cases heard this week; clerks and others no row", () async {
      final owner = await firstValue(
        container(overrides(_chamberOwner)),
        dashboardProvider,
      );
      expect(
        [for (final t in owner.team) (t.member.userId, t.cases)],
        [('user-1', 0), ('user-3', 1), ('user-2', 1)],
      );
      const advocate = Membership(
        orgId: 'org-1',
        orgName: 'Sharma Chambers',
        orgKind: 'chamber',
        role: 'advocate',
      );
      final other = await firstValue(
        container(overrides(advocate)),
        dashboardProvider,
      );
      expect(other.team, isEmpty);
    });

    test('an empty solo practice: nothing to count, no team row', () async {
      final c = container([
        ...FakeDiary(members: [testMembers.first]).overrides,
        ...FakeCases().caseOverrides,
        currentOrgProvider.overrideWithValue(ownerAccount.org),
      ]);
      final d = await firstValue(c, dashboardProvider);
      expect(d.empty, isTrue);
      expect(d.team, isEmpty);
    });

    test(
      'cases all disposed or archived: zeros, not the empty state',
      () async {
        final c = container([
          ...FakeDiary(members: [testMembers.first]).overrides,
          ...FakeCases(
            cases: [
              caseInfo(1, courtStatus: 'disposed'),
              caseInfo(2, status: 'archived'),
            ],
          ).caseOverrides,
          currentOrgProvider.overrideWithValue(ownerAccount.org),
        ]);
        final d = await firstValue(c, dashboardProvider);
        expect(d.activeCases, 0);
        expect(d.empty, isFalse);
      },
    );
  });
}
