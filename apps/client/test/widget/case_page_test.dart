import 'dart:async';

import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/router.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/case_text.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/features/board/board_share.dart';
import 'package:advocate_app/features/case_page/case_page.dart';
import 'package:advocate_app/features/case_page/case_page_text.dart';
import 'package:advocate_app/features/case_page/links.dart';
import 'package:advocate_app/features/cases/cases_screen.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';

import '../helpers.dart';

final AppLocalizations en = lookupAppLocalizations(const Locale('en'));
final AppLocalizations hi = lookupAppLocalizations(const Locale('hi'));
final _today = DateTime.utc(2026, 11, 5);

/// IST day [d] of November 2026.
DateTime nov(int d) => DateTime.utc(2026, 11, d);

/// The case page's sample (testNow: Thu 5 Nov 2026, 10:00 IST). WP 1001/2024 (m-1) is auto-tracked and listed today,
/// before Justice A. B. Sharma at the admission stage, assigned to Neha. Its timeline: today's hearing, the 28 Oct
/// order (unread) and hearing (court next date 5 Nov; the user noted 6 Nov, with a note). Three documents (ready,
/// being checked, quarantined), a team and a private note, three tasks, a deadline and client Suresh Patel. WP 1002
/// (m-2) is a manual case at an "Other court" with one hearing on 12 Nov; WP 1003 (m-3) has tracking off and no
/// next date.
FakeCases sampleCases({List<CaseInfo>? cases}) => FakeCases(
  cases:
      cases ??
      [
        caseInfo(
          1,
          nextDate: _today,
          judge: 'Justice A. B. Sharma',
          stage: 'Admission',
          assigneeId: 'user-3',
          assigneeName: 'Neha Verma',
        ),
        caseInfo(
          2,
          tracking: 'manual',
          courtName: 'Family Court, Indore',
          courtNo: '3',
          nextDate: nov(12),
        ),
        caseInfo(3, tracking: 'off'),
      ],
  hearings: {
    'm-1': [
      CaseHearing(
        id: 'h-1',
        date: _today,
        courtNo: '12',
        itemNo: '23',
        purpose: 'Admission',
      ),
      CaseHearing(
        id: 'h-2',
        date: DateTime.utc(2026, 10, 28),
        courtNo: '12',
        purpose: 'Arguments',
        outcome: 'Adjourned',
        nextDate: _today,
        userNextDate: nov(6),
        userNote: 'Client to bring the vakalatnama',
      ),
    ],
    'm-2': [
      CaseHearing(
        id: 'h-3',
        date: nov(12),
        source: 'manual',
        courtNo: '3',
        purpose: 'Evidence',
      ),
    ],
  },
  orders: {
    'm-1': [
      CaseOrder(
        id: 'o-1',
        date: DateTime.utc(2026, 10, 28),
        title: 'Reply within 4 weeks',
      ),
    ],
  },
  documents: {
    'm-1': const [
      CaseDocument(
        id: 'd-1',
        title: 'Writ petition',
        kind: 'pleading',
        sizeBytes: 245760,
        pages: 12,
      ),
      CaseDocument(
        id: 'd-2',
        title: 'Reply draft',
        kind: 'correspondence',
        uploadStatus: 'pending',
      ),
      CaseDocument(
        id: 'd-3',
        title: 'Scan from client',
        uploadStatus: 'quarantined',
      ),
    ],
  },
  notes: {
    'm-1': [
      CaseNote(
        id: 'n-1',
        body: 'Ask for the certified copy of the 28 Oct order.',
        authorId: 'user-3',
        authorName: 'Neha Verma',
        createdAt: DateTime.utc(2026, 11, 4, 5),
      ),
      CaseNote(
        id: 'n-2',
        body: 'Opposing counsel may seek time.',
        authorId: 'user-1',
        authorName: 'Ramesh Sharma',
        visibility: 'private',
        createdAt: DateTime.utc(2026, 11, 3, 12),
      ),
    ],
  },
  tasks: {
    'm-1': [
      CaseTask(
        id: 't-1',
        title: 'Collect certified copy',
        dueAt: taskDueAt(nov(3)),
      ),
      CaseTask(
        id: 't-2',
        title: 'File reply',
        dueAt: taskDueAt(nov(6), hour: 11, minute: 30),
        assigneeId: 'user-2',
        assigneeName: 'Rakesh Jain',
      ),
      const CaseTask(id: 't-3', title: 'Pay court fee', status: 'done'),
    ],
  },
  deadlines: {
    'm-1': [
      CaseDeadline(
        id: 'dl-1',
        kind: 'limitation',
        dueDate: DateTime.utc(2026, 12),
      ),
    ],
  },
  links: {
    'm-1': [
      (
        linkId: 'mc-1',
        client: const ClientInfo(
          id: 'cl-1',
          name: 'Suresh Patel',
          phone: '+919876543210',
          language: 'hi',
        ),
      ),
    ],
  },
  clients: const [
    ClientInfo(
      id: 'cl-1',
      name: 'Suresh Patel',
      phone: '+919876543210',
      language: 'hi',
    ),
    ClientInfo(id: 'cl-2', name: 'Ramesh Gupta', phone: '+919812345678'),
    ClientInfo(id: 'cl-3', name: 'राजेश शर्मा'),
  ],
);

/// A clerk of the same org: may do everything on the case page but delete it.
const clerkAccount = Account(
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

/// [call] is [name] with [args] (records compare maps by identity, so check each).
void expectCall(FakeCall call, String name, Object? args) {
  expect(call.name, name);
  expect(call.args, args);
}

/// The case page's scroll view (not the scrollable tab bar or a sheet).
Finder get pageScroll => find
    .descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    )
    .first;

