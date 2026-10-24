import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:flutter/material.dart';

/// Bottom sheet with the app's shape, drag handle and scroll-safe height.
Future<T?> showAppBottomSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (ctx) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
    child: builder(ctx),
  ),
);

/// Destructive confirmation. The destructive action is the only filled button.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) =>
          ConfirmDialog(title: title, body: body, confirmLabel: confirmLabel),
    ) ??
    false;

class ConfirmDialog extends StatelessWidget {
  const ConfirmDialog({
    required this.title,
    required this.body,
    required this.confirmLabel,
    super.key,
  });

  final String title;
  final String body;
  final String confirmLabel;

  @override
  Widget build(BuildContext context) {
    final urgent = context.colors.of(StatusKind.urgent);
    return AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(context.l10n.cancel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: urgent.fg,
            foregroundColor: urgent.bg,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}

/// "Deleted · Undo" for 5 seconds (spec §5.5); with a screen reader on it stays until dismissed, so Undo can be
/// reached (Flutter keeps a snackbar with an action by default). Its `closed` says whether Undo was tapped
/// ([SnackBarClosedReason.action]).
ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showUndoSnackbar(
  BuildContext context, {
  required String message,
  required VoidCallback onUndo,
}) {
  final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
  return messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 5),
      persist: MediaQuery.accessibleNavigationOf(context),
      action: SnackBarAction(label: context.l10n.undo, onPressed: onUndo),
    ),
  );
}
