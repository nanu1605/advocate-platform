import 'dart:async';
import 'dart:math';

import 'package:advocate_app/core/brand/brand.g.dart';
import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/router.dart';
import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/jobs.dart';
import 'package:advocate_app/data/notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleState, Locale, WidgetsBinding;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An OS notification (spec §13.3).
@immutable
class LocalNotice {
  const LocalNotice({
    required this.tag,
    required this.title,
    required this.body,
    required this.link,
    required this.channelName,
    this.urgent = false,
  });

  /// A newer notice with the same tag replaces the older one (the row's collapse key).
  final String tag;
  final String title;
  final String body;

  /// The app route a tap opens.
  final String link;

  /// The Android channel's name, in the user's language.
  final String channelName;

  /// Listed early or a deadline due today: the high-priority channel.
  final bool urgent;

  /// [tag] as a stable 31-bit id: the OS replaces a notification that has the same id.
  int get id => _fnv(tag);
}

/// [s] as a stable 31-bit number (FNV-1a; Dart's hashCode changes between runs).
int _fnv(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return h & 0x7fffffff;
}

/// Shows OS notifications: [PluginNotifier] on Android and Windows; tests fake it.
abstract interface class LocalNotifier {
  /// Prepares notifications; [onTap] receives the link of a tapped notice, also of one that launched the app.
  Future<void> start(void Function(String link) onTap);

  Future<void> show(LocalNotice notice);

  /// Clears the app's notifications from the tray (sign-out). Unpackaged Windows builds can't (ADR 0017).
  Future<void> cancelAll();
}

/// The Windows toast identity (ADR 0017): the app id the plugin registers for an unpackaged build, and the toast
/// activator's CLSID. The signed installer and the MSIX manifest must use the same two values.
const windowsAppId = 'in.jainavinfotech.advocate';
const windowsToastGuid = 'd70975db-0054-4132-9dc6-494bc79016cd';

/// flutter_local_notifications. Android: a "Case updates" and an "Urgent alerts" channel (named in the user's
/// language when shown), the launcher icon. Windows: toasts while the app runs.
/// ponytail: the launcher icon as the status-bar icon (Android draws it as a silhouette); add a monochrome drawable
/// with the brand work.
class PluginNotifier implements LocalNotifier {
  final _plugin = FlutterLocalNotificationsPlugin();
  void Function(String link)? _onTap;
  bool _started = false;

  static bool get _supported =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.windows;

  @override
  Future<void> start(void Function(String link) onTap) async {
    _onTap = onTap;
    if (_started || !_supported) return;
    try {
      // False on Windows when the app id can't be registered: then nothing is shown (show and cancelAll would throw).
      _started =
          await _plugin.initialize(
            settings: const InitializationSettings(
              android: AndroidInitializationSettings('@mipmap/ic_launcher'),
              windows: WindowsInitializationSettings(
                appName: Brand.appName,
                appUserModelId: windowsAppId,
                guid: windowsToastGuid,
              ),
            ),
            onDidReceiveNotificationResponse: (r) {
              if (r.payload case final link?) _onTap?.call(link);
            },
          ) ??
          false;
      if (!_started) return;
      final launch = await _plugin.getNotificationAppLaunchDetails();
      final link = launch?.notificationResponse?.payload;
      if ((launch?.didNotificationLaunchApp ?? false) && link != null) {
        onTap(link);
      }
    } on Object catch (e) {
      // Best effort: the app works without OS notifications (the centre still lists them).
      debugPrint('Local notifications unavailable: ${e.runtimeType}');
    }
  }

  /// Best effort, like [start]: a failure is logged (never the text) and the next notice still goes.
  @override
  Future<void> show(LocalNotice n) async {
    if (!_started) return;
    try {
      await _plugin.show(
        id: n.id,
        title: n.title,
        body: n.body,
        payload: n.link,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            n.urgent ? 'urgent' : 'updates',
            n.channelName,
            importance: n.urgent
                ? Importance.high
                : Importance.defaultImportance,
            priority: n.urgent ? Priority.high : Priority.defaultPriority,
            tag: n.tag,
          ),
          windows: const WindowsNotificationDetails(),
        ),
      );
    } on Object catch (e) {
      debugPrint('Local notification not shown: ${e.runtimeType}');
    }
  }

  /// Best effort: sign-out goes on to wipe the account's files whatever happens here.
  @override
  Future<void> cancelAll() async {
    if (!_started) return;
    try {
      await _plugin.cancelAll();
    } on Object catch (e) {
      debugPrint('Local notifications not cleared: ${e.runtimeType}');
    }
  }
}