/// Scrolls the case page down until [finder] is built (slivers past the screen aren't), or it ends.
Future<void> scrollUntilBuilt(WidgetTester tester, Finder finder) async {
  final position = tester.state<ScrollableState>(pageScroll).position;
  while (finder.evaluate().isEmpty &&
      position.pixels < position.maxScrollExtent) {
    position.jumpTo(position.pixels + 200);
    await tester.pump();
  }
}

/// Scrolls the case page so the tab bar sits at the top, its tab's content below it.
Future<void> scrollToTabs(WidgetTester tester) async {
  await scrollUntilBuilt(tester, find.byType(TabBar));
  final position = tester.state<ScrollableState>(pageScroll).position;
  final dy =
      tester.getTopLeft(find.byType(TabBar)).dy -
      tester.getTopLeft(pageScroll).dy;
  position.jumpTo(position.pixels + dy);
  await tester.pumpAndSettle();
}

void main() {
  late List<Uri> opened;
  late List<ShareParams> shared;

  setUp(() {
    opened = [];
    shared = [];
  });

  /// The case page at [location] on a phone, with [cases] (default [sampleCases]); external links and the share
  /// sheet are recorded in [opened] and [shared].
  Future<FakeApi> open(
    WidgetTester tester, {
    String location = '/cases/m-1',
    FakeCases? cases,
    String locale = 'en',
    double textScale = 1,
    Size size = const Size(400, 1600),
    Account account = ownerAccount,
    List<Override> overrides = const [],
  }) => pumpApp(
    tester,
    location: location,
    locale: locale,
    textScale: textScale,
    size: size,
    account: account,
    onboardingDone: true,
    overrides: [
      ...(cases ?? sampleCases()).overrides,
      openExternalProvider.overrideWithValue((uri) async {
        opened.add(uri);
        return true;
      }),
      shareProvider.overrideWithValue((p) async => shared.add(p)),
      ...overrides,
    ],
  );

  Future<void> tapMenu(WidgetTester tester, String item) async {
    await tester.tap(find.byTooltip(en.casePageMore));
    await tester.pumpAndSettle();
    await tester.tap(find.text(item));
    await tester.pumpAndSettle();
  }

  Finder snack(String text) => find.widgetWithText(SnackBar, text);

  group('header', () {
    testWidgets('auto-tracked: number, title, court, bench, pills, date, '
        'where it comes from, assignee', (tester) async {
      await open(tester);
      final c = sampleCases().cases.first;
      expect(find.widgetWithText(AppBar, 'WP 1001/2024'), findsOneWidget);
      expect(find.text('Sharma v. State of MP'), findsOneWidget);
      expect(find.text('MPHC Indore · ${en.courtNo('12')}'), findsOneWidget);
      expect(
        find.text(
          '${en.casePageBench('Justice A. B. Sharma')} · '
          '${en.casePageStage('Admission')}',
        ),
        findsOneWidget,
      );
      expect(find.text(en.statusListed), findsOneWidget);
      expect(find.text(en.statusNewOrder), findsWidgets);
      expect(find.text('Thu, 5 Nov 2026 · ${en.relToday}'), findsOneWidget);
      // Today's hearing gives the purpose for the next date.
      expect(find.text('Admission'), findsOneWidget);
      expect(
        find.text(caseStatusLine(en, const Locale('en'), c, _today)),
        findsOneWidget,
      );
      expect(
        find.text(
          '${en.foundPending} · ${en.casesUpdatedOn('Wed, 4 Nov', '7:42 pm')}',
        ),
        findsOneWidget,
      );
      expect(find.text(en.boardAssigneeIs('Neha Verma')), findsOneWidget);
      expect(find.byTooltip(en.casePageRefresh), findsOneWidget);
      expect(find.byTooltip(en.casePageShare), findsOneWidget);

      await tester.tap(find.byTooltip(en.casePageMore));
      await tester.pumpAndSettle();
      for (final item in [
        en.casePagePortal,
        en.casePageTrackingOff,
        en.casePageArchive,
        en.casePageDelete,
      ]) {
        expect(find.text(item), findsOneWidget, reason: item);
      }
    });

    testWidgets('manual: next date from its hearings, "Manual case", no '
        'refresh, portal or tracking', (tester) async {
      await open(tester, location: '/cases/m-2');
      expect(
        find.text('Family Court, Indore · ${en.courtNo('3')}'),
        findsOneWidget,
      );
      expect(
        find.text('Thu, 12 Nov 2026 · ${en.relInDays(7)}'),
        findsOneWidget,
      );
      expect(
        find.text('${en.foundPending} · ${en.casesManualCase}'),
        findsOneWidget,
      );
      expect(find.byTooltip(en.casePageRefresh), findsNothing);
      await tester.tap(find.byTooltip(en.casePageMore));
      await tester.pumpAndSettle();
      expect(find.text(en.casePagePortal), findsNothing);
      expect(find.text(en.casePageTrackingOff), findsNothing);
      expect(find.text(en.casePageArchive), findsOneWidget);
    });

    testWidgets('tracking off: says so, offers tracking on, no refresh; no '
        'next date says so plainly', (tester) async {
      await open(tester, location: '/cases/m-3');
      expect(
        find.text('${en.foundPending} · ${en.casesTrackingOff}'),
        findsOneWidget,
      );
      expect(find.text(en.casesNoNextDate), findsOneWidget);
      expect(find.byTooltip(en.casePageRefresh), findsNothing);
      await tester.tap(find.byTooltip(en.casePageMore));
      await tester.pumpAndSettle();
      expect(find.text(en.casePageTrackingOn), findsOneWidget);
    });

    final undated = [caseInfo(1), caseInfo(2, tracking: 'manual')];

    testWidgets('no next date on a tracked case: say so, offer Refresh', (
      tester,
    ) async {
      final api = await open(tester, cases: sampleCases(cases: undated));
      expect(find.text(en.casesNoNextDate), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, en.casePageRefresh));
      await tester.pumpAndSettle();
      expect(api.callNames, contains('refreshMatter'));
    });

    testWidgets('no next date on a manual case: say so, offer Add date', (
      tester,
    ) async {
      await open(
        tester,
        location: '/cases/m-2',
        cases: sampleCases(cases: undated),
      );
      expect(find.text(en.casesNoNextDate), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, en.casePageAddDate));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text(en.casePageAddNextDate),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a removed case says so and leads back to the list', (
      tester,
    ) async {
      await open(tester, location: '/cases/m-9');
      expect(find.text(en.casePageRemoved), findsOneWidget);
      await tester.tap(find.text(en.casePageBackToCases));
      await tester.pumpAndSettle();
      expect(find.byType(CasesScreen), findsOneWidget);
      expect(find.byType(CasePage), findsNothing);
    });

    testWidgets('Assign to: no one, with Undo', (tester) async {
      final cases = sampleCases();
      await open(tester, cases: cases);
      await tester.tap(find.text(en.boardAssignTo));
      await tester.pumpAndSettle();
      expect(find.text(en.boardAssignTitle('WP 1001/2024')), findsOneWidget);
      // Members but clerks, "Me" first, and "No one".
      expect(find.text('Mohan Lal'), findsNothing);
      await tester.tap(find.text(en.casePageAssignNone));
      await tester.pumpAndSettle();
      expectCall(cases.writes.last, 'assignCase', {
        'matterId': 'm-1',
        'assigneeId': null,
      });
      expect(find.text(en.casePageUnassigned), findsOneWidget);
      await tester.tap(find.text(en.undo));
      await tester.pumpAndSettle();
      expectCall(cases.writes.last, 'assignCase', {
        'matterId': 'm-1',
        'assigneeId': 'user-3',
      });
    });
  });

  group('actions', () {
    testWidgets('Refresh asks the court; a recent refresh is up to date; '
        'offline says so; F5 refreshes too', (tester) async {
      final api = await open(tester);
      await tester.tap(find.byTooltip(en.casePageRefresh));
      await tester.pumpAndSettle();
      expect(api.calls.last.name, 'refreshMatter');
      expect((api.calls.last.args! as Map)['id'], 'm-1');
      expect(snack(en.todayRefreshChecking(1)), findsOneWidget);

      api.refreshedRecently.add('m-1');
      await tester.sendKeyEvent(LogicalKeyboardKey.f5);
      await tester.pumpAndSettle();
      expect(api.callNames.where((n) => n == 'refreshMatter'), hasLength(2));
      expect(snack(en.todayRefreshUpToDate), findsOneWidget);

      api.offline = true;
      await tester.tap(find.byTooltip(en.casePageRefresh));
      await tester.pumpAndSettle();
      expect(snack(en.todayRefreshOffline), findsOneWidget);
    });

    testWidgets('Share case status: the title only when asked, never clients', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.byTooltip(en.casePageShare));
      await tester.pumpAndSettle();
      final c = sampleCases().cases.first;
      final plain = caseShareText(
        en,
        const Locale('en'),
        c,
        titles: false,
        purpose: 'Admission',
      );
      expect(find.text(plain), findsOneWidget);
      expect(plain, isNot(contains('Sharma v.')));
      expect(plain, isNot(contains('Suresh')));
      await tester.tap(find.text(en.casePageShareTitles));
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.boardShareAsText));
      await tester.pumpAndSettle();
      expect(shared.single.text, contains('Sharma v. State of MP'));
      expect(shared.single.text, isNot(contains('Suresh')));
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets(
      'Open on official portal: explains the CAPTCHA, copies the CNR, '
      'opens outside',
      (tester) async {
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
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        final api = await open(tester);
        await tapMenu(tester, en.casePagePortal);
        expectCall(api.calls.last, 'officialLink', 'm-1');
        expect(
          find.text(en.casePagePortalBody('MPHC010000000001')),
          findsOneWidget,
        );
        expect(copied, 'MPHC010000000001');
        await tester.tap(find.text(en.casePagePortalOpen));
        await tester.pumpAndSettle();
        expect(opened, [Uri.parse('https://hcservices.ecourts.gov.in/')]);

        api.offline = true;
        await tapMenu(tester, en.casePagePortal);
        expect(snack(en.errorNeedsNetwork), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
      },
    );

    testWidgets('tracking off asks first; on over the allowance explains it', (
      tester,
    ) async {
      final cases = sampleCases();
      final api = await open(tester, cases: cases);
      await tapMenu(tester, en.casePageTrackingOff);
      expect(find.text(en.casePageTrackingOffTitle), findsOneWidget);
      await tester.tap(
        find.widgetWithText(FilledButton, en.casePageTrackingOff),
      );
      await tester.pumpAndSettle();
      expectCall(api.calls.last, 'setTracking', {
        'id': 'm-1',
        'tracking': 'off',
      });
      expect(snack(en.casePageTrackingOffDone), findsOneWidget);

      // Sync brings the change; turning it back on finds the allowance used up.
      cases.updateCase('m-1', (c) => c.copyWith(tracking: 'off'));
      await tester.pumpAndSettle();
      api.fail['setTracking'] = const ApiException(
        'TRACKED_CASE_LIMIT',
        status: 409,
        details: {'limit': 100},
      );
      await tapMenu(tester, en.casePageTrackingOn);
      expectCall(api.calls.last, 'setTracking', {
        'id': 'm-1',
        'tracking': 'auto',
      });
      expect(snack(en.casesTrackingLimit(100)), findsOneWidget);
    });

    testWidgets('Archive with Undo; an archived case offers Unarchive', (
      tester,
    ) async {
      final cases = sampleCases();
      await open(tester, cases: cases);
      await tapMenu(tester, en.casePageArchive);
      expectCall(cases.writes.last, 'setArchived', {
        'matterId': 'm-1',
        'archived': true,
      });
      expect(find.textContaining(en.casesSectionArchived), findsOneWidget);
      await tester.tap(find.text(en.undo));
      await tester.pumpAndSettle();
      expect(cases.writes.last.args, {'matterId': 'm-1', 'archived': false});

      cases.updateCase('m-1', (c) => c.copyWith(status: 'archived'));
      await tester.pumpAndSettle();
      await tapMenu(tester, en.casePageUnarchive);
      expect(cases.writes.last.args, {'matterId': 'm-1', 'archived': false});
    });

    testWidgets('Delete: owners confirm, the API deletes, back to the list', (
      tester,
    ) async {
      final api = await open(tester);
      await tapMenu(tester, en.casePageDelete);
      expect(find.text(en.casePageDeleteTitle('WP 1001/2024')), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, en.casePageDelete));
      await tester.pumpAndSettle();
      expectCall(api.calls.last, 'deleteMatter', 'm-1');
      expect(snack(en.casePageDeleted), findsOneWidget);
      expect(find.byType(CasesScreen), findsOneWidget);
      expect(find.byType(CasePage), findsNothing);
    });

    testWidgets('Delete: offline keeps the case and says so', (tester) async {
      final api = await open(tester);
      api.offline = true;
      await tapMenu(tester, en.casePageDelete);
      await tester.tap(find.widgetWithText(FilledButton, en.casePageDelete));
      await tester.pumpAndSettle();
      expect(snack(en.errorNeedsNetwork), findsOneWidget);
      expect(find.byType(CasePage), findsOneWidget);
    });

    testWidgets('a clerk has no Delete', (tester) async {
      await open(tester, account: clerkAccount);
      await tester.tap(find.byTooltip(en.casePageMore));
      await tester.pumpAndSettle();
      expect(find.text(en.casePageArchive), findsOneWidget);
      expect(find.text(en.casePageDelete), findsNothing);
    });
  });

  group('timeline', () {
    testWidgets('court values first, "You noted" where they differ, notes, '
        'and New on an unread order', (tester) async {
      await open(tester);
      expect(find.text('${en.casePageHearing} · Admission'), findsOneWidget);
      expect(
        find.text('${en.courtNo('12')} · ${en.itemNo('23')}'),
        findsOneWidget,
      );
      expect(
        find.text(
          [
            en.courtNo('12'),
            en.casePageOutcome('Adjourned'),
            en.casesShareNext('Thu, 5 Nov 2026'),
            en.casePageYouNoted('Fri, 6 Nov 2026'),
            en.casePageNote('Client to bring the vakalatnama'),
          ].join('\n'),
        ),
        findsOneWidget,
      );
      expect(find.text('Reply within 4 weeks'), findsOneWidget);
      expect(find.text('28 Oct 2026'), findsNWidgets(2));
      // The header's pill and the order's.
      expect(find.text(en.statusNewOrder), findsNWidgets(2));
    });

    testWidgets('opening an order reads it and opens it outside; offline it '
        'stays New', (tester) async {
      final cases = sampleCases();
      final api = await open(tester, cases: cases);
      api.offline = true;
      await tester.tap(find.text(en.casePageOpenOrder));
      await tester.pumpAndSettle();
      expect(snack(en.errorNeedsNetwork), findsOneWidget);
      expect(cases.writes, isEmpty);
      expect(opened, isEmpty);

      api.offline = false;
      await tester.tap(find.text(en.casePageOpenOrder));
      await tester.pumpAndSettle();
      expectCall(api.calls.last, 'orderPdfUrl', 'o-1');
      expectCall(cases.writes.single, 'markOrderRead', 'o-1');
      expect(opened, [Uri.parse('https://files.test/orders/o-1')]);
      expect(find.text(en.statusNewOrder), findsNothing);
    });

    testWidgets('a hearing note on a court hearing', (tester) async {
      final cases = sampleCases();
      await open(tester, cases: cases);
      await tester.tap(find.text(en.casePageAddNote).first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(TextField),
        ),
        'Bring the paper book',
      );
      await tester.tap(find.text(en.casePageSave));
      await tester.pumpAndSettle();
      expectCall(cases.writes.last, 'setHearingNote', {
        'id': 'h-1',
        'note': 'Bring the paper book',
      });
      expect(
        find.textContaining(en.casePageNote('Bring the paper book')),
        findsOneWidget,
      );
      // Court hearings aren't edited or deleted.
      expect(find.widgetWithText(TextButton, en.casePageEdit), findsNothing);
    });

    testWidgets('manual case: add the next date (validated), edit and delete '
        'a hearing', (tester) async {
      final cases = sampleCases();
      await open(tester, location: '/cases/m-2', cases: cases);
      await tester.tap(
        find.widgetWithText(OutlinedButton, en.casePageAddNextDate),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.casePageSave));
      await tester.pumpAndSettle();
      expect(find.text(en.casePageDateRequired), findsOneWidget);
      expect(cases.writes, isEmpty);

      final sheet = find.byType(BottomSheet);
      Finder field(String label) => find.descendant(
        of: sheet,
        matching: find.widgetWithText(TextField, label),
      );
      await tester.enterText(field(en.dateLabel), '09-11-2026');
      await tester.enterText(field(en.boardPurpose), 'Framing of issues');
      await tester.tap(find.text(en.casePageSave));
      await tester.pumpAndSettle();
      expect(cases.writes.last.name, 'addHearing');
      expect(cases.writes.last.args, {
        'matterId': 'm-2',
        'date': DateTime(2026, 11, 9),
        'courtNo': '',
        'itemNo': '',
        'purpose': 'Framing of issues',
        'outcome': '',
      });
      // The earliest hearing from today is the next date now.
      expect(find.text('Mon, 9 Nov 2026 · ${en.relInDays(4)}'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, en.casePageEdit).last);
      await tester.pumpAndSettle();
      await tester.enterText(field(en.casePageOutcomeLabel), 'Adjourned');
      await tester.tap(find.text(en.casePageSave));
      await tester.pumpAndSettle();
      expect(cases.writes.last.name, 'editHearing');
      expect((cases.writes.last.args! as Map)['outcome'], 'Adjourned');

      await tester.tap(find.widgetWithText(TextButton, en.delete).first);
      await tester.pumpAndSettle();
      expect(find.text('${en.casePageHearing} · Evidence'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expectCall(cases.writes.last, 'deleteHearing', 'h-3');
    });
  });

  group('documents', () {
    testWidgets('a ready file opens outside; one being checked or quarantined '
        'says why not', (tester) async {
      final api = await open(tester, location: '/cases/m-1?tab=documents');
      expect(
        find.text('${en.casesDocPleading} · 240 KB · ${en.pages(12)}'),
        findsOneWidget,
      );
      expect(
        find.text('${en.casesDocCorrespondence} · ${en.casePageDocChecking}'),
        findsOneWidget,
      );
      await tester.tap(find.text('Reply draft'));
      await tester.pumpAndSettle();
      expect(snack(en.errorDocumentNotReady), findsOneWidget);
      await tester.tap(find.text('Scan from client'));
      await tester.pumpAndSettle();
      expect(snack(en.errorDocumentQuarantined), findsOneWidget);
      expect(api.callNames, isNot(contains('documentUrl')));

      await tester.tap(find.text('Writ petition'));
      await tester.pumpAndSettle();
      expectCall(api.calls.last, 'documentUrl', 'd-1');
      expect(opened, [Uri.parse('https://files.test/documents/d-1')]);

      await tester.tap(find.text(en.addDocument));
      await tester.pumpAndSettle();
      expect(snack(en.comingSoon), findsOneWidget);
    });

    testWidgets('no documents: an empty state', (tester) async {
      await open(tester, location: '/cases/m-2?tab=documents');
      expect(find.text(en.casePageDocumentsEmpty), findsOneWidget);
    });
  });

  group('notes & tasks', () {
    testWidgets('notes: add (not empty) as private, edit, delete', (
      tester,
    ) async {
      final cases = sampleCases();
      await open(tester, location: '/cases/m-1?tab=notes', cases: cases);
      expect(find.text('Neha Verma · Wed, 4 Nov, 10:30 am'), findsOneWidget);
      expect(
        find.text(
          'Ramesh Sharma · Tue, 3 Nov, 5:30 pm · ${en.casePagePrivate}',
        ),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(TextButton, en.casePageAddNote));
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.casePageSave));
      await tester.pumpAndSettle();
      expect(find.text(en.casePageNoteEmpty), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(TextField),
        ),
        'Call the client tonight',
      );
      await tester.tap(find.text(en.casePagePrivate));
      await tester.tap(find.text(en.casePageSave));
      await tester.pumpAndSettle();
      expectCall(cases.writes.last, 'addNote', {
        'matterId': 'm-1',
        'body': 'Call the client tonight',
        'private': true,
      });
      expect(find.text('Call the client tonight'), findsOneWidget);

      // Neha's team note (its menu named by the note's start): editable, but only its author may make it private.
      await tester.tap(
        find.byTooltip(
          en.boardMoreActions('Ask for the certified copy of the 28 Oct…'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.casePageEdit));
      await tester.pumpAndSettle();
      expect(find.text(en.casePagePrivate), findsNothing);
      await tester.enterText(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(TextField),
        ),
        'Certified copy applied for',
      );
      await tester.tap(find.text(en.casePageSave));
      await tester.pumpAndSettle();
      expectCall(cases.writes.last, 'editNote', {
        'id': 'n-1',
        'body': 'Certified copy applied for',
        'private': false,
      });

      // Delete takes the note away at once, with Undo; it is written only when the snackbar goes.
      Future<void> delete() async {
        await tester.tap(
          find.byTooltip(en.boardMoreActions('Call the client tonight')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(en.delete));
        await tester.pumpAndSettle();
      }

      await delete();
      expect(find.text('Call the client tonight'), findsNothing);
      expect(snack(en.deleted), findsOneWidget);
      await tester.tap(find.text(en.undo));
      await tester.pumpAndSettle();
      expect(find.text('Call the client tonight'), findsOneWidget);
      expect(cases.writes.last.name, 'editNote');

      await delete();
      expect(find.text('Call the client tonight'), findsNothing);
      expect(cases.writes.last.name, 'editNote');
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(snack(en.deleted), findsNothing);
      expect(cases.writes.last.name, 'deleteNote');
      expect(find.text('Call the client tonight'), findsNothing);
    });

    testWidgets('deleting the last note or task still writes the delete', (
      tester,
    ) async {
      // The last row's widget leaves the tree when it hides, so the delete can't depend on that row's ref.
      final cases = sampleCases();
      await open(tester, location: '/cases/m-1?tab=notes', cases: cases);
      Future<void> delete(String label) async {
        await scrollUntilBuilt(
          tester,
          find.byTooltip(en.boardMoreActions(label)),
        );
        await tester.ensureVisible(find.byTooltip(en.boardMoreActions(label)));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip(en.boardMoreActions(label)));
        await tester.pumpAndSettle();
        await tester.tap(find.text(en.delete));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
      }

      await delete('Opposing counsel may seek time.');
      expectCall(cases.writes.last, 'deleteNote', 'n-2');
      await delete('Pay court fee');
      expectCall(cases.writes.last, 'deleteTask', 't-3');
    });

    testWidgets('tasks: due text, overdue, done with Undo, add, delete', (
      tester,
    ) async {
      final cases = sampleCases();
      await open(tester, location: '/cases/m-1?tab=notes', cases: cases);
      expect(find.text(en.taskDue('Tue, 3 Nov 2026')), findsOneWidget);
      expect(find.text(en.statusOverdue), findsOneWidget);
      expect(
        find.text(en.taskDue('Fri, 6 Nov 2026, 11:30 am')),
        findsOneWidget,
      );
      expect(find.text('Rakesh Jain'), findsOneWidget);

      await tester.tap(find.text('File reply'));
      await tester.pumpAndSettle();
      expectCall(cases.writes.last, 'setTaskDone', {'id': 't-2', 'done': true});
      await tester.tap(find.text(en.undo));
      await tester.pumpAndSettle();
      expect(cases.writes.last.args, {'id': 't-2', 'done': false});

      await tester.tap(find.widgetWithText(TextButton, en.addTask));
      await tester.pumpAndSettle();
      // The case is this one; no case picker.
      expect(find.text(en.casePageCase), findsNothing);
      await tester.tap(find.text(en.casePageSave));
      await tester.pumpAndSettle();
      expect(find.text(en.casePageTaskTitleEmpty), findsOneWidget);
      final sheet = find.byType(BottomSheet);
      await tester.enterText(
        find.descendant(
          of: sheet,
          matching: find.widgetWithText(TextField, en.casePageTaskTitle),
        ),
        'Prepare paper book',
      );
      await tester.enterText(
        find.descendant(
          of: sheet,
          matching: find.widgetWithText(TextField, en.casePageDueDate),
        ),
        '10-11-2026',
      );
      await tester.tap(find.text(en.casePageSave));
      await tester.pumpAndSettle();
      expectCall(cases.writes.last, 'addTask', {
        'title': 'Prepare paper book',
        'matterId': 'm-1',
        'dueAt': DateTime.utc(2026, 11, 9, 18, 30),
        'assigneeId': null,
      });
      expect(find.text('Prepare paper book'), findsOneWidget);

      await tester.tap(find.byTooltip(en.boardMoreActions('Pay court fee')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.delete));
      await tester.pumpAndSettle();
      expect(find.text('Pay court fee'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expectCall(cases.writes.last, 'deleteTask', 't-3');
    });

    testWidgets('deadlines: add (validated), done with Undo, delete', (
      tester,
    ) async {
      final cases = sampleCases();
      await open(tester, location: '/cases/m-1?tab=notes', cases: cases);
      // Deadlines come last: bring them into view (longer text pushes them down).
      Future<void> tapShown(Finder finder) async {
        await scrollUntilBuilt(tester, finder);
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      await scrollUntilBuilt(tester, find.text(en.casesDeadlineLimitation));
      expect(find.text(en.casesDeadlineLimitation), findsOneWidget);
      expect(find.text(en.taskDue('Tue, 1 Dec 2026')), findsOneWidget);

      await tapShown(find.text(en.casePageAddDeadline));
      await tester.tap(find.text(en.casesDeadlineFiling));
      await tester.tap(find.text(en.casePageSave));
      await tester.pumpAndSettle();
      expect(find.text(en.casePageDateRequired), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(TextField),
        ),
        '20-11-2026',
      );
      await tester.tap(find.text(en.casePageSave));
      await tester.pumpAndSettle();
      expectCall(cases.writes.last, 'addDeadline', {
        'matterId': 'm-1',
        'kind': 'filing',
        'dueDate': DateTime(2026, 11, 20),
      });

      await tapShown(
        find.byTooltip(en.boardMoreActions(en.casesDeadlineFiling)),
      );
      await tester.tap(find.text(en.delete));
      await tester.pumpAndSettle();
      expect(find.text(en.casesDeadlineFiling), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(cases.writes.last.name, 'deleteDeadline');

      await tapShown(find.text(en.casesDeadlineLimitation));
      expectCall(cases.writes.last, 'setDeadlineDone', {
        'id': 'dl-1',
        'done': true,
      });
      expect(snack(en.casePageDeadlineDone), findsOneWidget);
      await tester.tap(find.text(en.undo));
      await tester.pumpAndSettle();
      expectCall(cases.writes.last, 'setDeadlineDone', {
        'id': 'dl-1',
        'done': false,
      });
    });
  });

  group('client', () {
    testWidgets('call, and unlink with Undo', (tester) async {
      final cases = sampleCases();
      await open(tester, location: '/cases/m-1?tab=client', cases: cases);
      expect(find.text('Suresh Patel'), findsOneWidget);
      expect(find.text('+919876543210 · ${en.casePageLangHi}'), findsOneWidget);
      await tester.tap(find.byTooltip(en.casePageCall('Suresh Patel')));
      await tester.pumpAndSettle();
      expect(opened, [Uri(scheme: 'tel', path: '+919876543210')]);

      await tester.tap(find.byTooltip(en.boardMoreActions('Suresh Patel')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.casePageUnlink));
      await tester.pumpAndSettle();
      expectCall(cases.writes.last, 'unlinkClient', 'mc-1');
      expect(find.text(en.casePageClientsEmpty), findsOneWidget);
      await tester.tap(find.text(en.undo));
      await tester.pumpAndSettle();
      expectCall(cases.writes.last, 'linkClient', {
        'matterId': 'm-1',
        'clientId': 'cl-1',
      });
      expect(find.text('Suresh Patel'), findsOneWidget);
    });

    testWidgets('link an existing client found across scripts', (tester) async {
      final cases = sampleCases();
      await open(tester, location: '/cases/m-1?tab=client', cases: cases);
      await tester.tap(find.text(en.casePageLinkClient));
      await tester.pumpAndSettle();
      // Already linked clients aren't offered again.
      final sheet = find.byType(BottomSheet);
      expect(
        find.descendant(of: sheet, matching: find.text('Suresh Patel')),
        findsNothing,
      );
      await tester.enterText(
        find.descendant(of: sheet, matching: find.byType(TextField)).first,
        'sharma',
      );
      await tester.pumpAndSettle();
      expect(find.text('Ramesh Gupta'), findsNothing);
      await tester.tap(find.text('राजेश शर्मा'));
      await tester.pumpAndSettle();
      expectCall(cases.writes.last, 'linkClient', {
        'matterId': 'm-1',
        'clientId': 'cl-3',
      });
      expect(find.text('राजेश शर्मा'), findsOneWidget);
    });

    testWidgets('create and link a new client, validated inline', (
      tester,
    ) async {
      final cases = sampleCases();
      await open(tester, location: '/cases/m-2?tab=client', cases: cases);
      expect(find.text(en.casePageClientsEmpty), findsOneWidget);
      await tester.tap(find.text(en.casePageLinkClient));
      await tester.pumpAndSettle();
      final sheet = find.byType(BottomSheet);
      Finder field(String label) => find.descendant(
        of: sheet,
        matching: find.widgetWithText(TextField, label),
      );
      await tester.enterText(field(en.phoneLabel), '12345');
      await tester.tap(find.text(en.casePageCreateLink));
      await tester.pumpAndSettle();
      expect(find.text(en.casePageClientNameEmpty), findsOneWidget);
      expect(find.text(en.phoneInvalid), findsOneWidget);
      expect(cases.writes, isEmpty);

      await tester.enterText(field(en.casePageClientName), 'Anita Joshi');
      await tester.enterText(field(en.phoneLabel), '9876501234');
      await tester.tap(find.text(en.casePageLangEn));
      await tester.tap(find.text(en.casePageCreateLink));
      await tester.pumpAndSettle();
      expect(cases.writes.map((w) => w.name), ['createClient', 'linkClient']);
      expect(cases.writes.first.args, {
        'name': 'Anita Joshi',
        'phone': '+919876501234',
        'language': 'en',
      });
      expect(find.text('Anita Joshi'), findsOneWidget);
    });
  });

  testWidgets('Add task from the + sheet picks its case by search', (
    tester,
  ) async {
    final cases = sampleCases();
    await open(tester, location: '/today', cases: cases);
    await tester.tap(find.text(en.navAdd));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.addTask));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, en.casePageTaskTitle),
      'Draft rejoinder',
    );
    await tester.tap(find.text(en.casePageCase));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, en.searchCasesHint),
      '1002',
    );
    await tester.pumpAndSettle();
    expect(find.text('WP 1001/2024'), findsNothing);
    await tester.tap(find.text('WP 1002/2024'));
    await tester.pumpAndSettle();
    expect(find.text('WP 1002/2024'), findsOneWidget);
    await tester.tap(find.text(en.casePageSave));
    await tester.pumpAndSettle();
    expectCall(cases.writes.last, 'addTask', {
      'title': 'Draft rejoinder',
      'matterId': 'm-2',
      'dueAt': null,
      'assigneeId': null,
    });
    expect(snack(en.casePageTaskAdded), findsOneWidget);
  });

  testWidgets('every sheet meets the tap-target and label guidelines', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await open(tester);
    Future<void> check(String location, Finder opener) async {
      container(tester).read(routerProvider).go(location);
      await tester.pumpAndSettle();
      await tester.tap(opener);
      await tester.pumpAndSettle();
      final sheet = find.byType(BottomSheet);
      expect(sheet, findsOneWidget);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      Navigator.of(tester.element(sheet)).pop();
      await tester.pumpAndSettle();
    }

    await check('/cases/m-1', find.byTooltip(en.casePageShare));
    await check('/cases/m-1', find.text(en.boardAssignTo));
    await check('/cases/m-1', find.text(en.casePageAddNote).first);
    await check(
      '/cases/m-2',
      find.widgetWithText(OutlinedButton, en.casePageAddNextDate),
    );
    await check(
      '/cases/m-1?tab=notes',
      find.widgetWithText(TextButton, en.casePageAddNote),
    );
    await check('/cases/m-1?tab=notes', find.text(en.addTask));
    await check('/cases/m-1?tab=notes', find.text(en.casePageAddDeadline));
    await check('/cases/m-1?tab=client', find.text(en.casePageLinkClient));
    semantics.dispose();
  });

  testWidgets('a wide window shows the case beside the list', (tester) async {
    await open(tester, size: const Size(1280, 800));
    expect(find.byType(CasesScreen), findsOneWidget);
    expect(find.byType(CasePage), findsOneWidget);
    expect(find.text('MPHC Indore · ${en.courtNo('12')}'), findsWidgets);
    // The list is right there: the case beside it has no back arrow (spec §5.3).
    expect(find.byType(BackButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets("wide window: a refresh still running on one case isn't the "
      "next case's", (tester) async {
    final api = await open(
      tester,
      size: const Size(1280, 800),
      cases: sampleCases(
        cases: [
          caseInfo(1, nextDate: _today),
          caseInfo(4, nextDate: nov(9)),
        ],
      ),
    );
    final gate = api.gates['refreshMatter'] = Completer<void>();
    await tester.tap(find.byTooltip(en.casePageRefresh));
    await tester.pump();
    expect(find.text(en.todayRefreshing), findsOneWidget);

    await tester.tap(find.text('WP 1004/2024'));
    await tester.pumpAndSettle();
    expect(tester.widget<CasePage>(find.byType(CasePage)).matterId, 'm-4');
    expect(find.text(en.todayRefreshing), findsNothing);
    final refresh = find.widgetWithIcon(IconButton, AppIcons.arrowClockwise);
    expect(tester.widget<IconButton>(refresh).onPressed, isNotNull);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets("phone: a link to another case doesn't carry a running "
      'refresh over', (tester) async {
    final api = await open(
      tester,
      cases: sampleCases(
        cases: [
          caseInfo(1, nextDate: _today),
          caseInfo(4, nextDate: nov(9)),
        ],
      ),
    );
    final gate = api.gates['refreshMatter'] = Completer<void>();
    await tester.tap(find.byTooltip(en.casePageRefresh));
    await tester.pump();
    expect(find.text(en.todayRefreshing), findsOneWidget);

    // e.g. a notification for another case while this one refreshes.
    container(tester).read(routerProvider).go('/cases/m-4');
    await tester.pumpAndSettle();
    expect(tester.widget<CasePage>(find.byType(CasePage)).matterId, 'm-4');
    expect(find.text(en.todayRefreshing), findsNothing);
    final refresh = find.widgetWithIcon(IconButton, AppIcons.arrowClockwise);
    expect(tester.widget<IconButton>(refresh).onPressed, isNotNull);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });

  for (final (tab, table, content) in [
    ('documents', 'documents', 'Writ petition'),
    ('notes', 'notes', 'Ask for the certified copy of the 28 Oct order.'),
    ('client', 'clients', 'Suresh Patel'),
  ]) {
    testWidgets('$tab tab: a failed read says so, with Retry', (tester) async {
      final cases = sampleCases()..failing.add(table);
      await open(tester, location: '/cases/m-1?tab=$tab', cases: cases);
      await scrollToTabs(tester);
      expect(find.byType(ErrorState), findsOneWidget);
      expect(find.text(en.errorGeneric), findsOneWidget);
      // Not an empty tab.
      expect(find.text(en.casePageNotesEmpty), findsNothing);
      expect(find.text(en.casePageDocumentsEmpty), findsNothing);
      expect(find.text(en.casePageClientsEmpty), findsNothing);

      cases.failing.clear();
      await tester.tap(find.text(en.retry));
      await tester.pumpAndSettle();
      expect(find.byType(ErrorState), findsNothing);
      expect(find.text(content), findsOneWidget);
    });
  }

  group('task sheet', () {
    Finder inSheet(Finder f) =>
        find.descendant(of: find.byType(BottomSheet), matching: f);

    testWidgets('a time without a date says so and saves nothing', (
      tester,
    ) async {
      final cases = sampleCases();
      await open(tester, location: '/cases/m-1?tab=notes', cases: cases);
      await tester.tap(find.widgetWithText(TextButton, en.addTask));
      await tester.pumpAndSettle();
      await tester.enterText(
        inSheet(find.widgetWithText(TextField, en.casePageTaskTitle)),
        'Call the client',
      );
      await tester.tap(find.text(en.casePageAddTime));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.casePageSave));
      await tester.pumpAndSettle();
      expect(find.text(en.casePageTimeNeedsDate), findsOneWidget);
      expect(cases.writes, isEmpty);

      await tester.enterText(
        inSheet(find.widgetWithText(TextField, en.casePageDueDate)),
        '10-11-2026',
      );
      await tester.pump();
      expect(find.text(en.casePageTimeNeedsDate), findsNothing);
      await tester.tap(find.text(en.casePageSave));
      await tester.pumpAndSettle();
      expectCall(cases.writes.last, 'addTask', {
        'title': 'Call the client',
        'matterId': 'm-1',
        'dueAt': DateTime.utc(2026, 11, 10, 5),
        'assigneeId': null,
      });
    });

    testWidgets('a task of someone no longer in the team keeps them', (
      tester,
    ) async {
      final cases = sampleCases();
      cases.tasks['m-1']!.add(
        const CaseTask(id: 't-9', title: 'Old errand', assigneeId: 'user-9'),
      );
      await open(tester, location: '/cases/m-1?tab=notes', cases: cases);
      await scrollUntilBuilt(tester, find.text('Old errand'));
      await tester.tap(find.byTooltip(en.boardMoreActions('Old errand')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.casePageEdit));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(inSheet(find.text(en.casePageFormerMember)), findsOneWidget);
      await tester.tap(find.text(en.casePageSave));
      await tester.pumpAndSettle();
      expect((cases.writes.last.args! as Map)['assigneeId'], 'user-9');
    });
  });

  // Spec §4.3 AC: every tab renders at 200% text, in both languages, with 48 dp labelled targets (§5.9).
  for (final tab in CaseTab.values) {
    for (final locale in ['en', 'hi']) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('${tab.name} tab, $locale, ${scale}x', (tester) async {
          final l = locale == 'en' ? en : hi;
          final semantics = tester.ensureSemantics();
          await open(
            tester,
            location: '/cases/m-1?tab=${tab.name}',
            locale: locale,
            textScale: scale,
            size: const Size(400, 860),
          );
          expect(tester.takeException(), isNull);
          await scrollToTabs(tester);
          final content = find.text(switch (tab) {
            CaseTab.timeline => l.casePageOpenOrder,
            CaseTab.documents => 'Writ petition',
            CaseTab.notes => 'Ask for the certified copy of the 28 Oct order.',
            CaseTab.client => 'Suresh Patel',
          });
          await scrollUntilBuilt(tester, content);
          expect(content, findsOneWidget);
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          final position = tester.state<ScrollableState>(pageScroll).position;
          position.jumpTo(position.maxScrollExtent);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          semantics.dispose();
        });
      }
    }
  }
}
