import 'dart:async';

import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/diary.dart';
import 'package:advocate_app/features/board/assign_sheet.dart';
import 'package:advocate_app/features/case_page/case_page_text.dart';
import 'package:advocate_app/features/case_page/sheet_form.dart';
import 'package:advocate_app/ui/fields.dart';
import 'package:advocate_app/ui/focus_ring.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/sheets.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Add task (spec §4.3 Notes & tasks; the centre "+" sheet), or edit [task]: what needs doing, due date (DD-MM-YYYY
/// or the picker) with an optional time, assignee, and the case ([matterId], or picked from a searchable list
/// when null). Writes through `CaseWriter.addTask` / `editTask`; local, so it works offline.
Future<void> showTaskSheet(
  BuildContext context, {
  String? matterId,
  CaseTask? task,
}) => showAppBottomSheet<void>(
  context,
  builder: (_) => _TaskSheet(matterId: matterId, task: task),
);

class _TaskSheet extends ConsumerStatefulWidget {
  const _TaskSheet({this.matterId, this.task});

  final String? matterId;
  final CaseTask? task;

  @override
  ConsumerState<_TaskSheet> createState() => _TaskSheetState();
}

class _TaskSheetState extends ConsumerState<_TaskSheet> {
  late final _title = TextEditingController(text: widget.task?.title);
  late final TextEditingController _date;

  /// Midnight IST means no time (see [taskDueAt]).
  TimeOfDay? _time;
  late String? _assigneeId = widget.task?.assigneeId;
  late String? _matterId = widget.matterId;
  String? _titleError;
  String? _dateError;

  @override
  void initState() {
    super.initState();
    final at = widget.task?.dueAt;
    final ist = at == null ? null : istOf(at);
    _date = TextEditingController(text: ist == null ? '' : Formats.entry(ist));
    if (ist != null && (ist.hour != 0 || ist.minute != 0)) {
      _time = TimeOfDay(hour: ist.hour, minute: ist.minute);
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _date.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _time ?? const TimeOfDay(hour: 10, minute: 30),
    );
    if (picked != null) {
      setState(() {
        _time = picked;
        _dateError = null;
      });
    }
  }

  Future<void> _pickCase() async {
    final picked = await showAppBottomSheet<({String? id})>(
      context,
      builder: (_) => const _CasePicker(),
    );
    if (picked != null) setState(() => _matterId = picked.id);
  }

