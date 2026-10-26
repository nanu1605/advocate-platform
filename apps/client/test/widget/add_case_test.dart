import 'dart:async';

import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/courts.dart';
import 'package:advocate_app/features/case_page/case_page.dart';
import 'package:advocate_app/features/cases/manual_case_screen.dart';
import 'package:advocate_app/features/cases/search_cases_screen.dart';
import 'package:advocate_app/ui/skeleton.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

final Court _indore = testCourts[0];
final Court _jabalpur = testCourts[1];
final Court _supreme = testCourts[4];

/// Search hit [n]: WP 100n/2024 at MPHC Indore (provider code MPHC01), the same CNR as `caseInfo(n)`.
CaseHit _hit(
  int n, {
  bool tracked = false,
  String status = 'pending',
  String title = 'Sharma v. State of MP',
}) => CaseHit(
  cnr: 'MPHC01${n.toString().padLeft(10, '0')}',
  courtCode: 'MPHC01',
  caseType: 'WP',
  caseNumber: '${1000 + n}',
  caseYear: 2024,
  title: title,
  status: status,
  nextHearingDate: DateTime.utc(2026, 11, 12),
  advocates: const [(name: 'R. K. Verma', side: 'petitioner')],
  tracked: tracked,
);

CaseSearchPage _page(
  List<CaseHit> items, {
  int page = 1,
  bool hasNext = false,
  bool postFiltered = false,
  List<String> ignored = const [],
}) => CaseSearchPage(
  items: items,
  total: items.length,
  page: page,
  hasNext: hasNext,
  postFiltered: postFiltered,
  ignoredCourtIds: ignored,
);

/// The cases in [cases], the synced courts, and MPHC Indore as the provider's court MPHC01.
List<Override> _overrides([FakeCases? cases]) => [
  ...(cases ?? FakeCases()).overrides,
  courtsProvider.overrideWithValue(const AsyncData(testCourts)),
  courtsByCodeProvider.overrideWithValue(AsyncData({'MPHC01': _indore})),
];

