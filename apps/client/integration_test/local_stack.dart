// What the integration tests share against the local stack (`just dev`): a new account per run, the API as that
// user, and an admin client that deletes what the run made.
import 'package:advocate_app/core/config.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// The well-known service-role key of every local Supabase stack, not a secret (like LOCAL_ANON_KEY in
// services/api/tests/conftest.py). It only works against a local stack.
const _serviceKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0'
    '.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU';

/// Service role: bypasses row-level security. Only for deleting test accounts.
final _admin = SupabaseClient(
  Config.supabaseUrl,
  _serviceKey,
  authOptions: const AuthClientOptions(autoRefreshToken: false),
);

Future<Supabase>? _started;

/// Signs in a test number from supabase/config.toml (`919999900037`, code 123456) as a new account: whatever an
/// earlier run left for the number is deleted first. That also lets a rerun start at once, as Supabase sends a
/// number a code at most once a minute per account (`[auth.sms] max_frequency`). Supabase starts once per
/// process: a second `Supabase.initialize` asserts.
Future<SupabaseClient> signIn(String phone) async {
  expect(Config.powersyncUrl, isNotEmpty, reason: 'pass env.local.json');
  for (final p
      in await _admin.from('profiles').select('id').eq('phone', phone)) {
    await dropUser(p['id'] as String);
  }
  await (_started ??= Supabase.initialize(
    url: Config.supabaseUrl,
    publishableKey: Config.supabaseAnonKey,
    authOptions: const FlutterAuthClientOptions(
      localStorage: EmptyLocalStorage(),
    ),
  ));
  final supabase = Supabase.instance.client;
  await supabase.auth.signInWithOtp(phone: phone);
  await supabase.auth.verifyOTP(
    phone: phone,
    token: '123456',
    type: OtpType.sms,
  );
  return supabase;
}

/// Deletes the account with the organisations it owns, everything in them and their cost records (as `drop_orgs`
/// in conftest.py: org-less cost rows would count against the global daily cap).
Future<void> dropUser(String userId) async {
  final owned = [
    for (final o
        in await _admin
            .from('organizations')
            .select('id')
            .eq('owner_id', userId))
      o['id'] as String,
  ];
  await _admin.from('provider_calls').delete().inFilter('org_id', owned);
  await _admin.from('organizations').delete().inFilter('id', owned);
  await _admin.auth.admin.deleteUser(userId);
}

/// The API as the signed-in user.
ApiClient apiAs(SupabaseClient supabase) => ApiClient(
  Dio(
    BaseOptions(
      // ignore: avoid_redundant_argument_values, set by --dart-define at build time
      baseUrl: Config.apiUrl,
      headers: {
        'Authorization': 'Bearer ${supabase.auth.currentSession!.accessToken}',
      },
    ),
  ),
);

/// Polls [done] until it holds; fails after [timeout].
Future<void> until(
  Future<bool> Function() done, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}
