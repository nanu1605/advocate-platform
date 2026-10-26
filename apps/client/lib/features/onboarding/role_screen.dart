import 'dart:async';

import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/team.dart';
import 'package:advocate_app/features/onboarding/onboarding_layout.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// /onboarding/role (spec §4.1 step 5, §9.2). Only navigates: the organisation is created when the details are
/// submitted (Advocate → solo, Chamber owner → chamber) or a team is joined (Junior, Clerk). Someone removed from
/// their only team lands here too ([removedFromTeamProvider]): one line says why, and joining another team by code
/// comes first.
class RoleScreen extends ConsumerWidget {
  const RoleScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final removedFrom = ref.watch(removedFromTeamProvider);
    Widget role(IconData icon, String title, String hint, String to) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 8,
          ),
          leading: Icon(icon, color: context.colors.primary),
          title: Text(title, style: context.text.titleMedium),
          subtitle: Text(hint, style: context.text.bodyMedium),
          trailing: const Icon(AppIcons.caretRight),
          onTap: () => unawaited(context.push(to)),
        ),
      ),
    );
    return OnboardingLayout(
      title: l.roleTitle,
      subtitle: l.onboardingRoleSubtitle,
      children: [
        if (removedFrom != null) ...[
          StepNotice(
            removedFrom.isEmpty
                ? l.teamDataRemovedUnknown
                : l.teamDataRemoved(removedFrom),
            kind: StatusKind.adjourned,
          ),
          role(
            AppIcons.usersThree,
            l.teamDataJoinAnother,
            l.onboardingJoinSubtitle,
            '/onboarding/join',
          ),
        ],
        role(
          AppIcons.gavel,
          l.onboardingRoleAdvocate,
          l.onboardingRoleAdvocateHint,
          '/onboarding/details',
        ),
        role(
          AppIcons.briefcase,
          l.onboardingRoleJunior,
          l.onboardingRoleJuniorHint,
          '/onboarding/join?role=junior',
        ),
        role(
          AppIcons.folderSimple,
          l.onboardingRoleClerk,
          l.onboardingRoleClerkHint,
          '/onboarding/join',
        ),
        role(
          AppIcons.users,
          l.onboardingRoleChamber,
          l.onboardingRoleChamberHint,
          '/onboarding/details?kind=chamber',
        ),
      ],
    );
  }
}
