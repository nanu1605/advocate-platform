import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/data/auth.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:advocate_app/features/lock/app_lock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Sign-out in one place: ends the Supabase session and forgets per-account device state
/// (synced rows and unsent changes, consent marker, app lock). Language and theme stay.
class Session {
  Session(this._ref);

  final Ref _ref;

  Future<void> signOut() async {
    await _ref.read(syncDatabaseProvider)?.disconnectAndClear();
    await _ref.read(authRepositoryProvider).signOut();
    await _ref.read(settingsProvider.notifier).clearAccountState();
    await _ref.read(appLockProvider.notifier).reset();
  }
}

final sessionProvider = Provider<Session>(Session.new);
