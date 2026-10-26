import 'dart:async';

import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/case_text.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/features/case_page/case_page_text.dart';
import 'package:advocate_app/features/case_page/sheet_form.dart';
import 'package:advocate_app/features/case_page/task_sheet.dart';
import 'package:advocate_app/ui/fields.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/section_header.dart';
import 'package:advocate_app/ui/sheets.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:advocate_app/ui/tiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Notes & tasks (spec §4.3): team and private notes (members edit and delete any note they can see, RLS
/// `notes_update`; private notes reach only their author's device), the case's tasks (done with Undo) and its
/// manual deadlines (spec §17 P1; calendar views are task 10). All local writes; deletes have Undo. A sliver for
/// the case page.
class NotesTab extends ConsumerWidget {
  const NotesTab(this.c, {super.key});

  final CaseInfo c;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final notesAsync = ref.watch(caseNotesProvider(c.id));
    final tasksAsync = ref.watch(caseTasksProvider(c.id));
    final deadlinesAsync = ref.watch(caseDeadlinesProvider(c.id));
    final waiting = tabWaiting(
      context,
      [notesAsync, tasksAsync, deadlinesAsync],
      onRetry: () => ref
        ..invalidate(caseNotesProvider(c.id))
        ..invalidate(caseTasksProvider(c.id))
        ..invalidate(caseDeadlinesProvider(c.id)),
    );
    if (waiting != null) return waiting;
    final hidden = ref.watch(hiddenRowsProvider);
    final notes = [
      for (final n in notesAsync.requireValue)
        if (!hidden.contains(n.id)) n,
    ];
    final tasks = [
      for (final t in tasksAsync.requireValue)
        if (!hidden.contains(t.id)) t,
    ];
    final deadlines = [
      for (final d in deadlinesAsync.requireValue)
        if (!hidden.contains(d.id)) d,
    ];
    Widget none(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text, style: context.text.bodyMedium),
    );
    return SliverList.list(
      children: [
        SectionHeader(
          l.caseNotes,
          count: notes.length,
          actionLabel: l.casePageAddNote,
          onAction: () => unawaited(_editNote(context, ref, null)),
        ),
        if (notes.isEmpty) none(l.casePageNotesEmpty),
        for (final n in notes)
          _Note(n, onEdit: () => _editNote(context, ref, n)),
        SectionHeader(
          l.casePageTasks,
          count: tasks.length,
          actionLabel: l.addTask,
          onAction: () => unawaited(showTaskSheet(context, matterId: c.id)),
        ),
        if (tasks.isEmpty) none(l.casePageTasksEmpty),
        for (final t in tasks) _Task(t, matterId: c.id),
        SectionHeader(
          l.casePageDeadlines,
          count: deadlines.length,
          actionLabel: l.casePageAddDeadline,
          onAction: () => unawaited(showDeadlineSheet(context, matterId: c.id)),
        ),
        if (deadlines.isEmpty) none(l.casePageDeadlinesEmpty),
        for (final d in deadlines) _Deadline(d),
      ],
    );
  }

  /// Add a note ([note] null) or edit one. Only the author may switch a note between team and private.
  Future<void> _editNote(BuildContext context, WidgetRef ref, CaseNote? note) {
    final l = context.l10n;
    final writer = ref.read(caseWriterProvider);
    final mine =
        note == null || note.authorId == ref.read(currentUserIdProvider);
    return showTextSheet(
      context,
      title: note == null ? l.casePageAddNote : l.casePageEditNote,
      label: l.caseNotes,
      initial: note?.body,
      private: mine ? note?.private ?? false : null,
      required: true,
      onSave: (text, {required private}) async {
        if (note == null) {
          await writer.addNote(c.id, text, private: private);
        } else {
          await writer.editNote(
            note.id,
            text,
            private: mine ? private : note.private,
          );
        }
      },
    );
  }
}

/// Edit / Delete for a row, behind one 48 dp button.
class _RowMenu extends StatelessWidget {
  const _RowMenu({required this.label, required this.onDelete, this.onEdit});

  /// What the row is, for screen readers: "More actions for …".
  final String label;
  final VoidCallback? onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return PopupMenuButton<bool>(
      tooltip: l.boardMoreActions(label),
      icon: const Icon(AppIcons.dotsThreeVertical),
      onSelected: (edit) => edit ? onEdit!() : onDelete(),
      itemBuilder: (_) => [
        if (onEdit != null)
          PopupMenuItem(value: true, child: Text(l.casePageEdit)),
        PopupMenuItem(value: false, child: Text(l.delete)),
      ],
    );
  }
}

class _Note extends ConsumerWidget {
  const _Note(this.note, {required this.onEdit});

