import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/ui/focus_ring.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:flutter/material.dart';

/// Title (count) and an optional action (spec §5.11 #6), which moves under the title when both don't fit on one
/// line (200% text). With [onToggle] the whole header shows or hides its section (Cases list): a caret says which,
/// and screen readers hear whether it is [expanded].
class SectionHeader extends StatelessWidget {
  const SectionHeader(
    this.title, {
    this.count,
    this.actionLabel,
    this.onAction,
    this.expanded = true,
    this.onToggle,
    super.key,
  });

  final String title;
  final int? count;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool expanded;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final label = Text(
      count == null ? title : '$title ($count)',
      style: context.text.titleMedium,
    );
    final toggle = onToggle;
    if (toggle != null) {
      final l = context.l10n;
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Semantics(
          header: true,
          expanded: expanded,
          child: Tooltip(
            message: expanded
                ? l.groupHide(title)
                : l.groupShow(title, count ?? 0),
            child: FocusRing(
              child: InkWell(
                onTap: toggle,
                borderRadius: BorderRadius.circular(8),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Row(
                    children: [
                      Expanded(child: label),
                      Icon(
                        expanded ? AppIcons.caretUp : AppIcons.caretDown,
                        color: context.colors.ink2,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    final header = Semantics(header: true, child: label);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
      child: actionLabel == null
          ? header
          // Full width, so the action sits at the end of the line.
          : SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  header,
                  TextButton(onPressed: onAction, child: Text(actionLabel!)),
                ],
              ),
            ),
    );
  }
}
