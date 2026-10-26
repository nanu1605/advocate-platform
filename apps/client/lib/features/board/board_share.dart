import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/diary.dart';
import 'package:advocate_app/data/diary_text.dart';
import 'package:advocate_app/ui/focus_ring.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/sheets.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Tomorrow's board as text for the share sheet (spec §4.2 "Share", §13.2): the date, then each court with its
/// cases and their court and item numbers. Case titles (party names) only when [titles]; never clients or
/// assignees. [entries] are in diary order (grouped by court); [note] ends it (the board isn't built yet).
String boardShareText(
  AppLocalizations l,
  Locale locale,
  DateTime day,
  List<DiaryEntry> entries, {
  required bool titles,
  String? note,
}) {
  final lines = [
    l.boardShareHeader(Formats(locale).shortDate(day)),
    if (entries.isEmpty) l.boardEmpty,
  ];
  for (final (i, e) in entries.indexed) {
    if (i == 0 || e.courtId != entries[i - 1].courtId) {
      if (i > 0) lines.add('');
      lines.add(e.court?.label(locale) ?? l.foundOtherCourt);
    }
    // A manual case with no number or CNR is labelled by its title, which is party names.
    final numbered = e.caseLabel.isNotEmpty && e.caseLabel != e.title;
    final label = numbered
        ? e.caseLabel
        : titles && e.title != null
        ? e.title!
        : l.boardShareNoNumber;
    final position = positionText(l, e);
    lines.add('• $label${position == null ? '' : ' — $position'}');
    if (titles && numbered && e.title != null) lines.add('  ${e.title}');
  }
  if (note != null) lines.addAll(['', note]);
  return lines.join('\n');
}

/// The OS share sheet (share_plus: text and files on Android and Windows 10 1809+); tests override it.
final shareProvider = Provider<Future<void> Function(ShareParams)>(
  (_) => (params) async {
    await SharePlus.instance.share(params);
  },
);

/// The one folder a shared board image is written to: `board_share` in [temp], with the platform's separators
/// (Windows' share API can't open a path with `/` in it).
Directory boardShareDir(String temp) =>
    Directory('$temp${Platform.pathSeparator}board_share');

/// Where shared board images go (in the OS temp folder); tests override it.
final boardShareDirProvider = Provider<Future<Directory> Function()>(
  (_) =>
      () async => boardShareDir((await getTemporaryDirectory()).path),
);

/// Deletes shared board images, which may hold case titles: before each new one and at sign-out (spec §15.4).
/// ponytail: a file the receiving app still holds open (Windows) stays until the next share or sign-out.
void clearBoardShares(Directory dir) {
  try {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  } on FileSystemException {
    // Locked; see above.
  }
}

/// Share for tomorrow's board: a live preview of exactly what goes out, "Include case titles" (off), and
/// Share as text or as an image of the preview.
Future<void> showBoardShareSheet(
  BuildContext context,
  DateTime day,
  List<DiaryEntry> entries, {
  String? note,
}) => showAppBottomSheet<void>(
  context,
  builder: (_) => BoardShareSheet(day: day, entries: entries, note: note),
);

class BoardShareSheet extends ConsumerStatefulWidget {
  const BoardShareSheet({
    required this.day,
    required this.entries,
    this.note,
    super.key,
  });

  final DateTime day;
  final List<DiaryEntry> entries;
  final String? note;

  @override
  ConsumerState<BoardShareSheet> createState() => _BoardShareSheetState();
}

class _BoardShareSheetState extends ConsumerState<BoardShareSheet> {
  final GlobalKey _preview = GlobalKey();
  bool _titles = false;
  bool _busy = false;

  /// The preview as a PNG at the screen's density (at least 2x, so it stays sharp on 100% Windows displays), written
  /// to the share folder (emptied first) as `board-YYYY-MM-DD.png`: share_plus would otherwise leave a copy in a
  /// new temp folder each time, under a path Windows can't open.
  Future<XFile> _png(double pixelRatio, Directory dir) async {
    final boundary =
        _preview.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      clearBoardShares(dir);
      dir.createSync(recursive: true);
      final file = File(
        '${dir.path}${Platform.pathSeparator}board-${isoDate(widget.day)}.png',
      );
      await file.writeAsBytes(png!.buffer.asUint8List());
      return XFile(file.path, mimeType: 'image/png');
    } finally {
      image.dispose();
    }
  }

  Future<void> _share(String text, {required bool image}) async {
    final l = context.l10n;
    final share = ref.read(shareProvider);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final sheet = ModalRoute.of(context);
    final shareDir = ref.read(boardShareDirProvider);
    final ratio = max(MediaQuery.devicePixelRatioOf(context), 2).toDouble();
    // Windows needs a title for its share UI; Android shows it on the chooser.
    final title = l.boardShareHeader(
      Formats(Localizations.localeOf(context)).shortDate(widget.day),
    );
    final box = context.findRenderObject() as RenderBox?;
    // iPad anchors the share popover here.
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    setState(() => _busy = true);
    try {
      await share(
        image
            ? ShareParams(
                files: [await _png(ratio, await shareDir())],
                title: title,
                sharePositionOrigin: origin,
              )
            : ShareParams(
                text: text,
                title: title,
                sharePositionOrigin: origin,
              ),
      );
      // The sheet may have been dismissed meanwhile; then popping would close the board.
      if (sheet?.isCurrent ?? false) navigator.pop();
    } on Object catch (e) {
      // Windows before 1809 can't share files; a platform failure is the generic message, never a raw error.
      showSnack(messenger, errorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = context.colors;
    final text = boardShareText(
      l,
      Localizations.localeOf(context),
      widget.day,
      widget.entries,
      titles: _titles,
      note: widget.note,
    );
    void Function()? share({required bool image}) =>
        _busy ? null : () => unawaited(_share(text, image: image));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(l.boardShareTitle, style: context.text.titleLarge),
        ),
        const SizedBox(height: 8),
        FocusRing(
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l.boardShareTitles),
            subtitle: Text(l.boardShareTitlesHint),
            value: _titles,
            onChanged: (v) => setState(() => _titles = v),
          ),
        ),
        const SizedBox(height: 8),
        Text(l.boardSharePreview, style: context.text.labelLarge),
        const SizedBox(height: 8),
        RepaintBoundary(
          key: _preview,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: c.surface,
              border: Border.all(color: c.line, width: c.borderWidth),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(text, style: context.text.bodyMedium),
            ),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: share(image: false),
          icon: const Icon(AppIcons.fileText),
          label: Text(l.boardShareAsText),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: share(image: true),
          icon: const Icon(AppIcons.image),
          label: Text(l.boardShareAsImage),
        ),
      ],
    );
  }
}
