import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/core/theme/tokens.g.dart';
import 'package:advocate_app/ui/focus_ring.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:flutter/material.dart';

/// A citation's check (spec §12.7): shown as an icon and a word, never colour alone.
enum CitationCheck { verified, needsReview, notFound, checkManually }

/// A source an AI answer rests on, e.g. "Order dated 28-10-2026 · p. 3 · para 4". Tapping it opens the source at
/// that page and paragraph (spec §5.1). With [check] it is a citation chip showing the citation's check status
/// (spec §5.11 #8).
class SourceChip extends StatelessWidget {
  const SourceChip(
    this.label, {
    this.page,
    this.paragraph,
    this.check,
    this.onTap,
    super.key,
  });

  final String label;
  final int? page;
  final int? paragraph;
  final CitationCheck? check;

  /// Opens the source at [page] and [paragraph].
  final VoidCallback? onTap;

  static StatusKind colorKind(CitationCheck c) => switch (c) {
    CitationCheck.verified => StatusKind.success,
    CitationCheck.needsReview => StatusKind.adjourned,
    CitationCheck.notFound => StatusKind.urgent,
    CitationCheck.checkManually => StatusKind.disposed,
  };

  static IconData icon(CitationCheck c) => switch (c) {
    CitationCheck.verified => AppIcons.sealCheck,
    CitationCheck.needsReview => AppIcons.sealWarning,
    CitationCheck.notFound => AppIcons.xCircle,
    CitationCheck.checkManually => AppIcons.sealQuestion,
  };

  static String checkLabel(BuildContext context, CitationCheck c) {
    final l = context.l10n;
    return switch (c) {
      CitationCheck.verified => l.citationVerified,
      CitationCheck.needsReview => l.citationNeedsReview,
      CitationCheck.notFound => l.citationNotFound,
      CitationCheck.checkManually => l.citationCheckManually,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = context.colors;
    final p = page;
    final para = paragraph;
    final status = check == null ? null : checkLabel(context, check!);
    final shown = [
      label,
      if (p != null) l.sourcePage(p),
      if (para != null) l.sourcePara(para),
      ?status,
    ].join(' · ');
    // "p. 3" read out as words.
    final spoken = [
      label,
      if (p != null) l.sourcePageSpoken(p),
      if (para != null) l.sourceParaSpoken(para),
      ?status,
    ].join(', ');
    final s = check == null ? null : c.of(colorKind(check!));
    final fg = s?.fg ?? c.ink;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Radii.input),
      side: BorderSide(color: c.outline, width: c.borderWidth),
    );
    // Not a Material chip: a chip's label can't wrap, and a long citation must at 200% text (spec §5.9).
    return Semantics(
      button: true,
      label: spoken,
      onTap: onTap,
      excludeSemantics: true,
      child: FocusRing(
        child: Material(
          color: s?.bg ?? c.surface,
          shape: shape,
          child: InkWell(
            onTap: onTap,
            customBorder: shape,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      check == null ? AppIcons.fileText : icon(check!),
                      size: inlineIconSize(context, 18),
                      color: s?.fg ?? c.ink2,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        shown,
                        style: context.text.bodySmall?.copyWith(color: fg),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
