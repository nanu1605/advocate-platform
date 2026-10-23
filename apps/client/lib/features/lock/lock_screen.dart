import 'dart:async';

import 'package:advocate_app/core/brand/brand.g.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/auth.dart';
import 'package:advocate_app/features/lock/app_lock.dart';
import 'package:advocate_app/features/session.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Covers the whole app while locked, above the router so no deep link can bypass it.
/// Tracks background time for the lock timeout (spec §15.2).
class AppLockGate extends ConsumerStatefulWidget {
  const AppLockGate({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onHide: () => ref.read(appLockProvider.notifier).backgrounded(),
      onShow: () => ref.read(appLockProvider.notifier).resumed(),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final locked = ref.watch(appLockProvider.select((s) => s.locked));
    final signedIn = ref.watch(signedInProvider).value ?? false;
    return Stack(
      children: [
        // Hidden from screen readers and input while the lock is up.
        ExcludeSemantics(excluding: locked && signedIn, child: widget.child),
        if (locked && signedIn)
          Positioned.fill(
            child: Overlay(
              initialEntries: [
                OverlayEntry(builder: (_) => const LockScreen()),
              ],
            ),
          ),
      ],
    );
  }
}

class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  final _pin = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (ref.read(appLockProvider).method == LockMethod.device) {
        unawaited(_device());
      }
    });
  }

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _device() => ref
      .read(appLockProvider.notifier)
      .unlockWithDevice(context.l10n.unlockReason);

  Future<void> _checkPin(String pin) async {
    final result = await ref.read(appLockProvider.notifier).unlockWithPin(pin);
    if (!mounted) return;
    switch (result) {
      case PinResult.ok:
        return;
      case PinResult.wrong:
        _pin.clear();
        final left = maxPinFailures - ref.read(appLockProvider).failures;
        setState(() => _error = context.l10n.unlockWrongPin(left));
      case PinResult.tooMany:
        // Too many wrong PINs: sign out. Data stays safe on the server; OTP sign-in restores access.
        await ref.read(sessionProvider).signOut();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final method = ref.watch(appLockProvider.select((s) => s.method));
    final hi = Localizations.localeOf(context).languageCode == 'hi';
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    AppIcons.lockSimple,
                    size: 56,
                    color: context.colors.ink2,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l.unlockTitle(hi ? Brand.appNameHi : Brand.appName),
                    textAlign: TextAlign.center,
                    style: context.text.titleLarge,
                  ),
                  const SizedBox(height: 24),
                  if (method == LockMethod.device)
                    FilledButton.icon(
                      onPressed: _device,
                      icon: const Icon(AppIcons.fingerprint),
                      label: Text(l.unlockWithBiometric),
                    ),
                  if (method == LockMethod.pin)
                    TextField(
                      controller: _pin,
                      autofocus: true,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      style: context.text.titleLarge?.copyWith(
                        letterSpacing: 12,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(4),
                      ],
                      decoration: InputDecoration(
                        labelText: l.pinLabel,
                        errorText: _error,
                      ),
                      onChanged: (v) {
                        if (v.length == 4) unawaited(_checkPin(v));
                      },
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
