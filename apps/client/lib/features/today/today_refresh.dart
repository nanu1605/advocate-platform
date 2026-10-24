import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/device.dart';

/// What a Today refresh did: cases sent to the court, cases already refreshed in the last 6 h, whether the
/// network was missing, and the first other failure.
typedef RefreshOutcome = ({
  int checking,
  int upToDate,
  bool offline,
  Object? error,
});

/// Pull-to-refresh / F5 on Today (spec §4.2, §11.5 `on_demand_refresh`): asks the court for each of [matterIds]
/// (today's auto-tracked cases), [concurrency] at a time, one Idempotency-Key per request. RATE_LIMITED means
/// the case was refreshed in the last 6 h, so it counts as up to date; manual or untracked cases are skipped.
Future<RefreshOutcome> refreshMatters(
  ApiClient api, {
  required String orgId,
  required Iterable<String> matterIds,
  int concurrency = 3,
}) async {
  final queue = [...matterIds];
  var (checking, upToDate, offline) = (0, 0, false);
  Object? error;
  Future<void> worker() async {
    while (queue.isNotEmpty) {
      final id = queue.removeAt(0);
      try {
        await api.refreshMatter(
          orgId: orgId,
          matterId: id,
          idempotencyKey: uuidV4(),
        );
        checking++;
      } on ApiException catch (e) {
        switch (e.code) {
          case 'RATE_LIMITED':
            upToDate++;
          case 'NETWORK':
            offline = true;
            queue.clear();
          case 'MANUAL_CASE' || 'TRACKING_OFF':
            break;
          default:
            error ??= e;
        }
      }
    }
  }

  await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
  return (
    checking: checking,
    upToDate: upToDate,
    offline: offline,
    error: error,
  );
}

/// The one snackbar a refresh shows: "Checking 4 cases with the court", else offline, else the error, else
/// "Already up to date".
String refreshSummary(AppLocalizations l, RefreshOutcome o) => o.checking > 0
    ? l.todayRefreshChecking(o.checking)
    : o.offline
    ? l.todayRefreshOffline
    : o.error != null
    ? errorText(l, o.error)
    : l.todayRefreshUpToDate;
