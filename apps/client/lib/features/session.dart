import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/data/auth.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:advocate_app/features/lock/app_lock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Sign-out in one place: ends the Supabase session and forgets per-account device state
/// (synced rows and unsent changes, consent marker, onboarding flag, app lock). Language and theme stay.
class Session {
  Session(this._ref);

  final Ref _ref;
  Future<void>? _forgetting;

  Future<void> signOut() async {
    await _ref.read(syncDatabaseProvider)?.disconnectAndClear();
    await _ref.read(authRepositoryProvider).signOut();
    await forget();
  }

  /// Forgets per-account device state. Also run by the router when the session ends by itself (a revoked or
  /// expired refresh token), not only on [signOut]; overlapping calls share one run.
  Future<void> forget() => _forgetting ??= () async {
    await _ref.read(settingsProvider.notifier).clearAccountState();
    await _ref.read(appLockProvider.notifier).reset();
    await _ref.read(syncDatabaseProvider)?.disconnectAndClear();
  }().whenComplete(() => _forgetting = null);
}

final sessionProvider = Provider<Session>(Session.new);
