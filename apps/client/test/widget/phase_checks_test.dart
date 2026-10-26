import 'dart:io';

import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/router.dart';
import 'package:advocate_app/core/theme/app_theme.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/feedback.dart';
import 'package:advocate_app/data/found_cases.dart';
import 'package:advocate_app/data/jobs.dart';
import 'package:advocate_app/features/board/board_screen.dart';
import 'package:advocate_app/features/board/board_share.dart';
import 'package:advocate_app/features/calendar/calendar_screen.dart';
import 'package:advocate_app/features/case_page/case_page.dart';
import 'package:advocate_app/features/case_page/links.dart';
import 'package:advocate_app/features/cases/cases_screen.dart';
import 'package:advocate_app/features/cases/manual_case_screen.dart';
import 'package:advocate_app/features/cases/search_cases_screen.dart';
import 'package:advocate_app/features/clients/client_profile.dart';
import 'package:advocate_app/features/clients/clients_screen.dart';
import 'package:advocate_app/features/dashboard/dashboard_screen.dart';
import 'package:advocate_app/features/documents/documents_screen.dart';
import 'package:advocate_app/features/documents/upload_flow.dart';
import 'package:advocate_app/features/documents/viewer_screen.dart';
import 'package:advocate_app/features/found_cases/found_cases_screen.dart';
import 'package:advocate_app/features/lock/app_lock.dart';
import 'package:advocate_app/features/lock/lock_screen.dart';
import 'package:advocate_app/features/notifications/notification_centre.dart';
import 'package:advocate_app/features/notifications/notification_prefs_screen.dart';
import 'package:advocate_app/features/onboarding/account_loading_screen.dart';
import 'package:advocate_app/features/onboarding/consent_screen.dart';
import 'package:advocate_app/features/onboarding/details_screen.dart';
import 'package:advocate_app/features/onboarding/finding_screen.dart';
import 'package:advocate_app/features/onboarding/join_screen.dart';
import 'package:advocate_app/features/onboarding/language_screen.dart';
import 'package:advocate_app/features/onboarding/lock_setup_screen.dart';
import 'package:advocate_app/features/onboarding/notifications_screen.dart';
import 'package:advocate_app/features/onboarding/role_screen.dart';
import 'package:advocate_app/features/onboarding/sign_in_screens.dart';
import 'package:advocate_app/features/settings/settings_screen.dart';
import 'package:advocate_app/features/shell/screens.dart';
import 'package:advocate_app/features/team/team_screen.dart';
import 'package:advocate_app/features/today/today_screen.dart';
import 'package:advocate_app/ui/command_palette.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';
import 'board_test.dart' show boardSample;
import 'case_page_test.dart' show sampleCases;
import 'documents_test.dart' show FakeSources, fakeFile, sampleQueue;
import 'notifications_test.dart' show sampleNotifications;
import 'today_test.dart' show sampleDiary;

/// Phase checks (task 12; spec §5.9, §5.13, §16.4): every screen, sheet and dialog in one place, in English and
/// Hindi at 100% and 200% text, on a 360 dp phone and the smallest Windows window (1024 × 640). Each must open
/// without an exception or overflow, with 48 dp, labelled tap targets; shell screens also open offline under the
/// banner. A guard fails when lib/core/router.dart gains a route no scene opens. English also runs here under
/// tools/pseudo_l10n.py (+40% text).
///
/// A scene opens once per language and window size (pumpApp, then its taps) at 100% text; the OS text size then
/// goes to 200% in place.

/// Where the device is in Phase 0's first run; [app] is past it.
enum _Stage { welcome, signIn, consent, appLock, locked, app }

class _Scene {
  const _Scene(
    this.name, {
    required this.shows,
    this.route,
    this.location = '/today',
    this.open,
    this.account = ownerAccount,
    this.onboardingDone = true,
    this.stage = _Stage.app,
    this.data = _world,
    this.found = const [],
    this.shell = false,
    this.still = false,
    this.offlineApi = false,
    this.desktopOnly = false,
  });

