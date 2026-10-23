import 'dart:async';

import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/auth.dart';
import 'package:advocate_app/data/device.dart';
import 'package:advocate_app/features/onboarding/onboarding_layout.dart';
import 'package:advocate_app/ui/fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

String authErrorText(BuildContext context, Object e) {
  final l = context.l10n;
  return switch (classifyAuthError(e)) {
    AuthFailure.network => l.errorNetwork,
    AuthFailure.tooMany => l.errorTooMany,
    AuthFailure.invalidCode => l.otpInvalid,
    AuthFailure.other => l.errorGeneric,
  };
}

class PhoneScreen extends ConsumerStatefulWidget {
  const PhoneScreen({super.key});

  @override
  ConsumerState<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends ConsumerState<PhoneScreen> {
  final _phone = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final phone = _phone.text;
    if (!isValidIndianMobile(phone)) {
      setState(() => _error = context.l10n.phoneInvalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider).sendOtp(phone);
      if (mounted) unawaited(context.push('/sign-in/otp', extra: phone));
    } on Object catch (e) {
      if (mounted) setState(() => _error = authErrorText(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return OnboardingLayout(
      title: l.signInTitle,
      subtitle: l.signInSubtitle,
      primary: BusyButton(label: l.sendCode, busy: _busy, onPressed: _send),
      children: [
        AutofillGroup(
          child: PhoneField(
            controller: _phone,
            error: _error,
            onSubmitted: (_) => _send(),
          ),
        ),
      ],
    );
  }
}

class OtpScreen extends ConsumerStatefulWidget {
  const OtpScreen({required this.phone, super.key});

  final String phone;

  @override
  ConsumerState<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends ConsumerState<OtpScreen> {
  static const _resendAfter = 60;

  /// Spec §15.2: after 5 wrong codes this code is dead until a new one is sent (ADR 0008).
  static const _maxWrong = 5;
  final _code = TextEditingController();
  String? _error;
  bool _busy = false;
  int _wait = _resendAfter;
  int _wrong = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _wait = _resendAfter;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_wait <= 1) t.cancel();
      setState(() => _wait--);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    super.dispose();
  }

  bool get _locked => _wrong >= _maxWrong;

  Future<void> _verify() async {
    if (_locked) return;
    if (_code.text.length != 6) {
      setState(() => _error = context.l10n.otpInvalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authRepositoryProvider)
          .verifyOtp(widget.phone, _code.text);
      // Best effort; neither may block sign-in when offline.
      unawaited(ref.read(deviceRegistrarProvider).register());
      final lang = ref.read(settingsProvider).locale?.languageCode;
      if (lang != null) {
        ref.read(apiClientProvider).patchMe({
          'preferred_language': lang,
        }).ignore();
      }
      // The router moves on to consent when the session appears.
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          if (classifyAuthError(e) == AuthFailure.invalidCode) _wrong++;
          _error = _locked ? context.l10n.otpLocked : authErrorText(context, e);
          if (_locked) _code.clear();
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    try {
      await ref.read(authRepositoryProvider).sendOtp(widget.phone);
      setState(() {
        _wrong = 0;
        _error = null;
        _startTimer();
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = authErrorText(context, e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return OnboardingLayout(
      title: l.otpTitle,
      subtitle: l.otpSentTo('+91 ${widget.phone}'),
      showBack: true,
      primary: BusyButton(
        label: l.verify,
        busy: _busy,
        onPressed: _locked ? null : _verify,
      ),
      secondary: TextButton(
        onPressed: _wait > 0 ? null : _resend,
        child: Text(_wait > 0 ? l.resendIn(_wait) : l.resend),
      ),
      children: [
        OtpField(
          controller: _code,
          error: _error,
          onCompleted: (_) => _verify(),
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            onPressed: () => context.pop(),
            child: Text(l.changeNumber),
          ),
        ),
      ],
    );
  }
}
