import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/router.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/features/case_page/case_page.dart';
import 'package:advocate_app/features/case_page/links.dart';
import 'package:advocate_app/features/clients/client_profile.dart';
import 'package:advocate_app/features/clients/clients_screen.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:advocate_app/ui/tiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

final AppLocalizations en = lookupAppLocalizations(const Locale('en'));

const _suresh = ClientInfo(
  id: 'cl-1',
  name: 'Suresh Patel',
  phone: '+919876543210',
  language: 'hi',
  email: 'suresh@example.com',
  address: '12 MG Road, Indore',
  notes: 'Prefers calls after 6 pm.',
);
const _gupta = ClientInfo(
  id: 'cl-2',
  name: 'Ramesh Gupta',
  phone: '+919812345678',
);
const _rajesh = ClientInfo(id: 'cl-3', name: 'राजेश शर्मा');

/// Suresh Patel (every field) has two cases, Ramesh Gupta one, राजेश शर्मा none; WP 1004 is linked to no one.
FakeCases _fake({List<ClientInfo> clients = const [_suresh, _gupta, _rajesh]}) {
  return FakeCases(
    cases: [
      caseInfo(
        1,
        nextDate: DateTime.utc(2026, 11, 5),
        title: 'Suresh Patel v. State of MP',
      ),
      caseInfo(
        2,
        caseType: 'MCRC',
        nextDate: DateTime.utc(2026, 11, 20),
        title: 'Patel v. Verma',
      ),
      caseInfo(
        3,
        title: 'Gupta v. Housing Board',
        clients: const [(id: 'cl-2', name: 'Ramesh Gupta')],
      ),
      caseInfo(4, title: 'Jain v. Jain', clients: const []),
    ],
    links: {
      'm-1': [(linkId: 'mc-1', client: _suresh)],
      'm-2': [(linkId: 'mc-2', client: _suresh)],
      'm-3': [(linkId: 'mc-3', client: _gupta)],
    },
    clients: clients,
  );
}

const _tall = Size(400, 1600);
const _wide = Size(1280, 800);

String _path(WidgetTester tester) =>
    container(tester)
        .read(routerProvider)
        .routerDelegate
        .currentConfiguration
        .uri
        .path;

/// The list's rows by name, top to bottom.
List<String> _rows(WidgetTester tester) => [
  for (final t in tester.widgetList<ClientTile>(find.byType(ClientTile)))
    t.name,
];

Finder _inSheet(Finder f) =>
    find.descendant(of: find.byType(BottomSheet), matching: f);

Finder _field(String label) => _inSheet(find.widgetWithText(TextField, label));