final localNotifierProvider = Provider<LocalNotifier>((_) => PluginNotifier());

/// Whether the user can be looking at the app: it is in front (or its state isn't known yet). A screen left open in
/// the background or minimised isn't being read.
bool _looking() {
  final s = WidgetsBinding.instance.lifecycleState;
  return s == null || s == AppLifecycleState.resumed;
}

/// What [alertsToShow] decided: the rows to show, and every row it dealt with (shown or held back), so none of them
/// pops up later.
typedef AlertDecision = ({List<AppNotification> show, Set<String> seen});

/// What [alertsToShow] remembers a row by: its id and its text, so a row the server rewrites (the evening board's
/// later attempt, `notify.board_summary`) is new again and replaces its notification instead of leaving the old
/// count in the tray.
String shownKey(AppNotification r) =>
    '${r.id}@${_fnv('${r.title}\n${r.body}')}';

/// Which synced [rows] (newest first) become OS notifications now (spec §13.2–13.3): rows not dealt with before
/// ([shown] holds their [shownKey]s) and created at or after [since] (see [LocalAlerts.onRows]: never a replay of
/// old rows after a sign-in, a reinstall or a long sleep), or dealt with before and since rewritten; unread, whose
/// kind is on and that may alert now ([mayAlert]); none while the user is looking at the notification centre
/// ([centreOpen]). Of rows sharing a collapse key, the newest.
AlertDecision alertsToShow(
  List<AppNotification> rows, {
  required Set<String> shown,
  required DateTime since,
  required NotificationPrefs prefs,
  required bool urgentBreaksQuiet,
  required DateTime nowIst,
  required bool centreOpen,
}) {
  final known = {for (final s in shown) s.split('@').first};
  final fresh = [
    for (final r in rows)
      if (!shown.contains(shownKey(r)) &&
          (known.contains(r.id) || !(r.createdAt?.isBefore(since) ?? true)))
        r,
  ];
  return (
    show: centreOpen
        ? const <AppNotification>[]
        : collapseNotifications([
            for (final r in fresh)
              if (r.readAt == null &&
                  mayAlert(
                    r,
                    prefs: prefs,
                    urgentBreaksQuiet: urgentBreaksQuiet,
                    nowIst: nowIst,
                  ))
                r,
          ]),
    seen: {for (final r in fresh) shownKey(r)},
  );
}

/// Local notifications while the app runs (spec §13.3; push is Track B): new notification rows as they sync
/// ([alertsToShow]), and "We found 37 cases" when the user's find-cases search finishes away from the Finding
/// screen (ADR 0013 follow-up). Shown rows are kept in [store] (the last [_keep]), so a restart doesn't repeat them.
class LocalAlerts {
  LocalAlerts({
    required this.notifier,
    required this.store,
    required this.clock,
    required this.location,
  }) : _since = clock().subtract(recent);

  final LocalNotifier notifier;
  final SharedPreferences store;
  final DateTime Function() clock;

  /// The route the user is looking at now; '' while the app is in the background or minimised.
  final String Function() location;

  static const _shownKey = 'notifications.shown';
  static const _keep = 200;

  /// Rows this much older than the service's start still count as new (they arrived while it started).
  static const recent = Duration(minutes: 5);

  /// A row this old when it syncs (after a sleep, Doze or a long offline spell) is only marked seen: yesterday's
  /// "Tomorrow: 6 matters" would now mislead.
  static const stale = Duration(hours: 1);

  /// When this service started, less [recent].
  final DateTime _since;
  late final Set<String> _shown = {...?store.getStringList(_shownKey)};

  /// Find jobs seen unfinished while running.
  final _running = <String>{};

  /// Forgets the shown rows (sign-out).
  static Future<void> forget(SharedPreferences store) =>
      store.remove(_shownKey);

  void _remember(Iterable<String> ids) {
    _shown.addAll(ids);
    final keep = _shown.skip(max(0, _shown.length - _keep)).toList();
    unawaited(store.setStringList(_shownKey, keep));
  }

