import 'dart:async';
import 'dart:io';

import 'package:advocate_app/app.dart';
import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/router.dart';
import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/core/theme/app_theme.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/auth.dart';
import 'package:advocate_app/data/courts.dart';
import 'package:advocate_app/data/device.dart';
import 'package:advocate_app/data/diary.dart';
import 'package:advocate_app/data/found_cases.dart';
import 'package:advocate_app/data/jobs.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:advocate_app/features/board/board_share.dart';
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

  /// Matter ids refreshMatter answers with RATE_LIMITED: refreshed in the last 6 h, so already up to date.
  final refreshedRecently = <String>{};

  @override
  Future<String> refreshMatter({
    required String orgId,
    required String matterId,
    required String idempotencyKey,
  }) => _call('refreshMatter', {'id': matterId, 'key': idempotencyKey}, () {
    if (refreshedRecently.contains(matterId)) {
      throw const ApiException(
        'RATE_LIMITED',
        retryable: true,
        status: 429,
        details: {'retry_after_s': 3600},
      );
    }
    return 'job-$matterId';
  });
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
        testShareDir(),
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

/// Shared board images go to a fresh temp folder (see [boardShareDirProvider]), deleted after the test.
Override testShareDir() {
  final temp = Directory.systemTemp.createTempSync('pairavi_test_');
  addTearDown(() => temp.deleteSync(recursive: true));
  return boardShareDirProvider.overrideWithValue(
    () async => boardShareDir(temp.path),
  );
}

/// The app's provider container, e.g. to read the router or a provider's state.
ProviderContainer container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(App)));

/// Thu 5 Nov 2026, 10:00 IST: [FakeDiary]'s default now. Today is [testToday], tomorrow [testTomorrow].
final testNow = DateTime.utc(2026, 11, 5, 4, 30);
const testToday = '2026-11-05';
const testTomorrow = '2026-11-06';

/// The current org's members (ownerAccount is user-1, the owner).
const testMembers = [
  OrgMember(userId: 'user-1', role: 'owner', name: 'Ramesh Sharma'),
  OrgMember(userId: 'user-3', role: 'advocate', name: 'Neha Verma'),
  OrgMember(userId: 'user-2', role: 'junior', name: 'Rakesh Jain'),
  OrgMember(userId: 'user-4', role: 'clerk', name: 'Mohan Lal'),
];

/// Diary entry [n] (matter `m-n`, board entry `b-n` unless [boarded] is false): WP 100n/2024 at MPHC Indore,
/// Court 12, item [item] (default n) with the worker's HC slot for it (10:30 + 4 min per item). Without a board
/// entry it has no item number and no slot, as before the evening build. Set [court] to another of [testCourts]
/// for a different complex.
DiaryEntry diaryEntry(
  int n, {
  Court? court,
  String? courtNo = '12',
  int? item,
  Duration? slot,
  bool boarded = true,
  String? title,
  String? purpose = 'Admission',
  String? bench,
  String? client = 'Suresh Patel',
  String? assigneeId,
  String? assigneeName,
  bool proxy = false,
  String tracking = 'auto',
}) {
  final c = court ?? testCourts.first;
  final i = item ?? n;
  return DiaryEntry(
    matterId: 'm-$n',
    caseLabel: 'WP ${1000 + n}/2024',
    title: title ?? 'Sharma v. State of MP',
    courtId: c.id,
    court: c,
    courtNo: courtNo,
    itemNo: boarded ? '$i' : null,
    slot: boarded
        ? slot ?? Duration(minutes: 10 * 60 + 30 + (i - 1) * 4)
        : null,
    bench: bench,
    purpose: purpose,
    client: client,
    assigneeId: assigneeId,
    assigneeName: assigneeName,
    proxyArranged: proxy,
    boardEntryId: boarded ? 'b-$n' : null,
    tracking: tracking,
  );
}

/// The diary in memory for widget tests (no PowerSync): what Today and the board read, by IST date, and the
/// writer they write through. Writes change what the providers show, as the synced database would: Assign to and
/// Mark proxy arranged re-apply the clash rule, a completed task leaves Tasks due, a read notification leaves New
/// orders and Needs attention. Pass [overrides] to pumpApp (they include the clock, [now]); [writes] records each
/// write (`assign`, `setProxy`, `completeTask`, `reopenTask`, `markNotificationRead`).
class FakeDiary extends DiaryWriter {
  FakeDiary({
    Map<String, List<DiaryEntry>> days = const {},
    this.tasks = const [],
    this.orders = const [],
    this.attention = const [],
    this.members = testMembers,
    this.ownerId = 'user-1',
    this.hasMatters = true,
    this.eveningSwitch = defaultEveningSwitch,
    DateTime? now,
  }) : now = now ?? testNow,
       days = {
         for (final MapEntry(:key, :value) in days.entries)
           key: withClashes(value, ownerId),
       },
       super(null, DateTime.now);

