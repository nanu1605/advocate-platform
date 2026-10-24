import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/router.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/courts.dart';
import 'package:advocate_app/data/found_cases.dart';
import 'package:advocate_app/ui/selectable_row.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

const _district = 'c0000000-0000-0000-0000-000000000005';

/// WP 1001 (ticked), WP 1002 low confidence (unticked), CS 1003 at the district court (ticked), a disposed case.
List<FoundCase> _sample() => [
  foundCase(1, nextDate: DateTime(2026, 11, 5)),
  foundCase(2, confidence: 'low', title: 'Gupta v. Jain'),
  foundCase(3, courtId: _district, caseType: 'CS', caseYear: 2019),
  foundCase(4, status: 'disposed', title: 'Verma v. State'),
];

Future<FakeApi> _open(
  WidgetTester tester, {
  List<FoundCase>? found,
  String locale = 'en',
  double scale = 1,
  Size size = const Size(400, 860),
  int? allowance = 100,
  bool offline = false,
  bool onboardingDone = false,
  bool settled = false,
  FakeApi? api,
}) => pumpApp(
  tester,
  location: '/found',
  onboardingDone: onboardingDone,
  locale: locale,
  textScale: scale,
  size: size,
  api: api,
  overrides: syncedData(
    found: found ?? _sample(),
    allowance: allowance,
    offline: offline,
    settled: settled,
  ),
);

String _path(WidgetTester tester) =>
    container(tester)
        .read(routerProvider)
        .routerDelegate
        .currentConfiguration
        .uri
        .path;

/// Pumps through the add request and the success check.
Future<void> _settleAdd(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
}

