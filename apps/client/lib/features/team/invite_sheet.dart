import 'dart:async';

import 'package:advocate_app/core/brand/brand.g.dart';
import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/team.dart';
import 'package:advocate_app/features/board/board_share.dart';
import 'package:advocate_app/features/clients/client_profile.dart';
import 'package:advocate_app/features/onboarding/onboarding_layout.dart';
import 'package:advocate_app/ui/fields.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

/// The invite as a message for WhatsApp or SMS, in the app's language: the code, the link once there is one
/// (Track B) and how long it works. Never the phone number.
String inviteShareText(AppLocalizations l, Invite i) => switch (i.link) {
  final link? => l.teamShareTextLink(Brand.appName, i.code, link),
  null => l.teamShareText(Brand.appName, i.code),
};

/// [errorText] for the owner inviting: TEAM_LIMIT says how to make room (open invites hold places too) instead of
/// the invitee's wording.
String inviteErrorText(AppLocalizations l, Object? e) =>
    e is ApiException && e.code == 'TEAM_LIMIT'
    ? l.teamLimit(e.details['limit'] as int? ?? 10)
    : errorText(l, e);

/// The owner's invite flow (spec §4.4 F16, §10.2 Team): the role and, optionally, the one mobile number that may use
/// it; then the 8-character code to copy or share through the OS share sheet. Nothing is sent for the owner (SMS and
/// WhatsApp are Track B), and it says so. Creating needs a connection: offline, or on any error, the sheet says why
/// and keeps what was entered.
Future<void> showInviteSheet(BuildContext context) =>
    showAppBottomSheet<void>(context, builder: (_) => const _InviteSheet());

class _InviteSheet extends ConsumerStatefulWidget {
  const _InviteSheet();

  @override
  ConsumerState<_InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends ConsumerState<_InviteSheet> {
  final _phone = TextEditingController();
  String _role = 'junior';
  String? _phoneError;
  String? _error;
  bool _busy = false;
  bool _copied = false;
  Invite? _invite;

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  /// One invite per tap: the API makes a new one on each call (no idempotency key), so taps while busy are ignored.
  Future<void> _create() async {
    if (_busy) return;
    final l = context.l10n;
    final phone = _phone.text.trim();
    if (phone.isNotEmpty && !isValidIndianMobile(phone)) {
      setState(() => _phoneError = l.phoneInvalid);
      announce(context, l.phoneInvalid);
      return;
    }
    final org = ref.read(currentOrgIdProvider);
    if (org == null) return;
    setState(() {
      _busy = true;
      _phoneError = null;
      _error = null;
    });
    try {
      final invite = await ref
          .read(apiClientProvider)
          .createInvite(
            orgId: org,
            role: _role,
            phone: phone.isEmpty ? null : phone,
          );
      if (!mounted) return;
      setState(() => _invite = invite);
      announce(context, l.teamInviteReady);
    } on Object catch (e) {
      if (!mounted) return;
      final message = inviteErrorText(l, e);
      setState(() => _error = message);
      announce(context, message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy(Invite i) async {
    final l = context.l10n;
    await Clipboard.setData(ClipboardData(text: i.code));
    if (!mounted) return;
    setState(() => _copied = true);
    announce(context, l.teamCodeCopied);
  }

  Future<void> _share(Invite i) async {
    final l = context.l10n;
    final box = context.findRenderObject() as RenderBox?;
    setState(() => _error = null);
    try {
      await ref.read(shareProvider)(
        ShareParams(
          text: inviteShareText(l, i),
          // Windows needs a title for its share UI.
          title: l.teamShareInvite,
          // iPad anchors the share popover here.
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } on Object catch (e) {
      if (mounted) setState(() => _error = errorText(l, e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final invite = _invite;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: invite == null ? _form(context) : _ready(context, invite),
      ),
    );
  }

  List<Widget> _form(BuildContext context) {
    final l = context.l10n;
    return [
      Semantics(
        header: true,
        child: Text(l.teamInviteTitle, style: context.text.titleLarge),
      ),
      const SizedBox(height: 16),
      Text(l.teamInviteRole, style: context.text.labelLarge),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final r in memberRoles)
            ChoiceChip(
              label: Text(roleLabel(l, r)),
              selected: _role == r,
              onSelected: (_) => setState(() => _role = r),
            ),
        ],
      ),
      const SizedBox(height: 16),
      AppTextField(
        controller: _phone,
        label: l.teamInvitePhone,
        hint: l.phoneHint,
        error: _phoneError,
        prefixText: '+91 ',
        keyboardType: TextInputType.phone,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(10),
        ],
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => unawaited(_create()),
      ),
      const SizedBox(height: 8),
      Text(l.teamInvitePhoneHint, style: context.text.bodySmall),
      if (_error case final e?) StepNotice(e),
      const SizedBox(height: 16),
      BusyButton(
        label: l.teamInviteCreate,
        busy: _busy,
        onPressed: () => unawaited(_create()),
      ),
    ];
  }

  List<Widget> _ready(BuildContext context, Invite i) {
    final l = context.l10n;
    final c = context.colors;
    final until = Formats(Localizations.localeOf(context))
        .shortDate(istOf(i.expiresAt));
    return [
      Semantics(
        header: true,
        child: Text(l.teamInviteReady, style: context.text.titleLarge),
      ),
      const SizedBox(height: 8),
      Text(
        l.teamInviteReadyBody(roleLabel(l, i.role), until),
        style: context.text.bodyLarge,
      ),
      const SizedBox(height: 16),
      Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          child: Column(
            children: [
              Text(l.teamInviteCodeLabel, style: context.text.labelLarge),
              const SizedBox(height: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  i.code,
                  // Read out letter by letter, so the code is never heard as a word.
                  semanticsLabel: i.code.split('').join(' '),
                  style: context.text.displaySmall?.copyWith(
                    letterSpacing: 4,
                    color: c.ink,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: () => unawaited(_share(i)),
        icon: const Icon(AppIcons.shareNetwork),
        label: Text(l.teamShareInvite),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: () => unawaited(_copy(i)),
        icon: Icon(_copied ? AppIcons.checkCircleFill : AppIcons.copy),
        label: Text(_copied ? l.teamCopied : l.teamCopyCode),
      ),
      if (_error case final e?) StepNotice(e),
      if (i.phone case final p?) ...[
        const SizedBox(height: 8),
        Text(
          l.teamInviteOnly(phoneText('+$p')),
          style: context.text.bodyMedium,
        ),
      ],
      StepNotice(l.teamInviteNotSent, kind: StatusKind.listed),
      const SizedBox(height: 8),
      TextButton(onPressed: () => Navigator.pop(context), child: Text(l.close)),
    ];
  }
}