  final CaseNote note;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final f = Formats(Localizations.localeOf(context));
    final at = note.createdAt;
    final meta = [
      ?note.authorName,
      if (at != null) '${f.shortDate(istOf(at))}, ${f.time(istOf(at))}',
      if (note.private) l.casePagePrivate,
    ].join(' · ');
    // Each note's menu says which note it is: the start of its text.
    final body = note.body.characters;
    final excerpt = body.length > 40 ? '${body.take(40)}…' : note.body;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(note.body, style: context.text.bodyLarge),
      subtitle: meta.isEmpty ? null : Text(meta, style: context.text.bodySmall),
      trailing: _RowMenu(
        label: excerpt,
        onEdit: onEdit,
        onDelete: () =>
            deleteWithUndo(context, ref, note.id, (w) => w.deleteNote(note.id)),
      ),
    );
  }
}

class _Task extends ConsumerWidget {
  const _Task(this.task, {required this.matterId});

  final CaseTask task;
  final String matterId;

  /// Done with a light haptic (unless switched off) and Undo; reopening needs neither (spec §5.5).
  void _toggle(BuildContext context, WidgetRef ref, {required bool done}) {
    final writer = ref.read(caseWriterProvider);
    unawaited(writer.setTaskDone(task.id, done: done));
    if (!done) return;
    if (ref.read(settingsProvider).haptics) {
      unawaited(HapticFeedback.lightImpact());
    }
    showUndoSnackbar(
      context,
      message: context.l10n.todayTaskDone,
      onUndo: () => unawaited(writer.setTaskDone(task.id, done: false)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = Localizations.localeOf(context);
    final today = ref.watch(istTodayProvider);
    final due = task.dueAt;
    return Row(
      children: [
        Expanded(
          child: TaskItem(
            title: task.title,
            done: task.done,
            due: due == null ? null : taskDueText(locale, due),
            overdue:
                !task.done && due != null && due.isBefore(istInstant(today)),
            assignee: task.assigneeName,
            onChanged: (done) => _toggle(context, ref, done: done),
          ),
        ),
        _RowMenu(
          label: task.title,
          onEdit: () =>
              unawaited(showTaskSheet(context, matterId: matterId, task: task)),
          onDelete: () => deleteWithUndo(
            context,
            ref,
            task.id,
            (w) => w.deleteTask(task.id),
          ),
        ),
      ],
    );
  }
}

class _Deadline extends ConsumerWidget {
  const _Deadline(this.deadline);

  final CaseDeadline deadline;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final d = deadline;
    final kind = deadlineKindLabel(l, d.kind);
    final writer = ref.read(caseWriterProvider);
    return Row(
      children: [
        Expanded(
          child: TaskItem(
            title: kind,
            done: d.done,
            due: Formats(Localizations.localeOf(context)).date(d.dueDate),
            overdue: !d.done && d.dueDate.isBefore(ref.watch(istTodayProvider)),
            onChanged: (done) {
              unawaited(writer.setDeadlineDone(d.id, done: done));
              if (!done) return;
              showUndoSnackbar(
                context,
                message: l.casePageDeadlineDone,
                onUndo: () =>
                    unawaited(writer.setDeadlineDone(d.id, done: false)),
              );
            },
          ),
        ),
        _RowMenu(
          label: kind,
          onDelete: () =>
              deleteWithUndo(context, ref, d.id, (w) => w.deleteDeadline(d.id)),
        ),
      ],
    );
  }
}

/// Add a manual deadline (spec §17 P1): its kind (limitation, compliance, filing, other) and due date.
Future<void> showDeadlineSheet(
  BuildContext context, {
  required String matterId,
}) =>
    showAppBottomSheet<void>(context, builder: (_) => _DeadlineSheet(matterId));

class _DeadlineSheet extends ConsumerStatefulWidget {
  const _DeadlineSheet(this.matterId);

  final String matterId;

  @override
  ConsumerState<_DeadlineSheet> createState() => _DeadlineSheetState();
}

class _DeadlineSheetState extends ConsumerState<_DeadlineSheet> {
  final _date = TextEditingController();
  String _kind = deadlineKinds.first;
  String? _error;

  @override
  void dispose() {
    _date.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l = context.l10n;
    final date = Formats.parseEntry(_date.text);
    if (date == null) {
      setState(
        () => _error = _date.text.isEmpty ? l.casePageDateRequired : null,
      );
      announce(context, _error ?? l.dateInvalid);
      return;
    }
    final navigator = Navigator.of(context);
    await ref
        .read(caseWriterProvider)
        .addDeadline(widget.matterId, kind: _kind, dueDate: date);
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return SheetForm(
      title: l.casePageAddDeadline,
      onSave: () => unawaited(_save()),
      children: [
        Semantics(
          header: true,
          child: Text(l.casePageDeadlineKind, style: context.text.labelLarge),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final k in deadlineKinds)
              ChoiceChip(
                label: Text(deadlineKindLabel(l, k)),
                selected: _kind == k,
                onSelected: (_) => setState(() => _kind = k),
              ),
          ],
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DateField(
              label: l.casePageDueDate,
              controller: _date,
              onChanged: (_) => setState(() => _error = null),
            ),
            if (_error != null) FieldError(_error!),
          ],
        ),
      ],
    );
  }
}
