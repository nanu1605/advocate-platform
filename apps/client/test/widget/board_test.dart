import 'dart:async';
import 'dart:io';

import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/router.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/courts.dart';
import 'package:advocate_app/data/diary.dart';
import 'package:advocate_app/features/board/board_screen.dart';
import 'package:advocate_app/features/board/board_share.dart';
import 'package:advocate_app/features/cases/case_placeholder_screen.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';

import '../helpers.dart';

final Court _district = testCourts[3];

/// Tomorrow: WP 1001 (MPHC Indore, Court 12, item 23, about 11:58) and WP 1002 (District Court, about 11:30)
/// clash, both unassigned (the owner's); WP 1003 is the user's; WP 1004 is Neha's.
List<DiaryEntry> boardSample() => [
  diaryEntry(1, item: 23),
  diaryEntry(
    2,
    court: _district,
    courtNo: '5',
    item: 5,
    slot: const Duration(hours: 11, minutes: 30),
    purpose: 'Evidence',
  ),
  diaryEntry(
    3,
    courtNo: '7',
    item: 41,
    assigneeId: 'user-1',
    assigneeName: 'Ramesh Sharma',
  ),
  diaryEntry(
    4,
    court: _district,
    courtNo: '9',
    item: 2,
    slot: const Duration(hours: 14),
    assigneeId: 'user-3',
    assigneeName: 'Neha Verma',
  ),
];

const _clerk = Account(
  id: 'user-4',
  memberships: [
    Membership(
      orgId: 'org-1',
      orgName: 'Sharma Chambers',
      orgKind: 'chamber',
      role: 'clerk',
    ),
  ],
);

Future<FakeDiary> _open(
  WidgetTester tester, {
  List<DiaryEntry>? tomorrow,
  FakeDiary? diary,
  String locale = 'en',
  double scale = 1,
  Size size = const Size(400, 860),
  Account account = ownerAccount,
  List<Override> overrides = const [],
}) async {
  final d = diary ?? FakeDiary(days: {testTomorrow: tomorrow ?? boardSample()});
  await pumpApp(
    tester,
    location: '/board/tomorrow',
    locale: locale,
    textScale: scale,
    size: size,
    account: account,
    onboardingDone: true,
    overrides: [...d.overrides, ...overrides],
  );
  return d;
}

