import 'dart:async';

import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/case_text.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/document_files.dart';
import 'package:advocate_app/data/documents.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:advocate_app/features/case_page/links.dart';
import 'package:advocate_app/features/case_page/sheet_form.dart';
import 'package:advocate_app/ui/fields.dart';
import 'package:advocate_app/ui/focus_ring.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/sheets.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A file to upload: where it is on the device and the name the user knows it by.
typedef PickedFile = ({String path, String name});

/// The upload sheet's answers.
typedef DocumentDetails = ({String title, String kind, String? matterId});

/// The API's limit on a document's title (spec §10.2).
const docTitleMax = 300;

/// Where files come from (spec §4.3 "Upload sources", §7.1), behind [uploadSourcesProvider] so tests replace the
/// platform's pickers: the camera scanner on Android and iOS (ML Kit / VisionKit through cunning_document_scanner:
/// edges found and straightened, every page in one PDF), the file picker, and the type and size check made before
/// anything is copied. Windows picks files or takes them dropped.
class UploadSources {
  const UploadSources();

  bool get canScan =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// The scanned pages as one PDF; null when the user backs out. Throws when the scanner can't start (no camera
  /// permission, no camera).
  Future<String?> scan() async =>
      (await CunningDocumentScanner.getPictures(asPdf: true))?.firstOrNull;

  /// PDF, JPG, PNG or DOCX files, several at once; none when the user backs out.
  Future<List<PickedFile>> pick() async => [
    for (final f in await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: uploadTypes.keys.toList(),
    ))
      if (f.path case final path?) (path: path, name: f.name),
  ];

  Future<({String? mime, String? error})> check(PickedFile file) =>
      checkUploadFile(file.path, name: file.name);

  /// Deletes the scanner's and (Android) the picker's own copies, once the queue has its own and at sign-out: they
  /// would otherwise stay on the phone (the scanner's PDF in the app's external Pictures folder, not the private
  /// support folder). Windows picks the user's own files, so there is nothing to delete.
  Future<void> cleanUp() async {
    if (!canScan) return;
    for (final clean in [
      CunningDocumentScanner.cleanCache,
      FilePicker.clearTemporaryFiles,
    ]) {
      try {
        await clean();
      } on Exception {
        // Nothing to delete, or the next clean-up gets it.
      }
    }
  }
}

final uploadSourcesProvider = Provider<UploadSources>(
  (_) => const UploadSources(),
);

/// Add document (spec §4.3): the "+" sheet, the Documents screen, a case's Documents tab ([matterId] presets the
/// case) and files dropped on Windows ([files]). Picks the source (scan or files) where there is a camera, checks
/// each file (type by extension and first bytes, 50 MB), asks its title, type and case, and queues it: the queue
/// keeps a copy and uploads it when online (ADR 0016), so nothing is lost offline. A file that fails the check says
/// why and the rest go on.
Future<void> startUpload(
  BuildContext context, {
  String? matterId,
  List<PickedFile>? files,
}) async {
  final l = context.l10n;
  final locale = Localizations.localeOf(context);
  final container = ProviderScope.containerOf(context, listen: false);
  final sources = container.read(uploadSourcesProvider);
  var picked = files ?? const <PickedFile>[];
  if (files == null) {
    final scan = sources.canScan ? await _chooseSource(context) : false;
    if (scan == null || !context.mounted) return;
    try {
      if (scan) {
        final path = await sources.scan();
        final today = istOf(container.read(clockProvider)());
        final name = '${l.docsScanTitle(Formats(locale).date(today))}.pdf';
        picked = [if (path != null) (path: path, name: name)];
      } else {
        picked = await sources.pick();
      }
    } on Exception {
      if (context.mounted) {
        showMessage(context, scan ? l.docsScanFailed : l.errorGeneric);
      }
      return;
    }
  }
  var queued = 0;
  // Said once at the end, so no message covers the next file's sheet.
  final problems = <String>[];
  try {
    for (final (i, file) in picked.indexed) {
      final check = await sources.check(file);
      if (!context.mounted) break;
      if (check.error case final error?) {
        problems.add(l.docsFileProblem(file.name, errorText(l, error)));
        continue;
      }
      final details = await showAppBottomSheet<DocumentDetails>(
        context,
        builder: (_) => _DetailsSheet(
          heading: l.docsUploadTitle,
          saveLabel: l.docsUpload,
          title: titleFromFileName(file.name),
          kind: 'other',
          matterId: matterId,
          fileLine: [
            file.name,
            if (picked.length > 1) l.docsFileCount(i + 1, picked.length),
          ].join(' · '),
        ),
      );
      final org = container.read(currentOrgIdProvider);
      if (details == null || org == null) continue;
      try {
        final id = await container
            .read(uploadsProvider)
            .enqueue(
              orgId: org,
              path: file.path,
              title: details.title,
              kind: details.kind,
              mime: check.mime!,
              matterId: details.matterId,
            );
        if (id != null) queued++;
      } on Exception catch (e) {
        // This file only (SAVE_FAILED: the device is full); the rest go on.
        problems.add(l.docsFileProblem(file.name, errorText(l, e)));
      }
    }
  } finally {
    await sources.cleanUp();
  }
  final offline = container.read(syncViewProvider).value?.offline ?? false;
  final said = [
    ...problems,
    if (queued > 0 && offline)
      l.docsQueuedOffline(queued)
    else if (queued > 0)
      l.docsQueued(queued),
  ];
  if (said.isNotEmpty && context.mounted) {
    showMessage(context, said.join('\n'));
  }
}

