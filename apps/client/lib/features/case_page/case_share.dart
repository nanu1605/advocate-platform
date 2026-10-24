import 'dart:async';

import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/case_text.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/features/board/board_share.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

/// Share case status as text (spec §4.3, §13.2): a live preview of exactly what goes out (case number, court, next
/// date and purpose, status, last update), the title (party names) only behind "Include the case title", never
/// clients. Through the OS share sheet, like the board.
Future<void> showCaseShareSheet(
  BuildContext context,
  CaseInfo c, {
  String? purpose,
}) => showAppBottomSheet<void>(
  context,
  builder: (_) => _CaseShareSheet(c, purpose: purpose),
);

class _CaseShareSheet extends ConsumerStatefulWidget {
  const _CaseShareSheet(this.c, {this.purpose});

  final CaseInfo c;
  final String? purpose;

  @override
  ConsumerState<_CaseShareSheet> createState() => _CaseShareSheetState();
}

class _CaseShareSheetState extends ConsumerState<_CaseShareSheet> {
  bool _titles = false;
  bool _busy = false;

  Future<void> _share(String text) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final sheet = ModalRoute.of(context);
    final box = context.findRenderObject() as RenderBox?;
    setState(() => _busy = true);
    try {
      await ref.read(shareProvider)(
        ShareParams(
          text: text,
          // Windows needs a title for its share UI.
          title: l.casePageShare,
          // iPad anchors the share popover here.
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
      if (sheet?.isCurrent ?? false) navigator.pop();
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(errorText(l, e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = context.colors;
    final text = caseShareText(
      l,
      Localizations.localeOf(context),
      widget.c,
      titles: _titles,
      purpose: widget.purpose,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(l.casePageShare, style: context.text.titleLarge),
        ),
        const SizedBox(height: 8),
        if (widget.c.title != null)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l.casePageShareTitles),
            subtitle: Text(l.boardShareTitlesHint),
            value: _titles,
            onChanged: (v) => setState(() => _titles = v),
          ),
        const SizedBox(height: 8),
        Text(l.boardSharePreview, style: context.text.labelLarge),
        const SizedBox(height: 8),
        DecoratedBox(
          decoration: BoxDecoration(
            color: c.surface,
            border: Border.all(color: c.line, width: c.borderWidth),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(text, style: context.text.bodyMedium),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _busy ? null : () => unawaited(_share(text)),
          icon: const Icon(AppIcons.shareNetwork),
          label: Text(l.boardShareAsText),
        ),
      ],
    );
  }
}
