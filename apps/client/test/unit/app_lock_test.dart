import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/features/lock/app_lock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

void main() {
  late DateTime now;
  late MemoryLockStore store;

  ProviderContainer container({
    AppLockState initial = const AppLockState(),
    bool deviceOk = true,
  }) {
    final c = ProviderContainer(
      overrides: [
        lockStoreProvider.overrideWithValue(store),
        deviceAuthProvider.overrideWithValue(
          FakeDeviceAuth(isAvailable: true, succeeds: deviceOk),
        ),
        clockProvider.overrideWithValue(() => now),
        initialLockProvider.overrideWithValue(initial),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  setUp(() {
    now = DateTime(2026, 11, 5, 10);
    store = MemoryLockStore();
  });

  test('PIN is stored salted and hashed, never in clear', () async {
    final c = container();
    await c.read(appLockProvider.notifier).usePin('2468');
    expect(store.method, LockMethod.pin);
    expect(store.hash, isNot(contains('2468')));
    expect(store.hash, hashPin('2468', store.salt!));
  });

  test('locks only after the timeout in the background', () async {
    final c = container();
    final lock = c.read(appLockProvider.notifier);
    await lock.usePin('2468');

    lock.backgrounded();
    now = now.add(const Duration(minutes: 4, seconds: 59));
    lock.resumed();
    expect(c.read(appLockProvider).locked, isFalse);

    lock.backgrounded();
    now = now.add(const Duration(minutes: 5));
    lock.resumed();
    expect(c.read(appLockProvider).locked, isTrue);
  });

  test('timeout setting is honoured', () async {
    final c = container();
    final lock = c.read(appLockProvider.notifier);
    await lock.useDevice();
    await lock.setTimeoutMinutes(1);
    lock.backgrounded();
    now = now.add(const Duration(minutes: 1));
    lock.resumed();
    expect(c.read(appLockProvider).locked, isTrue);
    expect(store.timeout, 1);
  });

  test('wrong PIN counts down; fifth failure asks for sign-out', () async {
    final c = container();
    final lock = c.read(appLockProvider.notifier);
    await lock.usePin('2468');
    for (var i = 0; i < maxPinFailures - 1; i++) {
      expect(await lock.unlockWithPin('0000'), PinResult.wrong);
    }
    expect(await lock.unlockWithPin('0000'), PinResult.tooMany);
  });

  test('right PIN unlocks and resets failures', () async {
    final c = container();
    final lock = c.read(appLockProvider.notifier);
    await lock.usePin('2468');
    await lock.unlockWithPin('0000');
    expect(await lock.unlockWithPin('2468'), PinResult.ok);
    expect(c.read(appLockProvider).failures, 0);
    expect(c.read(appLockProvider).locked, isFalse);
  });

  test('device unlock follows the platform result', () async {
    final c = container(
      initial: const AppLockState(method: LockMethod.device, locked: true),
      deviceOk: false,
    );
    expect(
      await c.read(appLockProvider.notifier).unlockWithDevice('r'),
      isFalse,
    );
    expect(c.read(appLockProvider).locked, isTrue);
  });

  test('skipped lock (Windows without Hello) never locks', () async {
    final c = container();
    final lock = c.read(appLockProvider.notifier);
    await lock.skip();
    lock.backgrounded();
    now = now.add(const Duration(hours: 2));
    lock.resumed();
    expect(c.read(appLockProvider).locked, isFalse);
    expect(c.read(appLockProvider).configured, isTrue);
  });
}
