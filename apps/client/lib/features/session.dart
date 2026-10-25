import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/data/auth.dart';
import 'package:advocate_app/data/document_files.dart';
import 'package:advocate_app/data/documents.dart';
import 'package:advocate_app/data/feedback.dart';
import 'package:advocate_app/data/local_notifier.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:advocate_app/data/team.dart';
import 'package:advocate_app/features/board/board_share.dart';
import 'package:advocate_app/features/documents/upload_flow.dart';
import 'package:advocate_app/features/lock/app_lock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Sign-out in one place: ends the Supabase session and forgets per-account device state
/// (synced rows and unsent changes, consent marker, onboarding flag, app lock, shared board images, queued uploads,
/// offline copies of files, the scanner's and file picker's own copies, local notifications and the ids already
/// shown, an unsent feedback note). Language and theme stay.
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
    // With the rows gone, local alerts start afresh for whoever signs in next, and none of this account's stay in
    // the tray.
    _ref
      ..invalidate(localAlertsProvider)
      // An unsent feedback note isn't the next account's to send.
      ..invalidate(feedbackDraftProvider);
    _ref.read(removedFromTeamProvider.notifier).team = null;
    await LocalAlerts.forget(_ref.read(prefsProvider));
    await _ref.read(localNotifierProvider).cancelAll();
    clearBoardShares(await _ref.read(boardShareDirProvider)());
    final support = _ref.read(appSupportDirProvider);
    if (support != null) {
      // A file being sent or downloaded is held open, which Windows won't delete: stop the transfers first.
      await _ref.read(uploadsProvider).stop();
      await _ref.read(offlineFilesProvider).stop();
      clearDeviceFiles(support);
      await _ref.read(uploadSourcesProvider).cleanUp();
    }
  }().whenComplete(() => _forgetting = null);
}

final sessionProvider = Provider<Session>(Session.new);
