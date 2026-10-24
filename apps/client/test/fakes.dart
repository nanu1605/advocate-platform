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
import 'package:advocate_app/data/cases.dart';
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

  /// The next call to a method named here waits for its completer, e.g. to act while that request is in flight.
  final gates = <String, Completer<void>>{};

  Future<T> _call<T>(String name, Object? args, T Function() result) async {
    calls.add((name: name, args: args));
    final gate = gates.remove(name);
    if (gate != null) await gate.future;
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

  /// What searchCases returns for page n (`searchPages[n - 1]`); later pages are empty.
  List<CaseSearchPage> searchPages = const [];

  @override
  Future<CaseSearchPage> searchCases({
    required String orgId,
    String? party,
    String? advocate,
    String? judge,
    String? text,
    List<String> courtIds = const [],
    String? caseType,
    int? year,
    int page = 1,
    int pageSize = 20,
  }) => _call(
    'searchCases',
    {
      'party': party,
      'advocate': advocate,
      'judge': judge,
      'text': text,
      'courtIds': courtIds,
      'caseType': caseType,
      'year': year,
      'page': page,
    },
    () => page <= searchPages.length
        ? searchPages[page - 1]
        : CaseSearchPage(items: const [], total: 0, page: page, hasNext: false),
  );

  /// The matter id addManual answers with.
  String manualMatterId = 'matter-manual';

  @override
  Future<String> addManual({
    required String orgId,
    required String title,
    String? courtId,
    String? courtName,
    String? caseType,
    String? caseNumber,
    int? caseYear,
    String? ourSide,
    String? fileNo,
    DateTime? nextDate,
  }) => _call('addManual', {
    'title': title,
    'courtId': courtId,
    'courtName': courtName,
    'caseType': caseType,
    'caseNumber': caseNumber,
    'caseYear': caseYear,
    'ourSide': ourSide,
    'fileNo': fileNo,
    'nextDate': nextDate,
  }, () => manualMatterId);

  @override
  Future<({String url, String cnr, bool verified})> officialLink({
    required String orgId,
    required String matterId,
  }) => _call(
    'officialLink',
    matterId,
    () => (
      url: 'https://hcservices.ecourts.gov.in/',
      cnr: 'MPHC010000000001',
      verified: false,
    ),
  );

  @override
  Future<void> deleteMatter({
    required String orgId,
    required String matterId,
  }) => _call('deleteMatter', matterId, () {});

  /// The job id setTracking answers with when tracking turns on.
  String? trackingJobId = 'job-track';

  @override
  Future<({String tracking, String? jobId})> setTracking({
    required String orgId,
    required String matterId,
    required String tracking,
  }) => _call(
    'setTracking',
    {'id': matterId, 'tracking': tracking},
    () =>
        (tracking: tracking, jobId: tracking == 'auto' ? trackingJobId : null),
  );

  @override
  Future<String> documentUrl({
    required String orgId,
    required String documentId,
  }) => _call(
    'documentUrl',
    documentId,
    () => 'https://files.test/documents/$documentId',
  );

  @override
  Future<String> orderPdfUrl({
    required String orgId,
    required String orderId,
  }) =>
      _call('orderPdfUrl', orderId, () => 'https://files.test/orders/$orderId');
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

  Stream<T> _watch<T>(T Function() read) => _live(_changes.stream, read);

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

/// A stream of [read] that emits again on each [changes] event, as `db.watch` does after a write.
Stream<T> _live<T>(Stream<void> changes, T Function() read) =>
    Stream.multi((out) {
      void emit([_]) => out.add(read());
      emit();
      final sub = changes.listen(emit);
      out.onCancel = sub.cancel;
    });

/// Case [n] (matter `m-n`, the same case as [diaryEntry] n): WP 100n/2024 at MPHC Indore, Court 12, pending,
/// auto-tracked with a CNR, last fetched at 7:42 pm IST on Wed 4 Nov, with client Suresh Patel. A manual case has
/// no CNR, court status or fetch time unless given; [courtName] alone is an "Other court".
CaseInfo caseInfo(
  int n, {
  Court? court,
  String? courtName,
  String? courtNo = '12',
  String? caseType = 'WP',
  String? caseNumber,
  int? caseYear = 2024,
  String? cnr,
  String? title = 'Sharma v. State of MP',
  String? judge,
  String? stage,
  String status = 'active',
  String tracking = 'auto',
  String? courtStatus = 'pending',
  DateTime? nextDate,
  DateTime? courtFetchedAt,
  DateTime? updatedAt,
  String? assigneeId,
  String? assigneeName,
  List<({String id, String name})> clients = const [
    (id: 'cl-1', name: 'Suresh Patel'),
  ],
}) {
  final manual = tracking == 'manual';
  final c = courtName == null ? court ?? testCourts.first : court;
  return CaseInfo(
    id: 'm-$n',
    cnr: cnr ?? (manual ? null : 'MPHC01${n.toString().padLeft(10, '0')}'),
    caseType: caseType,
    caseNumber: caseNumber ?? '${1000 + n}',
    caseYear: caseYear,
    title: title,
    courtId: c?.id,
    court: c,
    courtName: courtName,
    courtNo: courtNo,
    judge: judge,
    stage: stage,
    status: status,
    tracking: tracking,
    source: manual ? 'manual' : 'cnr',
    courtStatus: manual ? null : courtStatus,
    nextDate: nextDate,
    courtFetchedAt:
        courtFetchedAt ?? (manual ? null : DateTime.utc(2026, 11, 4, 14, 12)),
    updatedAt: updatedAt,
    assigneeId: assigneeId,
    assigneeName: assigneeName,
    clients: clients,
  );
}

/// The cases data in memory for widget tests (no PowerSync): what the Cases list, the case page and the add
/// sheets read, and the [CaseWriter] they write through. Writes change what the providers show, as the synced
/// database would (a manual case's next date follows its hearings; linking a client adds it to the case);
/// [writes] records each one by method name with its arguments. Child rows are keyed by matter id (tasks without a
/// case under ''). Pass [overrides] to pumpApp (they include the clock, [now], and the org's [members]), or
/// [caseOverrides] next to a [FakeDiary]'s overrides, which set those already.
class FakeCases extends CaseWriter {
  FakeCases({
    List<CaseInfo> cases = const [],
    Map<String, List<CaseHearing>> hearings = const {},
    Map<String, List<CaseOrder>> orders = const {},
    Map<String, List<CaseDocument>> documents = const {},
    Map<String, List<CaseNote>> notes = const {},
    Map<String, List<CaseTask>> tasks = const {},
    Map<String, List<CaseDeadline>> deadlines = const {},
    Map<String, List<LinkedClient>> links = const {},
    List<ClientInfo> clients = const [],
    this.members = testMembers,
    this.pendingFound = 0,
    this.me = 'user-1',
    DateTime? now,
  }) : now = now ?? testNow,
       cases = [...cases],
       hearings = _copy(hearings),
       orders = _copy(orders),
       documents = _copy(documents),
       notes = _copy(notes),
       tasks = _copy(tasks),
       deadlines = _copy(deadlines),
       links = _copy(links),
       clients = [...clients],
       super(null, DateTime.now, orgId: 'org-1', userId: me);

  static Map<String, List<T>> _copy<T>(Map<String, List<T>> m) => {
    for (final MapEntry(:key, :value) in m.entries) key: [...value],
  };

  final List<CaseInfo> cases;
  final Map<String, List<CaseHearing>> hearings;
  final Map<String, List<CaseOrder>> orders;
  final Map<String, List<CaseDocument>> documents;
  final Map<String, List<CaseNote>> notes;
  final Map<String, List<CaseTask>> tasks;
  final Map<String, List<CaseDeadline>> deadlines;
  final Map<String, List<LinkedClient>> links;
  final List<ClientInfo> clients;
  final List<OrgMember> members;

  /// "Found for you (n)".
  final int pendingFound;

  /// The signed-in user (ownerAccount): the author of new notes.
  final String me;

  /// The instant the clock reads (default [testNow]); set it before pumping.
  DateTime now;

  final writes = <FakeCall>[];
  final _changes = StreamController<void>.broadcast();
  var _ids = 0;

  /// Case page tables whose reads fail, as a broken query would: `documents`, `notes` or `clients`.
  final failing = <String>{};

  Stream<T> _watch<T>(T Function() read) => _live(_changes.stream, read);

  Stream<T> _table<T>(String table, T Function() read) =>
      failing.contains(table)
      ? Stream.error(StateError('$table failed'))
      : _watch(read);

  /// The case providers and the writer, for use with a [FakeDiary]'s overrides.
  List<Override> get caseOverrides => [
    casesProvider.overrideWith((ref) => _watch(() => [...cases])),
    caseProvider.overrideWith(
      (ref, id) => _watch(() => cases.where((c) => c.id == id).firstOrNull),
    ),
    caseHearingsProvider.overrideWith(
      (ref, id) => _watch(
        () => [...?hearings[id]]..sort((a, b) => b.date.compareTo(a.date)),
      ),
    ),
    caseOrdersProvider.overrideWith(
      (ref, id) => _watch(() => [...?orders[id]]),
    ),
    caseDocumentsProvider.overrideWith(
      (ref, id) => _table('documents', () => [...?documents[id]]),
    ),
    caseNotesProvider.overrideWith(
      (ref, id) => _table('notes', () => [...?notes[id]]),
    ),
    caseTasksProvider.overrideWith((ref, id) => _watch(() => [...?tasks[id]])),
    caseDeadlinesProvider.overrideWith(
      (ref, id) => _watch(() => [...?deadlines[id]]),
    ),
    caseClientsProvider.overrideWith(
      (ref, id) => _table('clients', () => [...?links[id]]),
    ),
    clientsProvider.overrideWith((ref) => _watch(() => [...clients])),
    pendingFoundCountProvider.overrideWithValue(AsyncData(pendingFound)),
    caseWriterProvider.overrideWithValue(this),
  ];

  List<Override> get overrides => [
    clockProvider.overrideWithValue(() => now),
    orgMembersProvider.overrideWithValue(AsyncData(members)),
    ...caseOverrides,
  ];

  String _id(String prefix) => '$prefix-new-${++_ids}';

  String? _name(String? userId) =>
      members.where((m) => m.userId == userId).firstOrNull?.name;

  void _record(String name, Object? args) {
    writes.add((name: name, args: args));
    _changes.add(null);
  }

  /// Changes a case as sync would (e.g. after the API turned tracking on).
  void updateCase(String id, CaseInfo Function(CaseInfo) f) {
    final i = cases.indexWhere((c) => c.id == id);
    if (i >= 0) cases[i] = f(cases[i]);
    _changes.add(null);
  }

  /// A manual case's next date: its earliest hearing today or later (IST), as [nextDateOf] reads it.
  void _refreshNext(String? matterId) {
    final today = istDay(istOf(now));
    final dates = [
      for (final h in hearings[matterId] ?? const <CaseHearing>[])
        if (!h.date.isBefore(today)) h.date,
    ]..sort();
    final i = cases.indexWhere((c) => c.id == matterId);
    if (i >= 0 && cases[i].manual) {
      cases[i] = cases[i].copyWith(nextDate: dates.firstOrNull);
    }
  }

  /// Replaces the row matching [match] with what [f] returns, or removes it when that is null.
  void _replace<T>(
    Map<String, List<T>> rows,
    bool Function(T) match,
    T? Function(T) f,
  ) {
    for (final list in rows.values) {
      final i = list.indexWhere(match);
      if (i < 0) continue;
      final next = f(list[i]);
      if (next == null) {
        list.removeAt(i);
      } else {
        list[i] = next;
      }
      return;
    }
  }

  String? _matterOfHearing(String id) => hearings.entries
      .where((e) => e.value.any((h) => h.id == id))
      .firstOrNull
      ?.key;

  static DateTime _day(DateTime d) => DateTime.utc(d.year, d.month, d.day);

  @override
  Future<void> assignCase(String matterId, String? assigneeId) async {
    updateCase(
      matterId,
      (c) =>
          c.copyWith(assigneeId: assigneeId, assigneeName: _name(assigneeId)),
    );
    _record('assignCase', {'matterId': matterId, 'assigneeId': assigneeId});
  }

  @override
  Future<void> setArchived(String matterId, {required bool archived}) async {
    updateCase(
      matterId,
      (c) => c.copyWith(status: archived ? 'archived' : 'active'),
    );
    _record('setArchived', {'matterId': matterId, 'archived': archived});
  }

  @override
  Future<String> addHearing(
    String matterId, {
    required DateTime date,
    String? courtNo,
    String? itemNo,
    String? purpose,
    String? outcome,
  }) async {
    final id = _id('h');
    (hearings[matterId] ??= []).add(
      CaseHearing(
        id: id,
        date: _day(date),
        source: 'manual',
        courtNo: courtNo,
        itemNo: itemNo,
        purpose: purpose,
        outcome: outcome,
      ),
    );
    _refreshNext(matterId);
    _record('addHearing', {
      'matterId': matterId,
      'date': date,
      'courtNo': courtNo,
      'itemNo': itemNo,
      'purpose': purpose,
      'outcome': outcome,
    });
    return id;
  }

  @override
  Future<void> editHearing(
    String hearingId, {
    required DateTime date,
    String? courtNo,
    String? itemNo,
    String? purpose,
    String? outcome,
  }) async {
    final matter = _matterOfHearing(hearingId);
    _replace<CaseHearing>(
      hearings,
      (h) => h.id == hearingId,
      (h) => CaseHearing(
        id: h.id,
        date: _day(date),
        source: h.source,
        courtNo: courtNo,
        itemNo: itemNo,
        purpose: purpose,
        outcome: outcome,
        userNote: h.userNote,
        createdAt: h.createdAt,
      ),
    );
    _refreshNext(matter);
    _record('editHearing', {
      'id': hearingId,
      'date': date,
      'courtNo': courtNo,
      'itemNo': itemNo,
      'purpose': purpose,
      'outcome': outcome,
    });
  }

  @override
  Future<void> setHearingNote(String hearingId, String? note) async {
    _replace<CaseHearing>(
      hearings,
      (h) => h.id == hearingId,
      (h) => CaseHearing(
        id: h.id,
        date: h.date,
        source: h.source,
        courtNo: h.courtNo,
        itemNo: h.itemNo,
        purpose: h.purpose,
        outcome: h.outcome,
        nextDate: h.nextDate,
        userPurpose: h.userPurpose,
        userOutcome: h.userOutcome,
        userNextDate: h.userNextDate,
        userNote: (note ?? '').trim().isEmpty ? null : note!.trim(),
        createdAt: h.createdAt,
      ),
    );
    _record('setHearingNote', {'id': hearingId, 'note': note});
  }

  @override
  Future<void> deleteHearing(String hearingId) async {
    final matter = _matterOfHearing(hearingId);
    _replace<CaseHearing>(hearings, (h) => h.id == hearingId, (_) => null);
    _refreshNext(matter);
    _record('deleteHearing', hearingId);
  }

  @override
  Future<String> addNote(
    String matterId,
    String body, {
    required bool private,
  }) async {
    final id = _id('n');
    (notes[matterId] ??= []).insert(
      0,
      CaseNote(
        id: id,
        body: body.trim(),
        authorId: me,
        authorName: _name(me),
        visibility: private ? 'private' : 'team',
        createdAt: now,
      ),
    );
    _record('addNote', {
      'matterId': matterId,
      'body': body,
      'private': private,
    });
    return id;
  }

  @override
  Future<void> editNote(
    String noteId,
    String body, {
    required bool private,
  }) async {
    _replace<CaseNote>(
      notes,
      (n) => n.id == noteId,
      (n) => CaseNote(
        id: n.id,
        body: body.trim(),
        authorId: n.authorId,
        authorName: n.authorName,
        visibility: private ? 'private' : 'team',
        createdAt: n.createdAt,
      ),
    );
    _record('editNote', {'id': noteId, 'body': body, 'private': private});
  }

  @override
  Future<void> deleteNote(String noteId) async {
    _replace<CaseNote>(notes, (n) => n.id == noteId, (_) => null);
    _record('deleteNote', noteId);
  }

  @override
  Future<String> addTask({
    required String title,
    String? matterId,
    DateTime? dueAt,
    String? assigneeId,
  }) async {
    final id = _id('t');
    (tasks[matterId ?? ''] ??= []).add(
      CaseTask(
        id: id,
        title: title.trim(),
        dueAt: dueAt,
        assigneeId: assigneeId,
        assigneeName: _name(assigneeId),
      ),
    );
    _record('addTask', {
      'title': title,
      'matterId': matterId,
      'dueAt': dueAt,
      'assigneeId': assigneeId,
    });
    return id;
  }

  @override
  Future<void> editTask(
    String taskId, {
    required String title,
    DateTime? dueAt,
    String? assigneeId,
  }) async {
    _replace<CaseTask>(
      tasks,
      (t) => t.id == taskId,
      (t) => CaseTask(
        id: t.id,
        title: title.trim(),
        dueAt: dueAt,
        assigneeId: assigneeId,
        assigneeName: _name(assigneeId),
        status: t.status,
      ),
    );
    _record('editTask', {
      'id': taskId,
      'title': title,
      'dueAt': dueAt,
      'assigneeId': assigneeId,
    });
  }

  @override
  Future<void> setTaskDone(String taskId, {required bool done}) async {
    _replace<CaseTask>(
      tasks,
      (t) => t.id == taskId,
      (t) => CaseTask(
        id: t.id,
        title: t.title,
        dueAt: t.dueAt,
        assigneeId: t.assigneeId,
        assigneeName: t.assigneeName,
        status: done ? 'done' : 'open',
      ),
    );
    _record('setTaskDone', {'id': taskId, 'done': done});
  }

  @override
  Future<void> deleteTask(String taskId) async {
    _replace<CaseTask>(tasks, (t) => t.id == taskId, (_) => null);
    _record('deleteTask', taskId);
  }

  @override
  Future<String> addDeadline(
    String matterId, {
    required String kind,
    required DateTime dueDate,
  }) async {
    final id = _id('d');
    (deadlines[matterId] ??= []).add(
      CaseDeadline(id: id, kind: kind, dueDate: _day(dueDate)),
    );
    _record('addDeadline', {
      'matterId': matterId,
      'kind': kind,
      'dueDate': dueDate,
    });
    return id;
  }

  @override
  Future<void> setDeadlineDone(String deadlineId, {required bool done}) async {
    _replace<CaseDeadline>(
      deadlines,
      (d) => d.id == deadlineId,
      (d) => CaseDeadline(
        id: d.id,
        kind: d.kind,
        dueDate: d.dueDate,
        status: done ? 'done' : 'active',
      ),
    );
    _record('setDeadlineDone', {'id': deadlineId, 'done': done});
  }

  @override
  Future<void> deleteDeadline(String deadlineId) async {
    _replace<CaseDeadline>(deadlines, (d) => d.id == deadlineId, (_) => null);
    _record('deleteDeadline', deadlineId);
  }

  @override
  Future<String> createClient({
    required String name,
    String? phone,
    String? language,
  }) async {
    final id = _id('cl');
    clients.add(
      ClientInfo(id: id, name: name.trim(), phone: phone, language: language),
    );
    _record('createClient', {
      'name': name,
      'phone': phone,
      'language': language,
    });
    return id;
  }

  @override
  Future<String> linkClient(String matterId, String clientId) async {
    final id = _id('mc');
    final client = clients.firstWhere((c) => c.id == clientId);
    (links[matterId] ??= []).add((linkId: id, client: client));
    updateCase(
      matterId,
      (c) => c.copyWith(
        clients: [...c.clients, (id: client.id, name: client.name)],
      ),
    );
    _record('linkClient', {'matterId': matterId, 'clientId': clientId});
    return id;
  }

  @override
  Future<void> unlinkClient(String linkId) async {
    for (final MapEntry(key: matterId, value: list) in links.entries) {
      final link = list.where((l) => l.linkId == linkId).firstOrNull;
      if (link == null) continue;
      list.remove(link);
      updateCase(
        matterId,
        (c) => c.copyWith(
          clients: [
            for (final x in c.clients)
              if (x.id != link.client.id) x,
          ],
        ),
      );
    }
    _record('unlinkClient', linkId);
  }

  @override
  Future<void> markOrderRead(String orderId) async {
    _replace<CaseOrder>(
      orders,
      (o) => o.id == orderId,
      (o) => CaseOrder(
        id: o.id,
        date: o.date,
        title: o.title,
        documentId: o.documentId,
        hasCourtCopy: o.hasCourtCopy,
        read: true,
        createdAt: o.createdAt,
      ),
    );
    _record('markOrderRead', orderId);
  }
}
