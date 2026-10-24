import 'package:advocate_app/app.dart';
import 'package:advocate_app/core/router.dart';
import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/core/theme/app_theme.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/auth.dart';
import 'package:advocate_app/data/courts.dart';
import 'package:advocate_app/data/device.dart';
import 'package:advocate_app/data/found_cases.dart';
import 'package:advocate_app/data/jobs.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:advocate_app/features/lock/app_lock.dart';
import 'package:advocate_app/features/onboarding/consent_screen.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

/// Signed in, no organisation yet: onboarding starts at the role screen.
const newAccount = Account(id: 'user-1');

/// A solo advocate with complete Bar Council details (counts as set up).
const ownerAccount = Account(
  id: 'user-1',
  fullName: 'Ramesh Sharma',
  enrolmentNo: 'MP/1234/2010',
  barCouncilState: 'MP',
  memberships: [
    Membership(
      orgId: 'org-1',
      orgName: 'Ramesh Sharma',
      orgKind: 'solo',
      role: 'owner',
    ),
  ],
);

/// A junior who joined a chamber by invite (skips details, finding and found cases).
const juniorAccount = Account(
  id: 'user-2',
  memberships: [
    Membership(
      orgId: 'org-1',
      orgName: 'Sharma Chambers',
      orgKind: 'chamber',
      role: 'junior',
    ),
  ],
);

/// The courts seeded by the court-diary migration (HC first, the courts provider's order).
const testCourts = [
  Court(
    id: 'c0000000-0000-0000-0000-000000000003',
    level: 'HC',
    name: 'High Court of Madhya Pradesh, Bench at Indore',
    shortName: 'MPHC Indore',
    shortNameHi: 'MPHC इंदौर',
    state: 'MP',
    district: 'Indore',
  ),
  Court(
    id: 'c0000000-0000-0000-0000-000000000002',
    level: 'HC',
    name: 'High Court of Madhya Pradesh, Jabalpur',
    shortName: 'MPHC Jabalpur',
    shortNameHi: 'MPHC जबलपुर',
    state: 'MP',
    district: 'Jabalpur',
  ),
  Court(
    id: 'c0000000-0000-0000-0000-000000000004',
    level: 'HC',
    name: 'High Court of Madhya Pradesh, Bench at Gwalior',
    shortName: 'MPHC Gwalior',
    shortNameHi: 'MPHC ग्वालियर',
    state: 'MP',
    district: 'Gwalior',
  ),
  Court(
    id: 'c0000000-0000-0000-0000-000000000005',
    level: 'DC',
    name: 'District and Sessions Court, Indore',
    shortName: 'District Court Indore',
    shortNameHi: 'जिला कोर्ट इंदौर',
    state: 'MP',
    district: 'Indore',
  ),
  Court(
    id: 'c0000000-0000-0000-0000-000000000001',
    level: 'SC',
    name: 'Supreme Court of India',
    shortName: 'Supreme Court',
    shortNameHi: 'सुप्रीम कोर्ट',
  ),
];

/// Found case number [n] (id `fc-n`), by default a pending, high-confidence WP at MPHC Indore.
FoundCase foundCase(
  int n, {
  String? courtId = 'c0000000-0000-0000-0000-000000000003',
  String caseType = 'WP',
  int? caseYear = 2024,
  String status = 'pending',
  String confidence = 'high',
  String? title,
  DateTime? nextDate,
  String? courtNo = '12',
}) => FoundCase(
  id: 'fc-$n',
  cnr: 'MPHC01${n.toString().padLeft(10, '0')}',
  courtId: courtId,
  caseType: caseType,
  caseNumber: '${1000 + n}',
  caseYear: caseYear,
  courtNo: courtNo,
  title: title ?? 'Sharma v. State of MP',
  nextDate: nextDate,
  caseStatus: status,
  confidence: confidence,
);

typedef FakeCall = ({String name, Object? args});

/// In-memory API. [account] is what /v1/me returns; patchMe, createOrg and acceptInvite change it like the
/// server would. [fail] makes one method throw (`api.fail['findCases'] = const ApiException('RATE_LIMITED')`);
/// [failAfter] makes it throw after the server did the work (a lost response); [offline] makes every call
/// throw NETWORK (set it after pumpApp, so the account still loads). [calls] records each call with its
/// arguments.
class FakeApi extends ApiClient {
  FakeApi({this.account = newAccount}) : super(Dio());

  Account account;
  bool offline = false;
  final fail = <String, ApiException>{};
  final failAfter = <String, ApiException>{};
  final calls = <FakeCall>[];
  final consents = <Map<String, bool>>[];

  /// What job() returns by id; a missing id is a finished search that found nothing.
  final jobs = <String, Job>{};

  /// The role acceptInvite gives, in Sharma Chambers (org-2).
  String inviteRole = 'junior';
  AddResult addResult = (added: 0, alreadyTracked: 0, matterIds: const []);

  Iterable<String> get callNames => calls.map((c) => c.name);

  Future<T> _call<T>(String name, Object? args, T Function() result) async {
    calls.add((name: name, args: args));
    if (offline) throw const ApiException('NETWORK', retryable: true);
    final error = fail[name];
    if (error != null) throw error;
    final r = result();
    final lost = failAfter[name];
    if (lost != null) throw lost;
    return r;
  }

  Account _with({Map<String, Object?> fields = const {}, Membership? join}) =>
      account = Account(
        id: account.id,
        fullName: fields['full_name'] as String? ?? account.fullName,
        enrolmentNo: fields['enrolment_no'] as String? ?? account.enrolmentNo,
        barCouncilState:
            fields['bar_council_state'] as String? ?? account.barCouncilState,
        practiceCourtIds:
            (fields['practice_court_ids'] as List?)?.cast() ??
            account.practiceCourtIds,
        memberships: [...account.memberships, ?join],
      );

