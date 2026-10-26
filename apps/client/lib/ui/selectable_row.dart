import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/ui/focus_ring.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:flutter/material.dart';

/// Row with a checkbox (Found cases, spec §4.1). The screen reader reads the whole row as one item:
/// "Selected. WP 1234 of 2024. MP High Court Indore. Next date 5 November."
class SelectableRow extends StatelessWidget {
  const SelectableRow({
    required this.selected,
    required this.onChanged,
    required this.title,
    this.subtitle,
    this.warning,
    this.semanticsLabel,
    super.key,
  });

  final bool selected;
  final ValueChanged<bool> onChanged;
  final String title;
  final String? subtitle;

  /// e.g. "Check — might not be yours".
  final String? warning;

  /// Spoken description; defaults to title + subtitle.
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l = context.l10n;
    final spoken = semanticsLabel ?? [title, ?subtitle, ?warning].join('. ');
    return Semantics(
      container: true,
      checked: selected,
      label: '${selected ? l.selected : l.notSelected}. $spoken',
      excludeSemantics: true,
      onTap: () => onChanged(!selected),
      child: FocusRing(
        child: InkWell(
          onTap: () => onChanged(!selected),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The row is the keyboard stop (Space toggles it); a second stop on the checkbox would repeat it.
                ExcludeFocus(
                  child: Checkbox(
                    value: selected,
                    onChanged: (v) => onChanged(v ?? false),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: context.text.titleSmall),
                        if (subtitle != null)
                          Text(subtitle!, style: context.text.bodySmall),
                        if (warning != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(
                              children: [
                                Icon(
                                  AppIcons.warningCircle,
                                  size: inlineIconSize(context, 16),
                                  color: c.of(StatusKind.adjourned).fg,
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    warning!,
                                    style: context.text.bodySmall?.copyWith(
                                      color: c.of(StatusKind.adjourned).fg,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Group header with a tri-state checkbox: true = all, false = none, null = some.
class GroupHeader extends StatelessWidget {
  const GroupHeader({
    required this.title,
    required this.selectedCount,
    required this.total,
    required this.onSelectAll,
    this.expanded = true,
    this.onToggleExpanded,
    super.key,
  });

  final String title;
  final int selectedCount;
  final int total;
  final ValueChanged<bool> onSelectAll;
  final bool expanded;
  final VoidCallback? onToggleExpanded;

  bool? get value => selectedCount == 0
      ? false
      : selectedCount == total
      ? true
      : null;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Semantics(
      header: true,
      child: Row(
        children: [
          FocusRing(
            child: Checkbox(
              tristate: true,
              value: value,
              semanticLabel:
                  '$title. ${l.groupSelection(selectedCount, total)}',
              onChanged: (_) => onSelectAll(value != true),
            ),
          ),
          Expanded(
            child: Text('$title ($total)', style: context.text.titleMedium),
          ),
          // Says what it does and whether the rows are showing: "Show Disposed (4)", not just "Disposed".
          if (onToggleExpanded != null)
            MergeSemantics(
              child: Semantics(
                expanded: expanded,
                child: IconButton(
                  tooltip: expanded
                      ? l.groupHide(title)
                      : l.groupShow(title, total),
                  onPressed: onToggleExpanded,
                  icon: Icon(expanded ? AppIcons.caretUp : AppIcons.caretDown),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