  /// New synced rows: shows those [alertsToShow] picks, titled and worded exactly as the row.
  Future<void> onRows(
    List<AppNotification> rows, {
    required NotificationPrefs prefs,
    required bool urgentBreaksQuiet,
    required AppLocalizations l,
  }) async {
    if (rows.isEmpty) return;
    final at = clock();
    final cutoff = at.subtract(stale);
    final now = istOf(at);
    final d = alertsToShow(
      rows,
      shown: _shown,
      since: _since.isAfter(cutoff) ? _since : cutoff,
      prefs: prefs,
      urgentBreaksQuiet: urgentBreaksQuiet,
      nowIst: now,
      centreOpen: location().startsWith('/notifications'),
    );
    if (d.seen.isEmpty) return;
    _remember(d.seen);
    for (final n in d.show) {
      final urgent = isUrgent(n, istDay(now));
      await notifier.show(
        LocalNotice(
          tag: n.collapseKey,
          title: n.title ?? '',
          body: n.body ?? '',
          link: n.link ?? '/notifications',
          channelName: urgent
              ? l.notifDataChannelUrgent
              : l.notifDataChannelUpdates,
          urgent: urgent,
        ),
      );
    }
  }

  /// The user's newest find-cases job: once a search seen running here is done, "We found 37 cases. Tap to review."
  /// → /found, unless the user is on Finding or Found cases, or it is quiet hours ([prefs]; the result waits in
  /// Cases' "Found for you"). Only a search seen running: one that finished before the shell started finished on the
  /// Finding screen, which went on to Found cases. Once per job.
  Future<void> onFindJob(
    Job? job,
    AppLocalizations l, {
    required NotificationPrefs prefs,
  }) async {
    if (job == null) return;
    if (!job.finished) {
      _running.add(job.id);
      return;
    }
    if (!_running.remove(job.id) || job.status != JobStatus.done) return;
    final at = location();
    if (at.startsWith('/onboarding/finding') ||
        at.startsWith('/found') ||
        inQuietHours(istOf(clock()), prefs.quietStart, prefs.quietEnd)) {
      return;
    }
    final found = job.result?['found'] as int? ?? job.found;
    await notifier.show(
      LocalNotice(
        tag: 'find:${job.id}',
        title: l.notifDataFindDoneTitle,
        body: l.notifDataFindDone(found),
        link: '/found',
        channelName: l.notifDataChannelUpdates,
      ),
    );
  }
}

/// [LocalAlerts] while the shell is up (it watches this), on the synced rows, the preferences and the newest find
/// job; a fresh one for each signed-in user, so its start belongs to their session. A tap opens the notice's link
/// if it is one of the app's routes. Session.forget stops it.
final localAlertsProvider = Provider<void>((ref) {
  final notifier = ref.watch(localNotifierProvider);
  ref.watch(currentUserIdProvider);
  final alerts = LocalAlerts(
    notifier: notifier,
    store: ref.watch(prefsProvider),
    clock: ref.watch(clockProvider),
    // The top page, pushed ones included (the router's uri leaves pushes out, e.g. the bell's).
    location: () => _looking() ? ref.read(routerProvider).state.uri.path : '',
  );
  unawaited(
    notifier.start((link) {
      final to = appLink(link) ?? (link == '/notifications' ? link : null);
      if (to != null) ref.read(routerProvider).go(to);
    }),
  );
  AppLocalizations l10n() => lookupAppLocalizations(
    ref.read(settingsProvider).locale ?? const Locale('hi'),
  );
  void rows() {
    final (rows, prefs) = (
      ref.read(notificationRowsProvider).value,
      ref.read(notificationPrefsProvider).value,
    );
    if (rows == null || prefs == null) return;
    unawaited(
      alerts.onRows(
        rows,
        prefs: prefs,
        urgentBreaksQuiet: ref.read(settingsProvider).urgentBreaksQuiet,
        l: l10n(),
      ),
    );
  }

  ref
    ..listen(notificationRowsProvider, (_, _) => rows(), fireImmediately: true)
    ..listen(notificationPrefsProvider, (_, _) => rows())
    ..listen(
      latestFindJobProvider,
      (_, job) => unawaited(
        alerts.onFindJob(
          job.value,
          l10n(),
          prefs:
              ref.read(notificationPrefsProvider).value ??
              const NotificationPrefs(),
        ),
      ),
      fireImmediately: true,
    );
});
