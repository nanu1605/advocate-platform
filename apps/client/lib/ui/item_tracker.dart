import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/core/theme/motion.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';

/// A member's report of the item a court is at (spec F21): team-shared until a permitted source exists.
@immutable
class CourtUpdate {
  const CourtUpdate({required this.item, required this.at, required this.by});

  final int item;
  final DateTime at;

  /// Who posted it.
  final String by;
}

/// The live item tracker (spec F21, §5.11 #20): where [court] is against this matter's cause-list item [mine], from
/// the latest team [update]. After 20 minutes it fades and says it may be out of date; the caller drops it after
/// 2 hours. The bar eases to the new position and the count ticks (spec §5.5); changes are read out (spec §5.9).
class ItemTracker extends StatelessWidget {
  const ItemTracker({
    required this.court,
    required this.mine,
    this.update,
    this.now,
    this.onUpdate,
    super.key,
  });

  /// "Court 12".
  final String court;
  final int mine;
  final CourtUpdate? update;

  /// Injected in tests and goldens; defaults to now.
  final DateTime? now;

  /// Post the item the court is at now.
  final VoidCallback? onUpdate;

  static const fadeAfter = Duration(minutes: 20);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l = context.l10n;
    final m = Motion.of(context);
    final small = context.text.bodySmall?.copyWith(color: c.ink2);
    final u = update;
    final button = onUpdate == null
        ? null
        : OutlinedButton.icon(
            onPressed: onUpdate,
            icon: const Icon(AppIcons.pencilSimple),
            label: Text(l.trackerUpdate),
          );
    if (u == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l.trackerNone, style: context.text.bodyLarge),
          Text(l.trackerYourItem(mine), style: small),
          if (button != null) ...[const SizedBox(height: 8), button],
        ],
      );
    }
    final age = (now ?? DateTime.now()).difference(u.at);
    final stale = age > fadeAfter;
    final away = mine - u.item;
    String headline(int n) => n > 0
        ? l.trackerAway(n)
        : n == 0
        ? l.trackerNow
        : l.trackerPassed;
    final tone = stale
        ? c.ink2
        : away <= 0
        ? c.of(StatusKind.urgent).fg
        : c.ink;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l.trackerAt(court, u.item), style: context.text.bodyLarge),
        const SizedBox(height: 4),
        AnnouncedText(
          headline(away),
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: away.toDouble()),
            duration: m.base,
            curve: m.standard,
            builder: (context, v, _) => Text(
              headline(v.round()),
              style: context.text.titleMedium?.copyWith(color: tone),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: c.outline, width: c.borderWidth),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: mine > 0 ? (u.item / mine).clamp(0, 1) : 1),
              duration: m.base,
              curve: m.standard,
              builder: (context, v, _) => LinearProgressIndicator(
                value: v,
                minHeight: 8,
                color: stale ? c.outline : c.primaryFill,
                backgroundColor: c.surfaceAlt,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          [
            l.trackerYourItem(mine),
            l.trackerUpdated(age.inMinutes.clamp(0, 999), u.by),
            if (stale) l.trackerStale,
          ].join(' · '),
          style: small,
        ),
        if (button != null) ...[const SizedBox(height: 8), button],
      ],
    );
  }
}