  Future<void> _save() async {
    final l = context.l10n;
    final day = Formats.parseEntry(_date.text);
    if (_title.text.trim().isEmpty) {
      setState(() => _titleError = l.casePageTaskTitleEmpty);
      announce(context, l.casePageTaskTitleEmpty);
      return;
    }
    // An invalid date shows the field's own error; an empty one means no due date, so no time either.
    if (_date.text.isNotEmpty && day == null) {
      announce(context, l.dateInvalid);
      return;
    }
    if (day == null && _time != null) {
      setState(() => _dateError = l.casePageTimeNeedsDate);
      announce(context, l.casePageTimeNeedsDate);
      return;
    }
    final dueAt = day == null
        ? null
        : taskDueAt(day, hour: _time?.hour, minute: _time?.minute);
    final writer = ref.read(caseWriterProvider);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final task = widget.task;
    if (task == null) {
      await writer.addTask(
        title: _title.text,
        matterId: _matterId,
        dueAt: dueAt,
        assigneeId: _assigneeId,
      );
    } else {
      await writer.editTask(
        task.id,
        title: _title.text,
        dueAt: dueAt,
        assigneeId: _assigneeId,
      );
    }
    navigator.pop();
    // From the "+" sheet nothing else shows the new task.
    if (task == null && widget.matterId == null) {
      showSnack(messenger, l.casePageTaskAdded);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final f = Formats(Localizations.localeOf(context));
    final me = ref.watch(currentUserIdProvider);
    final members = ref.watch(orgMembersProvider).value ?? const <OrgMember>[];
    final cases = ref.watch(casesProvider).value ?? const <CaseInfo>[];
    final picked = cases.where((c) => c.id == _matterId).firstOrNull;
    final time = _time;
    // An assignee who isn't among the active members (removed from the team, or the members still loading) stays
    // the task's assignee, with an item of their own: the dropdown needs one item for its value.
    final assignee = _assigneeId;
    final unlisted =
        assignee != null && !members.any((m) => m.userId == assignee);
    return SheetForm(
      title: widget.task == null ? l.addTask : l.casePageEditTask,
      onSave: () => unawaited(_save()),
      children: [
        AppTextField(
          controller: _title,
          label: l.casePageTaskTitle,
          error: _titleError,
          autofocus: widget.task == null,
          onChanged: (_) {
            if (_titleError != null) setState(() => _titleError = null);
          },
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DateField(
              label: l.casePageDueDate,
              controller: _date,
              onChanged: (_) {
                if (_dateError != null) setState(() => _dateError = null);
              },
            ),
            if (_dateError != null) FieldError(_dateError!),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: () => unawaited(_pickTime()),
              icon: const Icon(AppIcons.clock),
              label: Text(
                time == null
                    ? l.casePageAddTime
                    : f.time(DateTime.utc(2000, 1, 1, time.hour, time.minute)),
              ),
            ),
            if (time != null)
              TextButton(
                onPressed: () => setState(() {
                  _time = null;
                  _dateError = null;
                }),
                child: Text(l.casePageNoTime),
              ),
          ],
        ),
        DropdownButtonFormField<String?>(
          initialValue: _assigneeId,
          isExpanded: true,
          decoration: InputDecoration(labelText: l.boardAssignee),
          items: [
            DropdownMenuItem(child: Text(l.casePageAssignNone)),
            if (unlisted)
              DropdownMenuItem(
                value: assignee,
                child: Text(
                  widget.task?.assigneeName ?? l.casePageFormerMember,
                ),
              ),
            for (final m in members)
              DropdownMenuItem(
                value: m.userId,
                child: Text(m.userId == me ? l.boardMe : memberName(l, m)),
              ),
          ],
          onChanged: (v) => setState(() => _assigneeId = v),
        ),
        if (widget.matterId == null && widget.task == null)
          FocusRing(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(AppIcons.briefcase),
              title: Text(l.casePageCase),
              subtitle: Text(picked?.caseLabel ?? l.casePageNoCase),
              trailing: const Icon(AppIcons.caretRight),
              onTap: () => unawaited(_pickCase()),
            ),
          ),
      ],
    );
  }
}

/// The task's case, from the org's live cases by number, party, client or CNR (with transliteration); "No case"
/// too. Returns the pick (`id` null for no case), or null when dismissed.
class _CasePicker extends ConsumerStatefulWidget {
  const _CasePicker();

  @override
  ConsumerState<_CasePicker> createState() => _CasePickerState();
}

class _CasePickerState extends ConsumerState<_CasePicker> {
  var _query = CaseQuery('');

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final cases = [
      for (final c in ref.watch(casesProvider).value ?? const <CaseInfo>[])
        if (!c.archived && _query.matches(c)) c,
    ];
    // ponytail: the first 30 matches; typing narrows it. A lazy list if people want to scroll every case.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(l.casePageChooseCase, style: context.text.titleLarge),
        ),
        const SizedBox(height: 16),
        SearchField(
          hint: l.searchCasesHint,
          autofocus: true,
          onChanged: (v) => setState(() => _query = CaseQuery(v)),
        ),
        const SizedBox(height: 8),
        FocusRing(
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l.casePageNoCase),
            onTap: () => Navigator.pop(context, (id: null)),
          ),
        ),
        for (final c in cases.take(30))
          FocusRing(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(c.caseLabel),
              subtitle: c.title == null || c.title == c.caseLabel
                  ? null
                  : Text(
                      c.title!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
              onTap: () => Navigator.pop(context, (id: c.id)),
            ),
          ),
      ],
    );
  }
}
