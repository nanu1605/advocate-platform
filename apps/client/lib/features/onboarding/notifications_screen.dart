import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/features/onboarding/onboarding_layout.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The OS notification permission. Android 13+ asks at runtime through a small channel in MainActivity.kt
/// (flutter_local_notifications shows notifications but can't open the app's notification settings); older
/// Android grants it at install and Windows toasts need none.
// ponytail: iOS isn't asked yet (P1 ships Android + Windows); add it with iOS push in P2.
class NotificationPermission {
  const NotificationPermission();

  static const _channel = MethodChannel('advocate_app/notifications');

  bool get needsPrompt => defaultTargetPlatform == TargetPlatform.android;

  /// Shows the OS prompt if needed; true when notifications may be shown.
  Future<bool> request() async =>
      await _channel.invokeMethod<bool>('request') ?? false;

  /// Whether the OS lets the app show notifications now (the user may turn them off in settings at any time).
  /// Always true where no prompt is needed.
  Future<bool> enabled() async =>
      !needsPrompt || (await _channel.invokeMethod<bool>('enabled') ?? false);

  /// The app's notification settings, for turning them on after a denial (spec §5.4 "Permission denied").
  Future<void> openSettings() => _channel.invokeMethod<void>('openSettings');
}

final notificationPermissionProvider = Provider<NotificationPermission>(
  (_) => const NotificationPermission(),
);

/// /onboarding/notifications (spec §4.1 step 9): the value first ("Get tomorrow's board at 7 pm"), then the OS
/// prompt. Finishing marks onboarding done here; the router then lands on Today. WhatsApp alerts come in P2.
class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  bool _denied = false;

  Future<void> _finish() =>
      ref.read(settingsProvider.notifier).setOnboardingDone(value: true);

  Future<void> _allow() async {
    if (await ref.read(notificationPermissionProvider).request()) {
      await _finish();
    } else if (mounted) {
      setState(() => _denied = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final permission = ref.watch(notificationPermissionProvider);
    final ask = permission.needsPrompt && !_denied;
    Widget point(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: context.colors.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: context.text.bodyLarge)),
        ],
      ),
    );
    return OnboardingLayout(
      title: l.notificationsTitle,
      subtitle: l.notifyExplainerSubtitle,
      primary: FilledButton(
        onPressed: ask ? _allow : _finish,
        child: Text(ask ? l.notifyExplainerAllow : l.continueButton),
      ),
      secondary: ask
          ? TextButton(onPressed: _finish, child: Text(l.notifyExplainerNotNow))
          : null,
      children: [
        point(AppIcons.calendarCheck, l.notifyExplainerBoard),
        point(AppIcons.bell, l.notifyExplainerUpdates),
        if (_denied) ...[
          StepNotice(l.notifyExplainerDenied, kind: StatusKind.adjourned),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton(
              onPressed: permission.openSettings,
              child: Text(l.notifyExplainerOpenSettings),
            ),
          ),
        ],
      ],
    );
  }
}
