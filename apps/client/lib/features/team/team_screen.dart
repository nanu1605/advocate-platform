import 'dart:async';
import 'dart:math' as math;

import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/diary.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:advocate_app/data/team.dart';
import 'package:advocate_app/features/clients/client_profile.dart';
import 'package:advocate_app/features/onboarding/onboarding_layout.dart';
import 'package:advocate_app/features/team/invite_sheet.dart';
import 'package:advocate_app/ui/fields.dart';
import 'package:advocate_app/ui/focus_ring.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/section_header.dart';
import 'package:advocate_app/ui/sheets.dart';
import 'package:advocate_app/ui/skeleton.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:advocate_app/ui/tiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// The owner's open invites (ADR 0017: `GET /v1/orgs/{id}/invites`; invites never sync, §9.4), fetched again when
/// the device comes back online and when the synced team changes size (someone joined with a code: their invite is
/// used). No automatic retry: the section says what went wrong, with Retry.
final FutureProvider<List<Invite>> _invitesProvider =
    FutureProvider.autoDispose<List<Invite>>((ref) {
      ref
        ..watch(syncViewProvider.select((s) => s.value?.offline ?? false))
        ..watch(orgMembersProvider.select((m) => m.value?.length));
      final org = ref.watch(currentOrgIdProvider);
      if (org == null) return Future.value(const []);
      return ref.watch(apiClientProvider).listInvites(org);
    }, retry: (_, _) => null);

/// /team (spec §4.4 F16, §15.3): the current org's active members (synced, so it works offline) with their role and
/// how many cases are assigned to them (tap: the Cases list filtered to them). The owner invites, changes roles and
/// names, removes members, and sees and revokes open invites; those go through the API, so offline they say they
/// need a connection. Everyone else sees the list only.
class TeamScreen extends ConsumerStatefulWidget {
  const TeamScreen({super.key});

  @override
  ConsumerState<TeamScreen> createState() => _TeamScreenState();
}

class _TeamScreenState extends ConsumerState<TeamScreen> {
  /// Members removed here: gone at once, before sync takes their membership off the device.
  final _gone = <String>{};

  /// Members and invites a change is being sent for: their row shows progress instead of its actions, so a double
  /// tap never sends twice.
  final _busy = <String>{};

  Future<void> _invite() async {
    await showInviteSheet(context);
    if (mounted) ref.invalidate(_invitesProvider);
  }

  void _say(String message) =>
      showSnack(ScaffoldMessenger.of(context), message);

  /// One owner change to [m] (`PATCH /v1/orgs/{id}/members/{user}`); sync brings the result to every device. Null
  /// when it went through, else why not.
  Future<String?> _update(
    TeamMember m, {
    String? role,
    String? status,
    String? displayName,
  }) async {
    final l = context.l10n;
    final org = ref.read(currentOrgIdProvider);
    if (org == null) return errorText(l, null);
    setState(() => _busy.add(m.userId));
    try {
      await ref
          .read(apiClientProvider)
          .updateMember(
            orgId: org,
            userId: m.userId,
            role: role,
            status: status,
            displayName: displayName,
          );
      return null;
    } on Object catch (e) {
      return errorText(l, e);
    } finally {
      if (mounted) setState(() => _busy.remove(m.userId));
    }
  }

