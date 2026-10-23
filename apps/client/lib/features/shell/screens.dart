import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/core/theme/app_theme.dart';
import 'package:advocate_app/features/shell/home_shell.dart';
import 'package:advocate_app/ui/fields.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Today (P0 shell). Matters, board and tasks arrive with court data in P1.
class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = ref.watch(settingsProvider.select((s) => s.theme));
    final sunlight = theme == AppThemeMode.sunlight;
    final date = Formats(Localizations.localeOf(context)).date(DateTime.now());
    return Scaffold(
      appBar: AppBar(
        title: Text('${l.navToday} · $date'),
        actions: [
          const SyncIndicator(SyncStatus.synced),
          // Sunlight is one tap from Today because people need it outdoors (spec §5.6).
          IconButton(
            tooltip: l.sunlightToggle,
            isSelected: sunlight,
            icon: const Icon(AppIcons.sunDim),
            selectedIcon: const Icon(AppIcons.sunDimFill),
            onPressed: () => ref
                .read(settingsProvider.notifier)
                .setTheme(
                  sunlight ? AppThemeMode.system : AppThemeMode.sunlight,
                ),
          ),
        ],
      ),
      body: EmptyState(
        icon: AppIcons.coffee,
        message: l.todayEmpty,
        actionLabel: l.addFirstCase,
        onAction: () => showAddSheet(context),
      ),
    );
  }
}

class CasesScreen extends StatelessWidget {
  const CasesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l.navCases)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: SearchField(hint: l.searchCasesHint),
          ),
          Expanded(
            child: EmptyState(
              icon: AppIcons.briefcase,
              message: l.casesEmpty,
              actionLabel: l.addFirstCase,
              onAction: () => showAddSheet(context),
            ),
          ),
        ],
      ),
    );
  }
}

/// Calendar, Clients, Documents: screens arrive in P1; the shell routes exist now.
class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({required this.title, required this.icon, super.key});

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: EmptyState(icon: icon, message: context.l10n.comingSoon),
  );
}

class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    Widget tile(IconData icon, String label, String path) => ListTile(
      leading: Icon(icon, color: context.colors.ink2),
      title: Text(label, style: context.text.bodyLarge),
      trailing: const Icon(AppIcons.caretRight),
      onTap: () => context.go(path),
    );
    return Scaffold(
      appBar: AppBar(title: Text(l.navMore)),
      body: ListView(
        children: [
          tile(AppIcons.calendarBlank, l.navCalendar, '/calendar'),
          tile(AppIcons.users, l.navClients, '/clients'),
          tile(AppIcons.files, l.navDocuments, '/documents'),
          tile(AppIcons.gear, l.navSettings, '/settings'),
          if (kDebugMode)
            tile(
              AppIcons.squaresFour,
              'Component kit (debug)',
              '/dev/kitchen-sink',
            ),
        ],
      ),
    );
  }
}
