import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/diary.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A member's display name, else their role.
String memberName(AppLocalizations l, OrgMember m) =>
    m.name ??
    (m.role == 'junior' ? l.onboardingRoleJunior : l.onboardingRoleAdvocate);

/// Assign to (spec §4.2 board, §4.3 case page): active members but clerks, "Me" first, the current one
/// ([currentId]) ticked; [allowNone] adds "No one". Returns the pick (`member` null for "No one"), or null when
/// dismissed.
Future<({OrgMember? member})?> showAssignSheet(
  BuildContext context, {
  required String caseLabel,
  String? currentId,
  bool allowNone = false,
}) => showAppBottomSheet<({OrgMember? member})>(
  context,
  builder: (_) => _AssignSheet(
    caseLabel: caseLabel,
    currentId: currentId,
    allowNone: allowNone,
  ),
);

class _AssignSheet extends ConsumerWidget {
  const _AssignSheet({
    required this.caseLabel,
    required this.currentId,
    required this.allowNone,
  });

  final String caseLabel;
  final String? currentId;
  final bool allowNone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final me = ref.watch(currentUserIdProvider);
    final members = ref.watch(orgMembersProvider).value ?? const [];
    final people = [
      ...members.where((m) => m.userId == me),
      ...members.where((m) => m.userId != me && m.role != 'clerk'),
    ];
    Widget option(String title, OrgMember? m) {
      final current = m?.userId == currentId;
      return ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title),
        selected: current,
        trailing: current ? const Icon(AppIcons.checkCircleFill) : null,
        onTap: () => Navigator.pop(context, (member: m)),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            l.boardAssignTitle(caseLabel),
            style: context.text.titleLarge,
          ),
        ),
        const SizedBox(height: 8),
        for (final m in people)
          option(m.userId == me ? l.boardMe : memberName(l, m), m),
        if (allowNone) option(l.casePageAssignNone, null),
      ],
    );
  }
}
