import 'package:advocate_app/features/cases/search_cases_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sync_db.dart';

/// The SQL that names a search hit's court, against a real on-device database (spec §11.7).
void main() {
  // IST now listens for the app resuming.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('courts by provider code: each court with a search code', () async {
    final db = await openTestDb();
    await insertRows(db, 'courts', [
      {
        'id': 'c-hc',
        'level': 'HC',
        'name': 'High Court of Madhya Pradesh, Bench at Indore',
        'short_name': 'MPHC Indore',
        'short_name_hi': 'MPHC इंदौर',
        'provider_codes': '{"ecourtsindia": "MPHC01"}',
      },
      {
        'id': 'c-dc',
        'level': 'DC',
        'name': 'District and Sessions Court, Indore',
        'short_name': 'District Court Indore',
        'provider_codes': '{}',
      },
    ]);
    final byCode = await firstValue(
      dbContainer(db),
      courtsByCodeProvider,
      (m) => m.isNotEmpty,
    );
    expect(byCode.keys, ['MPHC01']);
    expect(byCode['MPHC01']!.id, 'c-hc');
    expect(byCode['MPHC01']!.shortNameHi, 'MPHC इंदौर');
  });
}
