import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/features/today/today_refresh.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

/// Today's pull-to-refresh (spec §11.5 on_demand_refresh): one call per case with its own key, recent refreshes
/// count as up to date, and one summary line in either language. Then Today's copy as it reads (widget tests also run
/// under the pseudo-locale, so the exact wording is checked here).
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final hi = lookupAppLocalizations(const Locale('hi'));

  test('each case once with its own key; recent ones are up to date', () async {
    final api = FakeApi(account: ownerAccount)..refreshedRecently.add('m-2');
    final o = await refreshMatters(
      api,
      orgId: 'org-1',
      matterIds: ['m-1', 'm-2', 'm-3', 'm-4'],
    );
    expect((o.checking, o.upToDate, o.offline, o.error), (3, 1, false, null));
    final args = [for (final c in api.calls) c.args! as Map];
    expect({for (final a in args) a['id']}, {'m-1', 'm-2', 'm-3', 'm-4'});
    final keys = {for (final a in args) a['key'] as String};
    expect(keys, hasLength(4));
    expect(keys.every((k) => k.length >= 8), isTrue);
    expect(refreshSummary(en, o), en.todayRefreshChecking(3));
    expect(refreshSummary(en, o), 'Checking 3 cases with the court');
    expect(refreshSummary(hi, o), '3 केस कोर्ट से जाँचे जा रहे हैं');
    // Hindi verbs agree in number.
    expect(hi.todayRefreshChecking(1), '1 केस कोर्ट से जाँचा जा रहा है');
    expect(en.todayRefreshChecking(1), 'Checking 1 case with the court');
  });

  test(
    'all refreshed recently, or nothing to ask: already up to date',
    () async {
      final api = FakeApi(account: ownerAccount)
        ..refreshedRecently.addAll(['m-1', 'm-2']);
      final o = await refreshMatters(
        api,
        orgId: 'org-1',
        matterIds: ['m-1', 'm-2'],
      );
      expect((o.checking, o.upToDate), (0, 2));
      expect(refreshSummary(en, o), en.todayRefreshUpToDate);
      final none = await refreshMatters(api, orgId: 'org-1', matterIds: []);
      expect(refreshSummary(hi, none), hi.todayRefreshUpToDate);
    },
  );

  test('offline, manual cases and other failures', () async {
    final offline = FakeApi(account: ownerAccount)..offline = true;
    final o = await refreshMatters(
      offline,
      orgId: 'org-1',
      matterIds: ['m-1', 'm-2', 'm-3', 'm-4', 'm-5'],
    );
    expect(o.offline, isTrue);
    expect(refreshSummary(en, o), en.todayRefreshOffline);

    final manual = FakeApi(account: ownerAccount)
      ..fail['refreshMatter'] = const ApiException('MANUAL_CASE', status: 409);
    final m = await refreshMatters(manual, orgId: 'org-1', matterIds: ['m-1']);
    expect(refreshSummary(en, m), en.todayRefreshUpToDate);

    final down = FakeApi(
      account: ownerAccount,
    )..fail['refreshMatter'] = const ApiException('COURT_PROVIDER_UNAVAILABLE');
    final d = await refreshMatters(down, orgId: 'org-1', matterIds: ['m-1']);
    expect(refreshSummary(en, d), en.errorProviderDown);
  });

  test(
    'Tomorrow banner and date mismatch read correctly in both languages',
    () {
      expect(en.todayTomorrowBanner(6, 3), 'Tomorrow: 6 matters in 3 courts');
      expect(en.todayTomorrowBanner(1, 1), 'Tomorrow: 1 matter in 1 court');
      expect(hi.todayTomorrowBanner(6, 3), 'कल: 3 कोर्ट में 6 केस');
      expect(en.todayTomorrowLink(3), 'Tomorrow: 3 matters');
      expect(en.todayTomorrowLink(1), 'Tomorrow: 1 matter');
      expect(hi.todayTomorrowLink(3), 'कल: 3 केस');
      expect(
        en.todayAttnMismatch('Thu, 12 Nov', 'Sat, 14 Nov'),
        'Court record says Thu, 12 Nov; you noted Sat, 14 Nov',
      );
    },
  );
}
