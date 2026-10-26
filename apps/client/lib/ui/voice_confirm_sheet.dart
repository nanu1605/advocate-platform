import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/ui/fields.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:flutter/material.dart';

/// What a voice note was understood to say (`voice_parse`), for the user to check before anything is saved.
@immutable
class VoiceDraft {
  const VoiceDraft({
    required this.transcript,
    this.matter,
    this.matterUnsure = false,
    this.nextDate,
    this.nextDateUnsure = false,
    this.purpose,
    this.outcome,
    this.tasks = const [],
    this.note,
  });

  final String transcript;

  /// The id of one of the sheet's matters; null when the note didn't say which.
  final String? matter;
  final bool matterUnsure;
  final DateTime? nextDate;
  final bool nextDateUnsure;
  final String? purpose;
  final String? outcome;
  final List<String> tasks;
  final String? note;
}

/// The parsed fields of a voice note, editable, with the transcript (spec §5.11 #10, §12.9). Fields the model wasn't
/// sure of are marked until changed. Nothing is saved until Save, which needs a case and a next date that reads.
class VoiceConfirmSheet extends StatefulWidget {
  const VoiceConfirmSheet({
    required this.draft,
    required this.matters,
    required this.onSave,
    this.onCancel,
    super.key,
  });

  final VoiceDraft draft;

  /// Matter id → how it reads ("WP 1234/2024 · Sharma v. State").
  final Map<String, String> matters;

  /// The draft as confirmed, empty fields and tasks left out.
  final ValueChanged<VoiceDraft> onSave;
  final VoidCallback? onCancel;

  @override
  State<VoiceConfirmSheet> createState() => _VoiceConfirmSheetState();
}

class _VoiceConfirmSheetState extends State<VoiceConfirmSheet> {
  late final VoiceDraft d = widget.draft;
  late String? _matter = d.matter;
  late bool _matterUnsure = d.matterUnsure;
  late bool _dateUnsure = d.nextDateUnsure;
  late final _date = TextEditingController(
    text: d.nextDate == null ? '' : Formats.entry(d.nextDate!),
  );
  late final _purpose = TextEditingController(text: d.purpose);
  late final _outcome = TextEditingController(text: d.outcome);
  late final _note = TextEditingController(text: d.note);
  late final List<TextEditingController> _tasks = [
    for (final t in d.tasks) TextEditingController(text: t),
  ];

  @override
  void dispose() {
    for (final c in [_date, _purpose, _outcome, _note, ..._tasks]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _dateReads =>
      _date.text.isEmpty || Formats.parseEntry(_date.text) != null;

  static String? _text(TextEditingController c) =>
      c.text.trim().isEmpty ? null : c.text.trim();

  void _save() => widget.onSave(
    VoiceDraft(
      transcript: d.transcript,
      matter: _matter,
      nextDate: Formats.parseEntry(_date.text),
      purpose: _text(_purpose),
      outcome: _text(_outcome),
      tasks: [..._tasks.map(_text).nonNulls],
      note: _text(_note),
    ),
  );

  /// A field the model wasn't sure of: a tinted edge and "Please check".
  Widget _unsure(bool unsure, Widget field) {
    if (!unsure) return field;
    final s = context.colors.of(StatusKind.adjourned);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: s.bg,
        border: Border(left: BorderSide(color: s.fg, width: 4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                AppIcons.warning,
                size: inlineIconSize(context, 18),
                color: s.fg,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.l10n.voiceUnsure,
                  style: context.text.bodySmall?.copyWith(color: s.fg),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          field,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = context.colors;
    const gap = SizedBox(height: 12);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l.voiceConfirmTitle, style: context.text.titleLarge),
        gap,
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.line, width: c.borderWidth),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                AppIcons.quotes,
                size: inlineIconSize(context, 20),
                color: c.ink2,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.voiceTranscript,
                      style: context.text.bodySmall?.copyWith(color: c.ink2),
                    ),
                    Text(d.transcript, style: context.text.bodyLarge),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _unsure(
          _matterUnsure,
          DropdownButtonFormField<String>(
            initialValue: _matter,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: l.boardCase,
              hintText: l.voiceChooseCase,
            ),
            items: [
              for (final MapEntry(key: id, value: label)
                  in widget.matters.entries)
                DropdownMenuItem(value: id, child: Text(label)),
            ],
            onChanged: (v) => setState(() {
              _matter = v;
              _matterUnsure = false;
            }),
          ),
        ),
        gap,
        _unsure(
          _dateUnsure,
          DateField(
            controller: _date,
            label: l.nextDate,
            onChanged: (_) => setState(() => _dateUnsure = false),
          ),
        ),
        gap,
        AppTextField(label: l.boardPurpose, controller: _purpose),
        gap,
        AppTextField(label: l.voiceOutcome, controller: _outcome),
        const SizedBox(height: 16),
        Text(l.voiceTasks, style: context.text.titleSmall),
        for (final (i, t) in _tasks.indexed) ...[
          const SizedBox(height: 8),
          Row(
            key: ObjectKey(t),
            children: [
              Expanded(
                child: AppTextField(label: l.voiceTask(i + 1), controller: t),
              ),
              IconButton(
                tooltip: l.voiceRemoveTask(i + 1),
                icon: const Icon(AppIcons.trash),
                onPressed: () {
                  setState(() => _tasks.remove(t));
                  // Once its field is gone.
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => t.dispose(),
                  );
                },
              ),
            ],
          ),
        ],
        TextButton.icon(
          onPressed: () => setState(() => _tasks.add(TextEditingController())),
          icon: const Icon(AppIcons.plus),
          label: Text(l.addTask),
        ),
        gap,
        AppTextField(label: l.voiceNote, controller: _note),
        const SizedBox(height: 20),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: [
            TextButton(
              onPressed: widget.onCancel ?? () => Navigator.maybePop(context),
              child: Text(l.cancel),
            ),
            FilledButton(
              onPressed: _matter != null && _dateReads ? _save : null,
              child: Text(l.voiceSave),
            ),
          ],
        ),
      ],
    );
  }
}
