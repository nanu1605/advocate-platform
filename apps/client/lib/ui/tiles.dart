import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/core/theme/tokens.g.dart';
import 'package:advocate_app/ui/focus_ring.dart';
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
        // Initials stay inside the circle, shrunk if they must (200% text; the name is beside them).
        padding: EdgeInsets.symmetric(horizontal: size * 0.1),
        decoration: BoxDecoration(
          color: s.bg,
          shape: BoxShape.circle,
          border: context.colors.isSunlight
              ? Border.all(color: s.fg, width: context.colors.borderWidth)
              : null,
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            initials(name),
            style: context.text.titleSmall?.copyWith(color: s.fg),
          ),
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
    this.selected = false,
    this.autofocus = false,
    this.semanticsLabel,
    super.key,
  });

  final String name;
  final int caseCount;
  final String? phone;
  final VoidCallback? onTap;

  /// The client open beside the list (Windows two panes): a primary border, as on a selected case card.
  final bool selected;

  /// Takes keyboard focus when first built (the selected row of a list that was just rebuilt).
  final bool autofocus;

  /// The row as a screen reader says it, in place of its visible text; the row is then one item.
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tile = FocusRing(
      radius: Radii.card,
      selected: selected,
      child: ListTile(
        onTap: onTap,
        autofocus: autofocus,
        selected: selected,
        selectedTileColor: c.isSunlight ? null : c.primarySoft,
        shape: selected
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Radii.card),
                side: BorderSide(color: c.primary, width: 2),
              )
            : null,
        minVerticalPadding: 12,
        // Grows with the text so large initials stay inside the circle (spec §5.9): 40 dp at 100%.
        leading: Avatar(
          name,
          size: 24 + MediaQuery.textScalerOf(context).scale(16),
        ),
        title: Text(name, style: context.text.titleSmall),
        subtitle: Text(
          [?phone, context.l10n.linkedCases(caseCount)].join(' · '),
          style: context.text.bodySmall,
        ),
      ),
    );
    final spoken = semanticsLabel;
    return spoken == null
        ? tile
        : Semantics(
            container: true,
            button: onTap != null,
            selected: selected ? true : null,
            label: spoken,
            excludeSemantics: true,
            onTap: onTap,
            child: tile,
          );
  }
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
    return FocusRing(
      child: CheckboxListTile(
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
                  if (overdue) const StatusPill(PillKind.overdue),
                  if (assignee != null)
                    Text(assignee!, style: context.text.bodySmall),
                ],
              ),
      ),
    );
  }
}

/// What a document row says besides its line (spec §4.3): the server's safety check, or where its upload is.
enum DocState { checking, blocked, waiting, uploading, failed }

class DocumentTile extends StatelessWidget {
  const DocumentTile({
    required this.title,
    required this.kind,
    this.mime,
    this.pages,
    this.offline = false,
    this.state,
    this.progress,
    this.error,
    this.trailing,
    this.onTap,
    super.key,
  });

  final String title;

  /// The line under the title: Pleadings, Orders, Evidence …, with size and case (translated by the caller).
  final String kind;

  /// Picks the icon: PDF (default), image or Word.
  final String? mime;
  final int? pages;

  /// A copy is on this device: "Available offline" (when there is no [state]).
  final bool offline;
  final DocState? state;

  /// [DocState.uploading]'s share sent, 0–1.
  final double? progress;

  /// [DocState.failed]'s reason (translated by the caller).
  final String? error;

  /// e.g. the Keep offline toggle, or Remove.
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l = context.l10n;
    final percent = ((progress ?? 0) * 100).floor();
    // Always an icon with the words, never colour alone (spec §5.6).
    final status = switch (state) {
      DocState.checking => (AppIcons.clock, null, l.docsStateChecking),
      DocState.blocked => (
        AppIcons.shieldWarning,
        StatusKind.urgent,
        l.docsStateBlocked,
      ),
      DocState.waiting => (
        AppIcons.cloudArrowUp,
        StatusKind.adjourned,
        l.docsStateWaiting,
      ),
      DocState.uploading => (
        AppIcons.cloudArrowUp,
        StatusKind.listed,
        l.docsStateUploading(percent),
      ),
      DocState.failed => (
        AppIcons.warningCircle,
        StatusKind.urgent,
        error ?? l.errorGeneric,
      ),
      null when offline => (
        AppIcons.downloadSimpleFill,
        StatusKind.success,
        l.availableOffline,
      ),
      null => null,
    };
    final small = context.text.bodySmall;
    final tile = ListTile(
      onTap: onTap,
      minVerticalPadding: 12,
      leading: Icon(
        switch (mime) {
          'image/jpeg' || 'image/png' => AppIcons.fileImage,
          final m? when m.contains('wordprocessingml') => AppIcons.fileDoc,
          _ => AppIcons.filePdf,
        },
        size: 32,
        color: c.ink2,
      ),
      title: Text(
        title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: context.text.titleSmall,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [kind, if (pages != null) l.pages(pages!)].join(' · '),
            style: small,
          ),
          if (status case (final icon, final kind, final text)) ...[
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  icon,
                  size: inlineIconSize(context, 16),
                  color: kind == null ? c.ink2 : c.of(kind).fg,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    text,
                    style: small?.copyWith(
                      color: kind == null ? null : c.of(kind).fg,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (state == DocState.uploading) ...[
            const SizedBox(height: 6),
            // The theme's track is the bar's own colour: give it the status tint.
            LinearProgressIndicator(
              value: progress ?? 0,
              color: c.of(StatusKind.listed).fg,
              backgroundColor: c.of(StatusKind.listed).bg,
            ),
          ],
        ],
      ),
      trailing: trailing,
    );
    return FocusRing(child: tile);
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
            // Grows with large text so a month name isn't broken mid-word (spec §5.9).
            width: MediaQuery.textScalerOf(context)
                .clamp(maxScaleFactor: 1.5)
                .scale(72),
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
