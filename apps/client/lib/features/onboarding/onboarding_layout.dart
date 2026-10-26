import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Shared frame for onboarding steps: heading, body, one primary action pinned at the bottom. The offline
/// banner shows while sync reports the device offline, or when [offline] says so (spec §5.4).
class OnboardingLayout extends StatelessWidget {
  const OnboardingLayout({
    required this.title,
    required this.children,
    this.subtitle,
    this.primary,
    this.secondary,
    this.notice,
    this.showBack = false,
    this.offline = false,
    super.key,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;
  final Widget? primary;
  final Widget? secondary;

  /// The step's error, pinned above [primary] so it is on screen (and in the semantics tree, so read out) even
  /// when 200% text pushes the end of the body out of view (spec §5.9).
  final String? notice;
  final bool showBack;
  final bool offline;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: showBack ? AppBar(shape: const Border()) : null,
    body: SafeArea(
      child: Column(
        children: [
          Consumer(
            builder: (_, ref, _) =>
                offline || (ref.watch(syncViewProvider).value?.offline ?? false)
                ? const OfflineBanner(steps: true)
                : const SizedBox.shrink(),
          ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  children: [
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
                        children: [
                          Semantics(
                            header: true,
                            child: Text(
                              title,
                              style: context.text.displaySmall,
                            ),
                          ),
                          if (subtitle != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              subtitle!,
                              style: context.text.bodyLarge?.copyWith(
                                color: context.colors.ink2,
                              ),
                            ),
                          ],
                          const SizedBox(height: 24),
                          ...children,
                        ],
                      ),
                    ),
                    if (primary != null || secondary != null || notice != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (notice != null) StepNotice(notice!),
                            ?primary,
                            ?secondary,
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Primary button that shows a spinner while busy (spinners only for short button actions, spec §5.4).
class BusyButton extends StatelessWidget {
  const BusyButton({
    required this.label,
    required this.onPressed,
    this.busy = false,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) => FilledButton(
    onPressed: busy ? null : onPressed,
    child: busy
        ? SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: context.colors.onPrimary,
            ),
          )
        : Text(label),
  );
}

/// A message under a form or step, read out when it appears and when it changes ([AnnouncedText]), so its callers
/// don't [announce] it too: icon + text in the status colour.
class StepNotice extends StatelessWidget {
  const StepNotice(
    this.message, {
    this.kind = StatusKind.urgent,
    this.announced = true,
    super.key,
  });

  final String message;
  final StatusKind kind;

  /// False for a standing note that is part of the page, read with it rather than on its own.
  final bool announced;

  @override
  Widget build(BuildContext context) {
    final fg = context.colors.of(kind).fg;
    final style = context.text.bodyLarge?.copyWith(color: fg);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            kind == StatusKind.success
                ? AppIcons.checkCircleFill
                : AppIcons.warningCircle,
            size: inlineIconSize(context, 22),
            color: fg,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: announced
                ? AnnouncedText(message, style: style)
                : Text(message, style: style),
          ),
        ],
      ),
    );
  }
}

/// Supabase Auth errors → our error-template codes.
enum AuthFailure { network, tooMany, invalidCode, other }

AuthFailure classifyAuthError(Object e) => switch (e) {
  AuthRetryableFetchException() => AuthFailure.network,
  AuthException(statusCode: '429') => AuthFailure.tooMany,
  AuthException(statusCode: '403' || '400' || '422') => AuthFailure.invalidCode,
  _ => AuthFailure.other,
};
