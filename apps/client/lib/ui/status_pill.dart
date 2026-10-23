import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:flutter/material.dart';

enum PillKind { listed, newOrder, adjourned, urgent, disposed, manual, clash }

/// Status pill: always icon + text, never colour alone (spec §5.6). Sunlight: coloured border on white.
class StatusPill extends StatelessWidget {
  const StatusPill(this.kind, {super.key});

  final PillKind kind;

  static StatusKind colorKind(PillKind k) => switch (k) {
    PillKind.listed => StatusKind.listed,
    PillKind.newOrder => StatusKind.newOrder,
    PillKind.adjourned => StatusKind.adjourned,
    PillKind.urgent || PillKind.clash => StatusKind.urgent,
    PillKind.disposed || PillKind.manual => StatusKind.disposed,
  };

  static IconData icon(PillKind k) => switch (k) {
    PillKind.listed => AppIcons.calendarCheck,
    PillKind.newOrder => AppIcons.fileText,
    PillKind.adjourned => AppIcons.clockCounterClockwise,
    PillKind.urgent => AppIcons.warning,
    PillKind.disposed => AppIcons.archive,
    PillKind.manual => AppIcons.pencilSimple,
    PillKind.clash => AppIcons.arrowsLeftRight,
  };

  static String label(BuildContext context, PillKind k) {
    final l = context.l10n;
    return switch (k) {
      PillKind.listed => l.statusListed,
      PillKind.newOrder => l.statusNewOrder,
      PillKind.adjourned => l.statusAdjourned,
      PillKind.urgent => l.statusUrgent,
      PillKind.disposed => l.statusDisposed,
      PillKind.manual => l.statusManual,
      PillKind.clash => l.statusClash,
    };
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = c.of(colorKind(kind));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: ShapeDecoration(
        color: s.bg,
        shape: StadiumBorder(
          side: c.isSunlight
              ? BorderSide(color: s.fg, width: c.borderWidth)
              : BorderSide.none,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon(kind), size: inlineIconSize(context, 14), color: s.fg),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label(context, kind),
              style: context.text.labelSmall?.copyWith(color: s.fg),
            ),
          ),
        ],
      ),
    );
  }
}
