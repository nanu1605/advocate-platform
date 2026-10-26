import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/data/device.dart';
import 'package:advocate_app/data/feedback.dart';
import 'package:advocate_app/data/jobs.dart';
import 'package:advocate_app/data/local_notifier.dart';
import 'package:advocate_app/data/notifications.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers.dart';

/// IST wall-clock [h]:[m] on 5 Nov 2026 (see [istOf]).
DateTime _ist(int h, [int m = 0]) => DateTime.utc(2026, 11, 5, h, m);

/// Notifications (spec §13): collapse, preferences rows, quiet hours, what becomes an OS notification, links.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final hi = lookupAppLocalizations(const Locale('hi'));

  group('collapse and sections', () {
    test(
      'rows sharing a collapse key show the newest, with the rest folded',
      () {
        final rows = [
          notification(1, collapseKey: 'next_date_set:m-1'),
          notification(2),
          notification(3, collapseKey: 'next_date_set:m-1', read: true),
          notification(4, collapseKey: 'next_date_set:m-1'),
        ];
        final items = collapseNotifications(rows);
        expect(items.map((n) => n.id), ['n-1', 'n-2']);
        expect(items.first.earlier.map((n) => n.id), ['n-3', 'n-4']);
        expect(items.first.ids, ['n-1', 'n-3', 'n-4']);
        // A group is unread while any of it is.
        final readHead = collapseNotifications([
          notification(1, read: true, collapseKey: 'k'),
          notification(2, collapseKey: 'k'),
        ]).single;
        expect(readHead.unread, isTrue);
      },
    );

    test('a row without a collapse key stands alone', () {
      const a = AppNotification(id: 'a', kind: 'sync_issue');
      const b = AppNotification(id: 'b', kind: 'sync_issue');
      expect(collapseNotifications([a, b]).length, 2);
    });

    test('Today / Yesterday / Earlier by the IST day', () {
      final today = DateTime.utc(2026, 11, 5);
      final items = [
        // 00:10 IST on the 5th is 18:40 UTC on the 4th.
        notification(1, createdAt: DateTime.utc(2026, 11, 4, 18, 40)),
        notification(2, createdAt: DateTime.utc(2026, 11, 4, 18, 20)),
        notification(3, createdAt: DateTime.utc(2026, 11, 4, 6)),
        notification(4, createdAt: DateTime.utc(2026, 10)),
      ];
      final sections = notificationSections(items, today);
      expect(sections.map((s) => s.day), NotificationDay.values);
      expect(sections.map((s) => s.items.map((n) => n.id).toList()), [
        ['n-1'],
        ['n-2', 'n-3'],
        ['n-4'],
      ]);
    });
  });

  test('only the routes notifications open are links', () {
    for (final ok in [
      '/today',
      '/board/tomorrow',
      '/found',
      '/cases/9f1c2a4e-1111-4222-8333-444455556666',
    ]) {
      expect(appLink(ok), ok);
    }
    for (final bad in [
      null,
      3,
      '',
      'https://evil.test/cases/1',
      '/cases/1/../../settings',
      '/settings',
      '/cases/1?x=y',
      '/today/',
    ]) {
      expect(appLink(bad), isNull, reason: '$bad');
    }
    expect(notification(1, link: '/elsewhere').link, isNull);
  });

  group('preferences', () {
    test('row ids are v5 UUIDs of user and kind, the same on every device', () {
      final id = prefsRowId('user-1', 'new_order');
      // Python: uuid.uuid5(UUID('24cc73e1-d649-4f6f-bab6-8c3662d30cb6'), 'user-1:new_order')
      expect(id, '847d578c-8589-577a-868b-234ddd72bdfa');
      expect(prefsRowId('user-1', 'new_order'), id);
      expect(prefsRowId('user-1', 'next_date_set'), isNot(id));
      expect(prefsRowId('user-2', 'new_order'), isNot(id));
      expect(
        uuidV5('24cc73e1-d649-4f6f-bab6-8c3662d30cb6', 'x'),
        matches(RegExp('^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab]')),
      );
    });

    test('read from rows: off kinds, titles and quiet hours of the newest', () {
      expect(
        NotificationPrefs.fromRows(const []).quietStart,
        defaultQuietStart,
      );
      final p = NotificationPrefs.fromRows(const [
        {
          'kind': 'new_order',
          'channels': '[]',
          'quiet_start': '23:30:00',
          'quiet_end': '06:00:00',
          'include_titles': 1,
        },
        {
          'kind': 'tomorrow_board',
          'channels': '["push"]',
          'quiet_start': '22:00:00',
          'quiet_end': '07:00:00',
          'include_titles': 0,
        },
      ]);
      expect(p.off, {'new_order'});
      expect(p.enabled('new_order'), isFalse);
      expect(p.enabled('tomorrow_board'), isTrue);
      expect(p.enabled('deadline_due'), isTrue);
      expect(p.includeTitles, isTrue);
      expect(p.quietStart, const Duration(hours: 23, minutes: 30));
      expect(p.quietEnd, const Duration(hours: 6));
    });

    test('every P1 kind has a label in both languages', () {
      for (final l in [en, hi]) {
        final labels = {
          for (final k in notificationKinds) notificationKindLabel(l, k),
        };
        expect(labels.length, notificationKinds.length);
        expect(labels, isNot(contains(l.notifDataKindOther)));
      }
    });
  });

  group('quiet hours (IST)', () {
    const start = Duration(hours: 22);
    const end = Duration(hours: 7);

    test('an overnight window wraps across midnight', () {
      expect(inQuietHours(_ist(21, 59), start, end), isFalse);
      expect(inQuietHours(_ist(22), start, end), isTrue);
      expect(inQuietHours(_ist(23, 59), start, end), isTrue);
      expect(inQuietHours(_ist(0), start, end), isTrue);
      expect(inQuietHours(_ist(6, 59), start, end), isTrue);
      expect(inQuietHours(_ist(7), start, end), isFalse);
      expect(inQuietHours(_ist(12), start, end), isFalse);
    });

    test('a daytime window, and equal times meaning none', () {
      const s = Duration(hours: 13);
      const e = Duration(hours: 14, minutes: 30);
      expect(inQuietHours(_ist(12, 59), s, e), isFalse);
      expect(inQuietHours(_ist(14), s, e), isTrue);
      expect(inQuietHours(_ist(14, 30), s, e), isFalse);
      expect(inQuietHours(_ist(23), start, start), isFalse);
    });

    test('urgent kinds break quiet hours unless the user turned that off', () {
      final night = _ist(23, 15);
      const prefs = NotificationPrefs();
      final listed = notification(1, kind: 'listed_unexpectedly');
      final dueToday = notification(
        2,
        kind: 'deadline_due',
        data: {'due_date': '2026-11-05'},
      );
      final dueLater = notification(
        3,
        kind: 'deadline_due',
        data: {'due_date': '2026-11-08'},
      );
      final order = notification(4);
      bool may(AppNotification n, {bool urgent = true, DateTime? at}) =>
          mayAlert(
            n,
            prefs: prefs,
            urgentBreaksQuiet: urgent,
            nowIst: at ?? night,
          );
      expect(may(listed), isTrue);
      expect(may(dueToday), isTrue);
      expect(may(dueLater), isFalse);
      expect(may(order), isFalse);
      expect(may(listed, urgent: false), isFalse);
      expect(may(dueToday, urgent: false), isFalse);
      expect(may(order, at: _ist(10)), isTrue);
      // A kind turned off never alerts, urgent or not.
      expect(
        mayAlert(
          listed,
          prefs: const NotificationPrefs(off: {'listed_unexpectedly'}),
          urgentBreaksQuiet: true,
          nowIst: _ist(10),
        ),
        isFalse,
      );
    });
  });

  group('which rows become OS notifications', () {
    final since = testNow.subtract(LocalAlerts.recent);
    AlertDecision decide(
      List<AppNotification> rows, {
      Set<String> shown = const {},
      NotificationPrefs prefs = const NotificationPrefs(),
      DateTime? nowIst,
      bool centreOpen = false,
      bool urgentBreaksQuiet = true,
    }) => alertsToShow(
      rows,
      shown: shown,
      since: since,
      prefs: prefs,
      urgentBreaksQuiet: urgentBreaksQuiet,
      nowIst: nowIst ?? istOf(testNow),
      centreOpen: centreOpen,
    );

    test('new rows show; old ones (a first sync, a reinstall) never do', () {
      final fresh = notification(
        1,
        createdAt: testNow.add(const Duration(minutes: 1)),
      );
      final recent = notification(2, createdAt: since);
      final old = notification(
        3,
        createdAt: since.subtract(const Duration(seconds: 1)),
      );
      const undated = AppNotification(id: 'x', kind: 'new_order');
      final d = decide([fresh, recent, old, undated]);
      expect(d.show.map((n) => n.id), ['n-1', 'n-2']);
      expect(d.seen, {shownKey(fresh), shownKey(recent)});
    });

    test('a row shown before, or already read, is not shown', () {
      final read = notification(2, read: true);
      final d = decide(
        [notification(1), read],
        shown: {shownKey(notification(1))},
      );
      expect(d.show, isEmpty);
      expect(d.seen, {shownKey(read)});
    });

    test(
      'a row the server rewrote shows again, old as it is; unchanged, not',
      () {
        // Last evening's board, already shown, rewritten by a later attempt with a new count.
        final before = notification(
          1,
          kind: 'tomorrow_board',
          body: 'Tomorrow: 6 matters in 3 courts.',
          createdAt: since.subtract(const Duration(hours: 2)),
        );
        final after = notification(
          1,
          kind: 'tomorrow_board',
          body: 'Tomorrow: 8 matters in 3 courts.',
          createdAt: before.createdAt,
        );
        final d = decide([after], shown: {shownKey(before)});
        expect(d.show.single.body, 'Tomorrow: 8 matters in 3 courts.');
        expect(d.seen, {shownKey(after)});
        expect(decide([after], shown: {shownKey(after)}).seen, isEmpty);
      },
    );

    test('of rows sharing a collapse key, the newest', () {
      final rows = [
        notification(1, collapseKey: 'tomorrow_board:org-1'),
        notification(2, collapseKey: 'tomorrow_board:org-1'),
      ];
      final d = decide(rows);
      expect(d.show.map((n) => n.id), ['n-1']);
      expect(d.seen, rows.map(shownKey).toSet());
    });

    test('a kind turned off, or quiet hours, holds it back for good', () {
      final rows = [notification(1)];
      final off = decide(
        rows,
        prefs: const NotificationPrefs(off: {'new_order'}),
      );
      expect(off.show, isEmpty);
      expect(off.seen, {shownKey(rows.single)});
      final night = decide(rows, nowIst: _ist(23));
      expect(night.show, isEmpty);
      expect(night.seen, {shownKey(rows.single)});
      final listed = decide([
        notification(2, kind: 'listed_unexpectedly'),
      ], nowIst: _ist(23));
      expect(listed.show.single.id, 'n-2');
    });

    test('nothing pops up while the centre is open', () {
      final d = decide([notification(1)], centreOpen: true);
      expect(d.show, isEmpty);
      expect(d.seen, {shownKey(notification(1))});
    });
  });

  group('LocalAlerts', () {
    late SharedPreferences store;
    late FakeLocalNotifier notifier;
    var at = '/today';

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      store = await SharedPreferences.getInstance();
      notifier = FakeLocalNotifier();
      at = '/today';
    });

    LocalAlerts alerts([DateTime? now]) => LocalAlerts(
      notifier: notifier,
      store: store,
      clock: () => now ?? testNow,
      location: () => at,
    );

    Future<void> rows(LocalAlerts a, List<AppNotification> rows) => a.onRows(
      rows,
      prefs: const NotificationPrefs(),
      urgentBreaksQuiet: true,
      l: en,
    );

    test(
      'shows a new row exactly as written, tagged with its collapse key',
      () async {
        final a = alerts();
        final row = notification(
          1,
          kind: 'listed_unexpectedly',
          title: 'Listed early',
          body: 'WP 1001/2024 is listed tomorrow (earlier than expected).',
        );
        await rows(a, [row]);
        final n = notifier.shown.single;
        expect(n.title, 'Listed early');
        expect(
          n.body,
          'WP 1001/2024 is listed tomorrow (earlier than expected).',
        );
        expect(n.tag, 'listed_unexpectedly:m-1');
        expect(n.link, '/cases/m-1');
        expect(n.urgent, isTrue);
        expect(n.channelName, en.notifDataChannelUrgent);
        // The same rows again (another emission): nothing new.
        await rows(a, [row]);
        expect(notifier.shown, hasLength(1));
      },
    );

    test('the start is when the service started, not when the first row came', () async {
      var now = testNow;
      final a = LocalAlerts(
        notifier: notifier,
        store: store,
        clock: () => now,
        location: () => at,
      );
      // A junior with no rows yet: their first board syncs late, after a doze.
      now = testNow.add(const Duration(minutes: 50));
      await rows(a, [
        notification(1, createdAt: testNow.add(const Duration(minutes: 1))),
      ]);
      expect(notifier.shown, hasLength(1));
    });

    test('rows that sync long after they were written never pop up', () async {
      var now = testNow;
      final b = LocalAlerts(
        notifier: notifier,
        store: store,
        clock: () => now,
        location: () => at,
      );
      // The laptop slept overnight with the app open; at 09:00 IST last evening's board and this morning's summary
      // arrive.
      final woke = now = testNow.add(const Duration(hours: 23));
      final late = [
        notification(
          1,
          kind: 'today_morning',
          createdAt: woke.subtract(const Duration(hours: 2)),
        ),
        notification(
          2,
          kind: 'tomorrow_board',
          createdAt: testNow.add(const Duration(hours: 9)),
        ),
      ];
      await rows(b, late);
      expect(notifier.shown, isEmpty);
      // One written minutes ago still shows.
      await rows(b, [
        notification(3, createdAt: woke.subtract(const Duration(minutes: 10))),
      ]);
      expect(notifier.shown.single.body, 'New order in WP 1003/2024.');
    });

    test('a restart remembers what was shown', () async {
      await rows(alerts(), [notification(1)]);
      await rows(alerts(testNow.add(const Duration(minutes: 1))), [
        notification(1),
      ]);
      expect(notifier.shown, hasLength(1));
      await LocalAlerts.forget(store);
      expect(store.getStringList('notifications.shown'), isNull);
    });

    test('a notice goes from the tray once its row is deleted, out of the window or read', () async {
      final a = alerts();
      final shared = [
        notification(1, collapseKey: 'tomorrow_board:2026-11-06'),
        notification(2, collapseKey: 'tomorrow_board:2026-11-06'),
      ];
      await rows(a, [notification(3), notification(4), ...shared]);
      expect(notifier.shown, hasLength(3));
      // The server deletes row 3 (or it leaves the 90-day window): it no longer syncs.
      await rows(a, [notification(4), ...shared]);
      expect(notifier.cancelledTags, ['new_order:m-3']);
      // Read on another device.
      await rows(a, [notification(4, read: true), ...shared]);
      expect(notifier.cancelledTags, ['new_order:m-3', 'new_order:m-4']);
      // Rows sharing a collapse key share one notice: it stays while one of them is still there and unread.
      await rows(a, [shared.last]);
      expect(notifier.cancelledTags, hasLength(2));
      await rows(a, []);
      expect(notifier.cancelledTags.last, 'tomorrow_board:2026-11-06');
      // Each notice is taken back once.
      await rows(a, []);
      expect(notifier.cancelledTags, hasLength(3));
    });

    test('a notice whose row was deleted while the app was closed goes on the next start', () async {
      await rows(alerts(), [notification(1), notification(2)]);
      await rows(alerts(testNow.add(const Duration(hours: 2))), [
        notification(2),
      ]);
      expect(notifier.cancelledTags, ['new_order:m-1']);
      // Sign-out forgets the tray too (and clears it).
      await LocalAlerts.forget(store);
      expect(store.getStringList('notifications.tray'), isNull);
    });

    test('a row without a valid link opens the centre', () async {
      await rows(alerts(), [notification(1, link: 'https://x.test')]);
      expect(notifier.shown.single.link, '/notifications');
    });

    test('nothing while the user is in the centre', () async {
      at = '/notifications';
      await rows(alerts(), [notification(1)]);
      expect(notifier.shown, isEmpty);
    });

    Job find(JobStatus status, {int found = 0, String id = 'job-1'}) => Job(
      id: id,
      kind: 'find_cases',
      status: status,
      progress: {'found': found},
      result: status == JobStatus.done ? {'found': found} : null,
    );

    Future<void> job(LocalAlerts a, Job j, [AppLocalizations? l]) =>
        a.onFindJob(j, l ?? en, prefs: const NotificationPrefs());

    test('a search seen running says how many cases it found, once', () async {
      final a = alerts();
      await job(a, find(JobStatus.running, found: 12), hi);
      expect(notifier.shown, isEmpty);
      await job(a, find(JobStatus.done, found: 37), hi);
      final n = notifier.shown.single;
      expect(n.body, hi.notifDataFindDone(37));
      expect(n.body, contains('37'));
      expect(n.title, hi.notifDataFindDoneTitle);
      expect(n.link, '/found');
      await job(a, find(JobStatus.done, found: 37), hi);
      expect(notifier.shown, hasLength(1));
    });

    test('a search finished before the shell started (on Finding, then Found) says nothing', () async {
      // A new owner reaches Today minutes after reviewing the results.
      await job(alerts(), find(JobStatus.done, found: 3));
      expect(notifier.shown, isEmpty);
    });

    test('no notice on Finding or Found cases, in quiet hours, nor for a failed search', () async {
      final a = alerts();
      for (final (id, where) in [
        ('job-1', '/onboarding/finding'),
        ('job-2', '/found'),
      ]) {
        at = where;
        await job(a, find(JobStatus.running, id: id));
        await job(a, find(JobStatus.done, found: 5, id: id));
      }
      at = '/today';
      // 23:00 IST (17:30 UTC): the result waits in Cases' "Found for you".
      final night = alerts(DateTime.utc(2026, 11, 5, 17, 30));
      await job(night, find(JobStatus.running, id: 'job-3'));
      await job(night, find(JobStatus.done, found: 5, id: 'job-3'));
      await job(a, find(JobStatus.running, id: 'job-4'));
      await job(a, find(JobStatus.failed, id: 'job-4'));
      expect(notifier.shown, isEmpty);
    });

    test('the find message prints the count in Hindi too', () {
      expect(hi.notifDataFindDone(1), contains('1'));
      expect(en.notifDataFindDone(0), isNot(contains('0')));
    });
  });

  test('a notice id is a stable 31-bit number per tag', () {
    const a = LocalNotice(
      tag: 'new_order:m-1',
      title: '',
      body: '',
      link: '/today',
      channelName: '',
    );
    const b = LocalNotice(
      tag: 'new_order:m-2',
      title: '',
      body: '',
      link: '/today',
      channelName: '',
    );
    expect(a.id, a.id);
    expect(a.id, isNot(b.id));
    expect(a.id, inInclusiveRange(0, 0x7fffffff));
    // FNV-1a of the tag, the same on every run (Dart's hashCode isn't).
    expect(
      const LocalNotice(
        tag: 'a',
        title: '',
        body: '',
        link: '',
        channelName: '',
      ).id,
      0xe40c292c & 0x7fffffff,
    );
  });

  test('feedback names the screen as a route pattern, never ids or names', () {
    expect(screenPattern('/cases/:id'), '/cases/:id');
    expect(
      screenPattern('/cases/:id/orders/:orderId'),
      '/cases/:id/orders/:orderId',
    );
    expect(
      screenPattern('/cases/9f1c2a4e-1111-4222-8333-444455556666'),
      '/cases/:id',
    );
    expect(screenPattern('/cases/m-12/orders/o-3'), '/cases/:id/orders/:id');
    expect(screenPattern('/join/ABCD2345'), '/join/:id');
    expect(screenPattern('/cases?q=sharma&tab=notes'), '/cases');
    expect(screenPattern('/clients/Ramesh Sharma'), '/clients/:id');
    expect(screenPattern('/sign-in/otp'), '/sign-in/otp');
    expect(
      screenPattern('/settings/notifications#x'),
      '/settings/notifications',
    );
    expect(screenPattern(''), '/');
  });
}
