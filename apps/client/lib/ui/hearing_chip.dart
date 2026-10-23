import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:flutter/material.dart';

/// Relative label ("Tomorrow" / "कल") alongside the absolute date (spec §5.10), or null beyond a week.
String? relativeDay(BuildContext context, DateTime date, DateTime today) {
  final l = context.l10n;
  final d = DateTime(date.year, date.month, date.day);
  final t = DateTime(today.year, today.month, today.day);
  final diff = d.difference(t).inDays;
  return switch (diff) {
    0 => l.relToday,
    1 => l.relTomorrow,
    -1 => l.relYesterday,
    > 1 && <= 7 => l.relInDays(diff),
    < -1 && >= -7 => l.relDaysAgo(-diff),
    _ => null,
  };
}

class HearingChip extends StatelessWidget {
  const HearingChip({required this.date, this.today, super.key});

  final DateTime? date;

  /// Injected in tests and goldens; defaults to now.
  final DateTime? today;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final d = date;
    final label = d == null
        ? context.l10n.noDate
        : [
            Formats(Localizations.localeOf(context)).date(d),
            ?relativeDay(context, d, today ?? DateTime.now()),
          ].join(' · ');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.line, width: c.borderWidth),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            AppIcons.calendarBlank,
            size: inlineIconSize(context, 16),
            color: c.ink2,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: context.text.bodySmall?.copyWith(color: c.ink),
            ),
          ),
        ],
      ),
    );
  }
}
