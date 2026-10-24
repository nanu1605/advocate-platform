import 'dart:async';

import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/features/found_cases/add_by_cnr.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// A case year as typed in Search and Add by hand: null when empty or 1950–2100 (the API's range), else the error.
String? caseYearError(AppLocalizations l, String text) {
  final s = text.trim();
  final y = int.tryParse(s);
  return s.isEmpty || (y != null && y >= 1950 && y <= 2100)
      ? null
      : l.addCaseYearInvalid;
}

/// Opens case [id], which the API has just added: until sync brings its row, the case page shows it loading.
void openAddedCase(BuildContext context, String id) {
  ProviderScope.containerOf(
    context,
    listen: false,
  ).read(addedCasesProvider.notifier).add(id);
  context.go('/cases/$id');
}

/// Add case (spec §4.1, §4.3): By CNR (the existing sheet, then the new case opens), Search the courts
/// (`/cases/search`) or Add by hand (`/cases/manual`). From the centre "+" sheet, Ctrl+N and the Cases empty state.
Future<void> showAddCaseChooser(BuildContext context) =>
    showAppBottomSheet<void>(
      context,
      builder: (sheet) {
        final l = sheet.l10n;
        Widget option(
          IconData icon,
          String title,
          String hint,
          Future<void> Function() then,
        ) => ListTile(
          leading: Icon(icon),
          title: Text(title),
          subtitle: Text(hint),
          onTap: () {
            Navigator.of(sheet).pop();
            unawaited(then());
          },
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  l.casesAddTitle,
                  style: Theme.of(sheet).textTheme.titleLarge,
                ),
              ),
            ),
            option(
              AppIcons.fileText,
              l.casesAddByCnr,
              l.casesAddByCnrHint,
              () async {
                final id = await showAddByCnrSheet(context);
                if (id != null && context.mounted) openAddedCase(context, id);
              },
            ),
            option(
              AppIcons.magnifyingGlass,
              l.casesAddSearch,
              l.casesAddSearchHint,
              () => context.push('/cases/search'),
            ),
            option(
              AppIcons.pencilSimple,
              l.casesAddManual,
              l.casesAddManualHint,
              () => context.push('/cases/manual'),
            ),
          ],
        );
      },
    );