void main() {
  late List<Uri> opened;

  setUp(() => opened = []);

  Future<FakeCases> pump(
    WidgetTester tester, {
    FakeCases? fake,
    String location = '/clients',
    Size size = _tall,
    String locale = 'en',
    double textScale = 1,
    bool offline = false,
  }) async {
    final cases = fake ?? _fake();
    await pumpApp(
      tester,
      location: location,
      size: size,
      locale: locale,
      textScale: textScale,
      onboardingDone: true,
      overrides: [
        ...cases.overrides,
        if (offline) ...syncedData(offline: true),
        openExternalProvider.overrideWithValue((uri) async {
          opened.add(uri);
          return true;
        }),
      ],
    );
    return cases;
  }

  group('list', () {
    testWidgets('clients with their cases and phone; a row reads as one item '
        'and opens the profile', (tester) async {
      final semantics = tester.ensureSemantics();
      await pump(tester);
      expect(_rows(tester), ['Suresh Patel', 'Ramesh Gupta', 'राजेश शर्मा']);
      expect(
        find.text('+91 98765 43210 · ${en.linkedCases(2)}'),
        findsOneWidget,
      );
      expect(find.text(en.linkedCases(0)), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          'Suresh Patel. ${en.linkedCases(2)}. +91 98765 43210.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Suresh Patel'));
      await tester.pumpAndSettle();
      expect(_path(tester), '/clients/cl-1');
      expect(find.byType(ClientProfile), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('search: transliterated both ways, and by phone digits', (
      tester,
    ) async {
      await pump(tester);
      Future<void> search(String q) async {
        await tester.enterText(find.byType(TextField), q);
        await tester.pumpAndSettle();
      }

      await search('sharma');
      expect(_rows(tester), ['राजेश शर्मा']);
      await search('गुप्ता');
      expect(_rows(tester), ['Ramesh Gupta']);
      await search('98123');
      expect(_rows(tester), ['Ramesh Gupta']);
      await search('');
      expect(_rows(tester), hasLength(3));
    });

    testWidgets('no match: say so, and Add client takes the name searched', (
      tester,
    ) async {
      await pump(tester);
      await tester.enterText(find.byType(TextField), 'Anita Joshi');
      await tester.pumpAndSettle();
      expect(find.text(en.clientsNoMatch), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, en.clientsAdd));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(_field(en.casePageClientName))
            .controller!
            .text,
        'Anita Joshi',
      );
    });

    testWidgets('search stays while the app runs', (tester) async {
      await pump(tester);
      await tester.enterText(find.byType(TextField), 'gupta');
      await tester.pumpAndSettle();
      container(tester).read(routerProvider).go('/today');
      await tester.pumpAndSettle();
      container(tester).read(routerProvider).go('/clients');
      await tester.pumpAndSettle();
      expect(find.text('gupta'), findsOneWidget);
      expect(_rows(tester), ['Ramesh Gupta']);
    });

    testWidgets('no clients yet: one sentence and Add client', (tester) async {
      await pump(tester, fake: _fake(clients: []));
      expect(find.text(en.clientsEmpty), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text(en.clientsAdd), findsOneWidget);
    });

    testWidgets('offline: the saved clients show under the offline banner', (
      tester,
    ) async {
      await pump(tester, offline: true);
      expect(find.byType(OfflineBanner), findsOneWidget);
      expect(_rows(tester), hasLength(3));
    });
  });

  group('add and edit', () {
    testWidgets('add client: checked inline, then saved and opened', (
      tester,
    ) async {
      final cases = await pump(tester);
      await tester.tap(find.text(en.clientsAdd));
      await tester.pumpAndSettle();
      await tester.enterText(_field(en.phoneLabel), '12345');
      await tester.enterText(_field(en.clientsEmail), 'anita@');
      await tester.tap(_inSheet(find.text(en.casePageSave)));
      await tester.pumpAndSettle();
      expect(find.text(en.clientsDataNameRequired), findsOneWidget);
      expect(find.text(en.clientsDataPhoneInvalid), findsOneWidget);
      expect(find.text(en.clientsDataEmailInvalid), findsOneWidget);
      expect(cases.writes, isEmpty);

      await tester.enterText(_field(en.casePageClientName), ' Anita Joshi ');
      await tester.enterText(_field(en.phoneLabel), '+91 98765 01234');
      await tester.enterText(_field(en.clientsEmail), 'anita@example.com');
      await tester.enterText(_field(en.clientsAddress), 'Rajwada, Indore');
      await tester.tap(_inSheet(find.text(en.casePageLangEn)));
      await tester.tap(_inSheet(find.text(en.casePageSave)));
      await tester.pumpAndSettle();
      expect(cases.writes.single.name, 'createClient');
      expect(cases.writes.single.args, {
        'name': ' Anita Joshi ',
        'phone': '+919876501234',
        'language': 'en',
        'email': 'anita@example.com',
        'address': 'Rajwada, Indore',
      });
      expect(_path(tester), '/clients/cl-new-1');
      expect(find.text('Anita Joshi'), findsWidgets);
      expect(find.text('+91 98765 01234'), findsOneWidget);
    });

    testWidgets('edit: prefilled, name length checked, cleared fields saved', (
      tester,
    ) async {
      final cases = await pump(tester, location: '/clients/cl-1');
      await tester.tap(find.byTooltip(en.clientsEdit));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(_field(en.phoneLabel)).controller!.text,
        '+91 98765 43210',
      );
      await tester.enterText(_field(en.casePageClientName), 'S' * 201);
      await tester.tap(_inSheet(find.text(en.casePageSave)));
      await tester.pumpAndSettle();
      expect(find.text(en.clientsDataNameTooLong(200)), findsOneWidget);
      expect(cases.writes, isEmpty);

      await tester.enterText(_field(en.casePageClientName), 'Suresh K. Patel');
      await tester.enterText(_field(en.clientsEmail), '');
      await tester.tap(_inSheet(find.text(en.casePageSave)));
      await tester.pumpAndSettle();
      expect(cases.writes.single.name, 'updateClient');
      expect(cases.writes.single.args, {
        'id': 'cl-1',
        'name': 'Suresh K. Patel',
        'phone': '+919876543210',
        'language': 'hi',
        'email': null,
        'address': '12 MG Road, Indore',
        'notes': 'Prefers calls after 6 pm.',
      });
      expect(find.text('Suresh K. Patel'), findsOneWidget);
      expect(find.text('suresh@example.com'), findsNothing);
    });
  });

  group('profile', () {
    testWidgets('details: call, email, address, language, notes and cases', (
      tester,
    ) async {
      await pump(tester, location: '/clients/cl-1');
      expect(find.text('Suresh Patel'), findsOneWidget);
      expect(find.text(en.linkedCases(2)), findsOneWidget);
      expect(find.text('12 MG Road, Indore'), findsOneWidget);
      expect(find.text(en.casePageLangHi), findsOneWidget);
      expect(find.text('Prefers calls after 6 pm.'), findsOneWidget);
      expect(find.text('${en.clientsCases} (2)'), findsOneWidget);
      // By next date.
      final first = tester.getTopLeft(find.text('WP 1001/2024')).dy;
      expect(
        tester.getTopLeft(find.text('MCRC 1002/2024')).dy,
        greaterThan(first),
      );

      await tester.tap(find.text('+91 98765 43210'));
      await tester.tap(find.text('suresh@example.com'));
      await tester.pumpAndSettle();
      expect(opened, [
        Uri(scheme: 'tel', path: '+919876543210'),
        Uri(scheme: 'mailto', path: 'suresh@example.com'),
      ]);

      // A linked case opens over the profile (spec §5.1 "Never stuck"): Back returns here.
      await tester.tap(find.text('MCRC 1002/2024'));
      await tester.pumpAndSettle();
      expect(tester.widget<CasePage>(find.byType(CasePage)).matterId, 'm-2');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(ClientProfile), findsOneWidget);
    });

    testWidgets('WhatsApp opt-in: on records when, off clears it', (
      tester,
    ) async {
      final cases = await pump(tester, location: '/clients/cl-1');
      expect(find.text(en.clientsWhatsappHint), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(cases.writes.last.name, 'setClientWhatsapp');
      expect(cases.writes.last.args, {'id': 'cl-1', 'optIn': true});
      expect(
        find.text(
          '${en.clientsWhatsappHint}\n${en.clientsWhatsappAgreed('Thu, 5 Nov 2026')}',
        ),
        findsOneWidget,
      );

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(cases.writes.last.args, {'id': 'cl-1', 'optIn': false});
      expect(find.text(en.clientsWhatsappHint), findsOneWidget);
    });

    testWidgets('WhatsApp needs a phone number first', (tester) async {
      await pump(tester, location: '/clients/cl-3');
      expect(find.text(en.clientsWhatsappNeedsPhone), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
      expect(find.text(en.clientsCasesEmpty), findsOneWidget);
    });

    testWidgets('link a case, and unlink one with Undo', (tester) async {
      final cases = await pump(tester, location: '/clients/cl-1');
      await tester.tap(find.text(en.clientsLinkCase));
      await tester.pumpAndSettle();
      // Its own cases aren't offered again.
      expect(_inSheet(find.text('WP 1001/2024')), findsNothing);
      await tester.enterText(_inSheet(find.byType(TextField)), 'jain');
      await tester.pumpAndSettle();
      expect(_inSheet(find.text('WP 1003/2024')), findsNothing);
      await tester.tap(_inSheet(find.text('WP 1004/2024')));
      await tester.pumpAndSettle();
      expect(cases.writes.last.name, 'linkClient');
      expect(cases.writes.last.args, {'matterId': 'm-4', 'clientId': 'cl-1'});
      expect(find.text('${en.clientsCases} (3)'), findsOneWidget);

      await tester.tap(find.byTooltip(en.boardMoreActions('WP 1001/2024')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.casePageUnlink));
      await tester.pumpAndSettle();
      expect(cases.writes.last.name, 'unlinkClient');
      expect(cases.writes.last.args, 'mc-1');
      expect(find.text(en.clientsUnlinked('WP 1001/2024')), findsOneWidget);
      expect(find.text('WP 1001/2024'), findsNothing);
      await tester.tap(find.text(en.undo));
      await tester.pumpAndSettle();
      expect(cases.writes.last.args, {'matterId': 'm-1', 'clientId': 'cl-1'});
      expect(find.text('WP 1001/2024'), findsOneWidget);
    });

    testWidgets('delete: back to the list without it; Undo keeps it', (
      tester,
    ) async {
      final cases = await pump(tester, location: '/clients/cl-2');
      Future<void> delete() async {
        await tester.tap(find.byTooltip(en.boardMoreActions('Ramesh Gupta')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(en.clientsDelete));
        await tester.pumpAndSettle();
      }

      await delete();
      expect(_path(tester), '/clients');
      expect(_rows(tester), ['Suresh Patel', 'राजेश शर्मा']);
      await tester.tap(find.text(en.undo));
      await tester.pumpAndSettle();
      expect(_rows(tester), hasLength(3));
      expect(cases.writes, isEmpty);

      await tester.tap(find.text('Ramesh Gupta'));
      await tester.pumpAndSettle();
      await delete();
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(cases.writes.single.name, 'deleteClient');
      expect(cases.writes.single.args, 'cl-2');
      expect(_rows(tester), ['Suresh Patel', 'राजेश शर्मा']);
    });

    testWidgets('a deleted or unknown client says so', (tester) async {
      await pump(tester, location: '/clients/cl-9');
      expect(find.text(en.clientsRemoved), findsOneWidget);
      await tester.tap(find.text(en.clientsBack));
      await tester.pumpAndSettle();
      expect(_path(tester), '/clients');
    });
  });

  testWidgets("the case page's Client tab opens the client's profile", (
    tester,
  ) async {
    await pump(tester, location: '/cases/m-1?tab=client');
    await tester.tap(find.text('Suresh Patel'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ClientProfile>(find.byType(ClientProfile)).clientId,
      'cl-1',
    );
    // Over the case on a phone: Back returns to the case, not the Clients list.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(ClientProfile), findsNothing);
    expect(tester.widget<CasePage>(find.byType(CasePage)).matterId, 'm-1');

    // Deleted from there: back on the case too.
    await tester.tap(find.text('Suresh Patel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(en.boardMoreActions('Suresh Patel')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.clientsDelete));
    await tester.pumpAndSettle();
    expect(find.byType(ClientProfile), findsNothing);
    expect(tester.widget<CasePage>(find.byType(CasePage)).matterId, 'm-1');
  });

  testWidgets(
    "Windows: the case page's Client tab moves to Clients' two panes",
    (tester) async {
      await pump(tester, location: '/cases/m-1?tab=client', size: _wide);
      await tester.tap(find.text('Suresh Patel'));
      await tester.pumpAndSettle();
      expect(_path(tester), '/clients/cl-1');
      expect(find.byType(ClientsScreen), findsOneWidget);
    },
  );

  group('Windows', () {
    testWidgets('two panes: the list beside the chosen client', (tester) async {
      await pump(tester, size: _wide);
      expect(find.text(en.clientsPick), findsOneWidget);
      await tester.tap(find.text('Ramesh Gupta'));
      await tester.pumpAndSettle();
      expect(_path(tester), '/clients/cl-2');
      expect(find.byType(ClientsScreen), findsOneWidget);
      expect(
        tester.widget<ClientProfile>(find.byType(ClientProfile)).clientId,
        'cl-2',
      );
      ClientTile tile(String name) =>
          tester.widget<ClientTile>(find.widgetWithText(ClientTile, name));
      expect(tile('Ramesh Gupta').selected, isTrue);
      expect(tile('Suresh Patel').selected, isFalse);
    });

    testWidgets('Ctrl+F finds; Down moves to the rows; Enter opens', (
      tester,
    ) async {
      await pump(tester, size: _wide);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      final field = tester.widget<EditableText>(find.byType(EditableText));
      expect(field.focusNode.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(_path(tester), '/clients/cl-1');
    });
  });

  // Spec §5.9: 200% text in both languages, 48 dp labelled targets, on the list, the profile, the edit sheet and
  // the two panes.
  for (final locale in ['en', 'hi']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('list, profile and edit sheet, $locale, ${scale}x', (
        tester,
      ) async {
        final l = lookupAppLocalizations(Locale(locale));
        final semantics = tester.ensureSemantics();
        await pump(
          tester,
          locale: locale,
          textScale: scale,
          size: const Size(400, 860),
        );
        expect(tester.takeException(), isNull);
        expect(_rows(tester), hasLength(3));
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

        await tester.tap(find.text('Suresh Patel'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await tester.scrollUntilVisible(
          find.text('MCRC 1002/2024'),
          200,
          scrollable: find.byType(Scrollable).last,
        );
        expect(tester.takeException(), isNull);

        await tester.tap(find.byTooltip(l.clientsEdit));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsOneWidget);
        expect(tester.takeException(), isNull);
        Navigator.of(tester.element(find.byType(BottomSheet))).pop();
        await tester.pumpAndSettle();

        tester.view.physicalSize = _wide;
        container(tester).read(routerProvider).go('/clients/cl-1');
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(ClientProfile), findsOneWidget);
        expect(find.byType(ClientsScreen), findsOneWidget);
        semantics.dispose();
      });
    }
  }
}
