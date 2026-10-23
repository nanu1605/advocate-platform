import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

/// Spike 11f, host part: pdfrx builds on Flutter 3.47 and opens a 120-page Devanagari PDF (made by spike 11g).
/// Scroll/render timing on the low-end Android and on Windows needs real devices.
void main() {
  test('opens a 120-page PDF and reads page text', () async {
    pdfrxFlutterInitialize();
    final bytes = File(r'S:\Projects\lawyer-app\docs\spikes\11g-devanagari-pdf\out\long-120.pdf').readAsBytesSync();
    final sw = Stopwatch()..start();
    final doc = await PdfDocument.openData(bytes);
    final opened = sw.elapsedMilliseconds;
    expect(doc.pages.length, 120);
    final text = await doc.pages[59].loadText();
    final page = await doc.pages[59].render(width: 1080, height: 1527);
    stdout.writeln('open ${opened}ms · page 60 text ${text?.fullText.length} chars · render ${sw.elapsedMilliseconds - opened}ms · ${page?.width}x${page?.height}');
    page?.dispose();
    await doc.dispose();
  });

  testWidgets('PdfViewer widget compiles against the 3.47 SDK', (tester) async {
    expect(() => PdfViewer.file('x.pdf'), returnsNormally);
    expect(const Text('ok'), isNotNull);
  });
}
