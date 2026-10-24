import 'dart:io';

import 'package:advocate_app/data/clash.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

/// The clash rule against the fixture the worker's tests use (spec §4.2 AC), so app and worker agree.
void main() {
  final fixture = loadYaml(
    File('../../config/fixtures/board_clash.yaml').readAsStringSync(),
  ) as YamlMap;
  int? minutes(Object? hhmm) {
    if (hhmm == null) return null;
    final [h, m] = (hhmm as String).split(':').map(int.parse).toList();
    return h * 60 + m;
  }

  final cases = (fixture['clashes'] as YamlList).cast<YamlMap>();
  test('fixture has cases', () => expect(cases, isNotEmpty));

  for (final c in cases) {
    test(c['name'] as String, () {
      final entries = [
        for (final e in (c['entries'] as YamlList).cast<YamlMap>())
          (
            key: e['key'] as String,
            courtId: e['court'] as String?,
            slot: minutes(e['slot']),
            assignee: e['assignee'] as String?,
            proxy: e['proxy'] as bool? ?? false,
          ),
      ];
      expect(
        clashGroups(entries, c['advocate'] as String?),
        Map<String, int>.from(c['groups'] as YamlMap),
      );
    });
  }

  test('the window matches the worker', () => expect(clashWindowMinutes, 60));
}