  @override
  Future<Account> me() => _call('me', null, () => account);

  @override
  Future<Account> patchMe(Map<String, Object?> fields) =>
      _call('patchMe', fields, () => _with(fields: fields));

  @override
  Future<void> postConsents({
    required String version,
    required Map<String, bool> decisions,
  }) => _call('postConsents', decisions, () => consents.add(decisions));

  @override
  Future<void> registerDevice({
    required String id,
    required String platform,
    String? appVersion,
    String? pushToken,
  }) => _call('registerDevice', id, () {});

  @override
  Future<String> createOrg({required String name, required String kind}) =>
      _call('createOrg', {'name': name, 'kind': kind}, () {
        _with(
          join: Membership(
            orgId: 'org-1',
            orgName: name,
            orgKind: kind,
            role: 'owner',
          ),
        );
        return 'org-1';
      });

  @override
  Future<({String orgId, String role})> acceptInvite(String code) =>
      _call('acceptInvite', code, () {
        _with(
          join: Membership(
            orgId: 'org-2',
            orgName: 'Sharma Chambers',
            orgKind: 'chamber',
            role: inviteRole,
          ),
        );
        return (orgId: 'org-2', role: inviteRole);
      });

  @override
  Future<String> findCases({
    required String orgId,
    required String idempotencyKey,
  }) => _call('findCases', {
    'orgId': orgId,
    'key': idempotencyKey,
  }, () => 'job-1');

  @override
  Future<Job> job(String id) => _call(
    'job',
    id,
    () => jobs[id] ?? Job(id: id, kind: 'find_cases', status: JobStatus.done),
  );

  @override
  Future<Job> cancelJob(String id) => _call(
    'cancelJob',
    id,
    () => Job(id: id, kind: 'find_cases', status: JobStatus.cancelled),
  );

  @override
  Future<AddResult> addAllFoundCases({
    required String orgId,
    required String idempotencyKey,
  }) => _call('addAllFoundCases', {'key': idempotencyKey}, () => addResult);

  @override
  Future<AddResult> addFoundCases({
    required String orgId,
    required String idempotencyKey,
    required List<String> ids,
  }) => _call('addFoundCases', {
    'key': idempotencyKey,
    'ids': ids,
  }, () => addResult);

  @override
  Future<void> decideFoundCase({
    required String orgId,
    required String id,
    required String decision,
  }) => _call('decideFoundCase', {'id': id, 'decision': decision}, () {});

  @override
  Future<({String matterId, bool created})> addByCnr({
    required String orgId,
    required String idempotencyKey,
    required String cnr,
  }) => _call('addByCnr', {
    'key': idempotencyKey,
    'cnr': cnr,
  }, () => (matterId: 'matter-1', created: true));
}

class FakeRegistrar extends DeviceRegistrar {
  FakeRegistrar() : super(FakeApi());

  @override
  Future<void> register() async {}
}

/// Overrides for the synced tables (widget tests have no PowerSync). [offline] also shows the offline banner.
/// [settled]: the search has finished and synced (so "Add all" may go as `{all: true}`).
List<Override> syncedData({
  List<FoundCase> found = const [],
  List<Court> courts = testCourts,
  int? allowance = 100,
  bool offline = false,
  bool settled = false,
}) => [
  foundCasesProvider.overrideWithValue(AsyncData(found)),
  courtsProvider.overrideWithValue(AsyncData(courts)),
  remainingAllowanceProvider.overrideWithValue(AsyncData(allowance)),
  findSettledProvider.overrideWithValue(settled),
  if (offline)
    syncViewProvider.overrideWithValue(
      const AsyncData((status: SyncStatus.syncing, offline: true)),
    ),
];

/// The whole app with fake auth, API and lock storage: signed in, consented, app lock set, then sent to
/// [location] through the real router (which may redirect it). [onboardingDone] is the device flag; null lets
/// the router decide from [account]. Synced reads are empty unless [overrides] include [syncedData].
/// Returns the [FakeApi] for assertions; read the router with `container(tester).read(routerProvider)`.
Future<FakeApi> pumpApp(
  WidgetTester tester, {
  String location = '/today',
  Account account = ownerAccount,
  bool? onboardingDone,
  String locale = 'en',
  AppThemeMode theme = AppThemeMode.light,
  double textScale = 1,
  Size size = const Size(400, 860),
  List<Override> overrides = const [],
  FakeApi? api,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  SharedPreferences.setMockInitialValues({
    'settings.locale': locale,
    'settings.theme': theme.name,
    'settings.consent_version': consentNoticeVersion,
    'settings.onboarding_done': ?onboardingDone,
  });
  final prefs = await SharedPreferences.getInstance();
  final fake = api ?? FakeApi(account: account);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        authRepositoryProvider.overrideWithValue(FakeAuth(signedIn: true)),
        apiClientProvider.overrideWithValue(fake),
        deviceRegistrarProvider.overrideWithValue(FakeRegistrar()),
        lockStoreProvider.overrideWithValue(MemoryLockStore()),
        deviceAuthProvider.overrideWithValue(FakeDeviceAuth()),
        initialLockProvider.overrideWithValue(
          const AppLockState(method: LockMethod.none),
        ),
        ...overrides,
      ],
      child: const App(),
    ),
  );
  await tester.pump();
  if (location != '/today') container(tester).read(routerProvider).go(location);
  await tester.pumpAndSettle();
  return fake;
}

/// The app's provider container, e.g. to read the router or a provider's state.
ProviderContainer container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(App)));
