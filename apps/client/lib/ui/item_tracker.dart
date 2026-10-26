import 'dart:async';

import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/core/theme/motion.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';

/// A report of the item a court is at (spec F21): a member's, until a permitted source exists.
@immutable
class CourtUpdate {
  const CourtUpdate({required this.item, required this.at, this.by});

  /// As the cause list writes it: "18", or "S-12" on a supplementary list.
  final String item;
  final DateTime at;

  /// Who posted it; null for a source, or a member who has left.
  final String? by;
}

/// The numbers of [mine] and [current] when they are on the same list ("S-5" and "S-12" are, "18" and "S-12" aren't);
/// null when they can't be compared.
(int, int)? _numbers(String mine, String current) {
  final re = RegExp(r'^(\D*?)(\d+)$');
  final a = re.firstMatch(mine.trim());
  final b = re.firstMatch(current.trim());
  if (a == null || b == null || a[1]!.toLowerCase() != b[1]!.toLowerCase()) {
    return null;
  }
  return (int.parse(a[2]!), int.parse(b[2]!));
}

/// The live item tracker (spec F21, §5.11 #20): where [court] is against this matter's cause-list item [mine], from
/// the latest [update]. After 20 minutes it fades and says it may be out of date; the caller drops it after 2 hours.
/// The bar eases to the new position and the count ticks (spec §5.5); a move is read out (spec §5.9).
class ItemTracker extends StatefulWidget {
  const ItemTracker({
    required this.court,
    required this.mine,
    this.update,
    this.clock = DateTime.now,
    this.onUpdate,
    super.key,
  });

  /// "Court 12".
  final String court;

  /// This matter's item, as the cause list writes it.
  final String mine;
  final CourtUpdate? update;

  /// Now, as an instant (not an IST wall-clock time); read each minute so the update ages and fades on its own.
  final DateTime Function() clock;

  /// Post the item the court is at now.
  final VoidCallback? onUpdate;

  static const fadeAfter = Duration(minutes: 20);

  @override
  State<ItemTracker> createState() => _ItemTrackerState();
}

class _ItemTrackerState extends State<ItemTracker> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(ItemTracker old) {
    super.didUpdateWidget(old);
    if ((old.update == null) != (widget.update == null)) _schedule();
  }

  void _schedule() {
    _tick?.cancel();
    _tick = widget.update == null
        ? null
        : Timer.periodic(const Duration(minutes: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l = context.l10n;
    final m = Motion.of(context);
    final small = context.text.bodySmall?.copyWith(color: c.ink2);
    final u = widget.update;
    final mine = widget.mine;
    final button = widget.onUpdate == null
        ? null
        : OutlinedButton.icon(
            onPressed: widget.onUpdate,
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
    final age = widget.clock().difference(u.at);
    final minutes = age.inMinutes.clamp(0, 999);
    final stale = age > ItemTracker.fadeAfter;
    final numbers = _numbers(mine, u.item);
    String headline(int n) => n > 0
        ? l.trackerAway(n)
        : n == 0
        ? l.trackerNow
        : l.trackerPassed;
    final by = u.by;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l.trackerAt(widget.court, u.item), style: context.text.bodyLarge),
        if (numbers case (final mineNo, final at)) ...[
          const SizedBox(height: 4),
          AnnouncedText(
            headline(mineNo - at),
            onShow: false,
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: (mineNo - at).toDouble()),
              duration: m.base,
              curve: m.standard,
              builder: (context, v, _) => Text(
                headline(v.round()),
                style: context.text.titleMedium?.copyWith(
                  color: stale
                      ? c.ink2
                      : mineNo <= at
                      ? c.of(StatusKind.urgent).fg
                      : c.ink,
                ),
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
                tween: Tween(end: mineNo > 0 ? (at / mineNo).clamp(0, 1) : 1),
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
        ],
        const SizedBox(height: 8),
        Text(
          [
            l.trackerYourItem(mine),
            if (by == null)
              l.trackerUpdatedAgo(minutes)
            else
              l.trackerUpdated(minutes, by),
            if (stale) l.trackerStale,
          ].join(' · '),
          style: small,
        ),
        if (button != null) ...[const SizedBox(height: 8), button],
      ],
    );
  }
}
