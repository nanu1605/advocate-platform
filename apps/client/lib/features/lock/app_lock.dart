import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

/// device = biometrics / device credential / Windows Hello; pin = app PIN; none = skipped (Windows without Hello).
enum LockMethod { device, pin, none }

@immutable
class AppLockState {
  const AppLockState({
    this.method,
    this.timeoutMinutes = 5,
    this.locked = false,
    this.failures = 0,
  });

  /// null until set up during onboarding.
  final LockMethod? method;
  final int timeoutMinutes;
  final bool locked;
  final int failures;

  bool get configured => method != null;
  bool get enforced => method == LockMethod.device || method == LockMethod.pin;

  AppLockState copyWith({
    LockMethod? method,
    int? timeoutMinutes,
    bool? locked,
    int? failures,
  }) => AppLockState(
    method: method ?? this.method,
    timeoutMinutes: timeoutMinutes ?? this.timeoutMinutes,
    locked: locked ?? this.locked,
    failures: failures ?? this.failures,
  );
}

const maxPinFailures = 5;
const lockTimeouts = [1, 5, 15];

String hashPin(String pin, String salt) =>
    sha256.convert(utf8.encode('$salt:$pin')).toString();

/// Lock settings in the OS keystore.
class LockStore {
  static const _s = FlutterSecureStorage();

  Future<AppLockState> load() async {
    final method = LockMethod.values
        .asNameMap()[await _s.read(key: 'lock.method')];
    final timeout = int.tryParse(await _s.read(key: 'lock.timeout') ?? '') ?? 5;
    // Cold start always locks when a lock is set.
    return AppLockState(
      method: method,
      timeoutMinutes: timeout,
      locked: method == LockMethod.device || method == LockMethod.pin,
    );
  }

  Future<void> saveMethod(
    LockMethod method, {
    String? pinHash,
    String? salt,
  }) async {
    await _s.write(key: 'lock.method', value: method.name);
    await _s.write(key: 'lock.pin_hash', value: pinHash);
    await _s.write(key: 'lock.salt', value: salt);
  }

  Future<(String?, String?)> pin() async =>
      (await _s.read(key: 'lock.pin_hash'), await _s.read(key: 'lock.salt'));

  Future<void> saveTimeout(int minutes) =>
      _s.write(key: 'lock.timeout', value: '$minutes');

  Future<void> clear() async {
    for (final k in [
      'lock.method',
      'lock.pin_hash',
      'lock.salt',
      'lock.timeout',
    ]) {
      await _s.delete(key: k);
    }
  }
}

/// Wraps local_auth so tests can fake it.
class DeviceAuth {
  final _auth = LocalAuthentication();

  Future<bool> available() async {
    try {
      return await _auth.isDeviceSupported();
    } on Exception {
      return false;
    }
  }

  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        persistAcrossBackgrounding: true,
      );
    } on LocalAuthException {
      return false;
    }
  }
}

final lockStoreProvider = Provider<LockStore>((_) => LockStore());
final deviceAuthProvider = Provider<DeviceAuth>((_) => DeviceAuth());
final clockProvider = Provider<DateTime Function()>((_) => DateTime.now);

/// Loaded before runApp so the very first frame is already locked.
final initialLockProvider = Provider<AppLockState>((_) => const AppLockState());

enum PinResult { ok, wrong, tooMany }

class AppLockController extends Notifier<AppLockState> {
  DateTime? _backgroundedAt;

  LockStore get _store => ref.read(lockStoreProvider);

  @override
  AppLockState build() => ref.read(initialLockProvider);

  Future<void> useDevice() async {
    await _store.saveMethod(LockMethod.device);
    state = state.copyWith(method: LockMethod.device, locked: false);
  }

  Future<void> usePin(String pin) async {
    final r = Random.secure();
    final salt = base64Url.encode(
      List<int>.generate(16, (_) => r.nextInt(256)),
    );
    await _store.saveMethod(
      LockMethod.pin,
      pinHash: hashPin(pin, salt),
      salt: salt,
    );
    state = state.copyWith(method: LockMethod.pin, locked: false, failures: 0);
  }

  /// Only offered on Windows when Windows Hello is unavailable (spec §15.2).
  Future<void> skip() async {
    await _store.saveMethod(LockMethod.none);
    state = state.copyWith(method: LockMethod.none, locked: false);
  }

  Future<void> setTimeoutMinutes(int minutes) async {
    await _store.saveTimeout(minutes);
    state = state.copyWith(timeoutMinutes: minutes);
  }

  void backgrounded() => _backgroundedAt ??= ref.read(clockProvider)();

  void resumed() {
    final since = _backgroundedAt;
    _backgroundedAt = null;
    if (!state.enforced || since == null) return;
    final away = ref.read(clockProvider)().difference(since);
    if (away >= Duration(minutes: state.timeoutMinutes)) {
      state = state.copyWith(locked: true);
    }
  }

  Future<bool> unlockWithDevice(String reason) async {
    final ok = await ref.read(deviceAuthProvider).authenticate(reason);
    if (ok) state = state.copyWith(locked: false, failures: 0);
    return ok;
  }

  Future<PinResult> unlockWithPin(String pin) async {
    final (hash, salt) = await _store.pin();
    if (hash != null && salt != null && hashPin(pin, salt) == hash) {
      state = state.copyWith(locked: false, failures: 0);
      return PinResult.ok;
    }
    final failures = state.failures + 1;
    state = state.copyWith(failures: failures);
    return failures >= maxPinFailures ? PinResult.tooMany : PinResult.wrong;
  }

  /// Sign-out: the next account sets its own lock.
  Future<void> reset() async {
    await _store.clear();
    state = const AppLockState();
  }
}

final appLockProvider = NotifierProvider<AppLockController, AppLockState>(
  AppLockController.new,
);