  Future<void> _changeRole(TeamMember m, String name) async {
    final l = context.l10n;
    final role = await showAppBottomSheet<String>(
      context,
      builder: (sheet) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(l.teamRoleTitle(name), style: sheet.text.titleLarge),
          ),
          const SizedBox(height: 8),
          for (final r in memberRoles)
            FocusRing(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(roleLabel(l, r)),
                selected: r == m.role,
                trailing: r == m.role
                    ? const Icon(AppIcons.checkCircleFill)
                    : null,
                onTap: () => Navigator.pop(sheet, r),
              ),
            ),
        ],
      ),
    );
    if (role == null || role == m.role || !mounted) return;
    final failed = await _update(m, role: role);
    if (mounted) _say(failed ?? l.teamRoleChanged(name, roleLabel(l, role)));
  }

  Future<void> _editName(TeamMember m) async {
    final l = context.l10n;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _NameDialog(
        initial: m.name ?? '',
        save: (name) => _update(m, displayName: name),
      ),
    );
    if ((saved ?? false) && mounted) _say(l.teamNameSaved);
  }

  Future<void> _remove(TeamMember m, String name) async {
    final l = context.l10n;
    final ok = await showConfirmDialog(
      context,
      title: l.teamRemoveTitle(name),
      body: [
        l.teamRemoveBody,
        if (m.assignedCases > 0) l.teamRemoveAssigned(m.assignedCases),
      ].join(' '),
      confirmLabel: l.teamRemoveConfirm,
    );
    if (!ok || !mounted) return;
    final failed = await _update(m, status: 'removed');
    if (!mounted) return;
    if (failed == null) setState(() => _gone.add(m.userId));
    _say(failed ?? l.teamRemoved(name));
  }

  Future<void> _revoke(Invite i) async {
    final l = context.l10n;
    final org = ref.read(currentOrgIdProvider);
    if (org == null || _busy.contains(i.id)) return;
    final ok = await showConfirmDialog(
      context,
      title: l.teamRevokeTitle,
      body: l.teamRevokeBody(i.code),
      confirmLabel: l.teamRevoke,
    );
    if (!ok || !mounted) return;
    setState(() => _busy.add(i.id));
    try {
      await ref
          .read(apiClientProvider)
          .revokeInvite(orgId: org, inviteId: i.id);
      // Left the screen meanwhile: the list goes with it.
      if (!mounted) return;
      _say(l.teamRevoked);
      ref.invalidate(_invitesProvider);
    } on ApiException catch (e) {
      if (!mounted) return;
      // Accepted, run out or revoked elsewhere: the list was out of date.
      if (e.code == 'NOT_FOUND') ref.invalidate(_invitesProvider);
      _say(e.code == 'NOT_FOUND' ? l.teamInviteGone : errorText(l, e));
    } finally {
      if (mounted) setState(() => _busy.remove(i.id));
    }
  }

  /// The Cases list showing only [m]'s cases: other filters and the search are cleared so it matches the count.
  void _openCases(TeamMember m) {
    ref
        .read(caseFilterProvider.notifier)
        .change((f) => CaseFilter(sort: f.sort, assigneeId: m.userId));
    context.go('/cases');
  }

  /// The owner's open invites, newest first: code, role, the one number that may use it, until when; Revoke.
  /// Nothing while loading and when there are none; offline it says it needs a connection, with Retry. Rows, not one
  /// widget, so each is its own item for screen readers.
  List<Widget> _invites(BuildContext context) {
    final l = context.l10n;
    final f = Formats(Localizations.localeOf(context));
    final invites = ref.watch(_invitesProvider);
    if (invites.hasError) {
      return [
        SectionHeader(l.teamInvitesTitle),
        StepNotice(errorText(l, invites.error), kind: StatusKind.adjourned),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            onPressed: () => ref.invalidate(_invitesProvider),
            icon: const Icon(AppIcons.arrowClockwise),
            label: Text(l.retry),
          ),
        ),
      ];
    }
    final list = invites.value ?? const <Invite>[];
    if (list.isEmpty) return const [];
    List<String> details(Invite i) => [
      roleLabel(l, i.role),
      if (i.phone case final p?) l.teamInviteOnlyShort(phoneText('+$p')),
      l.teamInviteUntil(f.shortDate(istOf(i.expiresAt))),
    ];
    return [
      SectionHeader(l.teamInvitesTitle, count: list.length),
      for (final i in list)
        ListTile(
          key: ValueKey(i.id),
          minVerticalPadding: 12,
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: Icon(AppIcons.clock, color: context.colors.ink2),
          title: Text(
            i.code,
            // Read out letter by letter, so a code is never heard as a word.
            semanticsLabel: i.code.split('').join(' '),
            style: context.text.titleSmall?.copyWith(letterSpacing: 2),
          ),
          subtitle: Text(
            details(i).join(' · '),
            semanticsLabel: details(i).join(', '),
            style: context.text.bodySmall,
          ),
          trailing: _busy.contains(i.id)
              ? const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                )
              : IconButton(
                  tooltip: l.teamRevokeTooltip(i.code),
                  icon: const Icon(AppIcons.x),
                  onPressed: () => unawaited(_revoke(i)),
                ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final owner = ref.watch(managesTeamProvider);
    final team = ref.watch(teamProvider);
    final members = [
      for (final m in team.value ?? const <TeamMember>[])
        if (!_gone.contains(m.userId)) m,
    ];

    final List<Widget> children;
    if (team.hasError && !team.hasValue) {
      children = [
        ErrorState(
          message: errorText(l, team.error),
          onRetry: () => ref
            ..invalidate(orgMembersProvider)
            ..invalidate(casesProvider),
        ),
      ];
    } else if (!team.hasValue) {
      children = const [SizedBox(height: 16), SkeletonCaseList(count: 2)];
    } else {
      children = [
        SectionHeader(l.teamMembers, count: members.length),
        for (final m in members)
          _MemberRow(
            key: ValueKey(m.userId),
            member: m,
            busy: _busy.contains(m.userId),
            manage: owner && !m.owner,
            onOpenCases: () => _openCases(m),
            onChangeRole: _changeRole,
            onEditName: _editName,
            onRemove: _remove,
          ),
        if (owner) ...[
          if (members.length <= 1)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Card(
                child: EmptyState(
                  icon: AppIcons.usersThree,
                  message: l.teamAloneHint,
                  actionLabel: l.teamInviteSomeone,
                  onAction: () => unawaited(_invite()),
                ),
              ),
            ),
          ..._invites(context),
        ] else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(l.teamOwnerOnly, style: context.text.bodySmall),
          ),
      ];
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l.navTeam),
        actions: [
          if (owner)
            // A label too long for the bar at 200% text ends in "…" (screen readers hear it all).
            Flexible(
              child: Padding(
                padding: const EdgeInsetsDirectional.only(end: 8),
                child: TextButton.icon(
                  onPressed: () => unawaited(_invite()),
                  icon: const Icon(AppIcons.userPlus),
                  label: Text(
                    l.teamInvite,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
        ],
      ),
      // A readable column on a wide window.
      body: LayoutBuilder(
        builder: (context, box) {
          final side = math.max(16, (box.maxWidth - 720) / 2).toDouble();
          return ListView(
            padding: EdgeInsets.fromLTRB(side, 0, side, 24),
            children: children,
          );
        },
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.member,
    required this.busy,
    required this.manage,
    required this.onOpenCases,
    required this.onChangeRole,
    required this.onEditName,
    required this.onRemove,
    super.key,
  });

  final TeamMember member;
  final bool busy;

  /// The owner's menu: change role, edit name, remove (never on the owner's own row).
  final bool manage;
  final VoidCallback onOpenCases;
  final Future<void> Function(TeamMember, String name) onChangeRole;
  final Future<void> Function(TeamMember) onEditName;
  final Future<void> Function(TeamMember, String name) onRemove;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final m = member;
    final name = m.name ?? roleLabel(l, m.role);
    // Clerks aren't offered in Assign; one still shows cases left from an earlier role.
    final cases = m.role == 'clerk' && m.assignedCases == 0
        ? null
        : l.teamAssignedCases(m.assignedCases);
    // The title is the role when they have no name.
    final details = [if (m.name != null) roleLabel(l, m.role), ?cases];
    final open = m.assignedCases > 0 ? onOpenCases : null;
    final Widget? trailing;
    if (busy) {
      trailing = const SizedBox.square(
        dimension: 24,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      );
    } else if (manage) {
      trailing = PopupMenuButton<int>(
        tooltip: l.boardMoreActions(name),
        icon: const Icon(AppIcons.dotsThreeVertical),
        onSelected: (action) => unawaited(switch (action) {
          0 => onChangeRole(m, name),
          1 => onEditName(m),
          _ => onRemove(m, name),
        }),
        itemBuilder: (_) => [
          PopupMenuItem(value: 0, child: Text(l.teamChangeRole)),
          PopupMenuItem(value: 1, child: Text(l.teamEditName)),
          PopupMenuItem(value: 2, child: Text(l.teamRemove)),
        ],
      );
    } else {
      trailing = open == null ? null : const Icon(AppIcons.caretRight);
    }
    return FocusRing(
      child: ListTile(
        onTap: open,
        minVerticalPadding: 12,
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        // Grows with the text so large initials stay inside the circle (spec §5.9), as on ClientTile.
        leading: Avatar(
          name,
          size: 24 + MediaQuery.textScalerOf(context).scale(16),
        ),
        title: Text(
          m.me ? l.teamMemberMe(name) : name,
          style: context.text.titleSmall,
        ),
        // Screen readers pause between the parts instead of reading the dots.
        subtitle: details.isEmpty
            ? null
            : Text(
                details.join(' · '),
                semanticsLabel: details.join(', '),
                style: context.text.bodySmall,
              ),
        trailing: trailing,
      ),
    );
  }
}

