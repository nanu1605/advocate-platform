import 'dart:async';

import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/jobs.dart';
import 'package:advocate_app/features/documents/viewer_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';
import 'case_page_test.dart'
    show
        clerkAccount,
        en,
        expectCall,
        nov,
        orderSummary,
        sampleCases,
        scrollUntilBuilt;

/// The order summary sheet (spec §4.4 F07, F13, §12.14): the summary in either language with its pages, made on
/// demand (credits asked first, the order's text waited for, the job followed), and the actions proposed from the
/// order, confirmed or dismissed with Undo, here and on the Notes tab.
void main() {
  // Built in a test: date formats load with the app.
  String date(DateTime d) => Formats(const Locale('en')).date(d);

  Finder inSheet(Finder f) =>
      find.descendant(of: find.byType(BottomSheet), matching: f);

  /// The case page of WP 1001/2024 at [location] with [cases] (default the sample), on a tall phone.
  Future<FakeApi> open(
    WidgetTester tester, {
    String location = '/cases/m-1',
    FakeCases? cases,
    Account account = ownerAccount,
  }) => pumpApp(
    tester,
    location: location,
    account: account,
    size: const Size(400, 1600),
    overrides: [
      ...(cases ?? sampleCases()).overrides,
      ...FakeDocuments().overrides,
    ],
  );

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
  }

  Future<void> openSummary(WidgetTester tester) async {
    await tap(tester, find.text(en.summaryButton));
    await tester.pumpAndSettle();
  }

  /// The sample with o-1 summarised in English only, and nothing proposed from it.
  FakeCases englishOnly() => sampleCases()
    ..orders['m-1'] = [
      CaseOrder(
        id: 'o-1',
        date: DateTime.utc(2026, 10, 28),
        title: 'Reply within 4 weeks',
        summaryEn: orderSummary(),
      ),
    ]
    ..proposals.clear();

  List<Map<String, Object?>> calls(FakeApi api, String name) => [
    for (final c in api.calls)
      if (c.name == name) c.args! as Map<String, Object?>,
  ];

  testWidgets('Summary shows the sections with their pages, in English and '
      'Hindi; a page opens the order there', (tester) async {
    await open(tester);
    await openSummary(tester);
    expect(inSheet(find.text(en.summaryTitle)), findsOneWidget);
    expect(find.text('Order dated 28-10-2026'), findsOneWidget);
    expect(
      find.text(
        'Notice to the respondents; interim protection continues till the next date.',
      ),
      findsOneWidget,
    );
    for (final heading in [
      en.summaryGist,
      en.summaryOutcome,
      en.summaryDirections,
      en.nextDate,
      en.summaryAuthorities,
      en.summaryNextSteps,
    ]) {
      expect(inSheet(find.text(heading)), findsOneWidget, reason: heading);
    }
    // None given: no heading.
    expect(inSheet(find.text(en.summaryRelief)), findsNothing);
    expect(inSheet(find.text(en.summaryReasons)), findsNothing);
    expect(find.text(en.summaryAsCited), findsOneWidget);
    expect(
      find.text(
        '${en.summaryWho('the respondents')} · '
        '${en.summaryByWhen('within 4 weeks')}',
      ),
      findsOneWidget,
    );
    expect(find.text(date(DateTime.utc(2026, 12, 2))), findsOneWidget);
    expect(find.text(en.aiVerifyFooter), findsOneWidget);

    await tap(tester, inSheet(find.text('हिंदी')));
    await tester.pumpAndSettle();
    expect(find.text('28-10-2026 का आदेश'), findsOneWidget);
    expect(find.text('Order dated 28-10-2026'), findsNothing);

    await tap(tester, find.text('${en.casePageOrder} · ${en.sourcePage(3)}'));
    await tester.pumpAndSettle();
    final viewer = tester.widget<ViewerScreen>(find.byType(ViewerScreen));
    expect((viewer.orderId, viewer.page), ('o-1', 3));
    // Back is the sheet again.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('28-10-2026 का आदेश'), findsOneWidget);
  });

  testWidgets('it opens in the language that exists when the app language '
      "doesn't", (tester) async {
    final cases = englishOnly();
    cases.orders['m-1']![0] = CaseOrder(
      id: 'o-1',
      date: DateTime.utc(2026, 10, 28),
      summaryHi: orderSummary(hindi: true),
    );
    await open(tester, cases: cases);
    await openSummary(tester);
    expect(find.text('28-10-2026 का आदेश'), findsOneWidget);
    await tap(tester, inSheet(find.text('English')));
    await tester.pumpAndSettle();
    expect(find.text(en.summaryNone('English')), findsOneWidget);
    expect(find.text(en.summariseIn('English')), findsOneWidget);
  });

  testWidgets('summarising asks before spending credits, follows the job and '
      'shows the summary', (tester) async {
    final api = await open(tester, cases: englishOnly());
    api
      ..ai['summariseOrder'] = [
        const ApiException(
          'AI_CREDITS_NEEDED',
          status: 409,
          details: {'credits': 4, 'left': 96},
        ),
        const AiResult(jobId: 'job-sum'),
        AiResult(summary: orderSummary(hindi: true)),
      ]
      ..jobs['job-sum'] = const Job(
        id: 'job-sum',
        kind: 'order_summary',
        status: JobStatus.running,
      );
    await openSummary(tester);
    await tap(tester, inSheet(find.text('हिंदी')));
    await tester.pumpAndSettle();
    expect(find.text(en.summaryNone('हिंदी')), findsOneWidget);
    await tap(tester, find.text(en.summariseIn('हिंदी')));
    await tester.pumpAndSettle();
    expect(find.text(en.summaryCreditsTitle), findsOneWidget);
    expect(find.text(en.summaryCredits(4, 96)), findsOneWidget);
    await tester.tap(find.text(en.summarySummarise));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(en.summaryWorking), findsOneWidget);
    // The button waits while it works.
    expect(
      tester
          .widget<ButtonStyleButton>(
            find.ancestor(
              of: find.text(en.summariseIn('हिंदी')),
              matching: find.bySubtype<ButtonStyleButton>(),
            ),
          )
          .enabled,
      isFalse,
    );

    api.jobs['job-sum'] = const Job(
      id: 'job-sum',
      kind: 'order_summary',
      status: JobStatus.done,
      result: {'language': 'hi'},
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('28-10-2026 का आदेश'), findsOneWidget);
    expect(find.text(en.summaryWorking), findsNothing);

    final sent = calls(api, 'summariseOrder');
    expect([for (final c in sent) c['credits']], [0, 4, 0]);
    expect(
      sent.every((c) => c['id'] == 'o-1' && c['language'] == 'hi'),
      isTrue,
    );
    // Agreeing retries the same action; asking for the finished job's summary is a new one.
    expect(sent[1]['key'], sent[0]['key']);
    expect(sent[2]['key'], isNot(sent[1]['key']));
  });

  testWidgets('declining the credits spends nothing', (tester) async {
    final api = await open(tester, cases: englishOnly());
    api.ai['summariseOrder'] = [
      const ApiException(
        'AI_CREDITS_NEEDED',
        status: 409,
        details: {'credits': 4, 'left': 96},
      ),
    ];
    await openSummary(tester);
    await tap(tester, inSheet(find.text('हिंदी')));
    await tester.pumpAndSettle();
    await tap(tester, find.text(en.summariseIn('हिंदी')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.cancel));
    await tester.pumpAndSettle();
    expect(calls(api, 'summariseOrder'), hasLength(1));
    expect(find.text(en.summaryWorking), findsNothing);
    expect(find.text(en.summariseIn('हिंदी')), findsOneWidget);
  });

  testWidgets('while the order is being read it tries again every 5 s', (
    tester,
  ) async {
    final api = await open(tester, cases: englishOnly());
    const pending = ApiException(
      'ORDER_TEXT_PENDING',
      retryable: true,
      status: 409,
    );
    api.ai['summariseOrder'] = [pending, AiResult(summary: orderSummary())];
    await openSummary(tester);
    await tap(tester, inSheet(find.text('हिंदी')));
    await tester.pumpAndSettle();
    await tap(tester, find.text(en.summariseIn('हिंदी')));
    await tester.pump();
    expect(find.text(en.summaryReading), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(calls(api, 'summariseOrder'), hasLength(2));
    expect(find.text(en.summaryReading), findsNothing);
    expect(find.text('Order dated 28-10-2026'), findsOneWidget);
  });

  testWidgets('a pending order stops retrying after a minute', (tester) async {
    final api = await open(tester, cases: englishOnly());
    api.ai['summariseOrder'] = [
      const ApiException('ORDER_TEXT_PENDING', retryable: true, status: 409),
    ];
    await openSummary(tester);
    await tap(tester, inSheet(find.text('हिंदी')));
    await tester.pumpAndSettle();
    await tap(tester, find.text(en.summariseIn('हिंदी')));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(seconds: 5));
    }
    await tester.pumpAndSettle();
    expect(calls(api, 'summariseOrder'), hasLength(13));
    expect(find.text(en.errorOrderTextPending), findsOneWidget);
  });

  testWidgets("a failed job says why, in the job's words", (tester) async {
    final api = await open(tester, cases: englishOnly());
    api
      ..ai['summariseOrder'] = [const AiResult(jobId: 'job-sum')]
      ..jobs['job-sum'] = const Job(
        id: 'job-sum',
        kind: 'order_summary',
        status: JobStatus.failed,
        error: 'ORDER_TEXT_UNREADABLE',
      );
    await openSummary(tester);
    await tap(tester, inSheet(find.text('हिंदी')));
    await tester.pumpAndSettle();
    await tap(tester, find.text(en.summariseIn('हिंदी')));
    await tester.pumpAndSettle();
    expect(find.text(en.errorOrderTextUnreadable), findsOneWidget);
    expect(find.text(en.summariseIn('हिंदी')), findsOneWidget);
  });

  for (final code in ['AI_BUSY', 'AI_IN_PROGRESS']) {
    testWidgets('a job that gave up with $code asks to try again later', (
      tester,
    ) async {
      final api = await open(tester, cases: englishOnly());
      api
        ..ai['summariseOrder'] = [const AiResult(jobId: 'job-sum')]
        ..jobs['job-sum'] = Job(
          id: 'job-sum',
          kind: 'order_summary',
          status: JobStatus.failed,
          error: code,
        );
      await openSummary(tester);
      await tap(tester, inSheet(find.text('हिंदी')));
      await tester.pumpAndSettle();
      await tap(tester, find.text(en.summariseIn('हिंदी')));
      await tester.pumpAndSettle();
      // Nothing is still trying: it says what to do, and the button is back.
      expect(
        find.textContaining('Try again in a few minutes.'),
        findsOneWidget,
      );
      expect(find.text(en.summariseIn('हिंदी')), findsOneWidget);
    });
  }

  testWidgets('closing the sheet while a request is out ends it quietly', (
    tester,
  ) async {
    final api = await open(tester, cases: englishOnly());
    final gate = api.gates['summariseOrder'] = Completer<void>();
    api.ai['summariseOrder'] = [const AiResult(jobId: 'job-sum')];
    await openSummary(tester);
    await tap(tester, inSheet(find.text('हिंदी')));
    await tester.pumpAndSettle();
    await tap(tester, find.text(en.summariseIn('हिंदी')));
    await tester.pump();
    await tester.tapAt(const Offset(200, 20)); // outside the sheet
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);

    // The job it started isn't followed: the sheet's ref is gone.
    gate.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing the sheet while it asks about credits sends nothing '
      'more', (tester) async {
    final api = await open(tester, cases: englishOnly());
    api.ai['summariseOrder'] = [
      const ApiException(
        'AI_CREDITS_NEEDED',
        status: 409,
        details: {'credits': 4, 'left': 96},
      ),
    ];
    await openSummary(tester);
    await tap(tester, inSheet(find.text('हिंदी')));
    await tester.pumpAndSettle();
    await tap(tester, find.text(en.summariseIn('हिंदी')));
    await tester.pumpAndSettle();
    final sheet = ModalRoute.of(tester.element(find.byType(BottomSheet)))!;
    sheet.navigator!.removeRoute(sheet);
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.summarySummarise));
    await tester.pumpAndSettle();
    expect(calls(api, 'summariseOrder'), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  group('proposals', () {
    testWidgets('the timeline says how many wait, and the sheet confirms or '
        'dismisses each with Undo, or all', (tester) async {
      final cases = sampleCases();
      await open(tester, cases: cases);
      await tap(tester, find.text(en.summaryToReview(2)));
      await tester.pumpAndSettle();
      expect(inSheet(find.text('${en.summaryActions} (2)')), findsOneWidget);
      expect(find.text('File the reply'), findsOneWidget);
      expect(
        find.text('${en.calendarDeadline} · ${en.proposalDue(date(nov(25)))}'),
        findsOneWidget,
      );
      expect(find.text('Get instructions for the reply'), findsOneWidget);
      expect(find.text(en.proposalTask), findsOneWidget);
      // With proposals there is nothing to find.
      expect(find.text(en.summaryFindActions), findsNothing);

      await tap(
        tester,
        find.bySemanticsLabel(en.proposalConfirmFor('File the reply')),
      );
      await tester.pumpAndSettle();
      expectCall(cases.writes.last, 'confirmProposals', ['p-1']);
      expect(find.text('File the reply'), findsNothing);
      expect(inSheet(find.text(en.proposalsConfirmed(1))), findsOneWidget);
      // Undo is in the sheet, so it can be reached.
      await tester.tap(inSheet(find.text(en.undo)));
      await tester.pumpAndSettle();
      expectCall(cases.writes.last, 'restoreProposals', ['p-1']);
      expect(find.text('File the reply'), findsOneWidget);

      await tap(
        tester,
        find.bySemanticsLabel(
          en.proposalDismissFor('Get instructions for the reply'),
        ),
      );
      await tester.pumpAndSettle();
      expectCall(cases.writes.last, 'dismissProposal', 'p-2');
      expect(inSheet(find.text(en.proposalDismissed)), findsOneWidget);
      await tester.tap(inSheet(find.text(en.undo)));
      await tester.pumpAndSettle();
      expectCall(cases.writes.last, 'restoreProposals', ['p-2']);

      await tap(tester, inSheet(find.text(en.proposalsConfirmAll)));
      await tester.pumpAndSettle();
      expect(cases.writes.last.name, 'confirmProposals');
      expect(cases.writes.last.args, unorderedEquals(['p-1', 'p-2']));
      expect(inSheet(find.text(en.proposalsConfirmed(2))), findsOneWidget);
      expect(find.textContaining(en.summaryActions), findsNothing);
    });

    testWidgets('each shows the order it came from, which opens there (a '
        'deadline at its page)', (tester) async {
      await open(tester);
      await tap(tester, find.text(en.summaryToReview(2)));
      await tester.pumpAndSettle();
      await tap(
        tester,
        inSheet(find.text('Reply within 4 weeks · ${en.sourcePage(2)}')),
      );
      await tester.pumpAndSettle();
      var viewer = tester.widget<ViewerScreen>(find.byType(ViewerScreen));
      expect((viewer.orderId, viewer.page), ('o-1', 2));
      await tester.pageBack();
      await tester.pumpAndSettle();

      // A task has no page.
      await tap(tester, inSheet(find.text('Reply within 4 weeks')));
      await tester.pumpAndSettle();
      viewer = tester.widget<ViewerScreen>(find.byType(ViewerScreen));
      expect((viewer.orderId, viewer.page), ('o-1', null));
    });

    testWidgets('on the Notes tab an untitled order is named by its date', (
      tester,
    ) async {
      final cases = sampleCases();
      cases.proposals['m-1'] = [
        CaseProposal(
          id: 'p-1',
          table: 'deadlines',
          matterId: 'm-1',
          orderId: 'o-1',
          orderDate: DateTime.utc(2026, 10, 28),
          page: 2,
          title: 'File the reply',
          due: nov(25),
        ),
      ];
      await open(tester, location: '/cases/m-1?tab=notes', cases: cases);
      final chip = find.text(
        '${en.proposalSource(date(DateTime.utc(2026, 10, 28)))} · '
        '${en.sourcePage(2)}',
      );
      await scrollUntilBuilt(tester, chip);
      await tap(tester, chip);
      await tester.pumpAndSettle();
      final viewer = tester.widget<ViewerScreen>(find.byType(ViewerScreen));
      expect((viewer.orderId, viewer.page), ('o-1', 2));
    });

    testWidgets("an order with no date says its deadlines can't be counted", (
      tester,
    ) async {
      final api = await open(tester, cases: englishOnly());
      api.ai['orderIntel'] = [
        const ApiException('ORDER_DATE_UNKNOWN', status: 409),
      ];
      await openSummary(tester);
      await tap(tester, find.text(en.summaryFindActions));
      await tester.pumpAndSettle();
      expect(find.text(en.errorOrderDateUnknown), findsOneWidget);
      // It is summarised already: nothing sends the user back to summarising.
      expect(find.textContaining('Summarise'), findsNothing);
    });

    testWidgets('Find actions runs order intelligence: now, or by a job', (
      tester,
    ) async {
      final api = await open(tester, cases: englishOnly());
      api.ai['orderIntel'] = [
        const AiResult(proposed: 2),
        const AiResult(jobId: 'job-intel'),
      ];
      api.jobs['job-intel'] = const Job(
        id: 'job-intel',
        kind: 'order_intel',
        status: JobStatus.done,
        result: {'proposed': 0},
      );
      await openSummary(tester);
      await tap(tester, find.text(en.summaryFindActions));
      await tester.pumpAndSettle();
      expect(find.text(en.summaryActionsFound(2)), findsOneWidget);
      expect(calls(api, 'orderIntel').single, {
        'id': 'o-1',
        'credits': 0,
        'key': calls(api, 'orderIntel').single['key'],
      });

      await tap(tester, find.text(en.summaryFindActions));
      await tester.pumpAndSettle();
      expect(find.text(en.summaryActionsFound(0)), findsOneWidget);
    });

    testWidgets('a clerk may confirm but not find actions', (tester) async {
      await open(tester, cases: englishOnly(), account: clerkAccount);
      await openSummary(tester);
      expect(find.text('Order dated 28-10-2026'), findsOneWidget);
      expect(find.text(en.summaryFindActions), findsNothing);
    });

    testWidgets('the Notes tab lists them; Confirm all adds them to the tasks '
        'and deadlines, with Undo', (tester) async {
      final cases = sampleCases();
      await open(tester, location: '/cases/m-1?tab=notes', cases: cases);
      expect(find.text('${en.casePageTasks} (3)'), findsOneWidget);
      // After the notes, tasks and deadlines.
      final title = find.text('${en.proposalsTitle} (2)');
      await scrollUntilBuilt(tester, title);
      expect(title, findsOneWidget);
      await tap(tester, find.text(en.proposalsConfirmAll));
      await tester.pumpAndSettle();
      expect(cases.writes.last.args, unorderedEquals(['p-1', 'p-2']));
      expect(find.textContaining(en.proposalsTitle), findsNothing);
      expect(find.text('${en.casePageTasks} (4)'), findsOneWidget);
      expect(find.text('Get instructions for the reply'), findsOneWidget);
      // A confirmed deadline shows what it is, not just its kind.
      expect(find.text('${en.casePageDeadlines} (2)'), findsOneWidget);
      expect(find.text('File the reply'), findsOneWidget);
      await tester.tap(find.text(en.undo));
      await tester.pumpAndSettle();
      await scrollUntilBuilt(tester, title);
      expect(title, findsOneWidget);
      expect(find.text('File the reply'), findsOneWidget); // a proposal again
    });
  });

  testWidgets("an uploaded order's Summary is asked for and opens its pages", (
    tester,
  ) async {
    final cases = sampleCases()
      ..documents['m-1']!.add(
        const CaseDocument(
          id: 'd-4',
          title: 'Certified copy of the order',
          kind: 'order',
          pages: 3,
        ),
      );
    final api = await open(
      tester,
      location: '/cases/m-1?tab=documents',
      cases: cases,
    );
    api.ai['summariseDocument'] = [AiResult(summary: orderSummary())];
    Finder menu(String id) => find.descendant(
      of: find.byKey(ValueKey(id)),
      matching: find.byTooltip(en.docsMoreActions),
    );
    // Only an order has one.
    await tap(tester, menu('d-1'));
    await tester.pumpAndSettle();
    expect(find.text(en.summaryButton), findsNothing);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    await tap(tester, menu('d-4'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.summaryButton));
    await tester.pumpAndSettle();
    expect(find.text(en.summaryNone('English')), findsOneWidget);
    // No proposals for uploads.
    expect(find.text(en.summaryFindActions), findsNothing);
    await tap(tester, find.text(en.summariseIn('English')));
    await tester.pumpAndSettle();
    expect(calls(api, 'summariseDocument').single['id'], 'd-4');
    expect(find.text('Order dated 28-10-2026'), findsOneWidget);
    expect(find.text(en.summaryFindActions), findsNothing);

    await tap(
      tester,
      find.text('${en.casePageOrder} · ${en.sourcePage(2)}').first,
    );
    await tester.pumpAndSettle();
    final viewer = tester.widget<ViewerScreen>(find.byType(ViewerScreen));
    expect((viewer.documentId, viewer.page), ('d-4', 2));
  });

  for (final (code, text) in [
    ('AI_CREDITS_EXHAUSTED', en.errorAiCreditsExhausted),
    ('DOCUMENT_NOT_AN_ORDER', en.errorDocumentNotAnOrder),
    ('NETWORK', en.errorNeedsNetwork),
  ]) {
    testWidgets('$code is said under the button', (tester) async {
      final api = await open(tester, cases: englishOnly());
      api.ai['summariseOrder'] = [ApiException(code, status: 402)];
      await openSummary(tester);
      await tap(tester, inSheet(find.text('हिंदी')));
      await tester.pumpAndSettle();
      await tap(tester, find.text(en.summariseIn('हिंदी')));
      await tester.pumpAndSettle();
      expect(find.text(text), findsOneWidget);
    });
  }
}
