import 'dart:convert';
import 'dart:io';

import 'package:advocate_app/core/krutidev.dart';
import 'package:flutter_test/flutter_test.dart';

/// The same vectors as the Python converter (packages/shared/tests/test_krutidev.py).
void main() {
  final fixture = jsonDecode(
    File('../../config/fixtures/krutidev.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final vectors = (fixture['vectors'] as List).cast<Map<String, dynamic>>();
  final detect = fixture['detect'] as Map<String, dynamic>;

  test('the fixture has 100 vectors', () => expect(vectors, hasLength(100)));

  for (final v in vectors) {
    test('${v['unicode']} (${v['rule']})', () {
      expect(krutidevToUnicode(v['legacy'] as String), v['unicode']);
    });
  }

  for (final v in (fixture['devlys'] as List).cast<Map<String, dynamic>>()) {
    test('DevLys reads its own quote slots: ${v['unicode']}', () {
      expect(
        krutidevToUnicode(v['legacy'] as String, devlys: true),
        v['unicode'],
      );
      expect(krutidevToUnicode(v['legacy'] as String), isNot(v['unicode']));
    });
  }

  test('detects Kruti Dev text and leaves other text alone', () {
    for (final t in (detect['legacy'] as List).cast<String>()) {
      expect(looksLikeKrutidev(t), isTrue, reason: t);
    }
    for (final t in (detect['other'] as List).cast<String>()) {
      expect(looksLikeKrutidev(t), isFalse, reason: t);
    }
  });

  test('Unicode text passes through', () {
    expect(krutidevToUnicode('न्यायालय 302'), 'न्यायालय 302');
  });

  // A paste can run to pages, and a rule that rescans the rest of a run takes seconds on a long one (O(n²)): a run of
  // each kind a rule once rescanned, a reph after many vowel signs (once a walk back over them per reph), and real text.
  final text = (detect['legacy'] as List).cast<String>().join(' ');
  for (final t in [
    'a',
    ' ',
    'Z',
    'D',
    'b${'A' * 19998}b',
    '${'w' * 10000}${'Z' * 10000}',
    text,
  ]) {
    final s = (t * (20000 ~/ t.length + 1)).substring(0, 20000);
    test(
      '20,000 characters of ${t.substring(0, 1)}... convert in linear time',
      () {
        final watch = Stopwatch()..start();
        krutidevToUnicode(s);
        looksLikeKrutidev(s);
        expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
      },
    );
  }
}
