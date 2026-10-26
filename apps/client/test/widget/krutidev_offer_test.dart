import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/ui/krutidev_offer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

final AppLocalizations l = lookupAppLocalizations(const Locale('en'));

const _legacy =
    "U;k;ky; us vkns'k fn;k fd vkosnd dks tekur ij fjgk fd;k tk,A "
    "izdj.k vkxkeh fnukad 20&11&2026 dks is'k gksA";

/// Hindi pasted from an old Kruti Dev document is offered a conversion, and only converted on the tap (spec §12.11).
void main() {
  setUpAll(loadAppFonts);

  Future<TextEditingController> field(WidgetTester tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      host(
        Column(
          children: [
            TextField(controller: controller),
            KrutidevOffer(controller),
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
    expect(
      controller.text,
      'न्यायालय ने आदेश दिया कि आवेदक को जमानत पर रिहा किया जाए। '
      'प्रकरण आगामी दिनांक 20-11-2026 को पेश हो।',
    );
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
}
