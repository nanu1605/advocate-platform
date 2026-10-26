import 'dart:async';

import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/features/onboarding/onboarding_layout.dart';
import 'package:advocate_app/ui/fields.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// /onboarding/join, and the deep link /join/:code which prefills [code] (spec §4.1 step 5, §9.2): "Ask your
/// advocate to invite you" + the join code. Joining skips steps 6–8: the router moves on to notifications. An
/// invite link opened after onboarding confirms the join and goes to Today.
class JoinScreen extends ConsumerStatefulWidget {
  const JoinScreen({this.code, this.junior = false, super.key});

  final String? code;

  /// Chose "Junior advocate": may "Use on my own" instead (a clerk may not).
  final bool junior;

  @override
  ConsumerState<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends ConsumerState<JoinScreen> {
  late final _code = TextEditingController(text: widget.code?.toUpperCase());
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    if (_busy) return;
    final l = context.l10n;
    final code = _code.text.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();
    if (code.isEmpty) return _fail(l.onboardingJoinCodeEmpty);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      ({String orgId, String role})? joined;
      try {
        joined = await ref.read(apiClientProvider).acceptInvite(code);
      } on ApiException catch (e) {
        // Already in the team: carry on.
        if (e.code != 'ALREADY_MEMBER') rethrow;
      }
      // Onboarding: the router moves on to notifications once the membership shows.
      final account = await ref.read(accountProvider.notifier).refresh();
      if (!mounted || ref.read(settingsProvider).onboardingDone != true) return;
      // Already set up: the router has nowhere new to send this, so say what happened and go on.
      final org = account?.memberships
          .where((m) => m.orgId == joined?.orgId)
          .firstOrNull;
      showSnack(
        ScaffoldMessenger.of(context),
        org == null
            ? l.errorAlreadyMember
            : org.orgId == account?.org?.orgId
            ? l.onboardingJoinDone(org.orgName)
            // ponytail: the app works in the first team only; switching teams comes with multi-org.
            : l.onboardingJoinDoneLater(org.orgName),
      );
      context.go('/today');
    } on ApiException catch (e) {
      if (mounted) _fail(errorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _fail(String message) {
    setState(() => _error = message);
    announce(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    // The deep link may be the first screen after sign-in, with nothing to go back to.
    final canPop = context.canPop();
    return OnboardingLayout(
      title: l.joinTitle,
      subtitle: l.onboardingJoinSubtitle,
      showBack: canPop,
      primary: BusyButton(
        label: l.onboardingJoinSubmit,
        busy: _busy,
        onPressed: _join,
      ),
      secondary: widget.junior
          ? TextButton(
              onPressed: () => unawaited(context.push('/onboarding/details')),
              child: Text(l.onboardingJoinOnMyOwn),
            )
          : canPop
          ? null
          : TextButton(
              onPressed: () => context.go('/onboarding/role'),
              child: Text(l.onboardingJoinOtherRole),
            ),
      children: [
        AppTextField(
          controller: _code,
          label: l.onboardingJoinCode,
          hint: l.onboardingJoinCodeHint,
          error: _error,
          autofocus: widget.code == null,
          textInputAction: TextInputAction.done,
          inputFormatters: [_upperCase],
          onSubmitted: (_) => _join(),
        ),
      ],
    );
  }
}

final _upperCase = TextInputFormatter.withFunction(
  (_, v) => v.copyWith(text: v.text.toUpperCase()),
);
