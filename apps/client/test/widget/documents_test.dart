import 'dart:io';

import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/router.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/document_files.dart';
import 'package:advocate_app/data/documents.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:advocate_app/features/dev_kitchen_sink/kitchen_sink.dart';
import 'package:advocate_app/features/documents/upload_flow.dart';
import 'package:advocate_app/features/documents/viewer_screen.dart';
import 'package:advocate_app/ui/pdf_viewer.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show AsyncData;
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

/// Two cases' documents and one without a case: a ready PDF kept offline, a Word file being checked, a photo with
/// a Hindi title, a blocked scan and a Word letter; plus two uploads in the queue (one waiting, one too large).
FakeCases sampleDocCases() => FakeCases(
  cases: [caseInfo(1), caseInfo(2)],
  documents: {
    'm-1': const [
      CaseDocument(
        id: 'd-1',
        title: 'Writ petition',
        kind: 'pleading',
        mime: pdfMime,
        sizeBytes: 245760,
        pages: 12,
        keepOffline: true,
        offline: true,
      ),
      CaseDocument(
        id: 'd-2',
        title: 'Reply draft',
        kind: 'correspondence',
        mime: docxMime,
        uploadStatus: 'pending',
      ),
    ],
    'm-2': const [
      CaseDocument(
        id: 'd-3',
        title: 'शर्मा का शपथपत्र',
        kind: 'evidence',
        mime: 'image/jpeg',
        sizeBytes: 1258291,
      ),
      CaseDocument(
        id: 'd-4',
        title: 'Scan from client',
        uploadStatus: 'quarantined',
      ),
    ],
    '': const [
      CaseDocument(
        id: 'd-5',
        title: 'Bar council letter',
        kind: 'correspondence',
        mime: docxMime,
        sizeBytes: 81920,
      ),
    ],
  },
);

List<QueuedUpload> sampleQueue() => const [
  QueuedUpload(
    id: 'up-1',
    title: 'Vakalatnama',
    kind: 'other',
    mime: pdfMime,
    sizeBytes: 307200,
    matterId: 'm-1',
    caseLabel: 'WP 1001/2024',
  ),
  QueuedUpload(
    id: 'up-2',
    title: 'Evidence bundle',
    kind: 'evidence',
    mime: pdfMime,
    state: 'failed',
    error: 'FILE_TOO_LARGE',
  ),
];

/// A file the fake pickers give, with its size and first bytes.
typedef FakeFile = ({PickedFile file, int size, List<int> head});

FakeFile fakeFile(String name, {int size = 2048, String head = '%PDF-1.7'}) => (
  file: (path: 'C:/picked/$name', name: name),
  size: size,
  head: head.codeUnits,
);

/// The scanner and the file picker in memory: [files] are picked, [scanned] scanned (or [scanError] thrown); the
/// check runs the real one on each file's size and first bytes.
class FakeSources extends UploadSources {
  FakeSources({this.files = const [], this.scanned, this.scanError});

  final List<FakeFile> files;
  final String? scanned;
  final Exception? scanError;
  int cleaned = 0;

  @override
  bool get canScan => true;

  @override
  Future<String?> scan() async {
    if (scanError case final e?) throw e;
    return scanned;
  }

  @override
  Future<List<PickedFile>> pick() async => [for (final f in files) f.file];

  @override
  Future<({String? mime, String? error})> check(PickedFile file) async {
    final f = files.where((f) => f.file == file).firstOrNull;
    return uploadCheck(
      file.name,
      f?.size ?? 2048,
      f?.head ?? '%PDF-1.7'.codeUnits,
    );
  }