/// Edit a member's name as the team sees it (1–100 characters, the API's limit). It stays open with the text and
/// the reason when saving fails (offline: it needs a connection).
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.initial, required this.save});

  final String initial;

  /// Null when it went through, else why not.
  final Future<String?> Function(String name) save;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _name = TextEditingController(text: widget.initial);
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final l = context.l10n;
    final name = _name.text.trim();
    if (name.isEmpty) return _fail(l.teamNameEmpty);
    setState(() {
      _busy = true;
      _error = null;
    });
    final failed = await widget.save(name);
    if (!mounted) return;
    setState(() => _busy = false);
    if (failed == null) {
      Navigator.pop(context, true);
    } else {
      _fail(failed);
    }
  }

  void _fail(String message) {
    setState(() => _error = message);
    announce(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return AlertDialog(
      // As wide as the phone allows, so the field's label fits at 200% text; no wider than M3's dialogs on a desktop.
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      constraints: const BoxConstraints(minWidth: 280, maxWidth: 560),
      title: Text(l.teamEditName),
      content: SizedBox(
        width: double.maxFinite,
        child: AppTextField(
          controller: _name,
          label: l.teamNameLabel,
          error: _error,
          autofocus: true,
          textInputAction: TextInputAction.done,
          inputFormatters: const [CodePointLimit(100)],
          onSubmitted: (_) => unawaited(_submit()),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l.cancel),
        ),
        BusyButton(
          label: l.casePageSave,
          busy: _busy,
          onPressed: () => unawaited(_submit()),
        ),
      ],
    );
  }
}
