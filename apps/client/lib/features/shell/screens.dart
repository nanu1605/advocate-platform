import 'dart:async';

import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/features/feedback/feedback_sheet.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// A screen whose route exists before the screen does.
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
    Widget tile(IconData icon, String label, VoidCallback onTap) => ListTile(
      leading: Icon(icon, color: context.colors.ink2),
      title: Text(label, style: context.text.bodyLarge),
      trailing: const Icon(AppIcons.caretRight),
      onTap: onTap,
    );
    Widget go(IconData icon, String label, String path) =>
        tile(icon, label, () => context.go(path));
    return Scaffold(
      appBar: AppBar(title: Text(l.navMore)),
      body: ListView(
        children: [
          go(AppIcons.calendarBlank, l.navCalendar, '/calendar'),
          go(AppIcons.users, l.navClients, '/clients'),
          go(AppIcons.files, l.navDocuments, '/documents'),
          go(AppIcons.chartBar, l.navDashboard, '/dashboard'),
          go(AppIcons.usersThree, l.navTeam, '/team'),
          go(AppIcons.bell, l.navNotifications, '/notifications'),
          go(AppIcons.gear, l.navSettings, '/settings'),
          tile(
            AppIcons.chatTeardropText,
            l.navFeedback,
            () => unawaited(showFeedbackSheet(context)),
          ),
          if (kDebugMode)
            go(
              AppIcons.squaresFour,
              'Component kit (debug)',
              '/dev/kitchen-sink',
            ),
        ],
      ),
    );
  }
}