/// Tomorrow's Board (spec §4.2): rows by court, clashes with Assign to and proxy, roles, share, the evening
/// build, desktop table and keys.
void main() {
  setUpAll(loadAppFonts);
  final en = lookupAppLocalizations(const Locale('en'));
  final menu3 = en.boardMoreActions(en.diaryCaseOfYear('WP 1003', '2024'));

  for (final locale in ['en', 'hi']) {
    final l = lookupAppLocalizations(Locale(locale));
    for (final scale in [1.0, 2.0]) {
      testWidgets('rows by court with clashes, read in full ($locale ${scale}x)', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await _open(tester, locale: locale, scale: scale);
        expect(tester.takeException(), isNull);
        expect(find.textContaining(l.boardTitle), findsOneWidget);
        final (mphc, district) = locale == 'hi'
            ? ('MPHC इंदौर', 'जिला कोर्ट इंदौर')
            : ('MPHC Indore', 'District Court Indore');
        expect(find.text('$district (2)'), findsOneWidget);
        expect(find.text('$mphc (2)'), findsOneWidget);
        expect(find.text(l.statusClash), findsNWidgets(2));
        if (locale == 'en') {
          final why = l.diaryClashOther(
            'WP 1002/2024',
            'District Court Indore',
            '11:30 am',
          );
          expect(find.text(l.diaryClashExplain(why)), findsOneWidget);
          expect(
            find.bySemanticsLabel(
              '${l.diaryCaseOfYear('WP 1001', '2024')}. MP ${l.highCourt} Indore. '
              '${l.diaryCourtItem('12', '23')}. ${l.statusClash}. '
              'Sharma v. State of MP. Admission. ${l.boardClientIs('Suresh Patel')}.',
            ),
            findsOneWidget,
          );
          expect(
            find.bySemanticsLabel(
              RegExp('${RegExp.escape('${l.boardAssigneeIs(l.boardYou)}.')}\$'),
            ),
            findsOneWidget,
          );
        } else {
          expect(
            find.textContaining('समय आइटम नंबर से अनुमानित है'),
            findsNWidgets(2),
          );
          expect(
            find.bySemanticsLabel(
              RegExp(
                '^WP 1001 सन 2024। MP हाई कोर्ट इंदौर। कोर्ट 12, आइटम 23। एक साथ पेशी।',
              ),
            ),
            findsOneWidget,
          );
        }
        // The owner can act on clashes: two buttons each, and a menu on every boarded row.
        expect(find.text(l.boardAssignTo), findsNWidgets(2));
        expect(find.text(l.boardProxyMark), findsNWidgets(2));
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        handle.dispose();
      });
    }
  }

  testWidgets(
    'Assign to: members but clerks, Me first; the clash re-checks at once; Undo brings it back',
    (tester) async {
      final diary = await _open(tester);
      await tester.tap(find.text(en.boardAssignTo).first);
      await tester.pumpAndSettle();
      expect(find.text(en.boardAssignTitle('WP 1002/2024')), findsOneWidget);
      expect(find.text(en.boardMe), findsOneWidget);
      expect(find.text('Rakesh Jain'), findsOneWidget);
      expect(find.text('Mohan Lal'), findsNothing);
      expect(
        tester.getTopLeft(find.text(en.boardMe)).dy,
        lessThan(tester.getTopLeft(find.text('Neha Verma').last).dy),
      );
      await tester.tap(find.text('Neha Verma').last);
      await tester.pumpAndSettle();
      expect(diary.writes.last.name, 'assign');
      expect(diary.writes.last.args, {
        'boardEntryId': 'b-2',
        'userId': 'user-3',
      });
      expect(find.text(en.statusClash), findsNothing);
      expect(find.text(en.boardAssignTo), findsNothing);
      expect(
        find.text(en.boardAssignedSnack('WP 1002/2024', 'Neha Verma')),
        findsOneWidget,
      );
      // Unassigned before, so Undo gives it back to no one (the owner) and the clash returns.
      await tester.tap(find.text(en.undo));
      await tester.pumpAndSettle();
      expect(diary.writes.last.name, 'assign');
      expect(diary.writes.last.args, {'boardEntryId': 'b-2', 'userId': null});
      expect(find.text(en.statusClash), findsNWidgets(2));
    },
  );

  testWidgets(
    'Mark proxy arranged offline: the clash clears at once; Undo brings it back',
    (tester) async {
      final diary = await _open(tester, overrides: syncedData(offline: true));
      expect(find.byType(OfflineBanner), findsOneWidget);
      await tester.ensureVisible(find.text(en.boardProxyMark).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.boardProxyMark).last);
      await tester.pumpAndSettle();
      expect(diary.writes.last.name, 'setProxy');
      expect(diary.writes.last.args, {'boardEntryId': 'b-1', 'arranged': true});
      expect(find.text(en.statusClash), findsNothing);
      expect(find.text(en.boardProxyArranged), findsOneWidget);
      expect(
        find.text(en.boardProxyMarkedSnack('WP 1001/2024')),
        findsOneWidget,
      );
      await tester.tap(find.text(en.undo));
      await tester.pumpAndSettle();
      expect(diary.writes.last.name, 'setProxy');
      expect(diary.writes.last.args, {
        'boardEntryId': 'b-1',
        'arranged': false,
      });
      expect(find.text(en.statusClash), findsNWidgets(2));
    },
  );

  testWidgets('every boarded row has the actions in its menu', (tester) async {
    final diary = await _open(tester);
    await tester.tap(find.byTooltip(menu3));
    await tester.pumpAndSettle();
    expect(find.text(en.boardAssignTo), findsNWidgets(3));
    await tester.tap(find.text(en.boardProxyMark).last);
    await tester.pumpAndSettle();
    expect(diary.writes.last.name, 'setProxy');
    expect(diary.writes.last.args, {'boardEntryId': 'b-3', 'arranged': true});
    await tester.tap(find.byTooltip(menu3));
    await tester.pumpAndSettle();
    expect(find.text(en.boardProxyClear), findsOneWidget);
  });

  testWidgets(
    'keyboard: when Mark proxy arranged clears the clash, focus stays on the row',
    (tester) async {
      await _open(tester, size: const Size(1280, 800));
      Focus.of(tester.element(find.text('WP 1002/2024'))).requestFocus();
      await tester.pump();
      // The row, its menu, Assign to, Mark proxy arranged.
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      bool focused(Finder f) => find
          .descendant(
            of: f,
            matching: find.byWidget(
              FocusManager.instance.primaryFocus!.context!.widget,
            ),
          )
          .evaluate()
          .isNotEmpty;
      expect(
        focused(find.widgetWithText(OutlinedButton, en.boardProxyMark).first),
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text(en.boardProxyMark), findsNothing);
      // The buttons are gone; focus is back on the row's menu, and Tab goes on to the next row.
      expect(
        focused(
          find.byTooltip(
            en.boardMoreActions(en.diaryCaseOfYear('WP 1002', '2024')),
          ),
        ),
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
        Focus.of(tester.element(find.text('WP 1004/2024'))).hasPrimaryFocus,
        isTrue,
      );
    },
  );

  testWidgets('a clerk reads the board, clash explained, without actions', (
    tester,
  ) async {
    await _open(tester, account: _clerk);
    expect(find.text(en.statusClash), findsNWidgets(2));
    expect(find.textContaining('Times are estimated'), findsNWidgets(2));
    expect(
      find.textContaining(en.boardAssigneeIs('Neha Verma')),
      findsOneWidget,
    );
    expect(
      find.textContaining(en.boardAssigneeIs('Ramesh Sharma')),
      findsOneWidget,
    );
    expect(find.text(en.boardAssignTo), findsNothing);
    expect(find.text(en.boardProxyMark), findsNothing);
    expect(find.byIcon(AppIcons.dotsThreeVertical), findsNothing);
  });

  testWidgets(
    'share: the preview follows "Include case titles"; text and image go to the share sheet',
    (tester) async {
      final shared = <ShareParams>[];
      await _open(
        tester,
        overrides: [
          shareProvider.overrideWithValue((p) async => shared.add(p)),
        ],
      );
      await tester.tap(find.byTooltip(en.boardShare));
      await tester.pumpAndSettle();
      Finder inSheet(String text) => find.descendant(
        of: find.byType(BoardShareSheet),
        matching: find.textContaining(text),
      );
      expect(inSheet(en.boardShareHeader('Fri, 6 Nov')), findsOneWidget);
      expect(
        inSheet('• WP 1001/2024 — ${en.diaryCourtItem('12', '23')}'),
        findsOneWidget,
      );
      expect(inSheet('Sharma v. State of MP'), findsNothing);
      expect(inSheet('Suresh Patel'), findsNothing);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(inSheet('Sharma v. State of MP'), findsOneWidget);
      await tester.tap(find.text(en.boardShareAsText));
      await tester.pumpAndSettle();
      expect(shared.single.text, contains('\n  Sharma v. State of MP\n'));
      expect(shared.single.text, isNot(contains('Suresh Patel')));
      expect(shared.single.title, en.boardShareHeader('Fri, 6 Nov'));
      expect(find.byType(BoardShareSheet), findsNothing);

      // An image from an earlier share, which may hold case titles.
      final dir = await container(tester).read(boardShareDirProvider)();
      final old = File('${dir.path}${Platform.pathSeparator}board-old.png');
      dir.createSync(recursive: true);
      old.writeAsBytesSync([0]);
      await tester.tap(find.byTooltip(en.boardShare));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text(en.boardShareAsImage));
        for (var i = 0; i < 100 && shared.length < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();
      // A real file in the app's one share folder, with the platform's separators (Windows can't open a
      // path with '/'), and the folder emptied first.
      final file = shared.last.files!.single;
      expect(file.mimeType, 'image/png');
      expect(
        file.path,
        '${dir.path}${Platform.pathSeparator}board-2026-11-06.png',
      );
      if (Platform.isWindows) expect(file.path, isNot(contains('/')));
      expect(shared.last.fileNameOverrides, isNull);
      await tester.runAsync(() async {
        expect((await file.readAsBytes()).take(4), [0x89, 0x50, 0x4E, 0x47]);
      });
      expect(dir.listSync().map((f) => f.path), [file.path]);
    },
  );

  testWidgets('a sheet dismissed while sharing leaves the board open', (
    tester,
  ) async {
    final gate = Completer<void>();
    await _open(
      tester,
      overrides: [shareProvider.overrideWithValue((_) => gate.future)],
    );
    // Opened from Today, so a stray pop would land there.
    container(tester).read(routerProvider).go('/today');
    await tester.pumpAndSettle();
    unawaited(container(tester).read(routerProvider).push('/board/tomorrow'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(en.boardShare));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.boardShareAsText));
    await tester.pump();
    await tester.tapAt(const Offset(200, 20));
    await tester.pumpAndSettle();
    expect(find.byType(BoardShareSheet), findsNothing);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(BoardScreen), findsOneWidget);
  });

  testWidgets('a share that fails says so in words', (tester) async {
    await _open(
      tester,
      overrides: [
        shareProvider.overrideWithValue(
          (_) async => throw PlatformException(code: 'error'),
        ),
      ],
    );
    await tester.tap(find.byTooltip(en.boardShare));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.boardShareAsText));
    await tester.pumpAndSettle();
    expect(find.text(en.errorGeneric), findsOneWidget);
    expect(find.byType(BoardShareSheet), findsOneWidget);
  });

  testWidgets('before the evening build: known rows and when item numbers come', (
    tester,
  ) async {
    await _open(
      tester,
      diary: FakeDiary(
        days: {
          testTomorrow: [
            diaryEntry(1, boarded: false),
            diaryEntry(2, boarded: false, courtNo: '7'),
          ],
        },
        eveningSwitch: const Duration(hours: 19),
      ),
    );
    expect(find.text(en.boardNotBuilt('7:00 pm')), findsOneWidget);
    expect(find.text('WP 1001/2024'), findsOneWidget);
    expect(
      find.text(
        '${en.courtNo('12')} · Admission · ${en.boardClientIs('Suresh Patel')}',
      ),
      findsOneWidget,
    );
    expect(find.byIcon(AppIcons.dotsThreeVertical), findsNothing);
  });

  testWidgets(
    'after the switch, a board still not built says courts are late',
    (tester) async {
      await _open(
        tester,
        diary: FakeDiary(
          days: {
            testTomorrow: [diaryEntry(1, boarded: false)],
          },
          now: DateTime.utc(2026, 11, 5, 15, 30), // 21:00 IST
        ),
      );
      expect(find.text(en.boardNotBuiltLate), findsOneWidget);
      expect(find.textContaining('6:30 pm'), findsNothing);
    },
  );

  testWidgets('a phone row names the client and the assignee', (tester) async {
    await _open(tester);
    expect(
      find.text(
        '${en.courtNo('9')} · ${en.itemNo('2')} · Admission · '
        '${en.boardClientIs('Suresh Patel')} · ${en.boardAssigneeIs('Neha Verma')}',
      ),
      findsOneWidget,
    );
  });

  testWidgets('at 200% the date the board covers is shown whole', (
    tester,
  ) async {
    await _open(tester, scale: 2);
    expect(find.text('Fri, 6 Nov'), findsOneWidget);
    expect(find.widgetWithText(AppBar, en.boardTitle), findsOneWidget);
  });

  final note = en.boardNotBuilt('6:30 pm');

  testWidgets('empty board before the build: says so, and when items come', (
    tester,
  ) async {
    await _open(tester, diary: FakeDiary());
    expect(find.text(en.boardEmpty), findsOneWidget);
    expect(find.text(note), findsOneWidget);
    final share = find.widgetWithIcon(IconButton, AppIcons.shareNetwork);
    expect(tester.widget<IconButton>(share).onPressed, isNull);
  });

  testWidgets('empty board after the build (19:30 IST): nothing listed', (
    tester,
  ) async {
    await _open(tester, diary: FakeDiary(now: DateTime.utc(2026, 11, 5, 14)));
    expect(find.text(en.boardEmpty), findsOneWidget);
    expect(find.text(note), findsNothing);
  });

  testWidgets('a row opens its case; back returns to the board', (
    tester,
  ) async {
    await _open(tester);
    await tester.tap(find.text('WP 1003/2024'));
    await tester.pumpAndSettle();
    expect(find.byType(CasePlaceholderScreen), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'WP 1003/2024'), findsOneWidget);
    container(tester).read(routerProvider).pop();
    await tester.pumpAndSettle();
    expect(find.byType(CasePlaceholderScreen), findsNothing);
    expect(find.text('WP 1003/2024'), findsOneWidget);
  });

  testWidgets('desktop: a table; Tab moves between rows and Enter opens one', (
    tester,
  ) async {
    await _open(tester, size: const Size(1280, 800));
    for (final h in [
      en.boardCase,
      en.boardItem,
      en.boardPurpose,
      en.boardClient,
      en.boardAssignee,
    ]) {
      expect(find.text(h), findsOneWidget, reason: h);
    }
    expect(find.text('MPHC Indore · ${en.courtNo('12')}'), findsOneWidget);
    expect(find.text(en.boardYou), findsOneWidget);
    expect(find.text(en.statusClash), findsNWidgets(2));
    expect(tester.takeException(), isNull);

    final row = Focus.of(tester.element(find.text('WP 1003/2024')))
      ..requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(row.hasPrimaryFocus, isFalse);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(row.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'WP 1003/2024'), findsOneWidget);
  });
}