/// Found cases (spec §4.1): defaults, Add all or a selection, allowance, offline, empty and error states,
/// "Not mine", a selection that outlives the screen, and Windows keys.
void main() {
  setUpAll(loadAppFonts);
  final en = lookupAppLocalizations(const Locale('en'));

  for (final locale in ['en', 'hi']) {
    final l = lookupAppLocalizations(Locale(locale));
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'counts, groups and defaults, read in full ($locale ${scale}x)',
        (tester) async {
          final handle = tester.ensureSemantics();
          await _open(tester, locale: locale, scale: scale);
          expect(find.text(l.foundTitle), findsOneWidget);
          expect(find.text(l.foundHeading(4)), findsOneWidget);
          expect(find.text(l.foundSummary(3, 1)), findsOneWidget);
          expect(find.text(l.foundAddAll(3)), findsOneWidget);
          expect(find.text(l.foundAddCount(2)), findsOneWidget);
          expect(find.text(l.selectAll), findsOneWidget);
          // Said in full ("MP High Court Indore"): "MPHC" would be spelt out letter by letter.
          final court =
              'MP ${l.highCourt} ${locale == 'hi' ? 'इंदौर' : 'Indore'}';
          final date = locale == 'hi' ? '5 नवंबर' : '5 November';
          expect(
            find.bySemanticsLabel(
              '${l.selected}. ${l.foundCaseSpoken('WP', '1001', '2024')}. '
              '$court, ${l.courtNo('12')}. ${l.nextDate} $date. ${l.foundPending}. '
              'Sharma v. State of MP',
            ),
            findsOneWidget,
          );
          if (scale == 1) {
            expect(
              find.bySemanticsLabel(RegExp('^${l.notSelected}\\. .*Gupta')),
              findsOneWidget,
            );
            expect(find.text(l.foundCheck), findsOneWidget);
            // Disposed cases are folded under "Disposed (1)".
            expect(find.text('${l.statusDisposed} (1)'), findsOneWidget);
            expect(find.textContaining('Verma'), findsNothing);
          }
          expect(tester.takeException(), isNull);
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          handle.dispose();
        },
      );
    }
  }

  testWidgets(
    'ticking changes the count; all pending reads "Add all"; none reads "Skip for now"',
    (tester) async {
      await _open(tester);
      await tester.tap(find.textContaining('Gupta'));
      await tester.pumpAndSettle();
      expect(find.text(en.foundAddAllCount(3)), findsOneWidget);
      await tester.tap(find.text(en.selectNone));
      await tester.pumpAndSettle();
      expect(find.text(en.foundSkip), findsOneWidget);
      await tester.tap(find.text(en.selectAll));
      await tester.pumpAndSettle();
      expect(find.text(en.foundAddAllCount(3)), findsOneWidget);
      // The disposed group checkbox ticks disposed cases; then it is a selection, not "Add all".
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(GroupHeader, '${en.statusDisposed} (1)'),
          matching: find.byType(Checkbox),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(en.foundAddCount(4)), findsOneWidget);
    },
  );

  testWidgets('adding a selection sends its ids, then onboarding moves on', (
    tester,
  ) async {
    final api = await _open(tester);
    api.addResult = (added: 2, alreadyTracked: 0, matterIds: ['m-1', 'm-2']);
    await tester.tap(find.text(en.foundAddCount(2)));
    await _settleAdd(tester);
    final call = api.calls.singleWhere((c) => c.name == 'addFoundCases');
    expect((call.args! as Map)['ids'], ['fc-1', 'fc-3']);
    expect(_path(tester), '/onboarding/notifications');
  });

  testWidgets(
    'every pending match ticked still goes as its ids; outside onboarding, back',
    (tester) async {
      final api = await _open(tester, onboardingDone: true, settled: true);
      await tester.tap(find.text(en.selectAll));
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.foundAddAllCount(3)));
      await _settleAdd(tester);
      final call = api.calls.singleWhere((c) => c.name == 'addFoundCases');
      expect((call.args! as Map)['ids'], ['fc-1', 'fc-2', 'fc-3']);
      expect(api.callNames, isNot(contains('addAllFoundCases')));
      expect(_path(tester), '/cases');
    },
  );

  testWidgets('reduce motion: no success animation, straight on', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await _open(tester);
    await tester.tap(find.text(en.foundAddCount(2)));
    await tester.pumpAndSettle();
    expect(_path(tester), '/onboarding/notifications');
  });

  testWidgets('Add all with low-confidence matches asks first', (tester) async {
    final api = await _open(tester, settled: true);
    await tester.tap(find.text(en.foundAddAll(3)));
    await tester.pumpAndSettle();
    expect(find.text(en.foundLowTitle(1)), findsOneWidget);
    // "Review those" shows only the low-confidence matches.
    await tester.tap(find.text(en.foundLowReview(1)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Gupta'), findsOneWidget);
    expect(find.textContaining('Sharma'), findsNothing);
    expect(find.text(en.foundFilters(1)), findsOneWidget);
    expect(api.callNames, isNot(contains('addAllFoundCases')));

    await tester.tap(find.text(en.foundAddAll(3)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.foundLowAddAll(3)));
    await _settleAdd(tester);
    expect(api.callNames, contains('addAllFoundCases'));
  });

  testWidgets(
    'Add all while the search is still running sends the cases on screen, not {all: true}',
    (tester) async {
      // 10 synced so far; the server may already hold more (the job is still writing them).
      final api = await _open(
        tester,
        found: [for (var i = 1; i <= 10; i++) foundCase(i)],
      );
      await tester.tap(find.text(en.foundAddAll(10)));
      await _settleAdd(tester);
      expect(api.callNames, isNot(contains('addAllFoundCases')));
      final call = api.calls.singleWhere((c) => c.name == 'addFoundCases');
      expect((call.args! as Map)['ids'], [
        for (var i = 1; i <= 10; i++) 'fc-$i',
      ]);
    },
  );

  testWidgets('Add all reuses its key only while the set is the same', (
    tester,
  ) async {
    final api = await _open(
      tester,
      found: [foundCase(1), foundCase(2), foundCase(3)],
      settled: true,
    );
    api.fail['addAllFoundCases'] = const ApiException('NETWORK');
    Future<void> addAll(int n) async {
      await tester.tap(find.text(en.foundAddAll(n)));
      await tester.pumpAndSettle();
    }

    await addAll(3);
    await addAll(3);
    // One case marked "Not mine": a different set, so a new action.
    await tester.tap(find.byTooltip(en.foundRowActions('WP 1001/2024')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.foundNotMine));
    await tester.pumpAndSettle();
    await addAll(2);
    final keys = [
      for (final c in api.calls)
        if (c.name == 'addAllFoundCases') (c.args! as Map)['key'],
    ];
    expect(keys, hasLength(3));
    expect(keys[0], keys[1]);
    expect(keys[2], isNot(keys[1]));
  });

  testWidgets('TRACKED_CASE_LIMIT explains and keeps the selection', (
    tester,
  ) async {
    final api = await _open(tester);
    api.fail['addFoundCases'] = const ApiException(
      'TRACKED_CASE_LIMIT',
      status: 409,
      details: {'limit': 10, 'remaining': 1},
    );
    await tester.tap(find.text(en.foundAddCount(2)));
    await tester.pumpAndSettle();
    expect(find.text(en.errorTrackedCaseLimit(1)), findsOneWidget);
    expect(find.text(en.foundAddCount(2)), findsOneWidget);
    expect(_path(tester), '/found');
  });

  testWidgets('over the synced allowance: says so, keeps the selection', (
    tester,
  ) async {
    await _open(tester, allowance: 1);
    expect(find.text(en.foundAllowance(1)), findsOneWidget);
    FilledButton add() => tester.widget<FilledButton>(
      find.ancestor(
        of: find.text(en.foundAddCount(2)),
        matching: find.byType(FilledButton),
      ),
    );
    expect(add().onPressed, isNull);
    await tester.tap(find.textContaining('CS 1003'));
    await tester.pumpAndSettle();
    expect(find.text(en.foundAllowance(1)), findsNothing);
    expect(find.text(en.foundAddCount(1)), findsOneWidget);
  });

  testWidgets(
    'offline: saved rows, Add needs a connection and keeps the work; the retry reuses its key',
    (tester) async {
      final api = await _open(tester, offline: true);
      api.offline = true;
      expect(find.byType(OfflineBanner), findsOneWidget);
      expect(find.textContaining('WP 1001'), findsOneWidget);
      await tester.tap(find.text(en.foundAddCount(2)));
      await tester.pumpAndSettle();
      expect(find.text(en.errorNeedsNetwork), findsOneWidget);
      expect(find.text(en.foundAddCount(2)), findsOneWidget);

      api.offline = false;
      await tester.tap(find.text(en.foundAddCount(2)));
      await _settleAdd(tester);
      final keys = [
        for (final c in api.calls)
          if (c.name == 'addFoundCases') (c.args! as Map)['key'],
      ];
      expect(keys, hasLength(2));
      expect(keys.first, keys.last);
    },
  );

  testWidgets('nothing found: keep looking, add by CNR, or skip', (
    tester,
  ) async {
    final api = await _open(tester, found: []);
    expect(find.text(en.foundEmpty), findsOneWidget);
    await tester.tap(find.text(en.foundAddByCnr));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'ABC');
    await tester.tap(find.text(en.addCase));
    await tester.pumpAndSettle();
    expect(find.text(en.errorInvalidCnr), findsOneWidget);
    expect(api.callNames, isNot(contains('addByCnr')));

    await tester.enterText(find.byType(TextField), 'mphc 0100-1234-2024');
    await tester.tap(find.text(en.addCase));
    await tester.pumpAndSettle();
    final call = api.calls.singleWhere((c) => c.name == 'addByCnr');
    expect((call.args! as Map)['cnr'], 'MPHC010012342024');
    expect(find.text(en.foundCnrAdded), findsOneWidget);

    await tester.tap(find.text(en.foundSkip));
    await tester.pumpAndSettle();
    expect(_path(tester), '/onboarding/notifications');
  });

  testWidgets(
    'Add by CNR: a CNR already tracked says so; errors are read out; Enter twice sends once',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(supportsAnnounce: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final announced = <String>[];
      final messenger = tester.binding.defaultBinaryMessenger
        ..setMockDecodedMessageHandler<Object?>(SystemChannels.accessibility, (
          m,
        ) async {
          final data = (m! as Map)['data'] as Map?;
          if (data?['message'] case final String message) {
            announced.add(message);
          }
          return null;
        });
      addTearDown(
        () => messenger.setMockDecodedMessageHandler<Object?>(
          SystemChannels.accessibility,
          null,
        ),
      );
      final api = _AlreadyTrackedApi();
      await _open(tester, found: [], api: api);
      await tester.tap(find.text(en.foundAddByCnr));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'ABC');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(announced, [en.errorInvalidCnr]);

      await tester.enterText(find.byType(TextField), 'MPHC010012342024');
      // Enter twice before the reply (a held key): both reach the field's submit.
      final field = tester.widget<TextField>(find.byType(TextField));
      field.onSubmitted!(field.controller!.text);
      field.onSubmitted!(field.controller!.text);
      await tester.pumpAndSettle();
      expect(api.callNames.where((n) => n == 'addByCnr'), hasLength(1));
      expect(find.text(en.errorFoundCaseAdded), findsOneWidget);
      expect(find.text(en.foundCnrAdded), findsNothing);
      // One pop: the sheet, not the screen under it.
      expect(find.text(en.foundTitle), findsOneWidget);
    },
  );

  testWidgets(
    'the account failed to load (offline, nothing cached): says so instead of "nothing found"',
    (tester) async {
      final api = FakeApi(account: ownerAccount)..offline = true;
      await _open(tester, api: api, onboardingDone: true);
      expect(find.byType(ErrorState), findsOneWidget);
      expect(find.text(en.errorNeedsNetwork), findsOneWidget);
      expect(find.textContaining('WP 1001'), findsNothing);
      api.offline = false;
      await tester.tap(find.text(en.retry));
      await tester.pumpAndSettle();
      expect(find.textContaining('WP 1001'), findsOneWidget);
    },
  );

  testWidgets('a load error: what happened, Retry and Add by CNR', (
    tester,
  ) async {
    await pumpApp(
      tester,
      location: '/found',
      onboardingDone: false,
      overrides: <Override>[
        foundCasesProvider.overrideWithValue(
          AsyncError(Exception('sync'), StackTrace.empty),
        ),
        courtsProvider.overrideWithValue(const AsyncData(testCourts)),
        remainingAllowanceProvider.overrideWithValue(const AsyncData(100)),
      ],
    );
    expect(find.byType(ErrorState), findsOneWidget);
    expect(find.text(en.errorGeneric), findsOneWidget);
    expect(find.text(en.retry), findsOneWidget);
    expect(find.text(en.foundAddByCnr), findsOneWidget);
    expect(find.text(en.foundSkip), findsOneWidget);
  });

  testWidgets('"Not mine" excludes the case; Undo brings it back', (
    tester,
  ) async {
    final api = await _open(tester);
    await tester.tap(find.byTooltip(en.foundRowActions('WP 1001/2024')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.foundNotMine));
    await tester.pumpAndSettle();
    expect(api.calls.last.args, {'id': 'fc-1', 'decision': 'not_mine'});
    expect(find.textContaining('WP 1001'), findsNothing);
    expect(find.text(en.foundAddCount(1)), findsOneWidget);

    await tester.tap(find.text(en.undo));
    await tester.pumpAndSettle();
    expect(api.calls.last.args, {'id': 'fc-1', 'decision': 'pending'});
    expect(find.textContaining('WP 1001'), findsOneWidget);
  });

  testWidgets('the selection outlives the screen (found_selection)', (
    tester,
  ) async {
    await _open(tester);
    await tester.tap(find.textContaining('WP 1001'));
    await tester.pumpAndSettle();
    expect(find.text(en.foundAddCount(1)), findsOneWidget);
    final router = container(tester).read(routerProvider)
      ..go('/onboarding/notifications');
    await tester.pumpAndSettle();
    router.go('/found');
    await tester.pumpAndSettle();
    expect(find.text(en.foundAddCount(1)), findsOneWidget);
  });

  testWidgets('search matches Hindi spellings and case numbers', (
    tester,
  ) async {
    await _open(tester);
    await tester.enterText(find.byType(TextField), 'गुप्ता');
    await tester.pumpAndSettle();
    expect(find.textContaining('Gupta'), findsOneWidget);
    expect(find.textContaining('WP 1001'), findsNothing);
    await tester.enterText(find.byType(TextField), 'CS 1003');
    await tester.pumpAndSettle();
    expect(find.textContaining('CS 1003/2019'), findsOneWidget);
    expect(find.textContaining('Gupta'), findsNothing);
    await tester.enterText(find.byType(TextField), 'nobody');
    await tester.pumpAndSettle();
    expect(find.text(en.foundNoMatches), findsOneWidget);
    await tester.tap(find.text(en.foundClearFilters));
    await tester.pumpAndSettle();
    expect(find.textContaining('WP 1001'), findsOneWidget);
  });

  testWidgets(
    'Disposed is folded; its button says what it does and whether it is open',
    (tester) async {
      final handle = tester.ensureSemantics();
      await _open(tester);
      final show = find.byTooltip(en.groupShow(en.statusDisposed, 1));
      expect(show, findsOneWidget);
      expect(
        tester.getSemantics(show),
        isSemantics(
          tooltip: en.groupShow(en.statusDisposed, 1),
          isButton: true,
          hasExpandedState: true,
          isExpanded: false,
        ),
      );
      await tester.tap(show);
      await tester.pumpAndSettle();
      expect(find.textContaining('Verma'), findsOneWidget);
      expect(
        tester.getSemantics(find.byTooltip(en.groupHide(en.statusDisposed))),
        isSemantics(hasExpandedState: true, isExpanded: true),
      );
      handle.dispose();
    },
  );

  testWidgets('at 200% text, Filters sits under the search box', (
    tester,
  ) async {
    await _open(tester, scale: 2);
    final search = tester.getRect(find.byType(TextField));
    final filters = tester.getRect(find.text(en.foundFilters(0)));
    expect(filters.top, greaterThanOrEqualTo(search.bottom));
    // The hint (the field's only label) has the full width.
    expect(search.width, greaterThan(300));
  });

  testWidgets('filters: disposed only', (tester) async {
    await _open(tester);
    await tester.tap(find.text(en.foundFilters(0)));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, en.statusDisposed));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.foundShowCases));
    await tester.pumpAndSettle();
    expect(find.text(en.foundFilters(1)), findsOneWidget);
    expect(find.text('${en.statusDisposed} (1)'), findsOneWidget);
    expect(find.textContaining('WP 1001'), findsNothing);
  });

  testWidgets('over 300 results, groups show 100 rows at a time', (
    tester,
  ) async {
    await _open(tester, found: [for (var i = 1; i <= 310; i++) foundCase(i)]);
    final more = find.text(en.foundShowMore(100));
    // The list's Scrollable (the search box has one too).
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(more, 500, scrollable: list);
    expect(find.textContaining('WP 1101/'), findsNothing);
    await tester.tap(more);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(more, 500, scrollable: list);
    await tester.tap(more);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text(en.foundShowMore(10)),
      500,
      scrollable: list,
    );
  });

  testWidgets('Windows keys: Ctrl+A, Shift-click, Space and Enter', (
    tester,
  ) async {
    final api = await _open(tester, size: const Size(1280, 800));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text(en.foundAddAllCount(3)), findsOneWidget);

    // Click WP 1001 (unticks it), Shift-click CS 1003: the range WP 1001…CS 1003 is unticked.
    await tester.tap(find.textContaining('WP 1001'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.textContaining('CS 1003'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.text(en.foundSkip), findsOneWidget);

    Focus.of(tester.element(find.textContaining('WP 1001'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.text(en.foundAddCount(1)), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settleAdd(tester);
    final call = api.calls.singleWhere((c) => c.name == 'addFoundCases');
    expect((call.args! as Map)['ids'], ['fc-1']);
  });

  testWidgets('Ctrl+A in the search box selects its text, not every case', (
    tester,
  ) async {
    await _open(tester, size: const Size(1280, 800));
    await tester.enterText(find.byType(TextField), 'Sharma');
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('WP 1001'));
    await tester.pumpAndSettle();
    expect(find.text(en.foundAddCount(1)), findsOneWidget);
    await tester.showKeyboard(find.byType(TextField));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text(en.foundAddCount(1)), findsOneWidget);
  });
}

/// addByCnr finds the CNR already tracked (`created: false`), after a moment (so a second Enter lands mid-request).
class _AlreadyTrackedApi extends FakeApi {
  _AlreadyTrackedApi() : super(account: ownerAccount);

  @override
  Future<({String matterId, bool created})> addByCnr({
    required String orgId,
    required String idempotencyKey,
    required String cnr,
  }) async {
    await super.addByCnr(
      orgId: orgId,
      idempotencyKey: idempotencyKey,
      cnr: cnr,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return (matterId: 'matter-1', created: false);
  }
}
