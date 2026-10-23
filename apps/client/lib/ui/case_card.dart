import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/ui/court_badge.dart';
import 'package:advocate_app/ui/hearing_chip.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/status_pill.dart';
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

/// Case card (spec §5.11 #2). Hero = next matter on Today; list = Cases list; compact = dense rows.
class CaseCard extends StatelessWidget {
  const CaseCard(
    this.data, {
    this.variant = CaseCardVariant.list,
    this.actions = const [],
    this.onTap,
    this.today,
    super.key,
  });

  final CaseCardData data;
  final CaseCardVariant variant;

  /// Hero only: e.g. Open · Notes · Brief me.
  final List<Widget> actions;
  final VoidCallback? onTap;
  final DateTime? today;

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
      ],
    );

    final body = <Widget>[
      number,
      const SizedBox(height: 2),
      Text(
        data.title,
        maxLines: compact ? 1 : 2,
        overflow: TextOverflow.ellipsis,
        style: t.bodyLarge?.copyWith(color: c.ink2),
      ),
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

    return Card(
      color: hero && !c.isSunlight ? c.primarySoft : null,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: EdgeInsets.all(compact ? 12 : 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: body,
          ),
        ),
      ),
    );
  }
}
