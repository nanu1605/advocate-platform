import 'dart:async';

import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

/// Reads [message] out where the platform takes announcements (Windows, iOS). Elsewhere a field's error text
/// and [AnnouncedText] are live regions already (spec §5.9: form errors are announced).
void announce(BuildContext context, String message) {
  if (!MediaQuery.supportsAnnounceOf(context)) return;
  unawaited(
    SemanticsService.sendAnnouncement(
      View.of(context),
      message,
      Directionality.of(context),
    ),
  );
}

/// Shows [message] in a snackbar, replacing the one showing, and reads it out on Windows, which never reads a
/// snackbar's live region (spec §5.9: results and errors are announced). iOS and Android read that region already.
void showSnack(ScaffoldMessengerState messenger, String message) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
  announceSnack(messenger.context, message);
}

/// [announce] for a snackbar's text: not on iOS, which reads the snackbar's live region (so it isn't said twice).
void announceSnack(BuildContext context, String message) {
  if (defaultTargetPlatform != TargetPlatform.iOS) announce(context, message);
}

/// Text read out when it shows and whenever it changes (spec §5.9): a live region on Android, an [announce]
/// where the platform takes those, as Windows ignores live regions. Never both, so nothing is said twice.
class AnnouncedText extends StatefulWidget {
  const AnnouncedText(
    this.text, {
    this.style,
    this.textAlign,
    this.child,
    super.key,
  });

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;

  /// Shown instead of [text], which is then only its spoken label (a skeleton, say).
  final Widget? child;

  @override
  State<AnnouncedText> createState() => _AnnouncedTextState();
}

class _AnnouncedTextState extends State<AnnouncedText> {
  @override
  void initState() {
    super.initState();
    _say();
  }

  @override
  void didUpdateWidget(AnnouncedText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _say();
  }

  /// After the frame, once the text is on screen.
  void _say() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && widget.text.isNotEmpty) announce(context, widget.text);
  });

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: !MediaQuery.supportsAnnounceOf(context),
    label: widget.child == null ? null : widget.text,
    child:
        widget.child ??
        Text(widget.text, style: widget.style, textAlign: widget.textAlign),
  );
}

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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.warningCircle, size: 56, color: urgent.fg),
            const SizedBox(height: 16),
            AnnouncedText(
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
    );
  }
}

/// Thin banner while offline; actions keep queuing (spec §5.4). With [synced] it says sync has caught up again,
/// which the shell shows for a moment after a spell offline so a screen reader hears it too (spec §5.9).
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({this.synced = false, this.steps = false, super.key});

  final bool synced;

  /// Onboarding's and /loading's, before there is saved data: says the steps need the internet. Not read out on each
  /// step, as each says so itself when it can't go on (a failed action, Finding's note, the loading error).
  final bool steps;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = c.of(synced ? StatusKind.success : StatusKind.adjourned);
    final style = context.text.bodySmall?.copyWith(color: s.fg);
    return Container(
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
            synced ? AppIcons.cloudCheck : AppIcons.wifiSlash,
            size: inlineIconSize(context, 18),
            color: s.fg,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: steps
                ? Text(context.l10n.offlineBannerSteps, style: style)
                : AnnouncedText(
                    synced ? context.l10n.synced : context.l10n.offlineBanner,
                    style: style,
                  ),
          ),
        ],
      ),
    );
  }
}

enum SyncStatus { synced, syncing, failed }

/// Small sync indicator for the app bar; never blocks the UI. Not a live region: the shell says when sync
/// completes, not every local write's "Syncing" (spec §5.9).
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
      excludeFromSemantics: true,
      child: Semantics(
        label: label,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Icon(icon, size: 24, color: color),
        ),
      ),
    );
  }
}