/// Scan or files: true for the scanner, null when dismissed.
Future<bool?> _chooseSource(BuildContext context) {
  final l = context.l10n;
  return showAppBottomSheet<bool>(
    context,
    builder: (sheet) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(l.addDocument, style: sheet.text.titleLarge),
        ),
        const SizedBox(height: 8),
        FocusRing(
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(AppIcons.camera),
            title: Text(l.docsScan),
            subtitle: Text(l.docsScanHint),
            onTap: () => Navigator.pop(sheet, true),
          ),
        ),
        FocusRing(
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(AppIcons.folderSimple),
            title: Text(l.docsChooseFiles),
            subtitle: Text(l.docsChooseFilesHint),
            onTap: () => Navigator.pop(sheet, false),
          ),
        ),
      ],
    ),
  );
}

/// Edit a document's title, type and case (spec §9.3: the device may change these three). Local; uploads with sync.
Future<void> showDocumentDetailsSheet(
  BuildContext context, {
  required CaseDocument document,
}) async {
  final l = context.l10n;
  final writer = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(caseWriterProvider);
  final details = await showAppBottomSheet<DocumentDetails>(
    context,
    builder: (_) => _DetailsSheet(
      heading: l.docsEditDetails,
      saveLabel: l.casePageSave,
      title: document.title,
      kind: document.kind,
      matterId: document.matterId,
      caseLabel: document.caseLabel,
    ),
  );
  if (details == null) return;
  await writer.editDocument(
    document.id,
    title: details.title,
    kind: details.kind,
    matterId: details.matterId,
  );
}

/// Title (required, up to 300 characters), type and case (optional) of an upload or a document; pops the answers.
class _DetailsSheet extends ConsumerStatefulWidget {
  const _DetailsSheet({
    required this.heading,
    required this.saveLabel,
    required this.title,
    required this.kind,
    this.matterId,
    this.caseLabel,
    this.fileLine,
  });

  final String heading;
  final String saveLabel;
  final String title;
  final String kind;
  final String? matterId;

  /// [matterId]'s label, for when the cases haven't loaded.
  final String? caseLabel;

  /// The picked file's name (and "File 2 of 3").
  final String? fileLine;

  @override
  ConsumerState<_DetailsSheet> createState() => _DetailsSheetState();
}

class _DetailsSheetState extends ConsumerState<_DetailsSheet> {
  late final _title = TextEditingController(text: widget.title);
  late String _kind = widget.kind;
  late String? _matterId = widget.matterId;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _save() {
    final l = context.l10n;
    final title = _title.text.trim();
    final error = title.isEmpty
        ? l.docsTitleRequired
        : title.length > docTitleMax
        ? l.docsTitleTooLong(docTitleMax)
        : null;
    if (error != null) {
      setState(() => _error = error);
      announce(context, error);
      return;
    }
    Navigator.pop<DocumentDetails>(context, (
      title: title,
      kind: _kind,
      matterId: _matterId,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final cases = [...?ref.watch(casesProvider).value]
      ..sort((a, b) => a.caseLabel.compareTo(b.caseLabel));
    final preset = _matterId;
    return SheetForm(
      title: widget.heading,
      saveLabel: widget.saveLabel,
      onSave: _save,
      children: [
        if (widget.fileLine case final line?)
          Text(line, style: context.text.bodySmall),
        AppTextField(
          controller: _title,
          label: l.docsTitleLabel,
          error: _error,
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.docsTypeLabel, style: context.text.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final k in documentKinds)
                  ChoiceChip(
                    label: Text(documentKindLabel(l, k)),
                    selected: _kind == k,
                    onSelected: (_) => setState(() => _kind = k),
                  ),
              ],
            ),
          ],
        ),
        DropdownButtonFormField<String?>(
          initialValue: _matterId,
          isExpanded: true,
          decoration: InputDecoration(labelText: l.docsCaseLabel),
          items: [
            DropdownMenuItem(child: Text(l.docsNoCase)),
            if (preset != null && !cases.any((c) => c.id == preset))
              DropdownMenuItem(
                value: preset,
                child: Text(widget.caseLabel ?? '…'),
              ),
            for (final c in cases)
              DropdownMenuItem(
                value: c.id,
                child: Text(
                  c.caseLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (id) => setState(() => _matterId = id),
        ),
      ],
    );
  }
}

/// Windows (spec §5.1, §5.12): files dropped on [child] start an upload ([matterId] presets the case), with a
/// "Drop files here" overlay while they are over it. Elsewhere it is just [child].
class UploadDropTarget extends StatefulWidget {
  const UploadDropTarget({required this.child, this.matterId, super.key});

  final Widget child;
  final String? matterId;

  @override
  State<UploadDropTarget> createState() => _UploadDropTargetState();
}

class _UploadDropTargetState extends State<UploadDropTarget> {
  var _over = false;

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.windows) return widget.child;
    final c = context.colors;
    return DropTarget(
      onDragEntered: (_) => setState(() => _over = true),
      onDragExited: (_) => setState(() => _over = false),
      onDragDone: (drop) {
        setState(() => _over = false);
        unawaited(
          startUpload(
            context,
            matterId: widget.matterId,
            files: [
              for (final f in drop.files.whereType<DropItemFile>())
                (path: f.path, name: f.name),
            ],
          ),
        );
      },
      child: Stack(
        children: [
          widget.child,
          if (_over)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  margin: const EdgeInsets.all(8),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: c.primarySoft.withValues(alpha: 0.9),
                    border: Border.all(color: c.primary, width: 2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(AppIcons.cloudArrowUp, size: 48, color: c.primary),
                      const SizedBox(height: 8),
                      Text(
                        context.l10n.docsDropHere,
                        textAlign: TextAlign.center,
                        style: context.text.titleMedium,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