  /// Entries by IST date ([testToday], [testTomorrow]), in any order: the providers order them.
  final Map<String, List<DiaryEntry>> days;
  final List<DueTask> tasks;
  final List<DiaryNotice> orders;
  final List<AttentionItem> attention;
  final List<OrgMember> members;
  final String? ownerId;

  /// Null: still loading.
  final bool? hasMatters;
  final Duration eveningSwitch;

  /// The instant the clock reads (default [testNow]); set it before pumping.
  DateTime now;

  final writes = <FakeCall>[];
  final doneTasks = <String>{};
  final readNotifications = <String>{};
  final _changes = StreamController<void>.broadcast();

  Stream<T> _watch<T>(T Function() read) => Stream.multi((out) {
    void emit([_]) => out.add(read());
    emit();
    final sub = _changes.stream.listen(emit);
    out.onCancel = sub.cancel;
  });

  late final _attention = StreamProvider<List<AttentionItem>>(
    (ref) => _watch(
      () => [
        for (final a in attention)
          if (!readNotifications.contains(a.notificationId)) a,
      ],
    ),
  );

  List<Override> get overrides => [
    clockProvider.overrideWithValue(() => now),
    diaryProvider.overrideWith(
      (ref, day) => _watch(() => orderDiary(days[day] ?? const [])),
    ),
    tasksDueProvider.overrideWith(
      (ref) => _watch(
        () => [
          for (final t in tasks)
            if (!doneTasks.contains(t.id)) t,
        ],
      ),
    ),
    newOrdersProvider.overrideWith(
      (ref) => _watch(
        () => [
          for (final n in orders)
            if (!readNotifications.contains(n.id)) n,
        ],
      ),
    ),
    needsAttentionProvider.overrideWith((ref) => ref.watch(_attention)),
    eveningSwitchProvider.overrideWithValue(AsyncData(eveningSwitch)),
    orgMembersProvider.overrideWithValue(AsyncData(members)),
    hasMattersProvider.overrideWithValue(
      hasMatters == null ? const AsyncLoading() : AsyncData(hasMatters!),
    ),
    caseHeaderProvider.overrideWith(
      (ref, id) => _watch(() {
        final e = days.values.expand((d) => d).where((e) => e.matterId == id);
        return e.isEmpty
            ? null
            : (caseLabel: e.first.caseLabel, title: e.first.title);
      }),
    ),
    diaryWriterProvider.overrideWithValue(this),
  ];

  void _record(String name, Object? args) {
    writes.add((name: name, args: args));
    _changes.add(null);
  }

  void _updateBoard(String boardEntryId, DiaryEntry Function(DiaryEntry) f) {
    for (final MapEntry(key: day, value: entries) in days.entries.toList()) {
      if (entries.any((e) => e.boardEntryId == boardEntryId)) {
        days[day] = withClashes([
          for (final e in entries)
            if (e.boardEntryId == boardEntryId) f(e) else e,
        ], ownerId);
      }
    }
  }

  @override
  Future<void> assign(String boardEntryId, String? userId) async {
    final name = members.where((m) => m.userId == userId).firstOrNull?.name;
    _updateBoard(
      boardEntryId,
      (e) => e.copyWith(assignee: (id: userId, name: name)),
    );
    _record('assign', {'boardEntryId': boardEntryId, 'userId': userId});
  }

  @override
  Future<void> setProxy(String boardEntryId, {required bool arranged}) async {
    _updateBoard(boardEntryId, (e) => e.copyWith(proxyArranged: arranged));
    _record('setProxy', {'boardEntryId': boardEntryId, 'arranged': arranged});
  }

  @override
  Future<void> completeTask(String taskId) async {
    doneTasks.add(taskId);
    _record('completeTask', taskId);
  }

  @override
  Future<void> reopenTask(String taskId) async {
    doneTasks.remove(taskId);
    _record('reopenTask', taskId);
  }

  @override
  Future<void> markNotificationRead(String notificationId) async {
    readNotifications.add(notificationId);
    _record('markNotificationRead', notificationId);
  }
}
