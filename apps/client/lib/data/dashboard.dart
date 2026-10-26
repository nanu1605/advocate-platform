import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/calendar.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/diary.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The practice dashboard's numbers (spec §4.4 F18 P1).
@immutable
class DashboardCounts {
  const DashboardCounts({
    required this.activeCases,
    required this.hearingsThisWeek,
    required this.overdueTasks,
    required this.newOrders,
    this.hasCases = true,
    this.team = const [],
  });

  /// Live cases, not archived and not disposed or transferred.
  final int activeCases;

  /// Hearings this week (IST, Monday to Sunday), one per case per day, from the calendar's rule.
  final int hearingsThisWeek;

  /// Open tasks due before now, assigned to the user or to no one (Today's "Tasks due" rule).
  final int overdueTasks;

  /// Unread `new_order` notifications (Today's "New orders").
  final int newOrders;

  /// The org has cases, closed ones included.
  final bool hasCases;

  /// For a chamber's owner: each member but clerks with how many of their assigned cases have a hearing this
  /// week, in the member list's order; empty for anyone else.
  final List<({OrgMember member, int cases})> team;

  /// Nothing to count yet (no cases, nothing due or ordered): the dashboard's empty state, which offers to add a
  /// case. An org whose cases are all disposed or archived sees the tiles at zero instead.
  bool get empty => !hasCases && overdueTasks == 0 && newOrders == 0;
}

/// [DashboardCounts] from the queries Today, Cases and the Calendar already run (tasks 8–10): the cases list, this
/// week's calendar hearings, tasks due and new orders, and the members. Re-counted each minute (overdue moves with
/// the clock).
final Provider<AsyncValue<DashboardCounts>> dashboardProvider =
    Provider.autoDispose<AsyncValue<DashboardCounts>>((ref) {
      final nowIst = ref.watch(istNowProvider);
      final week = weekRange(istDay(nowIst));
      final cases = ref.watch(casesProvider);
      final hearings = ref.watch(calendarHearingsProvider(week));
      final tasks = ref.watch(tasksDueProvider);
      final orders = ref.watch(newOrdersProvider);
      final members = ref.watch(orgMembersProvider);
      final org = ref.watch(currentOrgProvider);
      final all = [cases, hearings, tasks, orders, members];
      if ((
            cases.value,
            hearings.value,
            tasks.value,
            orders.value,
            members.value,
          )
          case (final cs?, final hs?, final ts?, final os?, final ms?)) {
        final now = istInstant(nowIst);
        final heard = {for (final h in hs) (h.matterId, h.day)};
        final assignee = {for (final c in cs) c.id: c.assigneeId};
        final heardCases = {for (final (matter, _) in heard) matter};
        final chamberOwner =
            (org?.managesTeam ?? false) &&
            (org?.orgKind == 'chamber' || ms.length > 1);
        return AsyncData(
          DashboardCounts(
            activeCases: cs.where((c) => !c.archived && !c.disposed).length,
            hearingsThisWeek: heard.length,
            overdueTasks: ts.where((t) => t.dueAt.isBefore(now)).length,
            newOrders: os.length,
            hasCases: cs.isNotEmpty,
            team: [
              if (chamberOwner)
                for (final m in ms)
                  if (m.role != 'clerk')
                    (
                      member: m,
                      cases: heardCases
                          .where((id) => assignee[id] == m.userId)
                          .length,
                    ),
            ],
          ),
        );
      }
      final failed = all.where((p) => p.hasError).firstOrNull;
      return failed == null
          ? const AsyncLoading()
          : AsyncError(failed.error!, failed.stackTrace ?? StackTrace.current);
    });