  final String name;

  /// The router path this scene stands for (the guard checks every path has one).
  final String? route;
  final String location;

  /// What proves the scene is open, in the language on screen.
  final Finder Function(AppLocalizations l) shows;

  /// Taps, in the scene's language at 100% text, from [location] to the sheet or dialog.
  final Future<void> Function(WidgetTester tester, AppLocalizations l)? open;
  final Account account;
  final bool? onboardingDone;
  final _Stage stage;
  final List<Override> Function() data;
  final List<FoundCase> found;

  /// Inside the shell: also opened offline.
  final bool shell;

  /// Reduce motion, for screens whose progress ring turns until the work ends.
  final bool still;

  /// Every API call fails as offline from the start (nothing cached).
  final bool offlineApi;
  final bool desktopOnly;
}

const _phone = Size(360, 800);
const _desktop = Size(1024, 640);

final _invite = Invite(
  id: 'inv-old',
  code: 'QWER7890',
  role: 'clerk',
  phone: '919876543210',
  expiresAt: testNow.add(const Duration(days: 5)),
);

CaseHit _hit(int n, {bool tracked = false}) => CaseHit(
  cnr: 'MPHC01${n.toString().padLeft(10, '0')}',
  courtCode: 'MPHC01',
  caseType: 'WP',
  caseNumber: '${1000 + n}',
  caseYear: 2024,
  title: 'Sharma v. State of MP',
  status: 'pending',
  nextHearingDate: DateTime.utc(2026, 11, 12),
  advocates: const [(name: 'R. K. Verma', side: 'petitioner')],
  tracked: tracked,
);

/// The API every scene talks to: [account], a pending invite, two search hits with more to load, a running search.
FakeApi _api(Account account) => FakeApi(account: account)
  ..invites.add(_invite)
  ..searchPages = [
    CaseSearchPage(
      items: [_hit(1), _hit(2, tracked: true)],
      total: 30,
      page: 1,
      hasNext: true,
    ),
  ]
  ..jobs['job-1'] = const Job(
    id: 'job-1',
    kind: 'find_cases',
    status: JobStatus.running,
    progress: {
      'found': 12,
      'groups': [
        {'key': 'HC', 'state': 'done', 'found': 12},
        {'key': 'DC', 'state': 'running', 'found': 0},
        {'key': 'SC', 'state': 'pending', 'found': 0},
      ],
    },
  );

/// The synced data behind the shell: Today and tomorrow's board, the case page's sample (three found cases to
/// review), the upload queue, and the device services sheets reach.
List<Override> _world() => [
  ...sampleDiary(tomorrow: boardSample()).overrides,
  ...sampleCases(pendingFound: 3).caseOverrides,
  ..._services(),
];

/// As [_world], with notifications instead of the diary (the two fakes can't share the notification writer).
List<Override> _notifications() => [
  ...sampleCases(pendingFound: 3).overrides,
  ...sampleNotifications().overrides,
  ..._services(),
];

List<Override> _services() => [
  ...FakeDocuments(queue: sampleQueue()).overrides,
  uploadSourcesProvider.overrideWithValue(
    FakeSources(files: [fakeFile('Rejoinder final.pdf')]),
  ),
  courtsByCodeProvider.overrideWithValue(AsyncData({'MPHC01': testCourts[0]})),
  openExternalProvider.overrideWithValue((_) async => true),
  shareProvider.overrideWithValue((_) async {}),
  appVersionProvider.overrideWithValue(const AsyncData('0.1.0')),
  pendingChanges(),
  FakePermission().asOverride,
];

final List<FoundCase> _foundSample = [
  foundCase(1, nextDate: DateTime(2026, 11, 5)),
  foundCase(2, confidence: 'low', title: 'Gupta v. Jain'),
  foundCase(
    3,
    courtId: 'c0000000-0000-0000-0000-000000000005',
    caseType: 'CS',
    caseYear: 2019,
  ),
  foundCase(4, status: 'disposed', title: 'Verma v. State'),
];

