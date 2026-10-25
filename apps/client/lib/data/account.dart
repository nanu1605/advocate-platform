import 'dart:convert';

import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/auth.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' hide SyncStatus;

@immutable
class Membership {
  const Membership({
    required this.orgId,
    required this.orgName,
    required this.orgKind,
    required this.role,
  });

  factory Membership.fromJson(Map<String, dynamic> j) => Membership(
    orgId: j['org_id'] as String,
    orgName: j['org_name'] as String,
    orgKind: j['org_kind'] as String,
    role: j['role'] as String,
  );

  final String orgId;
  final String orgName;

  /// `solo` or `chamber`.
  final String orgKind;

  /// `owner`, `advocate`, `junior` or `clerk` (spec §15.3).
  final String role;

  /// Assign to and Mark proxy arranged on the board (RLS `board_entries_update`); others see it read-only.
  bool get managesBoard => role == 'owner' || role == 'advocate';

  /// Invite, change roles and remove members (spec §15.3); others see the team read-only.
  bool get managesTeam => role == 'owner';
}

/// Where the signed-in account stands in onboarding steps 5–8 (spec §4.1, §9.2).
enum AccountStage {
  /// No organisation yet: choose a role or join a team (step 5).
  noOrg,

  /// Owns an organisation but the Bar Council details are incomplete (step 6).
  needsDetails,

  /// Owner with complete details: find and add cases (steps 7–8).
  owner,

  /// Joined someone's team: skips steps 6–8.
  member;

  /// Set up enough to use the app. On a new device such an account skips onboarding (no second paid search).
  bool get setUp => this == owner || this == member;
}

/// The signed-in user from GET /v1/me.
@immutable
class Account {
  const Account({
    required this.id,
    this.fullName,
    this.enrolmentNo,
    this.barCouncilState,
    this.practiceCourtIds = const [],
    this.memberships = const [],
  });

  factory Account.fromJson(Map<String, dynamic> j) => Account(
    id: j['id'] as String,
    fullName: j['full_name'] as String?,
    enrolmentNo: j['enrolment_no'] as String?,
    barCouncilState: j['bar_council_state'] as String?,
    practiceCourtIds: (j['practice_court_ids'] as List? ?? const [])
        .cast<String>(),
    memberships: [
      for (final m in j['memberships'] as List? ?? const [])
        Membership.fromJson((m as Map).cast()),
    ],
  );

  final String id;
  final String? fullName;
  final String? enrolmentNo;

  /// The courts table's state code, e.g. `MP`.
  final String? barCouncilState;

  /// Empty means every court in the state (spec §4.1 step 6).
  final List<String> practiceCourtIds;

  /// Active memberships, oldest first.
  final List<Membership> memberships;

  /// The organisation the app works in: the first active membership (switching orgs comes later).
  Membership? get org => memberships.firstOrNull;

  /// The same fields POST /v1/onboarding/find-cases requires (else PROFILE_INCOMPLETE).
  bool get profileComplete => [
    fullName,
    enrolmentNo,
    barCouncilState,
  ].every((v) => (v ?? '').trim().isNotEmpty);

  AccountStage get stage => switch (org?.role) {
    null => AccountStage.noOrg,
    'owner' => profileComplete ? AccountStage.owner : AccountStage.needsDetails,
    _ => AccountStage.member,
  };
}

/// GET /v1/me for the signed-in user; null when signed out. When the API can't be reached (offline, or a
/// retryable server error) it falls back to the user's synced profile and memberships; with neither it is an
/// error (the router shows the offline state), retried when the device comes back online, wherever the user is.
/// Onboarding screens call [AccountController.refresh] after each step that changes the account.
class AccountController extends AsyncNotifier<Account?> {
  @override
  Future<Account?> build() async {
    final auth = ref.watch(authRepositoryProvider);
    final signedIn = ref.watch(
      signedInProvider.select((s) => s.value ?? auth.isSignedIn),
    );
    if (!signedIn) return null;
    ref
      ..listen(syncViewProvider.select((s) => s.value?.offline), (was, now) {
        final backOnline = (was ?? false) && now == false;
        if (backOnline && state.hasError) ref.invalidateSelf();
      })
      // Sync took a membership away (removed from a team, maybe the current one or the last): reload, so the
      // account moves to a team the user is still in, or the router sends them to join one.
      ..listen(_syncedMembershipsProvider, (was, now) {
        if (now.value case final n? when n < (was?.value ?? 0)) {
          ref.invalidateSelf();
        }
      });
    try {
      return await ref.read(apiClientProvider).me();
    } on ApiException catch (e) {
      if (!e.retryable) rethrow;
      final db = ref.read(syncDatabaseProvider);
      final userId = auth.userId;
      final cached = db == null || userId == null
          ? null
          : await _fromSync(db, userId);
      if (cached == null) rethrow;
      return cached;
    }
  }

  /// Reloads /me; the previous value stays visible meanwhile.
  Future<Account?> refresh() {
    ref.invalidateSelf();
    return future;
  }
}

/// The signed-in user's synced profile, never another account's rows still on the device.
Future<Account?> _fromSync(PowerSyncDatabase db, String userId) async {
  final profile = await db.getOptional(
    'select id, full_name, enrolment_no, bar_council_state, practice_court_ids from profiles where id = ?',
    [userId],
  );
  if (profile == null) return null;
  final memberships = await db.getAll(
    'select m.org_id, o.name as org_name, o.kind as org_kind, m.role from memberships m '
    "join organizations o on o.id = m.org_id where m.user_id = ? and m.status = 'active' "
    'order by m.created_at',
    [profile['id']],
  );
  final courts = profile['practice_court_ids'] as String?;
  return Account.fromJson({
    ...profile,
    'practice_court_ids': courts == null ? null : jsonDecode(courts),
    'memberships': memberships,
  });
}

/// How many active memberships the signed-in user's synced rows hold; nothing without sync.
final _syncedMembershipsProvider = StreamProvider<int>((ref) {
  final db = ref.watch(syncDatabaseProvider);
  final auth = ref.watch(authRepositoryProvider);
  ref.watch(signedInProvider);
  final userId = auth.userId;
  if (db == null || userId == null) return const Stream.empty();
  return db
      .watch(
        "select count(*) as n from memberships where user_id = ? and status = 'active'",
        parameters: [userId],
      )
      .map((rows) => rows.first['n'] as int);
});

// No automatic retry: /loading shows the offline state at once, with Retry; the controller retries on reconnect.
final accountProvider = AsyncNotifierProvider<AccountController, Account?>(
  AccountController.new,
  retry: (_, _) => null,
);

/// The organisation org-scoped calls and synced reads use; null until the account has one.
final currentOrgProvider = Provider<Membership?>(
  (ref) => ref.watch(accountProvider).value?.org,
);

/// [currentOrgProvider]'s id, for providers that only depend on which org it is.
final currentOrgIdProvider = Provider<String?>(
  (ref) => ref.watch(currentOrgProvider.select((m) => m?.orgId)),
);

/// The signed-in user's id; null until the account loads.
final currentUserIdProvider = Provider<String?>(
  (ref) => ref.watch(accountProvider.select((a) => a.value?.id)),
);
