import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/diary.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The roles an owner invites or switches a member to (spec §15.3); the owner's own role never changes.
const memberRoles = ['advocate', 'junior', 'clerk'];

/// [role]'s name: Owner, Advocate, Junior advocate, Clerk (Appendix C: मालिक, अधिवक्ता, जूनियर अधिवक्ता, मुंशी).
String roleLabel(AppLocalizations l, String role) => switch (role) {
  'owner' => l.teamDataRoleOwner,
  'advocate' => l.teamDataRoleAdvocate,
  'junior' => l.teamDataRoleJunior,
  _ => l.teamDataRoleClerk,
};

/// A member of the current org on the Team screen (spec §4.4 F16).
@immutable
class TeamMember {
  const TeamMember({
    required this.userId,
    required this.role,
    this.name,
    this.assignedCases = 0,
    this.me = false,
  });

  final String userId;

  /// `owner`, `advocate`, `junior` or `clerk`.
  final String role;

  /// The display name; null when they haven't set one (show [roleLabel]).
  final String? name;

  /// Live, unarchived cases assigned to them: what the Cases list's assignee filter shows.
  final int assignedCases;

  /// The signed-in user.
  final bool me;

  bool get owner => role == 'owner';
}

/// The current org's active members (task 8's [orgMembersProvider]; removed members are left out) with their
/// assigned cases (task 9's [casesProvider]): the owner first, then by name.
final teamProvider = Provider<AsyncValue<List<TeamMember>>>((ref) {
  final members = ref.watch(orgMembersProvider);
  final cases = ref.watch(casesProvider);
  final me = ref.watch(currentUserIdProvider);
  if ((members.value, cases.value) case (final ms?, final cs?)) {
    final assigned = <String, int>{};
    for (final c in cs) {
      if (c.assigneeId case final id? when !c.archived) {
        assigned[id] = (assigned[id] ?? 0) + 1;
      }
    }
    return AsyncData([
      for (final m in [
        ...ms.where((m) => m.role == 'owner'),
        ...ms.where((m) => m.role != 'owner'),
      ])
        TeamMember(
          userId: m.userId,
          role: m.role,
          name: m.name,
          assignedCases: assigned[m.userId] ?? 0,
          me: m.userId == me,
        ),
    ]);
  }
  final failed = members.hasError ? members : cases;
  return failed.hasError
      ? AsyncError(failed.error!, failed.stackTrace ?? StackTrace.current)
      : const AsyncLoading();
});

/// Whether the signed-in user may invite and manage members (spec §15.3: the owner only).
final managesTeamProvider = Provider<bool>(
  (ref) => ref.watch(currentOrgProvider)?.managesTeam ?? false,
);

/// Set when the account loaded in no team although this device had finished onboarding: the user was removed
/// from their only team. Holds that team's name, or '' when it isn't known here; null otherwise. The role screen
/// explains it; cleared once the account is in a team again, and on sign-out.
class RemovedFromTeam extends Notifier<String?> {
  @override
  String? build() => null;

  String? get team => state;
  set team(String? name) => state = name;
}

final removedFromTeamProvider = NotifierProvider<RemovedFromTeam, String?>(
  RemovedFromTeam.new,
);
