import 'dart:async';

import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/features/lock/app_lock.dart';
import 'package:advocate_app/features/onboarding/onboarding_layout.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// App lock setup (spec §4.1 step 4, §15.2): device biometrics/credential or a 4-digit PIN.
/// Skippable only on Windows when Windows Hello is unavailable.
class LockSetupScreen extends ConsumerStatefulWidget {
  const LockSetupScreen({super.key});

  @override
  ConsumerState<LockSetupScreen> createState() => _LockSetupScreenState();
}

class _LockSetupScreenState extends ConsumerState<LockSetupScreen> {
  bool? _deviceAvailable;
  bool _choosingPin = false;
  String? _firstPin;
  String? _error;
  final _pin = TextEditingController();

  bool get _windows => defaultTargetPlatform == TargetPlatform.windows;

  @override
  void initState() {
    super.initState();
    unawaited(
      ref.read(deviceAuthProvider).available().then((v) {
        if (mounted) setState(() => _deviceAvailable = v);
      }),
    );
  }

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _useDevice() async {
    final ok = await ref
        .read(deviceAuthProvider)
        .authenticate(context.l10n.unlockReason);
    if (ok) await ref.read(appLockProvider.notifier).useDevice();
  }

  Future<void> _onPin(String pin) async {
    if (pin.length != 4) return;
    if (_firstPin == null) {
      setState(() {
        _firstPin = pin;
        _error = null;
      });
      _pin.clear();
      return;
    }
    if (pin == _firstPin) {
      await ref.read(appLockProvider.notifier).usePin(pin);
      return;
    }
    setState(() {
      _firstPin = null;
      _error = context.l10n.lockPinMismatch;
    });
    _pin.clear();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final available = _deviceAvailable;
    return OnboardingLayout(
      title: l.lockTitle,
      subtitle: l.lockWhy,
      secondary: _windows && available == false && !_choosingPin
          ? TextButton(
              onPressed: () => ref.read(appLockProvider.notifier).skip(),
              child: Text(l.lockSkip),
            )
          : null,
      children: [
        if (!_choosingPin) ...[
          if (available ?? false)
            FilledButton.icon(
              onPressed: _useDevice,
              icon: Icon(
                _windows ? AppIcons.windowsLogo : AppIcons.fingerprint,
              ),
              label: Text(_windows ? l.lockWindowsHello : l.lockBiometric),
            ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => setState(() => _choosingPin = true),
            icon: const Icon(AppIcons.password),
            label: Text(l.lockSetPin),
          ),
        ] else ...[
          Text(
            _firstPin == null ? l.lockSetPin : l.lockConfirmPin,
            style: context.text.titleMedium,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pin,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            style: context.text.titleLarge?.copyWith(letterSpacing: 12),
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(4),
            ],
            decoration: InputDecoration(
              labelText: l.pinLabel,
              errorText: _error,
              errorMaxLines: 2,
            ),
            onChanged: _onPin,
          ),
        ],
      ],
    );
  }
}
