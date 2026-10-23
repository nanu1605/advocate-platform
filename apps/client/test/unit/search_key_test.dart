import 'dart:io';

import 'package:advocate_app/core/search_key.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  // Shared with the Python implementation, so both give identical keys.
  final fixture = loadYaml(
    File('../../config/fixtures/translit_pairs.yaml').readAsStringSync(),
  ) as YamlMap;
  final pairs = (fixture['pairs'] as YamlList).cast<YamlMap>();
  final other = (fixture['other'] as YamlList).cast<YamlMap>();

  test('fixture has 50 pairs', () => expect(pairs, hasLength(50)));

  for (final pair in pairs) {
    final spellings = [
      pair['hi'] as String,
      ...(pair['en'] as YamlList).cast<String>(),
    ];
    test('${spellings[1]} = ${spellings[0]}', () {
      expect(
        {for (final s in spellings) s: searchKey(s)},
        {for (final s in spellings) s: pair['key']},
      );
    });
  }

  for (final c in other) {
    test('"${c['text']}"', () {
      expect(searchKey(c['text'] as String), c['key']);
    });
  }
}
