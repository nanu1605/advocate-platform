import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/core/theme/tokens.g.dart';
import 'package:advocate_app/ui/court_badge.dart';
import 'package:advocate_app/ui/hearing_chip.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/status_pill.dart';
import 'package:advocate_app/ui/tiles.dart';
import 'package:flutter/material.dart';

enum CaseCardVariant { hero, list, compact }

enum CaseCardState {
  normal,
  listed,
  newOrder,
  adjourned,
  disposed,
  manual,
  syncing,
  error,
}

@immutable
class CaseCardData {
  const CaseCardData({
    required this.caseNumber,
    required this.title,
    required this.court,
    this.courtNo,
    this.itemNo,
    this.judge,
    this.purpose,
    this.nextDate,
    this.assignee,
    this.state = CaseCardState.normal,
  });

  final String caseNumber;
  final String title;
  final String court;
  final String? courtNo;
  final String? itemNo;
  final String? judge;
  final String? purpose;
  final DateTime? nextDate;

  /// Who the case is assigned to: list and compact cards show their initials.
  final String? assignee;
  final CaseCardState state;
}

PillKind? _pill(CaseCardState s) => switch (s) {
  CaseCardState.listed => PillKind.listed,
  CaseCardState.newOrder => PillKind.newOrder,
  CaseCardState.adjourned => PillKind.adjourned,
  CaseCardState.disposed => PillKind.disposed,
  CaseCardState.manual => PillKind.manual,
  CaseCardState.error => PillKind.urgent,
  CaseCardState.normal || CaseCardState.syncing => null,
};

/// Case card (spec §5.11 #2). Hero = next matter on Today; list = a roomy row; compact = Cases list rows (court and
/// next date on one line; an empty title and a missing date are left out). Titles show two lines at most (§5.7).
class CaseCard extends StatelessWidget {
  const CaseCard(
    this.data, {
    this.variant = CaseCardVariant.list,
    this.actions = const [],
    this.onTap,
    this.today,
    this.selected = false,
    this.semanticsLabel,
    this.autofocus = false,
    super.key,
  });

  final CaseCardData data;
  final CaseCardVariant variant;

  /// Hero only: e.g. Open · Notes · Brief me.
  final List<Widget> actions;
  final VoidCallback? onTap;
  final DateTime? today;

  /// The case open beside the list (Windows two panes): a primary border.
  final bool selected;

  /// The card as a screen reader says it, in place of its visible text; the card is then one item.
  final String? semanticsLabel;

  /// Takes keyboard focus when first built (the selected row of a list that was just rebuilt).
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final hero = variant == CaseCardVariant.hero;
    final compact = variant == CaseCardVariant.compact;
    final pill = _pill(data.state);

    final number = Row(
      children: [
        Expanded(
          child: Text(
            data.caseNumber,
            style: hero ? t.titleMedium : t.titleSmall,
          ),
        ),
        if (data.state == CaseCardState.syncing)
          Icon(AppIcons.arrowsClockwise, size: 18, color: c.ink3),
        if (pill != null) StatusPill(pill),
        if (data.assignee != null && !hero) ...[
          const SizedBox(width: 8),
          // Grows with the text so large initials stay inside the circle (spec §5.9).
          Avatar(
            data.assignee!,
            size: 16 + MediaQuery.textScalerOf(context).scale(16),
          ),
        ],
      ],
    );

    final body = <Widget>[
      number,
      if (data.title.isNotEmpty) ...[
        const SizedBox(height: 2),
        Text(
          data.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: t.bodyLarge?.copyWith(color: c.ink2),
        ),
      ],
      if (compact) ...[
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            CourtBadge(court: data.court, courtNo: data.courtNo),
            if (data.nextDate != null)
              HearingChip(date: data.nextDate, today: today),
          ],
        ),
      ],
      if (!compact) ...[
        const SizedBox(height: 8),
        CourtBadge(
          court: data.court,
          courtNo: data.courtNo,
          itemNo: data.itemNo,
        ),
      ],
      if (hero && (data.judge != null || data.purpose != null)) ...[
        const SizedBox(height: 4),
        Text([?data.judge, ?data.purpose].join(' · '), style: t.bodySmall),
      ],
      if (!compact) ...[
        const SizedBox(height: 8),
        HearingChip(date: data.nextDate, today: today),
      ],
      if (hero && actions.isNotEmpty) ...[
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: actions),
      ],
    ];

    final card = Card(
      color: (hero || selected) && !c.isSunlight ? c.primarySoft : null,
      shape: selected
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Radii.card),
              side: BorderSide(color: c.primary, width: 2),
            )
          : null,
      child: InkWell(
        onTap: onTap,
        autofocus: autofocus,
        borderRadius: BorderRadius.circular(Radii.card),
        child: Padding(
          padding: EdgeInsets.all(compact ? 12 : 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: body,
          ),
        ),
      ),
    );
    final spoken = semanticsLabel;
    return spoken == null
        ? card
        : Semantics(
            container: true,
            button: onTap != null,
            selected: selected ? true : null,
            label: spoken,
            excludeSemantics: true,
            onTap: onTap,
            child: card,
          );
  }
}
