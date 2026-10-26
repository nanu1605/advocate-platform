import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/ui/krutidev_offer.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

final AppLocalizations l = lookupAppLocalizations(const Locale('en'));

const _legacy =
    "U;k;ky; us vkns'k fn;k fd vkosnd dks tekur ij fjgk fd;k tk,A "
    "izdj.k vkxkeh fnukad 20&11&2026 dks is'k gksA";
const _hindi =
    'न्यायालय ने आदेश दिया कि आवेदक को जमानत पर रिहा किया जाए। '
    'प्रकरण आगामी दिनांक 20-11-2026 को पेश हो।';
const _english =
    'Bail hearing on 12 March. Bring the certified copy of the FIR and the '
    'charge sheet.';

/// Hindi pasted from an old Kruti Dev document is offered a conversion, and only converted on the tap (spec §12.11).
void main() {
  setUpAll(loadAppFonts);

  Future<TextEditingController> field(
    WidgetTester tester, {
    String? text,
    FocusNode? focus,
  }) async {
    final controller = TextEditingController(text: text);
    final node = focus ?? FocusNode();
    addTearDown(controller.dispose);
    addTearDown(node.dispose);
    await tester.pumpWidget(
      host(
        Column(
          children: [
            TextField(controller: controller, focusNode: node, maxLines: null),
            KrutidevOffer(controller, focusNode: node),
          ],
        ),
      ),
    );
    return controller;
  }

  testWidgets('offers to convert Kruti Dev text, and converts on the tap', (
    tester,
  ) async {
    final said = captureAnnouncements(tester);
    final controller = await field(tester);
    expect(find.text(l.krutidevConvert), findsNothing);

    await tester.enterText(find.byType(TextField), _legacy);
    await tester.pump();
    expect(find.text(l.krutidevFound), findsOneWidget);
    expect(controller.text, _legacy);

    await tester.tap(find.text(l.krutidevConvert));
    await tester.pump();
    expect(controller.text, _hindi);
    expect(find.text(l.krutidevConvert), findsNothing);
    expect(said, [l.krutidevConverted]);
  });

  testWidgets('leaves English and short text alone', (tester) async {
    await field(tester);
    for (final text in [
      'The respondent filed a reply within four weeks of the order.',
      "vkns'k",
    ]) {
      await tester.enterText(find.byType(TextField), text);
      await tester.pump();
      expect(find.text(l.krutidevConvert), findsNothing, reason: text);
    }
  });

  testWidgets('converts only the pasted Kruti Dev: English already in the '
      'field stays, and undo brings the paste back', (tester) async {
    final controller = await field(tester);
    await tester.enterText(find.byType(TextField), _english);
    await tester.pump();
    expect(find.text(l.krutidevConvert), findsNothing);
    // The paste, below the English line.
    await tester.enterText(find.byType(TextField), '$_english\n$_legacy');
    await tester.pump(const Duration(seconds: 1)); // past undo's grouping
    expect(find.text(l.krutidevFound), findsOneWidget);

    await tester.tap(find.text(l.krutidevConvert));
    await tester.pump();
    expect(controller.text, '$_english\n$_hindi');
    expect(find.text(l.krutidevConvert), findsNothing);

    await tester.pump(const Duration(seconds: 1));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(controller.text, '$_english\n$_legacy');
  });

  testWidgets('a click on Convert, which takes focus from the field, gives '
      'it back', (tester) async {
    final focus = FocusNode();
    await field(tester, focus: focus);
    await tester.enterText(find.byType(TextField), _legacy);
    await tester.pump();
    await tester.tap(
      find.text(l.krutidevConvert),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(focus.hasPrimaryFocus, isTrue);
  });

  testWidgets('a paste between English lines converts in place; the offer '
      'goes when the paste is deleted', (tester) async {
    final controller = await field(tester, text: 'Order:\n\nNext date.');
    await tester.enterText(
      find.byType(TextField),
      'Order:\n$_legacy\nNext date.',
    );
    await tester.pump();
    expect(find.text(l.krutidevConvert), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Order:\n\nNext date.');
    await tester.pump();
    expect(find.text(l.krutidevConvert), findsNothing);

    await tester.enterText(
      find.byType(TextField),
      'Order:\n$_legacy\nNext date.',
    );
    await tester.pump();
    await tester.tap(find.text(l.krutidevConvert));
    await tester.pump();
    expect(controller.text, 'Order:\n$_hindi\nNext date.');
    // The cursor after the converted text, not at the end of the field.
    expect(
      controller.selection,
      const TextSelection.collapsed(offset: 'Order:\n$_hindi'.length),
    );
  });

  testWidgets('Backspace on the newline a pasted paragraph came with keeps '
      'the offer; the English stays', (tester) async {
    final controller = await field(tester, text: '$_english\n');
    // Copied with its paragraph mark, as a triple-click in Word does.
    await tester.enterText(find.byType(TextField), '$_english\n$_legacy\n');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(controller.text, '$_english\n$_legacy');
    await tester.tap(find.text(l.krutidevConvert));
    await tester.pump();
    expect(controller.text, '$_english\n$_hindi');
  });

  testWidgets('a one-letter fix inside the paste keeps the offer, and is '
      'converted with it', (tester) async {
    final controller = await field(tester, text: '$_english\n\nNext date.');
    await tester.enterText(
      find.byType(TextField),
      '$_english\n${_legacy.replaceFirst('tekur', 'teur')}\nNext date.',
    );
    await tester.pump();
    await tester.enterText(
      find.byType(TextField),
      '$_english\n$_legacy\nNext date.',
    );
    await tester.pump();
    await tester.tap(find.text(l.krutidevConvert));
    await tester.pump();
    expect(controller.text, '$_english\n$_hindi\nNext date.');
  });

  testWidgets('a field that opens with English and Kruti Dev paragraphs '
      'converts only the Kruti Dev, last first', (tester) async {
    final controller = await field(
      tester,
      text: '$_legacy\n$_english\n$_legacy\nNext date.',
    );
    await tester.tap(find.text(l.krutidevConvert));
    await tester.pump();
    expect(controller.text, '$_hindi\n$_english\n$_hindi\nNext date.');
    // The cursor after the last converted paragraph.
    expect(
      controller.selection,
      TextSelection.collapsed(offset: controller.text.indexOf('\nNext')),
    );
  });

  testWidgets('a field that opens with Kruti Dev in short lines is converted '
      'whole', (tester) async {
    // Four words a line: none long enough to tell on its own.
    String lines(String s) =>
        s.replaceAllMapped(RegExp(r'((?:\S+ ){3}\S+) '), (m) => '${m[1]}\n');
    final controller = await field(tester, text: lines(_legacy));
    expect(find.text(l.krutidevFound), findsOneWidget);
    await tester.tap(find.text(l.krutidevConvert));
    await tester.pump();
    expect(controller.text, lines(_hindi));
  });
}
