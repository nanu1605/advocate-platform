import 'dart:async';

import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/router.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/feedback.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:advocate_app/features/case_page/case_page.dart';
import 'package:advocate_app/features/feedback/feedback_sheet.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

final Override _version = appVersionProvider.overrideWithValue(
  const AsyncData('0.1.0'),
);

/// Opens the sheet over WP 1001's case page, as the command palette would.
Future<FakeApi> _open(
  WidgetTester tester, {
  String locale = 'en',
  double scale = 1,
  List<Override> overrides = const [],
}) async {
  final api = await pumpApp(
    tester,
    location: '/cases/m-1',
    locale: locale,
    textScale: scale,
    overrides: [
      ...FakeCases(cases: [caseInfo(1)]).overrides,
      _version,
      ...overrides,
    ],
  );
  unawaited(showFeedbackSheet(tester.element(find.byType(CasePage))));
  await tester.pumpAndSettle();
  return api;
}

Future<void> _send(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

List<Object?> _sent(FakeApi api) => [
  for (final c in api.calls)
    if (c.name == 'sendFeedback') c.args,
];

/// "Send feedback" (spec §10.2): the note goes with the screen's route pattern and the app version; the empty,
/// rate-limited and offline cases keep the note.
void main() {
  setUpAll(loadAppFonts);
  final en = lookupAppLocalizations(const Locale('en'));

  for (final locale in ['en', 'hi']) {
    final l = lookupAppLocalizations(Locale(locale));
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'sends the note with the screen and version ($locale ${scale}x)',
        (tester) async {
          final api = await _open(tester, locale: locale, scale: scale);
          expect(find.text(l.feedbackIntro), findsOneWidget);
          // The case's id never leaves the device: the route pattern does.
          expect(
            find.text(l.feedbackAttached('/cases/:id', '0.1.0')),
            findsOneWidget,
          );
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          await tester.enterText(
            find.byType(TextField),
            'The board misses Court 7.',
          );
          await _send(tester, l.feedbackSend);
          expect(_sent(api), [
            {
              'note': 'The board misses Court 7.',
              'screen': '/cases/:id',
              'appVersion': '0.1.0',
              'orgId': 'org-1',
            },
          ]);
          expect(find.text(l.feedbackThanks), findsOneWidget);
          expect(find.byType(BottomSheet), findsNothing);
          expect(container(tester).read(feedbackDraftProvider), '');
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('an empty note asks for one and sends nothing', (tester) async {
    final announced = captureAnnouncements(tester);
    final api = await _open(tester);
    await tester.enterText(find.byType(TextField), '   ');
    announced.clear();
    await _send(tester, en.feedbackSend);
    expect(find.text(en.feedbackEmpty), findsOneWidget);
    expect(announced, [en.feedbackEmpty]);
    expect(_sent(api), isEmpty);
  });

  testWidgets('the counter shows the 4000-character limit', (tester) async {
    await _open(tester);
    await tester.enterText(find.byType(TextField), 'x' * 4100);
    await tester.pump();
    expect(find.text('4000/4000'), findsOneWidget);
  });

  testWidgets('Hindi counts as the server counts: code points, not letters', (
    tester,
  ) async {
    final api = await _open(tester, locale: 'hi');
    // "कि" is one letter on screen but two code points; the API's 4000 is code points.
    await tester.enterText(find.byType(TextField), 'कि' * 2500);
    await tester.pump();
    final text = tester
        .widget<TextField>(find.byType(TextField))
        .controller!
        .text;
    expect(text, 'कि' * 2000);
    expect(find.text('4000/4000'), findsOneWidget);
    await _send(
      tester,
      lookupAppLocalizations(const Locale('hi')).feedbackSend,
    );
    expect((_sent(api).single! as Map)['note'], 'कि' * 2000);
  });

  testWidgets('rate limited: says so and keeps the note', (tester) async {
    final api = FakeApi(account: ownerAccount);
    api.fail['sendFeedback'] = const ApiException('RATE_LIMITED');
    await pumpApp(
      tester,
      location: '/cases/m-1',
      api: api,
      overrides: [
        ...FakeCases(cases: [caseInfo(1)]).overrides,
        _version,
      ],
    );
    unawaited(showFeedbackSheet(tester.element(find.byType(CasePage))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Please add Hindi PDFs.');
    await _send(tester, en.feedbackSend);
    expect(find.text(en.feedbackTooMany), findsOneWidget);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Please add Hindi PDFs.'), findsOneWidget);
  });

  testWidgets(
    'offline: needs a connection, keeps the note while the app runs',
    (tester) async {
      final api = await _open(
        tester,
        overrides: [
          syncViewProvider.overrideWithValue(
            const AsyncData((status: SyncStatus.syncing, offline: true)),
          ),
        ],
      );
      await tester.enterText(find.byType(TextField), 'Court 7 is missing.');
      await _send(tester, en.feedbackSend);
      expect(find.text(en.errorNeedsNetwork), findsOneWidget);
      expect(_sent(api), isEmpty);
      // Closed and opened again, the note is still there.
      Navigator.pop(tester.element(find.byType(TextField)));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      unawaited(showFeedbackSheet(tester.element(find.byType(CasePage))));
      await tester.pumpAndSettle();
      expect(find.text('Court 7 is missing.'), findsOneWidget);
    },
  );

  testWidgets('a lost connection while sending keeps the note', (tester) async {
    final api = await _open(tester);
    api.offline = true;
    await tester.enterText(find.byType(TextField), 'Court 7 is missing.');
    await _send(tester, en.feedbackSend);
    expect(find.text(en.errorNeedsNetwork), findsOneWidget);
    expect(find.text('Court 7 is missing.'), findsOneWidget);
  });

  testWidgets('a case pushed over Today is the screen named, not Today', (
    tester,
  ) async {
    await pumpApp(
      tester,
      overrides: [
        ...FakeCases(cases: [caseInfo(1)]).overrides,
        _version,
      ],
    );
    // How Today, the board and the calendar open a case.
    unawaited(container(tester).read(routerProvider).push('/cases/m-1'));
    await tester.pumpAndSettle();
    unawaited(showFeedbackSheet(tester.element(find.byType(CasePage))));
    await tester.pumpAndSettle();
    expect(
      find.text(en.feedbackAttached('/cases/:id', '0.1.0')),
      findsOneWidget,
    );
  });
}
