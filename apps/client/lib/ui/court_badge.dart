import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:flutter/material.dart';

/// "MPHC Indore · Court 12 · Item 23". Court short names and numbers stay in Latin script (spec §5.7).
class CourtBadge extends StatelessWidget {
  const CourtBadge({required this.court, this.courtNo, this.itemNo, super.key});

  final String court;
  final String? courtNo;
  final String? itemNo;

  static String text(
    BuildContext context,
    String court,
    String? no,
    String? item,
  ) {
    final l = context.l10n;
    return [
      court,
      if (no != null) l.courtNo(no),
      if (item != null) l.itemNo(item),
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Icon(
          AppIcons.bank,
          size: inlineIconSize(context, 16),
          color: context.colors.ink2,
        ),
      ),
      const SizedBox(width: 6),
      Flexible(
        child: Text(
          text(context, court, courtNo, itemNo),
          style: context.text.bodySmall,
        ),
      ),
    ],
  );
}
