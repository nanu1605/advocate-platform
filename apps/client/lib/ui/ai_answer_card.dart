import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/core/theme/tokens.g.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/source_chip.dart';
import 'package:flutter/material.dart';

/// One line of an AI answer and the sources it rests on (spec §12.1: every claim tied to a source).
@immutable
class AnswerLine {
  const AnswerLine(this.text, {this.sources = const []});

  final String text;
  final List<SourceChip> sources;
}

/// AI output beside the work (spec §5.1, §5.11 #7): the AI badge, the answer line by line with its sources, the
/// actions, and a footer saying to check it. Copy, insert, undo and report show when they are given.
class AIAnswerCard extends StatelessWidget {
  const AIAnswerCard({
    required this.lines,
    this.title,
    this.onCopy,
    this.onInsert,
    this.onUndo,
    this.onReport,
    super.key,
  });

  final List<AnswerLine> lines;
  final String? title;
  final VoidCallback? onCopy;
  final VoidCallback? onInsert;
  final VoidCallback? onUndo;
  final VoidCallback? onReport;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l = context.l10n;
    final ai = c.of(StatusKind.ai);
    final actions = [
      if (onCopy != null) (AppIcons.copy, l.aiCopy, onCopy!),
      if (onInsert != null) (AppIcons.arrowSquareIn, l.aiInsert, onInsert!),
      if (onUndo != null) (AppIcons.arrowCounterClockwise, l.undo, onUndo!),
      if (onReport != null) (AppIcons.flag, l.aiReport, onReport!),
    ];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: c.line, width: c.borderWidth),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: ShapeDecoration(
                  color: ai.bg,
                  shape: StadiumBorder(
                    side: c.isSunlight
                        ? BorderSide(color: ai.fg, width: c.borderWidth)
                        : BorderSide.none,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      AppIcons.sparkle,
                      size: inlineIconSize(context, 14),
                      color: ai.fg,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      l.aiBadge,
                      style: context.text.labelSmall?.copyWith(color: ai.fg),
                    ),
                  ],
                ),
              ),
              if (title != null) Text(title!, style: context.text.titleSmall),
            ],
          ),
          for (final line in lines) ...[
            const SizedBox(height: 12),
            Text(line.text, style: context.text.bodyLarge),
            if (line.sources.isNotEmpty) ...[
              const SizedBox(height: 4),
              Wrap(spacing: 8, runSpacing: 8, children: line.sources),
            ],
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 8),
            // 8 dp between targets (spec §5.9).
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (icon, label, onPressed) in actions)
                  TextButton.icon(
                    onPressed: onPressed,
                    icon: Icon(icon),
                    label: Text(label),
                  ),
              ],
            ),
          ],
          Divider(height: 24, color: c.line),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                AppIcons.info,
                size: inlineIconSize(context, 18),
                color: c.ink2,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l.aiVerifyFooter,
                  style: context.text.bodySmall?.copyWith(color: c.ink2),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
