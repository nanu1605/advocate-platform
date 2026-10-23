import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Shared frame for onboarding steps: heading, body, one primary action pinned at the bottom.
class OnboardingLayout extends StatelessWidget {
  const OnboardingLayout({
    required this.title,
    required this.children,
    this.subtitle,
    this.primary,
    this.secondary,
    this.showBack = false,
    super.key,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;
  final Widget? primary;
  final Widget? secondary;
  final bool showBack;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: showBack ? AppBar(shape: const Border()) : null,
    body: SafeArea(
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
                      child: Text(title, style: context.text.displaySmall),
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
              if (primary != null || secondary != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [?primary, ?secondary],
                  ),
                ),
            ],
          ),
        ),
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

/// Supabase Auth errors → our error-template codes.
enum AuthFailure { network, tooMany, invalidCode, other }

AuthFailure classifyAuthError(Object e) => switch (e) {
  AuthRetryableFetchException() => AuthFailure.network,
  AuthException(statusCode: '429') => AuthFailure.tooMany,
  AuthException(statusCode: '403' || '400' || '422') => AuthFailure.invalidCode,
  _ => AuthFailure.other,
};
