import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/diary.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// `/cases/:id`: the case number and title, so Today's Open and Notes and notification links (`data.link`)
/// resolve. P1 task 9 replaces it with the case page.
class CasePlaceholderScreen extends ConsumerWidget {
  const CasePlaceholderScreen({required this.matterId, this.tab, super.key});

  final String matterId;

  /// The tab a link asked for (`?tab=notes`); the case page opens on it.
  final String? tab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final header = ref.watch(caseHeaderProvider(matterId)).value;
    return Scaffold(
      appBar: AppBar(title: Text(header?.caseLabel ?? '')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (header?.title case final title?)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Text(title, style: context.text.titleMedium),
            ),
          if (tab == 'notes')
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(l.caseNotes, style: context.text.labelLarge),
            ),
          Expanded(
            child: EmptyState(
              icon: AppIcons.briefcase,
              message: l.casePageSoon,
            ),
          ),
        ],
      ),
    );
  }
}
