import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/ui/icons.dart';
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
    this.proxy = false,
    this.note,
    this.semanticsLabel,
    this.onTap,
    this.actions = const [],
    this.menu,
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

  /// "Proxy arranged" (spec §4.2): someone else appears, so the row no longer clashes.
  final bool proxy;

  /// A line under the row, e.g. why it clashes.
  final String? note;

  /// The row as a screen reader says it ("WP 1234 of 2024. MP High Court Indore. Court 12, item 23. Clash."),
  /// in place of its visible text. Null reads the visible text.
  final String? semanticsLabel;

  /// Opens the case. The row is then one tap target and one keyboard stop (Enter opens it).
  final VoidCallback? onTap;

  /// Buttons under the row, e.g. a clash's Assign to and Mark proxy arranged.
  final List<Widget> actions;

  /// A trailing overflow menu (48 dp).
  final Widget? menu;
}

const _flex = [24, 20, 8, 14, 14, 12];

/// Tomorrow's Board: grouped list on phones, table on desktop (spec §4.2, §5.11 #21).
class BoardTable extends StatelessWidget {
  const BoardTable(this.rows, {super.key});

  final List<BoardRow> rows;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) =>
        box.maxWidth >= 840 ? _table(context) : _list(context),
  );

  /// The row's tap target (read as one item), its menu, then its note and actions.
  Widget _row(
    BuildContext context,
    BoardRow r,
    Widget content, {
    double inset = 0,
    bool reserveMenu = false,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: MergeSemantics(
              child: Semantics(
                button: r.onTap != null,
                label: r.semanticsLabel,
                excludeSemantics: r.semanticsLabel != null,
                onTap: r.onTap,
                child: InkWell(
                  onTap: r.onTap,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: content,
                  ),
                ),
              ),
            ),
          ),
          ?(r.menu ?? (reserveMenu ? const SizedBox(width: 48) : null)),
        ],
      ),
      if (r.note != null)
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(inset, 2, inset, 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  AppIcons.warning,
                  size: inlineIconSize(context, 16),
                  color: context.colors.of(StatusKind.urgent).fg,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(child: Text(r.note!, style: context.text.bodySmall)),
            ],
          ),
        ),
      if (r.actions.isNotEmpty)
        Padding(
          padding: EdgeInsetsDirectional.only(start: inset, bottom: 4),
          // 8 dp between targets, also when they wrap at 200% (spec §5.9).
          child: Wrap(spacing: 8, runSpacing: 8, children: r.actions),
        ),
    ],
  );

  /// The case number with its clash pill, which wraps under it when the text is large.
  Widget _caseLine(BuildContext context, BoardRow r) => Wrap(
    spacing: 8,
    runSpacing: 4,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text(r.caseNumber, style: context.text.titleSmall),
      if (r.clash) const StatusPill(PillKind.clash),
    ],
  );

  Widget _proxy(BuildContext context) {
    final s = context.colors.of(StatusKind.success);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            AppIcons.handshake,
            size: inlineIconSize(context, 16),
            color: s.fg,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              context.l10n.boardProxyArranged,
              style: context.text.bodySmall?.copyWith(color: s.fg),
            ),
          ),
        ],
      ),
    );
  }

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
          Semantics(
            header: true,
            child: Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 4),
              child: Text(
                '$court (${group.length})',
                style: context.text.titleMedium,
              ),
            ),
          ),
          for (final r in group)
            _row(
              context,
              r,
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _caseLine(context, r),
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
                        // Named, so the client and the colleague who appears can't be confused (no column headers).
                        if (r.client != null) l.boardClientIs(r.client!),
                        if (r.assignee != null) l.boardAssigneeIs(r.assignee!),
                      ].join(' · '),
                      style: context.text.bodySmall,
                    ),
                    if (r.proxy) _proxy(context),
                  ],
                ),
              ),
            ),
        ],
      ],
    );
  }

  /// One row per case in [_flex] columns; a Row rather than a Table so each case is one tap target.
  Widget _table(BuildContext context) {
    final l = context.l10n;
    final c = context.colors;
    final head = context.text.labelMedium?.copyWith(color: c.ink2);
    final menus = rows.any((r) => r.menu != null);
    Widget cells(List<Widget> children) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, child) in children.indexed)
          Expanded(
            flex: _flex[i],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: child,
            ),
          ),
      ],
    );
    Text txt(String? s, [TextStyle? style]) =>
        Text(s ?? '—', style: style ?? context.text.bodyMedium);
    final line = BoxDecoration(border: Border(bottom: c.lineSide));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          decoration: line,
          child: Row(
            children: [
              Expanded(
                child: cells([
                  for (final h in [
                    l.boardCase,
                    l.boardCourt,
                    l.boardItem,
                    l.boardPurpose,
                    l.boardClient,
                    l.boardAssignee,
                  ])
                    Text(h, style: head),
                ]),
              ),
              if (menus) const SizedBox(width: 48),
            ],
          ),
        ),
        for (final r in rows)
          DecoratedBox(
            decoration: line,
            child: _row(
              context,
              r,
              cells([
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _caseLine(context, r),
                    if (r.title != null) txt(r.title, context.text.bodySmall),
                    if (r.proxy) _proxy(context),
                  ],
                ),
                txt(
                  [
                    r.court,
                    if (r.courtNo != null) l.courtNo(r.courtNo!),
                  ].join(' · '),
                ),
                txt(r.itemNo),
                txt(r.purpose),
                txt(r.client),
                txt(r.assignee),
              ]),
              inset: 8,
              reserveMenu: menus,
            ),
          ),
      ],
    );
  }
}
