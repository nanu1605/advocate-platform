import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Phone-OTP sign-in through Supabase Auth (spec §15.2). Tests override [authRepositoryProvider] with a fake.
class AuthRepository {
  AuthRepository(this._client);

  final SupabaseClient _client;

  bool get isSignedIn => _client.auth.currentSession != null;
  String? get accessToken => _client.auth.currentSession?.accessToken;

  Stream<bool> get changes =>
      _client.auth.onAuthStateChange.map((s) => s.session != null);

  /// [phone] is the 10-digit Indian mobile number; Supabase gets E.164.
  Future<void> sendOtp(String phone) =>
      _client.auth.signInWithOtp(phone: '+91$phone');

  Future<void> verifyOtp(String phone, String code) => _client.auth.verifyOTP(
    phone: '+91$phone',
    token: code,
    type: OtpType.sms,
  );

  Future<void> signOut() => _client.auth.signOut();
}

final authRepositoryProvider = Provider<AuthRepository>(
  (_) => AuthRepository(Supabase.instance.client),
);

final signedInProvider = StreamProvider<bool>((ref) async* {
  final repo = ref.watch(authRepositoryProvider);
  yield repo.isSignedIn;
  yield* repo.changes;
});

/// Supabase session persistence in the OS keystore (Keychain / Keystore / DPAPI) instead of shared prefs.
class SecureSessionStorage extends LocalStorage {
  const SecureSessionStorage();

  static const _key = 'supabase.session';
  static const _storage = FlutterSecureStorage();

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasAccessToken() => _storage.containsKey(key: _key);

  @override
  Future<String?> accessToken() => _storage.read(key: _key);

  @override
  Future<void> persistSession(String persistSessionString) =>
      _storage.write(key: _key, value: persistSessionString);

  @override
  Future<void> removePersistedSession() => _storage.delete(key: _key);
}
