import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';

const hindi = 'माननीय उच्च न्यायालय — याचिकाकर्ता की ओर से क्षतिपूर्ति हेतु प्रार्थना';

Future<void> loadFonts() async {
  final manifest = json.decode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final e in manifest.cast<Map<String, dynamic>>()) {
    final l = FontLoader(e['family'] as String);
    for (final f in (e['fonts'] as List).cast<Map<String, dynamic>>()) {
      l.addFont(rootBundle.load(f['asset'] as String));
    }
    await l.load();
  }
  final mukta = FontLoader('Mukta')
    ..addFont(Future.value(ByteData.sublistView(File(r'S:\Projects\lawyer-app\apps\client\assets\fonts\Mukta\Mukta-Regular.ttf').readAsBytesSync())));
  await mukta.load();
}

Widget app(Widget child) => MaterialApp(
  theme: ThemeData(fontFamily: 'Mukta'),
  localizationsDelegates: const [
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    q.FlutterQuillLocalizations.delegate,
  ],
  home: Scaffold(body: SizedBox(width: 800, height: 600, child: child)),
);

void main() {
  setUpAll(loadFonts);

  testWidgets('flutter_quill: Devanagari and numbered paragraphs (no tables in core)', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    final controller = q.QuillController(
      document: q.Document.fromJson([
        {'insert': '$hindi\n'},
        {'insert': 'पहला आधार'},
        {'insert': '\n', 'attributes': {'list': 'ordered'}},
        {'insert': 'दूसरा आधार'},
        {'insert': '\n', 'attributes': {'list': 'ordered'}},
      ]),
      selection: const TextSelection.collapsed(offset: 0),
    );
    await tester.pumpWidget(app(q.QuillEditor.basic(controller: controller)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(find.byType(q.QuillEditor), matchesGoldenFile('out/quill.png'));
    expect(controller.document.toPlainText(), contains('क्षतिपूर्ति'));
  });
}
