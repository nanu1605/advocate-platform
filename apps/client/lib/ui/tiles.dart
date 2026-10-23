import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/status_pill.dart';
import 'package:flutter/material.dart';

/// Initials avatar; colour picked from the status palette by a stable name hash (spec §5.11 #19).
class Avatar extends StatelessWidget {
  const Avatar(this.name, {this.size = 40, super.key});

  final String name;
  final double size;

  static const List<StatusKind> _kinds = [
    StatusKind.listed,
    StatusKind.newOrder,
    StatusKind.adjourned,
    StatusKind.success,
    StatusKind.ai,
  ];

  static String initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    return parts.take(2).map((p) => p.characters.first.toUpperCase()).join();
  }

  @override
  Widget build(BuildContext context) {
    final hash = name.codeUnits.fold<int>(
      0,
      (h, c) => (h * 31 + c) & 0x7fffffff,
    );
    final s = context.colors.of(_kinds[hash % _kinds.length]);
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: s.bg,
          shape: BoxShape.circle,
          border: context.colors.isSunlight
              ? Border.all(color: s.fg, width: context.colors.borderWidth)
              : null,
        ),
        child: Text(
          initials(name),
          style: context.text.titleSmall?.copyWith(color: s.fg),
        ),
      ),
    );
  }
}

class ClientTile extends StatelessWidget {
  const ClientTile({
    required this.name,
    required this.caseCount,
    this.phone,
    this.onTap,
    super.key,
  });

  final String name;
  final int caseCount;
  final String? phone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    onTap: onTap,
    minVerticalPadding: 12,
    leading: Avatar(name),
    title: Text(name, style: context.text.titleSmall),
    subtitle: Text(
      [?phone, context.l10n.linkedCases(caseCount)].join(' · '),
      style: context.text.bodySmall,
    ),
  );
}

class TaskItem extends StatelessWidget {
  const TaskItem({
    required this.title,
    required this.done,
    required this.onChanged,
    this.due,
    this.assignee,
    this.overdue = false,
    super.key,
  });

  final String title;
  final bool done;
  final ValueChanged<bool> onChanged;
  final String? due;
  final String? assignee;
  final bool overdue;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return CheckboxListTile(
      value: done,
      onChanged: (v) => onChanged(v ?? false),
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: EdgeInsets.zero,
      title: Text(
        title,
        style: context.text.bodyLarge?.copyWith(
          decoration: done ? TextDecoration.lineThrough : null,
          color: done ? c.ink3 : c.ink,
        ),
      ),
      subtitle: due == null && assignee == null
          ? null
          : Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (due != null)
                  Text(
                    context.l10n.taskDue(due!),
                    style: context.text.bodySmall?.copyWith(
                      color: overdue ? c.of(StatusKind.urgent).fg : null,
                    ),
                  ),
                if (overdue) const StatusPill(PillKind.urgent),
                if (assignee != null)
                  Text(assignee!, style: context.text.bodySmall),
              ],
            ),
    );
  }
}

class DocumentTile extends StatelessWidget {
  const DocumentTile({
    required this.title,
    required this.kind,
    this.pages,
    this.offline = false,
    this.onTap,
    super.key,
  });

  final String title;

  /// Pleadings, Orders, Evidence … (translated by the caller).
  final String kind;
  final int? pages;
  final bool offline;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListTile(
      onTap: onTap,
      minVerticalPadding: 12,
      leading: Icon(AppIcons.filePdf, size: 32, color: c.ink2),
      title: Text(
        title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: context.text.titleSmall,
      ),
      subtitle: Text(
        [kind, if (pages != null) context.l10n.pages(pages!)].join(' · '),
        style: context.text.bodySmall,
      ),
      trailing: offline
          ? Icon(
              AppIcons.downloadSimpleFill,
              color: c.of(StatusKind.success).fg,
              semanticLabel: context.l10n.availableOffline,
            )
          : null,
    );
  }
}

enum TimelineKind { hearing, order }

/// Hearing or order on the case timeline, newest first.
class TimelineItem extends StatelessWidget {
  const TimelineItem({
    required this.date,
    required this.kind,
    required this.title,
    this.detail,
    this.isNew = false,
    this.isLast = false,
    this.action,
    super.key,
  });

  final String date;
  final TimelineKind kind;
  final String title;
  final String? detail;
  final bool isNew;
  final bool isLast;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 72,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(date, style: context.text.bodySmall),
            ),
          ),
          Column(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: c.surface,
                  shape: BoxShape.circle,
                  border: Border.all(color: c.outline, width: c.borderWidth),
                ),
                child: Icon(
                  kind == TimelineKind.order
                      ? AppIcons.fileText
                      : AppIcons.gavel,
                  size: 16,
                  color: c.ink2,
                ),
              ),
              if (!isLast)
                Expanded(child: VerticalDivider(color: c.line, width: 28)),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(title, style: context.text.titleSmall),
                      if (isNew) const StatusPill(PillKind.newOrder),
                    ],
                  ),
                  if (detail != null)
                    Text(detail!, style: context.text.bodySmall),
                  ?action,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
