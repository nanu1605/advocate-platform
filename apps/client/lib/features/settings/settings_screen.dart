import 'dart:async';

import 'package:advocate_app/core/brand/brand.g.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/core/theme/app_theme.dart';
import 'package:advocate_app/data/feedback.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:advocate_app/features/feedback/feedback_sheet.dart';
import 'package:advocate_app/features/lock/app_lock.dart';
import 'package:advocate_app/features/session.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/section_header.dart';
import 'package:advocate_app/ui/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Theme, language, text-size preview, reduce motion, haptics, app lock, sign-out (spec §17 P0 task 5).
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final s = ref.watch(settingsProvider);
    final lock = ref.watch(appLockProvider);
    final ctl = ref.read(settingsProvider.notifier);
    final hi = Localizations.localeOf(context).languageCode == 'hi';
    final scale = MediaQuery.textScalerOf(context).scale(100).round();

    return Scaffold(
      appBar: AppBar(title: Text(l.navSettings)),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          SectionHeader(l.settingsTheme),
          SegmentedButton<AppThemeMode>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: AppThemeMode.system,
                label: Text(l.themeSystem),
              ),
              ButtonSegment(
                value: AppThemeMode.light,
                label: Text(l.themeLight),
              ),
              ButtonSegment(value: AppThemeMode.dark, label: Text(l.themeDark)),
              ButtonSegment(
                value: AppThemeMode.sunlight,
                label: Text(l.themeSunlight),
              ),
            ],
            selected: {s.theme},
            onSelectionChanged: (v) => ctl.setTheme(v.first),
          ),
          SectionHeader(l.settingsLanguage),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'hi', label: Text('हिंदी')),
              ButtonSegment(value: 'en', label: Text('English')),
            ],
            selected: {s.locale?.languageCode ?? 'hi'},
            onSelectionChanged: (v) => ctl.setLocale(Locale(v.first)),
          ),
          SectionHeader('${l.settingsTextSize} · $scale%'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(l.textSizePreview, style: context.text.bodyLarge),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(l.textSizeHint, style: context.text.bodySmall),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l.settingsReduceMotion),
            value: s.reduceMotion,
            onChanged: (v) => ctl.setReduceMotion(value: v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l.settingsHaptics),
            value: s.haptics,
            onChanged: (v) => ctl.setHaptics(value: v),
          ),
          if (lock.enforced) ...[
            SectionHeader(l.settingsAppLock),
            RadioGroup<int>(
              groupValue: lock.timeoutMinutes,
              onChanged: (v) =>
                  ref.read(appLockProvider.notifier).setTimeoutMinutes(v!),
              child: Column(
                children: [
                  for (final m in lockTimeouts)
                    RadioListTile<int>(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l.lockAfter(m)),
                      value: m,
                    ),
                ],
              ),
            ),
          ],
          // The Windows rail has no More: these live here too.
          SectionHeader(l.settingsPractice),
          for (final (icon, label, open) in [
            (
              AppIcons.bell,
              l.navNotificationSettings,
              () => context.go('/settings/notifications'),
            ),
            (AppIcons.usersThree, l.navTeam, () => context.go('/team')),
            (AppIcons.chartBar, l.navDashboard, () => context.go('/dashboard')),
            (
              AppIcons.chatTeardropText,
              l.navFeedback,
              () => unawaited(showFeedbackSheet(context)),
            ),
          ])
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(icon, color: context.colors.ink2),
              title: Text(label, style: context.text.bodyLarge),
              onTap: open,
            ),
          const SizedBox(height: 16),
          OutlinedButton(
            // Signing out clears this device's queues (ADR 0013, 0017): say what would be lost.
            onPressed: () async {
              final p = await ref.read(pendingChangesProvider)();
              if (!context.mounted) return;
              final pending = p.changes + p.uploads > 0;
              final ok = await showConfirmDialog(
                context,
                title: l.signOut,
                body: pending
                    ? [
                        if (p.changes > 0) l.signOutPendingChanges(p.changes),
                        if (p.uploads > 0) l.signOutPendingUploads(p.uploads),
                        l.signOutPendingLost,
                      ].join(' ')
                    : l.signOutConfirm,
                confirmLabel: pending ? l.signOutPendingConfirm : l.signOut,
                cancelLabel: pending ? l.signOutPendingStay : null,
              );
              if (ok) await ref.read(sessionProvider).signOut();
            },
            child: Text(l.signOut),
          ),
          SectionHeader(l.about),
          Text(
            '${hi ? Brand.appNameHi : Brand.appName} · ${hi ? Brand.poweredByHi : Brand.poweredBy}',
            style: context.text.bodyLarge,
          ),
          Text(
            l.appVersion(ref.watch(appVersionProvider).value ?? '…'),
            style: context.text.bodySmall?.copyWith(color: context.colors.ink2),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
