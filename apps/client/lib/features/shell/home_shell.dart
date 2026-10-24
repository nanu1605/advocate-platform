import 'dart:async';

import 'package:advocate_app/core/flags.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/core/theme/app_theme.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:advocate_app/features/case_page/task_sheet.dart';
import 'package:advocate_app/features/cases/add_case.dart';
import 'package:advocate_app/ui/app_scaffold.dart';
import 'package:advocate_app/ui/command_palette.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/sheets.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Navigation shell for signed-in screens (spec §5.2). P1 phone bar: Today · Cases · (+) · More.
class HomeShell extends ConsumerWidget {
  const HomeShell({required this.location, required this.child, super.key});

  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final flags = ref.watch(featureFlagsProvider);
    final offline = ref.watch(syncViewProvider).value?.offline ?? false;
    final today = NavDest('/today', AppIcons.sun, AppIcons.sunFill, l.navToday);
    final cases = NavDest(
      '/cases',
      AppIcons.briefcase,
      AppIcons.briefcaseFill,
      l.navCases,
    );
    final rail = [
      today,
      cases,
      NavDest(
        '/calendar',
        AppIcons.calendarBlank,
        AppIcons.calendarBlankFill,
        l.navCalendar,
      ),
      if (flags.on(FeatureFlag.ask))
        NavDest(
          '/ask',
          AppIcons.chatCircleText,
          AppIcons.chatCircleTextFill,
          l.navAsk,
        ),
      NavDest('/clients', AppIcons.users, AppIcons.usersFill, l.navClients),
      NavDest('/documents', AppIcons.files, AppIcons.filesFill, l.navDocuments),
      NavDest('/settings', AppIcons.gear, AppIcons.gearFill, l.navSettings),
    ];
    final phone = [
      today,
      cases,
      if (flags.on(FeatureFlag.ask))
        NavDest(
          '/ask',
          AppIcons.chatCircleText,
          AppIcons.chatCircleTextFill,
          l.navAsk,
        ),
      NavDest(
        '/more',
        AppIcons.dotsThreeCircle,
        AppIcons.dotsThreeCircleFill,
        l.navMore,
      ),
    ];

    return AppScaffold(
      // The board belongs to Today.
      location: location.startsWith('/board/') ? '/today' : location,
      phoneDestinations: phone,
      railDestinations: rail,
      onNavigate: context.go,
      onCenterAction: () => showAddSheet(context),
      onNewCase: () => unawaited(showAddCaseChooser(context)),
      banner: offline ? const OfflineBanner() : null,
      onCommandPalette: () => showCommandPalette(context, [
        for (final (i, d) in rail.indexed)
          PaletteCommand(
            label: d.label,
            icon: d.icon,
            shortcut: 'Ctrl+${i + 1}',
            run: () => context.go(d.path),
          ),
        PaletteCommand(
          label: '${l.settingsTheme}: ${l.themeSunlight}',
          icon: AppIcons.sunDim,
          run: () => ref
              .read(settingsProvider.notifier)
              .setTheme(AppThemeMode.sunlight),
        ),
        PaletteCommand(
          label: l.addCase,
          icon: AppIcons.plus,
          shortcut: 'Ctrl+N',
          run: () => unawaited(showAddCaseChooser(context)),
        ),
      ]),
      child: child,
    );
  }
}

/// Centre "+" (P1): Add case (the chooser) · Add task · Add document (task 10: "coming soon" until then). Becomes
/// the mic in P2 (flag `voice`).
void showAddSheet(BuildContext context) {
  final l = context.l10n;
  void then(void Function() open) {
    Navigator.of(context).pop();
    open();
  }

  unawaited(
    showAppBottomSheet<void>(
      context,
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(AppIcons.briefcase),
            title: Text(l.addCase),
            onTap: () => then(() => unawaited(showAddCaseChooser(context))),
          ),
          ListTile(
            leading: const Icon(AppIcons.checkSquare),
            title: Text(l.addTask),
            onTap: () => then(() => unawaited(showTaskSheet(context))),
          ),
          ListTile(
            leading: const Icon(AppIcons.filePlus),
            title: Text(l.addDocument),
            onTap: () => then(
              () =>
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(l.comingSoon))),
            ),
          ),
        ],
      ),
    ),
  );
}