  @override
  Future<void> cleanUp() async => cleaned++;
}

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final hi = lookupAppLocalizations(const Locale('hi'));

  late FakeCases cases;
  late FakeDocuments docs;
  late FakeSources sources;
  late List<({String path, String mime})> openedElsewhere;

  setUp(() {
    cases = sampleDocCases();
    docs = FakeDocuments(queue: sampleQueue());
    sources = FakeSources();
    openedElsewhere = [];
  });

  Future<FakeApi> open(
    WidgetTester tester, {
    String location = '/documents',
    String locale = 'en',
    double textScale = 1,
    Size size = const Size(400, 2000),
    List<Override> overrides = const [],
    bool fakeFiles = true,
  }) => pumpApp(
    tester,
    location: location,
    locale: locale,
    textScale: textScale,
    size: size,
    onboardingDone: true,
    overrides: [
      ...cases.overrides,
      if (fakeFiles) ...docs.overrides,
      uploadSourcesProvider.overrideWithValue(sources),
      openFileProvider.overrideWithValue((path, mime) async {
        openedElsewhere.add((path: path, mime: mime));
        return path.isNotEmpty;
      }),
      ...overrides,
    ],
  );

  Finder snack(String text) => find.widgetWithText(SnackBar, text);
  Finder inSheet(Finder f) =>
      find.descendant(of: find.byType(BottomSheet), matching: f);
  Finder row(String title) =>
      find.ancestor(of: find.text(title), matching: find.byType(ListTile));

  group('list', () {
    testWidgets('uploads first, then documents newest first, with type, size, '
        'case and state', (tester) async {
      await open(tester);
      expect(find.text('Vakalatnama'), findsOneWidget);
      expect(
        find.text('${en.casesDocOther} · 300 KB · WP 1001/2024'),
        findsOneWidget,
      );
      expect(find.text(en.docsStateWaiting), findsOneWidget);
      expect(find.text(en.docsDataTooLarge), findsOneWidget);
      expect(
        find.text(
          '${en.casesDocPleading} · 240 KB · WP 1001/2024 · '
          '${en.pages(12)}',
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row('Writ petition'),
          matching: find.text(en.availableOffline),
        ),
        findsOneWidget,
      );
      expect(find.text(en.docsStateChecking), findsOneWidget);
      expect(find.text(en.docsStateBlocked), findsOneWidget);
      // A document without a case has no case in its line.
      expect(find.text('${en.casesDocCorrespondence} · 80 KB'), findsOneWidget);
      // The queue's items before the documents.
      expect(
        tester.getTopLeft(find.text('Evidence bundle')).dy,
        lessThan(tester.getTopLeft(find.text('Writ petition')).dy),
      );
    });

    testWidgets('an upload being sent shows its progress; Remove asks first', (
      tester,
    ) async {
      await open(tester);
      container(tester).read(uploadProgressProvider.notifier).set('up-1', 0.4);
      await tester.pump();
      expect(find.text(en.docsStateUploading(40)), findsOneWidget);
      expect(
        find.descendant(
          of: row('Vakalatnama'),
          matching: find.byTooltip(en.docsRemoveUpload),
        ),
        findsNothing,
      );

      await tester.tap(
        find.descendant(
          of: row('Evidence bundle'),
          matching: find.byTooltip(en.docsRemoveUpload),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(en.docsRemoveBody), findsOneWidget);
      await tester.tap(find.text(en.docsRemove));
      await tester.pumpAndSettle();
      expect(docs.calls.single, (name: 'remove', args: 'up-2'));
      expect(find.text('Evidence bundle'), findsNothing);
    });

    testWidgets('Keep offline toggles the own preference', (tester) async {
      await open(tester);
      final toggle = find.descendant(
        of: row('Writ petition'),
        matching: find.byTooltip(en.docsKeepOffline),
      );
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(cases.writes.last.name, 'setKeepOffline');
      expect(cases.writes.last.args, {'id': 'd-1', 'keep': false});
      // A file being checked can't be kept yet.
      expect(
        find.descendant(
          of: row('Reply draft'),
          matching: find.byTooltip(en.docsKeepOffline),
        ),
        findsNothing,
      );
    });

    testWidgets('search by title finds Hindi titles from English letters; '
        'type and case filters; nothing matches', (tester) async {
      await open(tester);
      await tester.enterText(find.byType(TextField), 'sharma');
      await tester.pump();
      expect(find.text('शर्मा का शपथपत्र'), findsOneWidget);
      expect(find.text('Writ petition'), findsNothing);

      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      final chip = find.widgetWithText(ChoiceChip, en.casesDocCorrespondence);
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(find.text('Reply draft'), findsOneWidget);
      expect(find.text('Bar council letter'), findsOneWidget);
      expect(find.text('Writ petition'), findsNothing);

      final cases = find.widgetWithText(ActionChip, en.docsAllCases);
      await tester.ensureVisible(cases);
      await tester.tap(cases);
      await tester.pumpAndSettle();
      await tester.tap(inSheet(find.text('WP 1002/2024')));
      await tester.pumpAndSettle();
      expect(find.text(en.docsNoMatches), findsOneWidget);
      await tester.tap(find.text(en.foundClearFilters));
      await tester.pumpAndSettle();
      expect(find.text('Writ petition'), findsOneWidget);
      expect(find.text('Scan from client'), findsOneWidget);
    });

    testWidgets('edit details and delete with Undo', (tester) async {
      await open(tester);
      await tester.tap(
        find.descendant(
          of: row('Bar council letter'),
          matching: find.byTooltip(en.docsMoreActions),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.docsEditDetails));
      await tester.pumpAndSettle();
      await tester.enterText(inSheet(find.byType(TextField)), ' ');
      await tester.tap(find.text(en.casePageSave));
      await tester.pumpAndSettle();
      expect(find.text(en.docsTitleRequired), findsOneWidget);
      await tester.enterText(
        inSheet(find.byType(TextField)),
        'Letter to the Bar Council',
      );
      await tester.tap(inSheet(find.text(en.casesDocOther)));
      await tester.tap(find.text(en.casePageSave));
      await tester.pumpAndSettle();
      expect(cases.writes.last.name, 'editDocument');
      expect(cases.writes.last.args, {
        'id': 'd-5',
        'title': 'Letter to the Bar Council',
        'kind': 'other',
        'matterId': null,
      });

      await tester.tap(
        find.descendant(
          of: row('Scan from client'),
          matching: find.byTooltip(en.docsMoreActions),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.delete));
      await tester.pumpAndSettle();
      expect(find.text('Scan from client'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(cases.writes.last, (name: 'deleteDocument', args: 'd-4'));
    });

    testWidgets('no documents: the empty state adds one', (tester) async {
      cases = FakeCases(cases: [caseInfo(1)]);
      docs = FakeDocuments();
      await open(tester);
      expect(find.text(en.docsEmpty), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, en.addDocument));
      await tester.pumpAndSettle();
      expect(find.text(en.docsScan), findsOneWidget);
    });

    testWidgets('a failed read says so, with Retry', (tester) async {
      cases.failing.add('documents');
      await open(tester);
      expect(find.text(en.errorGeneric), findsOneWidget);
      expect(find.text(en.retry), findsOneWidget);
    });
  });

  testWidgets('Windows: Ctrl+F finds', (tester) async {
    await open(tester, size: const Size(1280, 800));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    final search = tester.widget<TextField>(
      find.widgetWithText(TextField, en.docsSearchHint),
    );
    expect(search.focusNode!.hasPrimaryFocus, isTrue);
  });

  group('upload', () {
    testWidgets('choose files: a wrong one says why, the next is described '
        'and queued', (tester) async {
      sources = FakeSources(
        files: [
          fakeFile('notes.pdf', head: 'hello'),
          fakeFile('Rejoinder final.pdf'),
        ],
      );
      await open(tester);
      await tester.tap(find.byTooltip(en.addDocument));
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.docsChooseFiles));
      await tester.pumpAndSettle();
      expect(inSheet(find.text(en.docsUploadTitle)), findsOneWidget);
      expect(
        find.text('Rejoinder final.pdf · ${en.docsFileCount(2, 2)}'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextField>(inSheet(find.byType(TextField)))
            .controller!
            .text,
        'Rejoinder final',
      );
      await tester.tap(inSheet(find.text(en.casesDocPleading)));
      await tester.tap(find.byType(DropdownButtonFormField<String?>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('WP 1002/2024').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.docsUpload));
      await tester.pumpAndSettle();
      expect(docs.calls.single.name, 'enqueue');
      expect(docs.calls.single.args, {
        'path': 'C:/picked/Rejoinder final.pdf',
        'title': 'Rejoinder final',
        'kind': 'pleading',
        'mime': pdfMime,
        'matterId': 'm-2',
      });
      expect(sources.cleaned, 1);
      expect(
        snack(
          '${en.docsFileProblem('notes.pdf', en.docsDataWrongType)}\n'
          '${en.docsQueued(1)}',
        ),
        findsOneWidget,
      );
      // The new upload waits in the list.
      expect(find.text('Rejoinder final'), findsOneWidget);
    });

    testWidgets('a scan is one PDF named by the day; offline it waits on the '
        'device', (tester) async {
      sources = FakeSources(scanned: '/scanner/123.pdf');
      await open(
        tester,
        overrides: [
          syncViewProvider.overrideWithValue(
            const AsyncData((status: SyncStatus.syncing, offline: true)),
          ),
        ],
      );
      await tester.tap(find.byTooltip(en.addDocument));
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.docsScan));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(inSheet(find.byType(TextField)))
            .controller!
            .text,
        en.docsScanTitle('Thu, 5 Nov 2026'),
      );
      await tester.tap(find.text(en.docsUpload));
      await tester.pumpAndSettle();
      expect((docs.calls.single.args! as Map)['path'], '/scanner/123.pdf');
      expect(snack(en.docsQueuedOffline(1)), findsOneWidget);
    });

    testWidgets("the scanner that can't start says what to do", (tester) async {
      sources = FakeSources(scanError: Exception('permission_denied'));
      await open(tester);
      await tester.tap(find.byTooltip(en.addDocument));
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.docsScan));
      await tester.pumpAndSettle();
      expect(snack(en.docsScanFailed), findsOneWidget);
      expect(docs.calls, isEmpty);
    });

    testWidgets('from a case: the case is preset; a big file says so', (
      tester,
    ) async {
      sources = FakeSources(
        files: [
          fakeFile('Big bundle.pdf', size: maxUploadBytes + 1),
          fakeFile('Annexure P-1.png', head: '\x89PNG\r\n\x1a\n'),
        ],
      );
      await open(
        tester,
        location: '/cases/m-1?tab=documents',
        size: const Size(400, 1600),
      );
      await tester.tap(find.widgetWithText(OutlinedButton, en.addDocument));
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.docsChooseFiles));
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.docsUpload));
      await tester.pumpAndSettle();
      expect(
        snack(
          '${en.docsFileProblem('Big bundle.pdf', en.docsDataTooLarge)}\n'
          '${en.docsQueued(1)}',
        ),
        findsOneWidget,
      );
      expect((docs.calls.single.args! as Map)['matterId'], 'm-1');
      expect((docs.calls.single.args! as Map)['mime'], 'image/png');
    });

    testWidgets("a file whose copy can't be made says so; the rest go on", (
      tester,
    ) async {
      sources = FakeSources(
        files: [fakeFile('Big scan.pdf'), fakeFile('Reply.pdf')],
      );
      docs.failEnqueue.add('C:/picked/Big scan.pdf');
      await open(tester);
      await tester.tap(find.byTooltip(en.addDocument));
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.docsChooseFiles));
      await tester.pumpAndSettle();
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.text(en.docsUpload));
        await tester.pumpAndSettle();
      }
      expect(
        snack(
          '${en.docsFileProblem('Big scan.pdf', en.docsDataSaveFailed)}\n'
          '${en.docsQueued(1)}',
        ),
        findsOneWidget,
      );
      expect((docs.calls.single.args! as Map)['title'], 'Reply');
      expect(sources.cleaned, 1);
    });

    testWidgets('Windows: files dropped on a case upload into it', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      sources = FakeSources(files: [fakeFile('Rejoinder.pdf')]);
      await open(
        tester,
        location: '/cases/m-1?tab=client',
        size: const Size(1280, 800),
      );
      // Over the case, beside the list.
      for (final call in const [
        MethodCall('entered', [900.0, 400.0]),
        MethodCall('performOperation', ['C:/picked/Rejoinder.pdf']),
      ]) {
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'desktop_drop',
          const StandardMethodCodec().encodeMethodCall(call),
          (_) {},
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.docsUpload));
      await tester.pumpAndSettle();
      expect((docs.calls.single.args! as Map)['matterId'], 'm-1');
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets(
      'Windows: files dropped on the screen go to the details sheet',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        sources = FakeSources(files: [fakeFile('Order 28-10-2026.pdf')]);
        await open(tester, size: const Size(1280, 800));
        Future<void> platform(String method, Object args) =>
            tester.binding.defaultBinaryMessenger.handlePlatformMessage(
              'desktop_drop',
              const StandardMethodCodec().encodeMethodCall(
                MethodCall(method, args),
              ),
              (_) {},
            );
        await platform('entered', [700.0, 400.0]);
        await tester.pump();
        expect(find.text(en.docsDropHere), findsOneWidget);
        await platform('performOperation', ['C:/picked/Order 28-10-2026.pdf']);
        await tester.pumpAndSettle();
        expect(find.text(en.docsDropHere), findsNothing);
        expect(find.text(en.docsScan), findsNothing);
        await tester.tap(find.text(en.docsUpload));
        await tester.pumpAndSettle();
        expect((docs.calls.single.args! as Map)['title'], 'Order 28-10-2026');

        // Two at once: a sheet for each, then both wait in the queue.
        docs.calls.clear();
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        await platform('entered', [700.0, 400.0]);
        await tester.pump();
        await platform('performOperation', [
          'C:/picked/Reply.pdf',
          'C:/picked/Rejoinder.pdf',
        ]);
        await tester.pumpAndSettle();
        for (final name in ['Reply.pdf', 'Rejoinder.pdf']) {
          expect(find.textContaining(name), findsOneWidget);
          await tester.tap(find.text(en.docsUpload));
          await tester.pumpAndSettle();
        }
        expect(docs.calls.map((c) => (c.args! as Map)['title']), [
          'Reply',
          'Rejoinder',
        ]);
        expect(snack(en.docsQueued(2)), findsOneWidget);
        debugDefaultTargetPlatformOverride = null;
      },
    );
  });

  group('viewer', () {
    SamplePdfPages pagesOf(WidgetTester tester) =>
        tester.widget<AppPdfViewer>(find.byType(AppPdfViewer)).pages
            as SamplePdfPages;

    testWidgets('a PDF opens with pages, find, jump to page and zoom', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.text('Writ petition'));
      await tester.pumpAndSettle();
      expect(docs.calls.last, (
        name: 'open',
        args: (kind: 'document', id: 'd-1', mime: pdfMime),
      ));
      expect(find.widgetWithText(AppBar, 'Writ petition'), findsOneWidget);
      expect(find.text(en.docsPage(1, 3)), findsOneWidget);

      await tester.tap(find.byTooltip(en.docsFind));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'four');
      await tester.pump();
      expect(find.text(en.docsFindCount(1, 2)), findsOneWidget);
      expect(find.text(en.docsPage(2, 3)), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(find.text(en.docsFindCount(2, 2)), findsOneWidget);
      await tester.tap(find.byTooltip(en.docsFindPrevious));
      await tester.pump();
      expect(find.text(en.docsFindCount(1, 2)), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'bail');
      await tester.pump();
      expect(find.text(en.docsFindNone), findsOneWidget);
      await tester.tap(find.byTooltip(en.docsFindClose));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);

      await tester.tap(find.text(en.docsPage(2, 3)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '7');
      await tester.tap(find.text(en.docsGo));
      await tester.pump();
      expect(find.text(en.docsPageInvalid(3)), findsOneWidget);
      await tester.enterText(find.byType(TextField), '3');
      await tester.tap(find.text(en.docsGo));
      await tester.pumpAndSettle();
      expect(find.text(en.docsPage(3, 3)), findsOneWidget);

      await tester.tap(find.byTooltip(en.docsZoomIn));
      await tester.tap(find.byTooltip(en.docsZoomIn));
      await tester.tap(find.byTooltip(en.docsZoomOut));
      expect(pagesOf(tester).zoomed, 1);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(docs.calls.last, (name: 'close', args: 'd-1'));
    });

    testWidgets('keyboard: Ctrl+F finds, Enter goes on, Esc closes, Ctrl+= '
        'zooms', (tester) async {
      await open(
        tester,
        location: '/documents/d-1',
        size: const Size(1280, 800),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'weeks');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(find.text(en.docsFindCount(2, 2)), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(pagesOf(tester).zoomed, 1);
    });

    testWidgets('AC (spec §4.3): a document kept offline opens with the '
        'network off', (tester) async {
      docs = FakeDocuments(cached: {'d-1': File('d-1.pdf')})
        ..failOpen = const ApiException('NETWORK', retryable: true);
      final api = await open(tester);
      api.offline = true;
      container(tester).read(routerProvider).go('/documents/d-1');
      await tester.pumpAndSettle();
      expect(find.byType(AppPdfViewer), findsOneWidget);
      expect(find.text(en.docsPage(1, 3)), findsOneWidget);
      expect(api.callNames, isNot(contains('documentUrl')));
    });

    testWidgets('offline without a copy says so and keeps Retry', (
      tester,
    ) async {
      docs.failOpen = const ApiException('NETWORK', retryable: true);
      await open(tester, location: '/documents/d-3');
      expect(find.text(en.docsNoCopy), findsOneWidget);
      docs.failOpen = null;
      await tester.tap(find.text(en.retry));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
    });

    testWidgets('offline without a copy of a kept file: it comes when online', (
      tester,
    ) async {
      docs.failOpen = const ApiException('NETWORK', retryable: true);
      await open(tester, location: '/documents/d-1');
      expect(find.text(en.docsNoCopyKept), findsOneWidget);
      expect(find.text(en.docsNoCopy), findsNothing);
    });

    testWidgets("a failure that isn't the network's says so, with Retry", (
      tester,
    ) async {
      docs.failOpen = const FileSystemException('locked');
      await open(tester, location: '/documents/d-3');
      expect(find.text(en.errorGeneric), findsOneWidget);
      docs.failOpen = null;
      await tester.tap(find.text(en.retry));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
    });

    testWidgets('a Word file opens in another app, with a note', (
      tester,
    ) async {
      await open(tester, location: '/documents/d-5');
      expect(find.text(en.docsDocxNote), findsOneWidget);
      await tester.tap(find.text(en.docsOpenElsewhere));
      await tester.pumpAndSettle();
      expect(openedElsewhere.single.mime, docxMime);
      expect(openedElsewhere.single.path, 'd-5.docx');
    });

    testWidgets("a file being checked, or one that isn't here, says so", (
      tester,
    ) async {
      await open(tester, location: '/documents/d-2');
      expect(find.text(en.errorDocumentNotReady), findsOneWidget);
      container(tester).read(routerProvider).go('/documents/gone');
      await tester.pumpAndSettle();
      expect(find.text(en.docsMissing), findsOneWidget);
      expect(docs.calls, isEmpty);
    });

    testWidgets('a download shows progress and can be cancelled', (
      tester,
    ) async {
      final files = _SlowFiles();
      await open(
        tester,
        location: '/documents/d-3',
        fakeFiles: false,
        overrides: [offlineFilesProvider.overrideWithValue(files)],
      );
      files.progress!(0.25);
      await tester.pump();
      expect(find.text(en.docsDownloading(25)), findsOneWidget);
      await tester.tap(find.text(en.cancel));
      await tester.pumpAndSettle();
      expect(find.text(en.docsCancelled), findsOneWidget);
    });
  });

  // Spec §5.9, §4.3 AC: the list, the upload sheet and the viewer at 200% text, in both languages, with 48 dp
  // labelled targets.
  for (final locale in ['en', 'hi']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('documents, $locale, ${scale}x', (tester) async {
        final l = locale == 'en' ? en : hi;
        final semantics = tester.ensureSemantics();
        sources = FakeSources(files: [fakeFile('Rejoinder.pdf')]);
        await open(
          tester,
          locale: locale,
          textScale: scale,
          size: const Size(400, 860),
        );
        expect(tester.takeException(), isNull);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

        await tester.tap(find.byTooltip(l.addDocument));
        await tester.pumpAndSettle();
        await tester.tap(find.text(l.docsChooseFiles));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();

        container(tester).read(routerProvider).go('/documents/d-1');
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip(l.docsFind));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'four');
        await tester.pump();
        expect(tester.takeException(), isNull);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        semantics.dispose();
      });
    }
  }
}

/// A download that waits: [progress] reports, Cancel stops it.
class _SlowFiles extends OfflineFiles {
  _SlowFiles() : super(null, FakeApi(), null, DateTime.now);

  void Function(double)? progress;

  @override
  Future<File> open(
    FileRef ref, {
    required String orgId,
    void Function(double fraction)? onProgress,
    CancelToken? cancel,
  }) async {
    progress = onProgress;
    await cancel!.whenCancel;
    throw const ApiException('CANCELLED');
  }

  @override
  void close(String id) {}
}
