// Spec §16.1 app integration against the local stack (`just dev`): onboarding → find my cases → add all → Today.
// The Docker workers run with COURTDATA_LIVE unset, so the search goes to the synthetic stand-in
// (packages/court_data fake.py, its dates shifted to the worker's today), never a real provider. Run on a desktop:
//   flutter test integration_test/onboarding_import_test.dart -d windows --dart-define-from-file=env.local.json
import 'dart:io';

import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/diary.dart';
import 'package:advocate_app/data/jobs.dart';
import 'package:advocate_app/data/sync/schema.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:powersync/powersync.dart' hide SyncStatus;

import 'local_stack.dart';

const _phone = '919999900035'; // local test number (supabase/config.toml)

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    "a new advocate's found cases, added all, are in tomorrow's diary",
    (_) async {
      // A new account every run (find-cases allows three searches a day per user).
      final supabase = await signIn(_phone);
      final me = supabase.auth.currentUser!.id;
      addTearDown(() => dropUser(me));
      final api = apiAs(supabase);

      // Steps 6-7 as the details screen sends them: the fixture's advocate, every court in her state.
      await api.patchMe({
        'full_name': 'Neha Sharma',
        'enrolment_no': 'MP/1234/2010',
        'bar_council_state': 'MP',
        'practice_court_ids': <String>[],
      });
      final org = await api.createOrg(name: 'Neha Sharma', kind: 'solo');
      final jobId = await api.findCases(orgId: org, idempotencyKey: uuid.v4());
      late Job job;
      await until(
        () async => (job = await api.job(jobId)).finished,
        timeout: const Duration(seconds: 90),
      );
      expect(job.status, JobStatus.done, reason: job.error);
      final pending = job.result!['pending'] as int;
      expect(pending, greaterThan(0));

      // The found cases reach the device.
      final dir = await Directory.systemTemp.createTemp('pairavi_onboarding');
      final db = PowerSyncDatabase(schema: schema, path: '${dir.path}/test.db');
      addTearDown(() async {
        await db.disconnectAndClear();
        await db.close();
      });
      await db.connect(connector: SupabaseConnector(supabase));
      await db.waitForFirstSync();
      Future<int> count(String table, [String where = 'true']) async =>
          (await db.get(
                'select count(*) as n from $table where org_id = ? and $where',
                [org],
              ))['n']
              as int;
      await until(
        () async => await count('found_cases') == job.result!['found'],
      );

      final c = ProviderContainer(
        overrides: [
          syncDatabaseProvider.overrideWithValue(db),
          currentOrgIdProvider.overrideWithValue(org),
          currentUserIdProvider.overrideWithValue(me),
        ],
      );
      addTearDown(c.dispose);
      final tomorrow = isoDate(c.read(istTomorrowProvider));
      final due = {
        for (final r in await db.getAll(
          'select cnr from found_cases where org_id = ? and next_date = ? '
          "and case_status = 'pending'",
          [org, tomorrow],
        ))
          r['cnr'] as String,
      };
      expect(
        due,
        isNotEmpty,
        reason: 'the synthetic data lists cases tomorrow',
      );

      // Add all (step 8): the cases reach the device, then the fetch job's court details and past hearings.
      final added = await api.addAllFoundCases(
        orgId: org,
        idempotencyKey: uuid.v4(),
      );
      expect(added.added, pending);
      await until(
        () async =>
            await count('matters', 'court_fetched_at is not null') == pending &&
            await count('hearings') > 0,
        timeout: const Duration(seconds: 60),
      );

      // Today's tomorrow section (and Today itself after the evening switch) reads this.
      final diary = await c
          .listen(diaryProvider(tomorrow).future, (_, _) {})
          .read();
      final cnrOf = {
        for (final r in await db.getAll(
          'select id, cnr from matters where org_id = ?',
          [org],
        ))
          r['id']: r['cnr'],
      };
      expect({for (final e in diary) cnrOf[e.matterId]}, due);
    },
  );
}