Finder _sheet(AppLocalizations _) => find.byType(BottomSheet);

/// Brings [f] into view (scrolling the first scrollable under [within] until it is built), then taps it.
Future<void> _tap(WidgetTester tester, Finder f, {Finder? within}) async {
  if (f.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      f,
      200,
      scrollable: find
          .descendant(
            of: within ?? find.byType(Scaffold).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
  }
  // Settled first: a field just typed in scrolls itself back into view.
  await tester.pumpAndSettle();
  final target = f.first;
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

final Finder _casePage = find.byType(CasePage);

Future<void> _caseMenu(WidgetTester t, AppLocalizations l, String item) async {
  await _tap(t, find.byTooltip(l.casePageMore));
  await _tap(t, find.text(item));
}

Future<void> _plus(WidgetTester t, AppLocalizations l) =>
    _tap(t, find.byTooltip(l.navAdd));

Future<void> _teamMenu(WidgetTester t, AppLocalizations l, String item) async {
  await _tap(t, find.byTooltip(l.boardMoreActions('Neha Verma')));
  await _tap(t, find.text(item));
}

final _scenes = <_Scene>[
  // Phase 0: the first run, and the lock over the app.
  _Scene(
    'welcome',
    route: '/welcome',
    location: '/welcome',
    stage: _Stage.welcome,
    shows: (_) => find.byType(LanguageScreen),
  ),
  _Scene(
    'sign-in phone',
    route: '/sign-in',
    location: '/sign-in',
    stage: _Stage.signIn,
    shows: (_) => find.byType(PhoneScreen),
  ),
  _Scene(
    'sign-in code',
    route: '/sign-in/otp',
    location: '/sign-in',
    stage: _Stage.signIn,
    open: (t, l) async {
      container(t).read(routerProvider).go('/sign-in/otp', extra: '9876543210');
      await t.pumpAndSettle();
    },
    shows: (_) => find.byType(OtpScreen),
  ),
  _Scene(
    'consent',
    route: '/consent',
    location: '/consent',
    stage: _Stage.consent,
    shows: (_) => find.byType(ConsentScreen),
  ),
  _Scene(
    'app lock setup',
    route: '/app-lock',
    location: '/app-lock',
    stage: _Stage.appLock,
    shows: (_) => find.byType(LockSetupScreen),
  ),
  _Scene(
    'lock screen',
    stage: _Stage.locked,
    shows: (_) => find.byType(LockScreen),
  ),
  _Scene(
    'account loading, offline',
    route: '/loading',
    location: '/loading',
    offlineApi: true,
    onboardingDone: null,
    shows: (_) => find.byType(AccountLoadingScreen),
  ),
  // Onboarding.
  _Scene(
    'role',
    route: '/onboarding/role',
    location: '/onboarding/role',
    account: newAccount,
    onboardingDone: null,
    shows: (_) => find.byType(RoleScreen),
  ),
  _Scene(
    'join',
    route: '/onboarding/join',
    location: '/onboarding/join',
    account: newAccount,
    onboardingDone: null,
    shows: (_) => find.byType(JoinScreen),
  ),
  _Scene(
    'join by link',
    route: '/join/:code',
    location: '/join/ABCD2345',
    account: newAccount,
    onboardingDone: null,
    shows: (_) => find.byType(JoinScreen),
  ),
  _Scene(
    'details',
    route: '/onboarding/details',
    location: '/onboarding/details',
    account: newAccount,
    onboardingDone: null,
    shows: (_) => find.byType(DetailsScreen),
  ),
  _Scene(
    'details, chamber',
    location: '/onboarding/details?kind=chamber',
    account: newAccount,
    onboardingDone: null,
    shows: (l) => find.text(l.onboardingDetailsChamber),
  ),
  _Scene(
    'finding',
    route: '/onboarding/finding',
    location: '/onboarding/finding',
    onboardingDone: false,
    still: true,
    shows: (_) => find.byType(FindingScreen),
  ),
  _Scene(
    'finding, searching',
    location: '/onboarding/finding',
    onboardingDone: false,
    still: true,
    open: (t, l) => _tap(t, find.text(l.findingStart)),
    shows: (l) => find.text(l.findingStop),
  ),
  _Scene(
    'found cases',
    route: '/found',
    location: '/found',
    found: _foundSample,
    shows: (_) => find.byType(FoundCasesScreen),
  ),
  _Scene(
    'found cases filters',
    location: '/found',
    found: _foundSample,
    open: (t, l) => _tap(t, find.text(l.foundFilters(0))),
    shows: _sheet,
  ),
  _Scene(
    'found cases, check the unsure one',
    location: '/found',
    found: _foundSample,
    open: (t, l) => _tap(t, find.text(l.foundAddAll(3))),
    shows: (l) => find.text(l.foundLowTitle(1)),
  ),
  _Scene(
    'onboarding notifications',
    route: '/onboarding/notifications',
    location: '/onboarding/notifications',
    account: juniorAccount,
    onboardingDone: false,
    shows: (_) => find.byType(NotificationsScreen),
  ),
  // The shell's routes.
  _Scene(
    'today',
    route: '/today',
    shell: true,
    shows: (_) => find.byType(TodayScreen),
  ),
  _Scene(
    "tomorrow's board",
    route: '/board/tomorrow',
    location: '/board/tomorrow',
    shell: true,
    shows: (_) => find.byType(BoardScreen),
  ),
  _Scene(
    'cases',
    route: '/cases',
    location: '/cases',
    shell: true,
    shows: (_) => find.byType(CasesScreen),
  ),
  _Scene(
    'search the courts',
    route: '/cases/search',
    location: '/cases/search',
    shell: true,
    shows: (_) => find.byType(SearchCasesScreen),
  ),
  _Scene(
    'search the courts, results',
    location: '/cases/search',
    open: (t, l) async {
      await t.enterText(
        find.widgetWithText(TextField, l.addCaseParty),
        'Sharma',
      );
      await _tap(t, find.text(l.addCaseSearchAction));
    },
    shows: (l) => find.text(l.addCaseTrack),
  ),
  _Scene(
    'add by hand',
    route: '/cases/manual',
    location: '/cases/manual',
    shell: true,
    shows: (_) => find.byType(ManualCaseScreen),
  ),
  _Scene(
    'case page, timeline',
    route: '/cases/:id',
    location: '/cases/m-1',
    shell: true,
    shows: (_) => _casePage,
  ),
  for (final tab in ['documents', 'notes', 'client'])
    _Scene(
      'case page, $tab',
      location: '/cases/m-1?tab=$tab',
      shell: true,
      shows: (_) => _casePage,
    ),
  _Scene(
    'order viewer',
    route: '/cases/:id/orders/:orderId',
    location: '/cases/m-1/orders/o-1',
    shell: true,
    shows: (_) => find.byType(ViewerScreen),
  ),
  _Scene(
    'more',
    route: '/more',
    location: '/more',
    shell: true,
    shows: (_) => find.byType(MoreScreen),
  ),
  _Scene(
    'settings',
    route: '/settings',
    location: '/settings',
    shell: true,
    shows: (_) => find.byType(SettingsScreen),
  ),
  _Scene(
    'notification preferences',
    route: '/settings/notifications',
    location: '/settings/notifications',
    data: _notifications,
    shell: true,
    shows: (_) => find.byType(NotificationPrefsScreen),
  ),
  _Scene(
    'notification centre',
    route: '/notifications',
    location: '/notifications',
    data: _notifications,
    shell: true,
    shows: (_) => find.byType(NotificationCentre),
  ),
  _Scene(
    'team',
    route: '/team',
    location: '/team',
    shell: true,
    shows: (_) => find.byType(TeamScreen),
  ),
  _Scene(
    'dashboard',
    route: '/dashboard',
    location: '/dashboard',
    shell: true,
    shows: (_) => find.byType(DashboardScreen),
  ),
  _Scene(
    'calendar',
    route: '/calendar',
    location: '/calendar',
    shell: true,
    shows: (_) => find.byType(CalendarScreen),
  ),
  for (final view in [CalendarView.day, CalendarView.week, CalendarView.agenda])
    _Scene(
      'calendar, ${view.name}',
      location: '/calendar',
      open: (t, l) async {
        container(t).read(calendarPrefsProvider.notifier).setView(view);
        await t.pumpAndSettle();
      },
      shows: (_) => find.byType(CalendarScreen),
    ),
  _Scene(
    'clients',
    route: '/clients',
    location: '/clients',
    shell: true,
    shows: (_) => find.byType(ClientsScreen),
  ),
  _Scene(
    'client profile',
    route: '/clients/:id',
    location: '/clients/cl-1',
    shell: true,
    shows: (_) => find.byType(ClientProfile),
  ),
  _Scene(
    'documents',
    route: '/documents',
    location: '/documents',
    shell: true,
    shows: (_) => find.byType(DocumentsScreen),
  ),
  _Scene(
    'document viewer',
    route: '/documents/:id',
    location: '/documents/d-1',
    shell: true,
    shows: (_) => find.byType(ViewerScreen),
  ),
  // Sheets and dialogs.
  _Scene('add sheet', open: _plus, shows: (l) => find.text(l.addDocument)),
  _Scene(
    'add case chooser',
    open: (t, l) async {
      await _plus(t, l);
      await _tap(t, find.text(l.addCase));
    },
    shows: (l) => find.text(l.casesAddTitle),
  ),
  _Scene(
    'add by CNR',
    open: (t, l) async {
      await _plus(t, l);
      await _tap(t, find.text(l.addCase));
      await _tap(t, find.text(l.casesAddByCnr));
    },
    shows: (l) => find.text(l.foundCnrTitle),
  ),
  _Scene(
    'task sheet, its case picker',
    open: (t, l) async {
      await _plus(t, l);
      await _tap(t, find.text(l.addTask));
      await _tap(t, find.text(l.casePageCase));
    },
    shows: (l) => find.widgetWithText(TextField, l.searchCasesHint),
  ),
  _Scene(
    'cases filters',
    location: '/cases',
    open: (t, l) => _tap(t, find.text(l.foundFilters(0))),
    shows: _sheet,
  ),
  _Scene(
    'board, assign to',
    location: '/board/tomorrow',
    open: (t, l) => _tap(t, find.text(l.boardAssignTo)),
    shows: _sheet,
  ),
  _Scene(
    'board, share',
    location: '/board/tomorrow',
    open: (t, l) => _tap(t, find.byTooltip(l.boardShare)),
    shows: _sheet,
  ),
  _Scene(
    'case page, share',
    location: '/cases/m-1',
    open: (t, l) => _tap(t, find.byTooltip(l.casePageShare)),
    shows: _sheet,
  ),
  _Scene(
    'case page, assign to',
    location: '/cases/m-1',
    open: (t, l) => _tap(t, find.text(l.boardAssignTo), within: _casePage),
    shows: (l) => find.text(l.boardAssignTitle('WP 1001/2024')),
  ),
  _Scene(
    'case page, hearing note',
    location: '/cases/m-1',
    open: (t, l) => _tap(t, find.text(l.casePageAddNote), within: _casePage),
    shows: _sheet,
  ),
  _Scene(
    'case page, next date',
    location: '/cases/m-2',
    open: (t, l) => _tap(
      t,
      find.widgetWithText(OutlinedButton, l.casePageAddNextDate),
      within: _casePage,
    ),
    shows: _sheet,
  ),
  _Scene(
    'case page, note',
    location: '/cases/m-1?tab=notes',
    open: (t, l) => _tap(
      t,
      find.widgetWithText(TextButton, l.casePageAddNote),
      within: _casePage,
    ),
    shows: _sheet,
  ),
  _Scene(
    'case page, task',
    location: '/cases/m-1?tab=notes',
    open: (t, l) =>
        _tap(t, find.widgetWithText(TextButton, l.addTask), within: _casePage),
    shows: _sheet,
  ),
  _Scene(
    'case page, deadline',
    location: '/cases/m-1?tab=notes',
    open: (t, l) =>
        _tap(t, find.text(l.casePageAddDeadline), within: _casePage),
    shows: _sheet,
  ),
  _Scene(
    'case page, link client',
    location: '/cases/m-1?tab=client',
    open: (t, l) => _tap(t, find.text(l.casePageLinkClient), within: _casePage),
    shows: _sheet,
  ),
  _Scene(
    'case page, official portal',
    location: '/cases/m-1',
    open: (t, l) async {
      // It copies the CNR first: the clipboard answers.
      final messenger = t.binding.defaultBinaryMessenger
        ..setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await _caseMenu(t, l, l.casePagePortal);
    },
    shows: (l) => find.text(l.casePagePortalTitle),
  ),
  _Scene(
    'case page, tracking off',
    location: '/cases/m-1',
    open: (t, l) => _caseMenu(t, l, l.casePageTrackingOff),
    shows: (l) => find.text(l.casePageTrackingOffTitle),
  ),
  _Scene(
    'case page, delete',
    location: '/cases/m-1',
    open: (t, l) => _caseMenu(t, l, l.casePageDelete),
    shows: (l) => find.text(l.casePageDeleteTitle('WP 1001/2024')),
  ),
  _Scene(
    'clients, add',
    location: '/clients',
    open: (t, l) => _tap(t, find.text(l.clientsAdd)),
    shows: _sheet,
  ),
  _Scene(
    'client, edit',
    location: '/clients/cl-1',
    open: (t, l) => _tap(t, find.byTooltip(l.clientsEdit)),
    shows: _sheet,
  ),
  _Scene(
    'client, link a case',
    location: '/clients/cl-1',
    open: (t, l) => _tap(t, find.text(l.clientsLinkCase)),
    shows: _sheet,
  ),
  _Scene(
    'documents, case filter',
    location: '/documents',
    open: (t, l) => _tap(t, find.widgetWithText(ActionChip, l.docsAllCases)),
    shows: _sheet,
  ),
  _Scene(
    'documents, scan or files',
    location: '/documents',
    open: (t, l) => _tap(t, find.byTooltip(l.addDocument)),
    shows: (l) => find.text(l.docsChooseFiles),
  ),
  _Scene(
    'documents, upload details',
    location: '/documents',
    open: (t, l) async {
      await _tap(t, find.byTooltip(l.addDocument));
      await _tap(t, find.text(l.docsChooseFiles));
    },
    shows: (l) => find.text(l.docsUploadTitle),
  ),
  _Scene(
    'documents, edit details',
    location: '/documents',
    open: (t, l) async {
      await _tap(
        t,
        find.descendant(
          of: find.ancestor(
            of: find.text('Writ petition'),
            matching: find.byType(ListTile),
          ),
          matching: find.byTooltip(l.docsMoreActions),
        ),
      );
      await _tap(t, find.text(l.docsEditDetails));
    },
    shows: _sheet,
  ),
  _Scene(
    'documents, remove an upload',
    location: '/documents',
    open: (t, l) => _tap(t, find.byTooltip(l.docsRemoveUpload)),
    shows: (l) => find.text(l.docsRemoveBody),
  ),
  _Scene(
    'viewer, go to page',
    location: '/documents/d-1',
    open: (t, l) => _tap(t, find.text(l.docsPage(1, 3))),
    shows: (l) => find.text(l.docsGo),
  ),
  _Scene(
    'team, invite',
    location: '/team',
    open: (t, l) => _tap(t, find.text(l.teamInvite)),
    shows: _sheet,
  ),
  _Scene(
    'team, change role',
    location: '/team',
    open: (t, l) => _teamMenu(t, l, l.teamChangeRole),
    shows: (l) => find.text(l.teamRoleTitle('Neha Verma')),
  ),
  _Scene(
    'team, edit name',
    location: '/team',
    open: (t, l) => _teamMenu(t, l, l.teamEditName),
    shows: (l) => find.widgetWithText(TextField, l.teamNameLabel),
  ),
  _Scene(
    'team, remove',
    location: '/team',
    open: (t, l) => _teamMenu(t, l, l.teamRemove),
    shows: (l) => find.text(l.teamRemoveTitle('Neha Verma')),
  ),
  _Scene(
    'team, revoke invite',
    location: '/team',
    open: (t, l) => _tap(t, find.byTooltip(l.teamRevokeTooltip('QWER7890'))),
    shows: (l) => find.text(l.teamRevokeBody('QWER7890')),
  ),
  _Scene(
    'feedback',
    location: '/settings',
    open: (t, l) => _tap(t, find.text(l.navFeedback)),
    shows: (l) => find.text(l.feedbackIntro),
  ),
  _Scene(
    'sign out',
    location: '/settings',
    open: (t, l) => _tap(t, find.widgetWithText(OutlinedButton, l.signOut)),
    shows: (l) => find.text(l.signOutConfirm),
  ),
  _Scene(
    'command palette',
    desktopOnly: true,
    open: (t, l) async {
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyK);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pumpAndSettle();
    },
    shows: (_) => find.byType(CommandPalette),
  ),
];

/// Opens the scene named [name] as the checks below do (at 100% text): the golden scenes reuse it.
Future<void> openScene(
  WidgetTester tester,
  String name, {
  required Size size,
  required String locale,
  required AppThemeMode theme,
}) => _pump(
  tester,
  _scenes.singleWhere((s) => s.name == name),
  size,
  locale,
  theme: theme,
);

Future<void> _pump(
  WidgetTester tester,
  _Scene s,
  Size size,
  String locale, {
  bool offline = false,
  AppThemeMode theme = AppThemeMode.light,
}) async {
  if (s.still) {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  }
  await pumpApp(
    tester,
    location: s.location,
    account: s.account,
    onboardingDone: s.onboardingDone,
    locale: locale,
    theme: theme,
    size: size,
    api: _api(s.account)..offline = s.offlineApi,
    languageChosen: s.stage != _Stage.welcome,
    signedIn: s.stage.index > _Stage.signIn.index,
    consented: s.stage.index > _Stage.consent.index,
    lock: switch (s.stage) {
      _Stage.appLock => const AppLockState(),
      _Stage.locked => const AppLockState(method: LockMethod.pin, locked: true),
      _ => const AppLockState(method: LockMethod.none),
    },
    overrides: [
      ...syncedData(
        found: s.found,
        settled: s.found.isNotEmpty,
        offline: offline,
      ),
      ...s.data(),
    ],
  );
  await s.open?.call(tester, lookupAppLocalizations(Locale(locale)));
}

/// [androidTapTargetGuideline], but a target partly scrolled out of a list is skipped as off screen wherever the
/// list sits. (Flutter's own check compares the target with the list in different coordinates, so it only skips
/// one in a list at the window's top left, and fails one half under an app bar.)
class _TapTargets extends MinimumTapTargetGuideline {
  const _TapTargets()
    : super(
        size: const Size(48, 48),
        link: 'https://support.google.com/accessibility/android/answer/7101858',
      );

  @override
  bool shouldSkipNode(SemanticsNode node) {
    if (super.shouldSkipNode(node)) return true;
    var rect = node.rect;
    for (SemanticsNode? n = node; n != null; n = n.parent) {
      if (n != node && n.flagsCollection.hasImplicitScrolling) {
        final list = n.rect.deflate(0.001);
        if (!(list.contains(rect.topLeft) && list.contains(rect.bottomRight))) {
          return true;
        }
      }
      if (n.transform case final t?) rect = MatrixUtils.transformRect(t, rect);
    }
    return false;
  }
}

/// Every GoRoute path in lib/core/router.dart, nested ones joined to their parent's (`/cases/:id/orders/:orderId`).
Set<String> _routerPaths() {
  final source = File('lib/core/router.dart').readAsStringSync();
  final paths = <String>{};
  // Per open bracket: the parent path of a `routes: [` list, null for any other list.
  final lists = <String?>[];
  var last = '';
  for (final m in RegExp(
    r"(?:Go|Shell)Route\(|path: '([^']*)'|routes: \[|\[|\]",
  ).allMatches(source)) {
    final token = m[0]!;
    if (token.endsWith('Route(')) {
      last = '';
    } else if (m[1] case final path?) {
      final parent = lists.lastWhere((p) => p != null, orElse: () => '')!;
      last = path.startsWith('/') ? path : '$parent/$path';
      paths.add(last);
    } else if (token == ']') {
      lists.removeLast();
    } else {
      lists.add(token == '[' ? null : last);
    }
  }
  return paths;
}

void main() {
  setUpAll(loadAppFonts);

  test('every route in the router has a scene here', () {
    final paths = _routerPaths();
    expect(paths, containsAll(['/sign-in/otp', '/cases/:id/orders/:orderId']));
    final covered = {for (final s in _scenes) ?s.route};
    expect(
      paths.difference(covered)..remove('/dev/kitchen-sink'),
      isEmpty,
      reason: 'add a scene for each new route',
    );
  });

  for (final s in _scenes) {
    for (final locale in ['en', 'hi']) {
      for (final (device, size) in [('phone', _phone), ('Windows', _desktop)]) {
        if (s.desktopOnly && size == _phone) continue;
        testWidgets('${s.name}, $device, $locale: fits, 48 dp labelled '
            'targets', (tester) async {
          final semantics = tester.ensureSemantics();
          final l = lookupAppLocalizations(Locale(locale));
          await _pump(tester, s, size, locale);
          // Opened at 100%; the OS text size then goes to 200%.
          for (final scale in [1.0, 2.0]) {
            final tag = '${s.name}, $device, $locale ${scale}x';
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            await tester.pumpAndSettle();
            expect(s.shows(l), findsWidgets, reason: tag);
            expect(
              MediaQuery.textScalerOf(tester.element(s.shows(l).first))
                  .scale(1),
              scale,
              reason: tag,
            );
            expect(tester.takeException(), isNull, reason: tag);
            await expectLater(
              tester,
              meetsGuideline(const _TapTargets()),
              reason: tag,
            );
            await expectLater(
              tester,
              meetsGuideline(labeledTapTargetGuideline),
              reason: tag,
            );
          }
          semantics.dispose();
        });
      }
      if (s.shell) {
        testWidgets('${s.name}, offline, $locale: under the banner', (
          tester,
        ) async {
          await _pump(tester, s, _phone, locale, offline: true);
          for (final scale in [1.0, 2.0]) {
            final tag = '${s.name}, offline, $locale ${scale}x';
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            await tester.pumpAndSettle();
            expect(
              s.shows(lookupAppLocalizations(Locale(locale))),
              findsWidgets,
              reason: tag,
            );
            expect(find.byType(OfflineBanner), findsOneWidget, reason: tag);
            expect(tester.takeException(), isNull, reason: tag);
          }
        });
      }
    }
  }
}