/// Add case (spec §4.1, §4.3, §11.7): the chooser from "+" and Ctrl+N, Search the courts with "Track this case",
/// and Add by hand. Add task opens the task sheet.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  Future<void> openPlus(WidgetTester tester) async {
    await tester.tap(find.text(en.navAdd));
    await tester.pumpAndSettle();
  }

  /// Scrolls [finder] into view, then taps it. Settles first: a field just typed in scrolls itself back into view.
  Future<void> tapOn(WidgetTester tester, Finder finder) async {
    await tester.pumpAndSettle();
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.widgetWithText(TextField, label);

  /// Taps [finder], which adds a case, then lets the case page open; it never settles while the new case loads.
  Future<void> tapToAdd(WidgetTester tester, Finder finder) async {
    await tester.pumpAndSettle();
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// The case page for [id], just added: loading, not "removed", until sync brings its row ([row]), then the case.
  Future<void> expectNewCase(
    WidgetTester tester,
    FakeCases cases,
    CaseInfo row,
  ) async {
    expect(tester.widget<CasePage>(find.byType(CasePage)).matterId, row.id);
    expect(find.text(en.casePageRemoved), findsNothing);
    expect(find.byType(SkeletonCaseList), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text(en.casePageRemoved), findsNothing);
    cases.cases.add(row);
    cases.updateCase(row.id, (c) => c);
    await tester.pumpAndSettle();
    expect(find.byType(SkeletonCaseList), findsNothing);
    expect(find.widgetWithText(AppBar, row.caseLabel), findsOneWidget);
  }

  testWidgets('+ → Add case → the chooser: search, by hand, by CNR', (
    tester,
  ) async {
    final api = await pumpApp(tester, overrides: FakeCases().overrides);
    await openPlus(tester);
    await tester.tap(find.text(en.addCase));
    await tester.pumpAndSettle();
    expect(find.text(en.casesAddTitle), findsOneWidget);
    await tester.tap(find.text(en.casesAddSearch));
    await tester.pumpAndSettle();
    expect(find.byType(SearchCasesScreen), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await openPlus(tester);
    await tester.tap(find.text(en.addCase));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.casesAddManual));
    await tester.pumpAndSettle();
    expect(find.byType(ManualCaseScreen), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await openPlus(tester);
    await tester.tap(find.text(en.addCase));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.casesAddByCnr));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'MPHC010012342024');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(api.callNames, contains('addByCnr'));
    expect(tester.widget<CasePage>(find.byType(CasePage)).matterId, 'matter-1');
    // Loading while sync brings the row; a case that never arrives reads as removed after a minute.
    expect(find.byType(SkeletonCaseList), findsOneWidget);
    expect(find.text(en.casePageRemoved), findsNothing);
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(find.text(en.casePageRemoved), findsOneWidget);
  });

  testWidgets('By CNR over the allowance names the allowance', (tester) async {
    final api = await pumpApp(tester, overrides: FakeCases().overrides);
    api.fail['addByCnr'] = const ApiException(
      'TRACKED_CASE_LIMIT',
      details: {'limit': 100},
    );
    await openPlus(tester);
    await tester.tap(find.text(en.addCase));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.casesAddByCnr));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'MPHC010012342024');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text(en.casesTrackingLimit(100)), findsOneWidget);
  });

  testWidgets(
    '+ → Add task opens the task sheet; Add document asks scan or files',
    (tester) async {
      await pumpApp(tester, overrides: FakeCases().overrides);
      await openPlus(tester);
      await tester.tap(find.text(en.addTask));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text(en.addTask),
        ),
        findsOneWidget,
      );
      await tester.tapAt(const Offset(200, 40));
      await tester.pumpAndSettle();
      await openPlus(tester);
      await tester.tap(find.text(en.addDocument));
      await tester.pumpAndSettle();
      expect(find.text(en.docsScan), findsOneWidget);
      expect(find.text(en.docsChooseFiles), findsOneWidget);
    },
  );

  testWidgets('Ctrl+N opens the Add case chooser on Windows', (tester) async {
    await pumpApp(
      tester,
      size: const Size(1280, 800),
      overrides: FakeCases().overrides,
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text(en.casesAddTitle), findsOneWidget);
  });

  group('Search the courts', () {
    testWidgets('needs a name or words, and a year it can use', (tester) async {
      final announced = captureAnnouncements(tester);
      final api = await pumpApp(
        tester,
        location: '/cases/search',
        overrides: _overrides(),
      );
      announced.clear();
      await tapOn(tester, find.text(en.addCaseSearchAction));
      expect(find.text(en.errorSearchTerms), findsOneWidget);
      expect(announced, [en.errorSearchTerms]);

      await tester.enterText(field(en.addCaseYear), '1800');
      await tester.enterText(field(en.addCaseJudge), 'Mehta');
      await tapOn(tester, find.text(en.addCaseSearchAction));
      expect(find.text(en.errorSearchTerms), findsNothing);
      expect(find.text(en.addCaseYearInvalid), findsOneWidget);
      expect(announced, [en.errorSearchTerms, en.addCaseYearInvalid]);
      expect(api.callNames, isNot(contains('searchCases')));
    });

    testWidgets(
      'results with coverage notes; Track this case opens the new case',
      (tester) async {
        final cases = FakeCases();
        final api = FakeApi(account: ownerAccount)
          ..searchPages = [
            _page(
              [_hit(1), _hit(2, status: 'disposed')],
              postFiltered: true,
              ignored: [_supreme.id],
            ),
          ];
        await pumpApp(
          tester,
          location: '/cases/search',
          api: api,
          overrides: _overrides(cases),
        );
        await tester.enterText(field(en.addCaseParty), 'Sharma');
        await tester.enterText(field(en.addCaseCaseType), 'WP');
        await tester.enterText(field(en.addCaseYear), '2024');
        await tapOn(tester, find.widgetWithText(FilterChip, 'Supreme Court'));
        await tapOn(tester, find.widgetWithText(FilterChip, 'MPHC Indore'));
        await tapOn(tester, find.text(en.addCaseSearchAction));

        final args = api.calls.last.args! as Map<String, Object?>;
        expect(api.calls.last.name, 'searchCases');
        expect(args['party'], 'Sharma');
        expect(args['caseType'], 'WP');
        expect(args['year'], 2024);
        expect(args['courtIds'], [_supreme.id, _indore.id]);
        expect(args['page'], 1);

        // Narrowed by case type and year: the count is the hits shown, not the provider's total.
        expect(find.text(en.addCaseFound(2)), findsOneWidget);
        // The Supreme Court can't be searched yet: the note names only the court searched.
        expect(
          find.text(en.addCaseCoverage('MP ${en.highCourt} Indore')),
          findsOneWidget,
        );
        expect(find.text(en.addCaseIgnored('Supreme Court')), findsOneWidget);
        expect(find.text(en.addCaseNarrowed), findsOneWidget);
        expect(find.text('WP 1001/2024'), findsOneWidget);
        expect(find.text('MPHC Indore'), findsWidgets);
        expect(find.text(en.addCaseAdvocates('R. K. Verma')), findsNWidgets(2));
        expect(find.text(en.statusDisposed), findsOneWidget);
        expect(find.text(en.foundPending), findsOneWidget);

        await tapToAdd(tester, find.text(en.addCaseTrack).first);
        final track = api.calls.last;
        expect(track.name, 'addByCnr');
        expect((track.args! as Map)['cnr'], 'MPHC010000000001');
        expect(find.text(en.foundCnrAdded), findsOneWidget);
        await expectNewCase(
          tester,
          cases,
          CaseInfo(
            id: 'matter-1',
            cnr: 'MPHC010000000001',
            caseType: 'WP',
            caseNumber: '1001',
            caseYear: 2024,
          ),
        );
      },
    );

    testWidgets('only the courts the provider can search are named', (
      tester,
    ) async {
      final api = FakeApi(account: ownerAccount)
        ..searchPages = [
          _page([_hit(1)], ignored: [_supreme.id]),
        ];
      await pumpApp(
        tester,
        location: '/cases/search',
        api: api,
        overrides: _overrides(),
      );
      await tester.enterText(field(en.addCaseParty), 'Sharma');
      await tapOn(tester, find.widgetWithText(FilterChip, 'Supreme Court'));
      await tapOn(tester, find.text(en.addCaseSearchAction));
      // None of the chosen courts could be searched, so the API searched every court.
      expect(find.text(en.addCaseCoverageAll), findsOneWidget);
      expect(find.textContaining('Supreme Court +'), findsNothing);
      expect(find.text(en.addCaseIgnored('Supreme Court')), findsOneWidget);
    });

    testWidgets('the screen reader reads a hit as one row', (tester) async {
      final api = FakeApi(account: ownerAccount)
        ..searchPages = [
          _page([_hit(1)]),
        ];
      await pumpApp(
        tester,
        location: '/cases/search',
        api: api,
        overrides: _overrides(),
      );
      await tester.enterText(field(en.addCaseParty), 'Sharma');
      await tapOn(tester, find.text(en.addCaseSearchAction));
      final handle = tester.ensureSemantics();
      await tester.pump();
      final row = find.descendant(
        of: find.byType(Card).first,
        matching: find.byType(MergeSemantics),
      );
      expect(
        tester.getSemantics(row),
        isSemantics(
          label:
              '${en.foundCaseSpoken('WP', '1001', '2024')}. '
              'MP ${en.highCourt} Indore. ${en.nextDate} Thu, 12 Nov 2026. '
              '${en.foundPending}. Sharma v. State of MP. '
              '${en.addCaseAdvocates('R. K. Verma')}\n${en.addCaseTrack}',
          isButton: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('a hit the org tracks opens the case on the device', (
      tester,
    ) async {
      final api = FakeApi(account: ownerAccount)
        ..searchPages = [
          _page([_hit(2, tracked: true)]),
        ];
      await pumpApp(
        tester,
        location: '/cases/search',
        api: api,
        overrides: _overrides(FakeCases(cases: [caseInfo(2)])),
      );
      await tester.enterText(field(en.addCaseAdvocate), 'Verma');
      await tapOn(tester, find.text(en.addCaseSearchAction));
      expect(find.text(en.addCaseTrack), findsNothing);
      await tapOn(tester, find.text(en.addCaseTracking));
      expect(api.callNames, isNot(contains('addByCnr')));
      expect(tester.widget<CasePage>(find.byType(CasePage)).matterId, 'm-2');
    });

    testWidgets('Load more adds the next page', (tester) async {
      final api = FakeApi(account: ownerAccount)
        ..searchPages = [
          _page([_hit(1)], hasNext: true),
          _page([_hit(3)], page: 2),
        ];
      await pumpApp(
        tester,
        location: '/cases/search',
        api: api,
        overrides: _overrides(),
      );
      await tester.enterText(field(en.addCaseWords), 'housing board');
      await tapOn(tester, find.text(en.addCaseSearchAction));
      expect(find.text(en.addCaseCoverageAll), findsOneWidget);
      expect(find.text('WP 1003/2024'), findsNothing);
      await tapOn(tester, find.text(en.addCaseLoadMore));
      expect((api.calls.last.args! as Map)['page'], 2);
      expect((api.calls.last.args! as Map)['text'], 'housing board');
      expect(find.text('WP 1001/2024'), findsOneWidget);
      expect(find.text('WP 1003/2024'), findsOneWidget);
      expect(find.text(en.addCaseLoadMore), findsNothing);
    });

    testWidgets("a page still loading for the last search isn't added to "
        'a new one', (tester) async {
      final api = FakeApi(account: ownerAccount)
        ..searchPages = [
          _page([_hit(1)], hasNext: true),
          _page([_hit(3)], page: 2),
        ];
      await pumpApp(
        tester,
        location: '/cases/search',
        api: api,
        overrides: _overrides(),
      );
      await tester.enterText(field(en.addCaseWords), 'housing board');
      await tapOn(tester, find.text(en.addCaseSearchAction));
      final gate = api.gates['searchCases'] = Completer<void>();
      // The spinners turn while it loads, so pump rather than settle.
      await tester.ensureVisible(find.text(en.addCaseLoadMore));
      await tester.tap(find.text(en.addCaseLoadMore));
      await tester.pump();
      await tester.enterText(field(en.addCaseWords), 'housing');
      await tester.ensureVisible(find.text(en.addCaseSearchAction));
      await tester.tap(find.text(en.addCaseSearchAction));
      await tester.pump();
      await tester.pump();
      expect((api.calls.last.args! as Map)['text'], 'housing');
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('WP 1001/2024'), findsOneWidget);
      expect(find.text('WP 1003/2024'), findsNothing);
    });

    testWidgets('a case number goes in "Any other words", as its hint says, '
        'and is sent as the search text', (tester) async {
      final api = await pumpApp(
        tester,
        location: '/cases/search',
        overrides: _overrides(),
      );
      final words = field(en.addCaseWords);
      expect(
        tester.widget<TextField>(words).decoration?.hintText,
        en.addCaseWordsHint,
      );
      await tester.enterText(words, '1234');
      await tester.enterText(field(en.addCaseCaseType), 'WP');
      await tester.enterText(field(en.addCaseYear), '2024');
      await tapOn(tester, find.text(en.addCaseSearchAction));
      expect(api.calls.last.name, 'searchCases');
      final args = api.calls.last.args! as Map<String, Object?>;
      expect(args['text'], '1234');
      expect(args['caseType'], 'WP');
      expect(args['year'], 2024);
    });

    testWidgets('no results says so', (tester) async {
      await pumpApp(tester, location: '/cases/search', overrides: _overrides());
      await tester.enterText(field(en.addCaseParty), 'Nobody');
      await tapOn(tester, find.text(en.addCaseSearchAction));
      expect(find.text(en.addCaseNoResults), findsOneWidget);
    });

    for (final (code, text) in [
      ('SEARCH_TERMS_REQUIRED', en.errorSearchTerms),
      ('SEARCH_DAILY_CAP', en.errorSearchDailyCap),
      ('RATE_LIMITED', en.errorTooMany),
      ('COURT_PROVIDER_UNAVAILABLE', en.addCaseProviderDown),
      ('NETWORK', en.errorNeedsNetwork),
    ]) {
      testWidgets('$code is explained and the form is kept', (tester) async {
        final announced = captureAnnouncements(tester);
        final api = await pumpApp(
          tester,
          location: '/cases/search',
          overrides: _overrides(),
        );
        api.fail['searchCases'] = ApiException(code);
        await tester.enterText(field(en.addCaseParty), 'Sharma');
        await tapOn(tester, find.text(en.addCaseSearchAction));
        expect(find.text(text), findsOneWidget);
        // Read out once, by the notice; the screen doesn't say it as well.
        expect(announced.where((m) => m == text), hasLength(1));
        expect(find.text(code), findsNothing);
        expect(find.text('Sharma'), findsOneWidget);
      });
    }

    testWidgets('Track this case over the allowance names the allowance', (
      tester,
    ) async {
      final api = FakeApi(account: ownerAccount)
        ..searchPages = [
          _page([_hit(1)]),
        ]
        ..fail['addByCnr'] = const ApiException(
          'TRACKED_CASE_LIMIT',
          details: {'limit': 100},
        );
      await pumpApp(
        tester,
        location: '/cases/search',
        api: api,
        overrides: _overrides(),
      );
      await tester.enterText(field(en.addCaseParty), 'Sharma');
      await tapOn(tester, find.text(en.addCaseSearchAction));
      await tapOn(tester, find.text(en.addCaseTrack));
      expect(find.text(en.casesTrackingLimit(100)), findsOneWidget);
      expect(find.byType(SearchCasesScreen), findsOneWidget);
    });

    for (final locale in ['en', 'hi']) {
      testWidgets('results meet the a11y guidelines ($locale)', (tester) async {
        final api = FakeApi(account: ownerAccount)
          ..searchPages = [
            _page([_hit(1), _hit(2, tracked: true)], hasNext: true),
          ];
        await pumpApp(
          tester,
          location: '/cases/search',
          locale: locale,
          api: api,
          overrides: _overrides(),
        );
        final l = lookupAppLocalizations(Locale(locale));
        await tester.enterText(field(l.addCaseParty), 'Sharma');
        await tapOn(tester, find.text(l.addCaseSearchAction));
        final handle = tester.ensureSemantics();
        await tester.pump();
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        handle.dispose();
      });
    }
  });

  group('Add by hand', () {
    testWidgets('errors are inline and nothing is sent', (tester) async {
      final announced = captureAnnouncements(tester);
      final api = await pumpApp(
        tester,
        location: '/cases/manual',
        overrides: _overrides(),
      );
      announced.clear();
      final add = find.widgetWithText(FilledButton, en.addCase);
      await tapOn(tester, add);
      expect(find.text(en.addCasePartiesRequired), findsOneWidget);
      expect(announced, [en.addCasePartiesRequired]);
      expect(find.text(en.errorCourtRequired), findsOneWidget);

      await tester.enterText(field(en.addCaseParties), 'Sharma v. State');
      await tester.enterText(field(en.addCaseYear), '20');
      await tester.enterText(field(en.nextDate), '31-02-2026');
      await tapOn(tester, add);
      expect(find.text(en.addCasePartiesRequired), findsNothing);
      expect(find.text(en.addCaseYearInvalid), findsOneWidget);
      expect(find.text(en.dateInvalid), findsOneWidget);
      expect(api.callNames, isNot(contains('addManual')));
    });

    testWidgets('sends the case and opens it', (tester) async {
      final cases = FakeCases();
      final api = await pumpApp(
        tester,
        location: '/cases/manual',
        overrides: _overrides(cases),
      );
      await tester.enterText(field(en.addCaseParties), 'Sharma v. State');
      await tapOn(tester, find.byType(DropdownButtonFormField<String>));
      await tester.tap(find.text('MPHC Jabalpur').last);
      await tester.pumpAndSettle();
      await tester.enterText(field(en.addCaseCaseType), 'WP');
      await tester.enterText(field(en.addCaseNumber), '55');
      await tester.enterText(field(en.addCaseYear), '2023');
      await tester.enterText(field(en.addCaseOurSide), 'Petitioner');
      await tester.enterText(field(en.addCaseFileNo), 'F-12');
      await tester.enterText(field(en.nextDate), '12-11-2026');
      await tapToAdd(tester, find.widgetWithText(FilledButton, en.addCase));

      expect(api.calls.last.name, 'addManual');
      expect(api.calls.last.args, {
        'title': 'Sharma v. State',
        'courtId': _jabalpur.id,
        'courtName': null,
        'caseType': 'WP',
        'caseNumber': '55',
        'caseYear': 2023,
        'ourSide': 'Petitioner',
        'fileNo': 'F-12',
        'nextDate': DateTime.utc(2026, 11, 12),
      });
      expect(find.text(en.addCaseAdded), findsOneWidget);
      await expectNewCase(
        tester,
        cases,
        CaseInfo(
          id: 'matter-manual',
          caseType: 'WP',
          caseNumber: '55',
          caseYear: 2023,
          tracking: 'manual',
        ),
      );
    });

    testWidgets("fields stop at the API's lengths", (tester) async {
      await pumpApp(tester, location: '/cases/manual', overrides: _overrides());
      for (final (label, max) in [
        (en.addCaseParties, 300),
        (en.addCaseCaseType, 50),
        (en.addCaseNumber, 50),
        (en.addCaseOurSide, 100),
        (en.addCaseFileNo, 100),
      ]) {
        await tester.enterText(field(label), 'x' * (max + 20));
        expect(
          tester.widget<TextField>(field(label)).controller!.text,
          hasLength(max),
          reason: label,
        );
      }
    });

    testWidgets('Other court takes a typed name; offline keeps the form', (
      tester,
    ) async {
      final announced = captureAnnouncements(tester);
      final api = await pumpApp(
        tester,
        location: '/cases/manual',
        overrides: _overrides(),
      );
      await tester.enterText(field(en.addCaseParties), 'Sharma v. Sharma');
      await tapOn(tester, find.byType(DropdownButtonFormField<String>));
      await tester.tap(find.text(en.foundOtherCourt).last);
      await tester.pumpAndSettle();
      final add = find.widgetWithText(FilledButton, en.addCase);
      await tapOn(tester, add);
      expect(find.text(en.addCaseCourtNameRequired), findsOneWidget);

      await tester.enterText(field(en.addCaseCourtName), 'Family Court Indore');
      api.offline = true;
      await tapOn(tester, add);
      expect(find.text(en.errorNeedsNetwork), findsOneWidget);
      // Read out once, by the notice; the screen doesn't say it as well.
      expect(announced.where((m) => m == en.errorNeedsNetwork), hasLength(1));
      expect(find.text('Sharma v. Sharma'), findsOneWidget);
      expect(find.byType(ManualCaseScreen), findsOneWidget);

      api
        ..offline = false
        ..fail['addManual'] = const ApiException('UNKNOWN_COURT');
      await tapOn(tester, add);
      expect(find.text(en.errorUnknownCourt), findsOneWidget);

      api.fail.clear();
      await tapOn(tester, add);
      final args = api.calls.last.args! as Map;
      expect(args['courtId'], isNull);
      expect(args['courtName'], 'Family Court Indore');
      expect(args['nextDate'], isNull);
    });

    for (final locale in ['en', 'hi']) {
      testWidgets('the form meets the a11y guidelines ($locale)', (
        tester,
      ) async {
        await pumpApp(
          tester,
          location: '/cases/manual',
          locale: locale,
          overrides: _overrides(),
        );
        final handle = tester.ensureSemantics();
        await tester.pump();
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        handle.dispose();
      });
    }
  });
}
