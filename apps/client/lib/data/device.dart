import 'dart:io';
import 'dart:math';

import 'package:advocate_app/data/api_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Random v4 UUID (client-generated ids are allowed for offline rows, spec §9.1).
String uuidV4([Random? random]) {
  final r = random ?? Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

String get platformName => switch (defaultTargetPlatform) {
  TargetPlatform.iOS => 'ios',
  TargetPlatform.windows => 'windows',
  _ => 'android',
};

/// Registers this install with POST /v1/devices once per sign-in. The id lives in secure storage so a
/// reinstall counts as a new device (new-device alert, spec §15.2).
class DeviceRegistrar {
  DeviceRegistrar(this._api);

  final ApiClient _api;
  static const _storage = FlutterSecureStorage();
  static const _key = 'device.id';

  Future<String> deviceId() async {
    final existing = await _storage.read(key: _key);
    if (existing != null) return existing;
    final id = uuidV4();
    await _storage.write(key: _key, value: id);
    return id;
  }

  /// Best effort: a failure here (offline) must never block sign-in; it retries on next launch.
  Future<void> register() async {
    try {
      final info = await PackageInfo.fromPlatform();
      await _api.registerDevice(
        id: await deviceId(),
        platform: platformName,
        appVersion: info.version,
      );
    } on ApiException catch (e) {
      debugPrint('device registration deferred: ${e.code}');
    } on SocketException {
      debugPrint('device registration deferred: offline');
    }
  }
}

final deviceRegistrarProvider = Provider<DeviceRegistrar>(
  (ref) => DeviceRegistrar(ref.watch(apiClientProvider)),
);
