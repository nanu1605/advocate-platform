import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:flutter/material.dart';

/// Empty screen: icon + one sentence + one primary action (spec §5.4).
class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.message,
    this.icon = AppIcons.tray,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  final String message;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: context.colors.ink3),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: context.text.bodyLarge,
          ),
          if (actionLabel != null) ...[
            const SizedBox(height: 16),
            FilledButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    ),
  );
}

/// What happened + what we're doing + what you can do, with Retry. Never a raw error code (spec §5.4).
class ErrorState extends StatelessWidget {
  const ErrorState({required this.message, this.onRetry, super.key});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final urgent = context.colors.of(StatusKind.urgent);
    return Semantics(
      liveRegion: true,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(AppIcons.warningCircle, size: 56, color: urgent.fg),
              const SizedBox(height: 16),
              Text(
                message,
                textAlign: TextAlign.center,
                style: context.text.bodyLarge,
              ),
              if (onRetry != null) ...[
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(AppIcons.arrowClockwise),
                  label: Text(context.l10n.retry),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Thin banner while offline; actions keep queuing (spec §5.4).
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = c.of(StatusKind.adjourned);
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: s.bg,
          // Sunlight has no tints, so the banner gets a coloured edge instead.
          border: c.isSunlight
              ? Border(
                  bottom: BorderSide(color: s.fg, width: c.borderWidth),
                )
              : null,
        ),
        child: Row(
          children: [
            Icon(
              AppIcons.wifiSlash,
              size: inlineIconSize(context, 18),
              color: s.fg,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                context.l10n.offlineBanner,
                style: context.text.bodySmall?.copyWith(color: s.fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum SyncStatus { synced, syncing, failed }

/// Small sync indicator for the app bar; never blocks the UI.
class SyncIndicator extends StatelessWidget {
  const SyncIndicator(this.status, {super.key});

  final SyncStatus status;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l = context.l10n;
    final (icon, color, label) = switch (status) {
      SyncStatus.synced => (
        AppIcons.cloudCheck,
        c.of(StatusKind.success).fg,
        l.synced,
      ),
      SyncStatus.syncing => (AppIcons.arrowsClockwise, c.ink2, l.syncing),
      SyncStatus.failed => (
        AppIcons.cloudWarning,
        c.of(StatusKind.urgent).fg,
        l.syncFailed,
      ),
    };
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        liveRegion: true,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Icon(icon, size: 24, color: color),
        ),
      ),
    );
  }
}
