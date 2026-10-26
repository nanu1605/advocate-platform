import 'dart:async';

import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/notifications.dart';
import 'package:advocate_app/features/onboarding/notifications_screen.dart';
import 'package:advocate_app/features/onboarding/onboarding_layout.dart';
import 'package:advocate_app/ui/focus_ring.dart';
import 'package:advocate_app/ui/section_header.dart';
import 'package:advocate_app/ui/skeleton.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// /settings/notifications (spec §13.2): each kind on or off, "Include case titles", quiet hours (IST) and whether
/// urgent alerts may break them. The kinds, titles and quiet hours are the user's own `notification_prefs` rows,
/// written locally and uploaded later (works offline); the urgent override is a device setting (no column for it,
/// ADR 0017). On Android it also says when the OS has notifications off, with a way to its settings.
class NotificationPrefsScreen extends ConsumerWidget {
  const NotificationPrefsScreen({super.key});

  /// A 12-hour picker (spec §5.10) for one end of quiet hours; writes both ends.
  Future<void> _pick(
    BuildContext context,
    WidgetRef ref, {
    required bool start,
  }) async {
    final l = context.l10n;
    final p = ref.read(notificationPrefsProvider).value;
    if (p == null) return;
    final d = start ? p.quietStart : p.quietEnd;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: d.inHours, minute: d.inMinutes % 60),
      helpText: start ? l.notifPrefsPickStart : l.notifPrefsPickEnd,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: false),
        child: child!,
      ),
    );
    if (picked == null || !context.mounted) return;
    final t = Duration(hours: picked.hour, minutes: picked.minute);
    await ref
        .read(notificationWriterProvider)
        .setQuietHours(start ? t : p.quietStart, start ? p.quietEnd : t);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final f = Formats(Localizations.localeOf(context));
    final prefs = ref.watch(notificationPrefsProvider);
    final urgent = ref.watch(
      settingsProvider.select((s) => s.urgentBreaksQuiet),
    );
    String time(Duration d) => f.time(DateTime.utc(2000).add(d));
    Widget hint(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: context.text.bodySmall?.copyWith(color: context.colors.ink2),
      ),
    );

    final Widget body;
    if (prefs.hasError && !prefs.hasValue) {
      body = ErrorState(
        message: errorText(l, prefs.error),
        onRetry: () => ref.invalidate(notificationPrefsProvider),
      );
    } else if (!prefs.hasValue) {
      body = ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (var i = 0; i < 6; i++)
            const Padding(
              padding: EdgeInsets.only(bottom: 24),
              child: Skeleton(height: 24),
            ),
        ],
      );
    } else {
      final p = prefs.requireValue;
      final writer = ref.read(notificationWriterProvider);
      body = ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          const _PermissionNotice(),
          SectionHeader(l.notifPrefsKinds),
          hint(l.notifPrefsKindsHint),
          for (final kind in notificationKinds)
            FocusRing(
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(notificationKindLabel(l, kind)),
                value: p.enabled(kind),
                onChanged: (v) =>
                    unawaited(writer.setKindEnabled(kind, enabled: v)),
              ),
            ),
          SectionHeader(l.notifPrefsPrivacy),
          FocusRing(
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l.notifPrefsTitles),
              subtitle: Text(l.notifPrefsTitlesHint),
              value: p.includeTitles,
              onChanged: (v) => unawaited(writer.setIncludeTitles(include: v)),
            ),
          ),
          SectionHeader(l.notifPrefsQuiet),
          hint(l.notifPrefsQuietHint),
          for (final (start, label, value) in [
            (true, l.notifPrefsQuietStart, p.quietStart),
            (false, l.notifPrefsQuietEnd, p.quietEnd),
          ])
            FocusRing(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(label),
                subtitle: Text(time(value)),
                onTap: () => unawaited(_pick(context, ref, start: start)),
              ),
            ),
          FocusRing(
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l.notifPrefsUrgent),
              subtitle: Text(l.notifPrefsUrgentHint),
              value: urgent,
              onChanged: (v) => unawaited(
                ref
                    .read(settingsProvider.notifier)
                    .setUrgentBreaksQuiet(value: v),
              ),
            ),
          ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(l.navNotificationSettings)),
      body: body,
    );
  }
}

/// Android: notifications turned off for the app in the OS (spec §5.4 "Permission denied"): why it matters and a
/// button to the app's notification settings. Checked again when the user comes back from them.
class _PermissionNotice extends ConsumerStatefulWidget {
  const _PermissionNotice();

  @override
  ConsumerState<_PermissionNotice> createState() => _PermissionNoticeState();
}

class _PermissionNoticeState extends ConsumerState<_PermissionNotice> {
  late final AppLifecycleListener _lifecycle;
  bool _enabled = true;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(_check()));
    unawaited(_check());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    bool on;
    try {
      on = await ref.read(notificationPermissionProvider).enabled();
    } on MissingPluginException {
      on = true; // No channel here (tests, desktop): nothing to warn about.
    } on PlatformException {
      on = true;
    }
    if (mounted && on != _enabled) setState(() => _enabled = on);
  }

  @override
  Widget build(BuildContext context) {
    if (_enabled) return const SizedBox.shrink();
    final l = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StepNotice(l.notifyExplainerDenied, kind: StatusKind.adjourned),
          OutlinedButton(
            onPressed: () => unawaited(
              ref.read(notificationPermissionProvider).openSettings(),
            ),
            child: Text(l.notifyExplainerOpenSettings),
          ),
        ],
      ),
    );
  }
}
