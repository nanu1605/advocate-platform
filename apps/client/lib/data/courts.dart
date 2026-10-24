import 'package:advocate_app/data/sync/sync.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A court from the synced reference table (spec §9.2).
@immutable
class Court {
  const Court({
    required this.id,
    required this.level,
    required this.name,
    required this.shortName,
    this.nameHi,
    this.shortNameHi,
    this.state,
    this.district,
  });

  factory Court.fromRow(Map<String, dynamic> r) => Court(
    id: r['id'] as String,
    level: r['level'] as String,
    name: r['name'] as String,
    nameHi: r['name_hi'] as String?,
    shortName: r['short_name'] as String,
    shortNameHi: r['short_name_hi'] as String?,
    state: r['state'] as String?,
    district: r['district'] as String?,
  );

  final String id;

  /// SC, HC, DC or TRIBUNAL.
  final String level;
  final String name;
  final String? nameHi;

  /// "MPHC Indore", "District Court Indore", "Supreme Court".
  final String shortName;
  final String? shortNameHi;

  /// State code, e.g. MP (the Supreme Court has none).
  final String? state;
  final String? district;

  /// Short name in the UI language.
  String label(Locale locale) =>
      locale.languageCode == 'hi' ? shortNameHi ?? shortName : shortName;

  /// [label] as it is said, for screen readers and group headings: "MPHC Indore" → "MP High Court Indore"
  /// (spec §4.1 AC; screen readers spell "MPHC" out). [highCourt] is "High Court" in the UI language.
  String spokenLabel(Locale locale, String highCourt) => label(
    locale,
  ).replaceFirstMapped(RegExp(r'^([A-Z]+)HC\b'), (m) => '${m[1]} $highCourt');
}

/// Every court, High Courts first, then district courts, the Supreme Court and tribunals (the Finding screen's
/// order). Empty until the first sync, and in builds without sync.
final courtsProvider = StreamProvider<List<Court>>((ref) {
  final db = ref.watch(syncDatabaseProvider);
  if (db == null) return Stream.value(const []);
  return db
      .watch(
        'select id, level, name, name_hi, short_name, short_name_hi, state, district from courts '
        "order by case level when 'HC' then 0 when 'DC' then 1 when 'SC' then 2 else 3 end, short_name",
      )
      .map((rows) => rows.map(Court.fromRow).toList());
});
