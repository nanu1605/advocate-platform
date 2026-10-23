import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/ui/status_pill.dart';
import 'package:flutter/material.dart';

@immutable
class BoardRow {
  const BoardRow({
    required this.caseNumber,
    required this.court,
    this.title,
    this.courtNo,
    this.itemNo,
    this.purpose,
    this.client,
    this.assignee,
    this.clash = false,
  });

  final String caseNumber;
  final String court;
  final String? title;
  final String? courtNo;
  final String? itemNo;
  final String? purpose;
  final String? client;
  final String? assignee;
  final bool clash;
}

/// Tomorrow's Board: grouped list on phones, table on desktop (spec §4.2, §5.11 #21).
class BoardTable extends StatelessWidget {
  const BoardTable(this.rows, {super.key});

  final List<BoardRow> rows;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) =>
        box.maxWidth >= 840 ? _table(context) : _list(context),
  );

  Widget _list(BuildContext context) {
    final l = context.l10n;
    final byCourt = <String, List<BoardRow>>{};
    for (final r in rows) {
      (byCourt[r.court] ??= []).add(r);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final MapEntry(key: court, value: group) in byCourt.entries) ...[
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Text(
              '$court (${group.length})',
              style: context.text.titleMedium,
            ),
          ),
          for (final r in group)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.caseNumber, style: context.text.titleSmall),
                        if (r.title != null)
                          Text(
                            r.title!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: context.text.bodySmall,
                          ),
                        Text(
                          [
                            if (r.courtNo != null) l.courtNo(r.courtNo!),
                            if (r.itemNo != null) l.itemNo(r.itemNo!),
                            ?r.purpose,
                            ?r.assignee,
                          ].join(' · '),
                          style: context.text.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if (r.clash) const StatusPill(PillKind.clash),
                ],
              ),
            ),
        ],
      ],
    );
  }

  Widget _table(BuildContext context) {
    final l = context.l10n;
    final c = context.colors;
    final head = context.text.labelMedium?.copyWith(color: c.ink2);
    TableCell cell(Widget child) => TableCell(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: child,
      ),
    );
    Text txt(String? s, [TextStyle? style]) =>
        Text(s ?? '—', style: style ?? context.text.bodyMedium);
    return Table(
      columnWidths: const {
        0: FlexColumnWidth(2.4),
        1: FlexColumnWidth(2),
        2: FlexColumnWidth(0.8),
        3: FlexColumnWidth(1.4),
        4: FlexColumnWidth(1.4),
        5: FlexColumnWidth(1.2),
      },
      border: TableBorder(horizontalInside: c.lineSide, bottom: c.lineSide),
      children: [
        TableRow(
          children: [
            for (final h in [
              l.boardCase,
              l.boardCourt,
              l.boardItem,
              l.boardPurpose,
              l.boardClient,
              l.boardAssignee,
            ])
              cell(Text(h, style: head)),
          ],
        ),
        for (final r in rows)
          TableRow(
            children: [
              cell(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: txt(r.caseNumber, context.text.titleSmall),
                        ),
                        if (r.clash) ...[
                          const SizedBox(width: 8),
                          const StatusPill(PillKind.clash),
                        ],
                      ],
                    ),
                    if (r.title != null) txt(r.title, context.text.bodySmall),
                  ],
                ),
              ),
              cell(
                txt(
                  [
                    r.court,
                    if (r.courtNo != null) l.courtNo(r.courtNo!),
                  ].join(' · '),
                ),
              ),
              cell(txt(r.itemNo)),
              cell(txt(r.purpose)),
              cell(txt(r.client)),
              cell(txt(r.assignee)),
            ],
          ),
      ],
    );
  }
}
