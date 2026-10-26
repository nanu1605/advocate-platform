import 'dart:async';

import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/ui/focus_ring.dart';
import 'package:advocate_app/ui/krutidev_offer.dart';
import 'package:advocate_app/ui/sheets.dart';
import 'package:advocate_app/ui/skeleton.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A case page tab's skeleton while any of [values] loads, or the error with Retry (spec §5.4); null once every
/// one has data.
Widget? tabWaiting(
  BuildContext context,
  List<AsyncValue<Object?>> values, {
  required VoidCallback onRetry,
}) {
  if (values.every((v) => v.hasValue)) return null;
  final failed = values.where((v) => v.hasError).firstOrNull;
  return SliverToBoxAdapter(
    child: failed == null
        ? const SkeletonCaseList(count: 2)
        : ErrorState(
            message: errorText(context.l10n, failed.error),
            onRetry: onRetry,
          ),
  );
}

/// Rows deleted on the case page whose delete hasn't been written: the tabs leave them out.
final hiddenRowsProvider = NotifierProvider<HiddenRows, Set<String>>(
  HiddenRows.new,
);

class HiddenRows extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void hide(String id) => state = {...state, id};

  void show(String id) => state = {...state}..remove(id);
}

/// Delete with Undo (spec §5.5) for a note, task, deadline or manual hearing ([id]): the row leaves its list at
/// once and [delete] (a soft delete) runs when the 5 s snackbar closes without Undo. Writing it only then means
/// Undo never has to bring back a row that sync has already taken off the device. The writer is read now: the
/// row's widget (and its ref) is gone by then.
/// ponytail: rows leave without the slide-out; an AnimatedList would add it.
void deleteWithUndo(
  BuildContext context,
  WidgetRef ref,
  String id,
  Future<void> Function(CaseWriter writer) delete,
) {
  final writer = ref.read(caseWriterProvider);
  final hidden = ref.read(hiddenRowsProvider.notifier)..hide(id);
  final closed = showUndoSnackbar(
    context,
    message: context.l10n.deleted,
    onUndo: () => hidden.show(id),
  ).closed;
  // A committed delete stays hidden: sync drops the row.
  unawaited(
    closed.then((reason) async {
      if (reason != SnackBarClosedReason.action) await delete(writer);
    }),
  );
}

/// The case page's form sheets: a heading, the fields, and Save, kept above the keyboard.
class SheetForm extends StatelessWidget {
  const SheetForm({
    required this.title,
    required this.children,
    required this.onSave,
    this.saveLabel,
    super.key,
  });

  final String title;
  final List<Widget> children;
  final VoidCallback? onSave;

  /// Defaults to "Save".
  final String? saveLabel;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(title, style: context.text.titleLarge),
        ),
        for (final c in children) ...[const SizedBox(height: 16), c],
        const SizedBox(height: 24),
        FilledButton(
          onPressed: onSave,
          child: Text(saveLabel ?? context.l10n.casePageSave),
        ),
      ],
    ),
  );
}

/// An inline form error under a field that has no error slot of its own (spec §5.9: inline and announced; the
/// sheet announces it with [announce]).
class FieldError extends StatelessWidget {
  const FieldError(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
    child: Text(
      message,
      style: context.text.bodySmall?.copyWith(
        color: context.colors.of(StatusKind.urgent).fg,
      ),
    ),
  );
}

/// A note sheet: a hearing note, or a case note with "Private" when [private] is given. [required] refuses an
/// empty note (a hearing note may be cleared). [onSave] gets the text and whether it is private.
Future<void> showTextSheet(
  BuildContext context, {
  required String title,
  required String label,
  required Future<void> Function(String text, {required bool private}) onSave,
  String? initial,
  bool? private,
  bool required = false,
}) => showAppBottomSheet<void>(
  context,
  builder: (_) => _TextSheet(
    title: title,
    label: label,
    initial: initial,
    private: private,
    required: required,
    onSave: onSave,
  ),
);

class _TextSheet extends StatefulWidget {
  const _TextSheet({
    required this.title,
    required this.label,
    required this.initial,
    required this.private,
    required this.required,
    required this.onSave,
  });

  final String title;
  final String label;
  final String? initial;
  final bool? private;
  final bool required;
  final Future<void> Function(String text, {required bool private}) onSave;

  @override
  State<_TextSheet> createState() => _TextSheetState();
}

class _TextSheetState extends State<_TextSheet> {
  late final _text = TextEditingController(text: widget.initial);
  late bool _private = widget.private ?? false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l = context.l10n;
    if (widget.required && _text.text.trim().isEmpty) {
      setState(() => _error = l.casePageNoteEmpty);
      announce(context, l.casePageNoteEmpty);
      return;
    }
    final navigator = Navigator.of(context);
    await widget.onSave(_text.text, private: _private);
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return SheetForm(
      title: widget.title,
      onSave: _save,
      children: [
        TextField(
          controller: _text,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          textCapitalization: TextCapitalization.sentences,
          style: context.text.bodyLarge,
          decoration: InputDecoration(
            labelText: widget.label,
            alignLabelWithHint: true,
            errorText: _error,
            errorMaxLines: 3,
          ),
        ),
        KrutidevOffer(_text),
        if (widget.private != null)
          FocusRing(
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l.casePagePrivate),
              subtitle: Text(l.casePagePrivateHint),
              value: _private,
              onChanged: (v) => setState(() => _private = v),
            ),
          ),
      ],
    );
  }
}
