import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/documents.dart';
import 'package:advocate_app/ui/app_scaffold.dart';
import 'package:advocate_app/ui/board_table.dart';
import 'package:advocate_app/ui/case_card.dart';
import 'package:advocate_app/ui/command_palette.dart';
import 'package:advocate_app/ui/court_badge.dart';
import 'package:advocate_app/ui/fields.dart';
import 'package:advocate_app/ui/hearing_chip.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/pdf_viewer.dart';
import 'package:advocate_app/ui/section_header.dart';
import 'package:advocate_app/ui/selectable_row.dart';
import 'package:advocate_app/ui/sheets.dart';
import 'package:advocate_app/ui/skeleton.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:advocate_app/ui/status_pill.dart';
import 'package:advocate_app/ui/tiles.dart';
import 'package:flutter/material.dart';

/// Fixed "today" so goldens are stable: matters dated 5 Nov read as "Tomorrow".
final kitToday = DateTime(2026, 11, 4);
final _nov5 = DateTime(2026, 11, 5);

@immutable
class KitSection {
  const KitSection(this.id, this.build, {this.width = 400, this.height});

  final String id;
  final WidgetBuilder build;
  final double width;

  /// Only for sections that fill their box (scaffolds); others size to content.
  final double? height;
}

void _noop() {}

Widget _col(List<Widget> children) => Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  mainAxisSize: MainAxisSize.min,
  children: [
    for (final c in children)
      Padding(padding: const EdgeInsets.only(bottom: 12), child: c),
  ],
);

final _hero = CaseCardData(
  caseNumber: 'WP 1234/2024',
  title: 'Ramesh Sharma v. State of Madhya Pradesh and others',
  court: 'MPHC Indore',
  courtNo: '12',
  itemNo: '23',
  judge: 'Justice A. B. Verma',
  purpose: 'Hearing',
  nextDate: _nov5,
  state: CaseCardState.listed,
);

/// Every P0 kit component (ADR 0001), in the shapes the screens use.
final kitSections = <KitSection>[
  KitSection(
    'pills',
    (context) => _col([
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [for (final k in PillKind.values) StatusPill(k)],
      ),
      const SectionHeader(
        'Today',
        count: 5,
        actionLabel: 'By court',
        onAction: _noop,
      ),
      const SectionHeader('Later', count: 40, onToggle: _noop),
      const SectionHeader(
        'Disposed',
        count: 4,
        expanded: false,
        onToggle: _noop,
      ),
      const CourtBadge(court: 'MPHC Indore', courtNo: '12', itemNo: '23'),
      HearingChip(date: _nov5, today: kitToday),
      HearingChip(date: null, today: kitToday),
    ]),
  ),
  KitSection(
    'case_cards',
    (context) => _col([
      CaseCard(
        _hero,
        variant: CaseCardVariant.hero,
        today: kitToday,
        actions: [
          FilledButton(onPressed: _noop, child: Text(context.l10n.boardCase)),
          OutlinedButton(
            onPressed: _noop,
            child: Text(context.l10n.navDocuments),
          ),
        ],
      ),
      CaseCard(
        CaseCardData(
          caseNumber: 'CRA 455/2023',
          title: 'Mohan Lal v. State of MP',
          court: 'MPHC Indore',
          courtNo: '7',
          itemNo: '41',
          nextDate: _nov5,
          state: CaseCardState.newOrder,
        ),
        today: kitToday,
      ),
      CaseCard(
        CaseCardData(
          caseNumber: 'CS 210/2022',
          title: 'गुप्ता बनाम जैन',
          court: 'District Court Indore',
          courtNo: '5',
          nextDate: DateTime(2026, 11, 20),
          state: CaseCardState.adjourned,
        ),
        today: kitToday,
      ),
    ]),
  ),
  KitSection(
    'case_cards_compact',
    (context) => _col([
      for (final s in [
        CaseCardState.disposed,
        CaseCardState.manual,
        CaseCardState.syncing,
        CaseCardState.error,
      ])
        CaseCard(
          CaseCardData(
            caseNumber: 'MCRC 9921/2025',
            title: 'Verma v. State',
            court: 'MPHC Indore',
            state: s,
          ),
          variant: CaseCardVariant.compact,
        ),
      // Cases list rows: next date and assignee; the case open beside the list on Windows.
      CaseCard(
        CaseCardData(
          caseNumber: 'WP 1234/2024',
          title: 'Ramesh Sharma v. State of Madhya Pradesh and others',
          court: 'MPHC Indore',
          courtNo: '12',
          nextDate: _nov5,
          assignee: 'Neha Verma',
        ),
        variant: CaseCardVariant.compact,
        today: kitToday,
        selected: true,
      ),
    ]),
  ),
  KitSection(
    'selection',
    (context) => _col([
      GroupHeader(
        title: 'MP High Court · Indore',
        selectedCount: 1,
        total: 2,
        onSelectAll: (_) {},
        onToggleExpanded: _noop,
      ),
      SelectableRow(
        selected: true,
        onChanged: (_) {},
        title: 'WP 1234/2024  Sharma v. State',
        subtitle: 'Court 12 · Next 5 Nov · Pending',
      ),
      SelectableRow(
        selected: false,
        onChanged: (_) {},
        title: 'CS 77/2019  Gupta v. Jain',
        subtitle: 'Room 5 · No date',
        warning: 'Check — might not be yours',
      ),
    ]),
  ),
  KitSection(
    'states',
    (context) => _col([
      const OfflineBanner(),
      const Row(
        children: [
          SyncIndicator(SyncStatus.synced),
          SyncIndicator(SyncStatus.syncing),
          SyncIndicator(SyncStatus.failed),
        ],
      ),
      EmptyState(
        message: context.l10n.todayEmpty,
        actionLabel: context.l10n.addFirstCase,
        onAction: _noop,
      ),
      ErrorState(message: context.l10n.errorNetwork, onRetry: _noop),
      const SkeletonCaseList(count: 2),
    ]),
  ),
  KitSection(
    'fields',
    (context) => _col([
      AppTextField(
        label: context.l10n.phoneLabel,
        hint: context.l10n.phoneHint,
      ),
      PhoneField(
        controller: TextEditingController(text: '98765'),
        error: context.l10n.phoneInvalid,
      ),
      OtpField(controller: TextEditingController(text: '1234')),
      DateField(onChanged: (_) {}, initial: _nov5),
      SearchField(hint: context.l10n.searchCasesHint),
    ]),
  ),
  KitSection(
    'controls',
    (context) => _col([
      Wrap(
        spacing: 8,
        children: [
          FilterChip(
            label: Text(context.l10n.statusListed),
            selected: true,
            onSelected: (_) {},
          ),
          FilterChip(
            label: Text(context.l10n.statusDisposed),
            selected: false, // ignore: avoid_redundant_argument_values, shown for contrast
            onSelected: (_) {},
          ),
          const Chip(label: Text('MPHC Indore')),
        ],
      ),
      DefaultTabController(
        length: 3,
        child: TabBar(
          isScrollable: true,
          tabs: [
            Tab(text: context.l10n.boardCase),
            Tab(text: context.l10n.navDocuments),
            Tab(text: context.l10n.boardClient),
          ],
        ),
      ),
      SegmentedButton<int>(
        showSelectedIcon: false,
        segments: [
          ButtonSegment(value: 0, label: Text(context.l10n.themeLight)),
          ButtonSegment(value: 1, label: Text(context.l10n.themeDark)),
          ButtonSegment(value: 2, label: Text(context.l10n.themeSunlight)),
        ],
        selected: const {2},
        onSelectionChanged: (_) {},
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(context.l10n.settingsReduceMotion),
        value: true,
        onChanged: (_) {},
      ),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(context.l10n.consentWhatsapp),
        value: false,
        onChanged: (_) {},
      ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton(
            onPressed: _noop,
            child: Text(context.l10n.continueButton),
          ),
          OutlinedButton(onPressed: _noop, child: Text(context.l10n.cancel)),
          TextButton(onPressed: _noop, child: Text(context.l10n.retry)),
        ],
      ),
    ]),
  ),
  // Keyboard focus on Windows (spec §5.9): the 2 dp ring round buttons and rows.
  const KitSection('focus', _focused),
  KitSection(
    'tiles',
    (context) => _col([
      DocumentTile(
        title: 'Order dated 28-10-2026 — reply within 4 weeks',
        kind: context.l10n.statusNewOrder,
        pages: 3,
        offline: true,
        onTap: _noop,
      ),
      TaskItem(
        title: 'File reply in WP 1234/2024',
        done: false,
        onChanged: (_) {},
        due: 'Thu, 5 Nov',
        assignee: 'Priya',
        overdue: true,
      ),
      TaskItem(title: 'Collect certified copy', done: true, onChanged: (_) {}),
      const ClientTile(
        name: 'Ramesh Sharma',
        caseCount: 2,
        phone: '+91 98765 43210',
        onTap: _noop,
      ),
      // The client open beside the list (Windows two panes).
      const ClientTile(
        name: 'राजेश शर्मा',
        caseCount: 1,
        onTap: _noop,
        selected: true,
      ),
      const Row(
        children: [
          Avatar('रमेश शर्मा'),
          SizedBox(width: 8),
          Avatar('Priya Jain'),
          SizedBox(width: 8),
          Avatar('Mohan'),
        ],
      ),
    ]),
  ),
  // Document rows' states (Documents screen, case Documents tab) and the PDF viewer (kit #17).
  KitSection('document_tiles', (context) {
    final l = context.l10n;
    return _col([
      DocumentTile(
        title: 'Writ petition',
        kind: '${l.casesDocPleading} · 240 KB · WP 1234/2024',
        pages: 12,
        offline: true,
        trailing: IconButton(
          isSelected: true,
          tooltip: l.docsKeepOffline,
          icon: const Icon(AppIcons.downloadSimple),
          selectedIcon: const Icon(AppIcons.downloadSimpleFill),
          onPressed: _noop,
        ),
        onTap: _noop,
      ),
      DocumentTile(
        title: 'Reply draft',
        kind: '${l.casesDocCorrespondence} · 80 KB',
        mime: docxMime,
        state: DocState.checking,
      ),
      DocumentTile(
        title: 'Photo from client',
        kind: '${l.casesDocEvidence} · 1.2 MB',
        mime: 'image/jpeg',
        state: DocState.blocked,
      ),
      DocumentTile(
        title: 'Vakalatnama',
        kind: '${l.casesDocOther} · 300 KB',
        state: DocState.uploading,
        progress: 0.4,
      ),
      DocumentTile(
        title: 'Annexure P-3',
        kind: l.casesDocAnnexure,
        state: DocState.waiting,
        trailing: IconButton(
          tooltip: l.docsRemoveUpload,
          icon: const Icon(AppIcons.trash),
          onPressed: _noop,
        ),
      ),
      DocumentTile(
        title: 'Evidence bundle',
        kind: '${l.casesDocEvidence} · 64 MB',
        state: DocState.failed,
        error: l.docsDataTooLarge,
      ),
    ]);
  }),
  KitSection('pdf_viewer', (_) => const _SamplePdf(), height: 520),
  KitSection(
    'timeline',
    (context) => _col([
      Column(
        children: [
          TimelineItem(
            date: '28 Oct',
            kind: TimelineKind.order,
            title: 'Order uploaded',
            detail: '"Reply within 4 weeks..."',
            isNew: true,
            action: TextButton(
              onPressed: _noop,
              child: Text(context.l10n.boardPurpose),
            ),
          ),
          const TimelineItem(
            date: '28 Oct',
            kind: TimelineKind.hearing,
            title: 'Hearing · Adjourned',
          ),
          const TimelineItem(
            date: '12 Sep',
            kind: TimelineKind.hearing,
            title: 'Hearing · Notice issued',
            isLast: true,
          ),
        ],
      ),
    ]),
  ),
  KitSection('board_phone', (context) => BoardTable(_board(context))),
  KitSection(
    'board_desktop',
    (context) => BoardTable(_board(context)),
    width: 1000,
  ),
  KitSection(
    'dialogs',
    (context) => _col([
      ConfirmDialog(
        title: context.l10n.confirmDeleteTitle,
        body: context.l10n.confirmDeleteBody,
        confirmLabel: context.l10n.delete,
      ),
      // With its own cancel label: Settings' sign-out with changes still to upload.
      ConfirmDialog(
        title: context.l10n.signOut,
        body:
            '${context.l10n.signOutPendingChanges(3)} '
            '${context.l10n.signOutPendingLost}',
        confirmLabel: context.l10n.signOutPendingConfirm,
        cancelLabel: context.l10n.signOutPendingStay,
      ),
    ]),
  ),
  KitSection(
    'command_palette',
    (context) => CommandPalette(
      commands: [
        PaletteCommand(
          label: context.l10n.navToday,
          icon: AppIcons.sun,
          shortcut: 'Ctrl+1',
          run: _noop,
        ),
        PaletteCommand(
          label: context.l10n.navCases,
          icon: AppIcons.briefcase,
          shortcut: 'Ctrl+2',
          run: _noop,
        ),
        PaletteCommand(
          label: context.l10n.addCase,
          icon: AppIcons.plus,
          shortcut: 'Ctrl+N',
          run: _noop,
        ),
      ],
    ),
    width: 640,
    height: 480,
  ),
  const KitSection('scaffold_phone', _scaffold, height: 640),
  const KitSection('scaffold_desktop', _scaffold, width: 1100, height: 640),
];

List<BoardRow> _board(BuildContext context) {
  final l = context.l10n;
  final menu = IconButton(
    tooltip: l.boardMoreActions('WP 1234/2024'),
    icon: const Icon(AppIcons.dotsThreeVertical),
    onPressed: _noop,
  );
  return [
    BoardRow(
      caseNumber: 'WP 1234/2024',
      court: 'MPHC Indore',
      title: 'Sharma v. State of MP',
      courtNo: '12',
      itemNo: '23',
      purpose: 'Hearing',
      client: 'R. Sharma',
      assignee: 'Priya',
      onTap: _noop,
      menu: menu,
    ),
    BoardRow(
      caseNumber: 'CRA 455/2023',
      court: 'MPHC Indore',
      courtNo: '7',
      itemNo: '41',
      purpose: 'Arguments',
      client: 'M. Lal',
      assignee: 'Self',
      proxy: true,
      onTap: _noop,
      menu: menu,
    ),
    BoardRow(
      caseNumber: 'CS 210/2022',
      court: 'District Court Indore',
      courtNo: '5',
      itemNo: '8',
      purpose: 'Evidence',
      client: 'A. Gupta',
      clash: true,
      note: 'Clashes with WP 1234/2024 at MPHC Indore, about 11:58 am. Times are estimated from item numbers.',
      onTap: _noop,
      actions: [
        OutlinedButton.icon(
          onPressed: _noop,
          icon: const Icon(AppIcons.userSwitch),
          label: Text(l.boardAssignTo),
        ),
        OutlinedButton.icon(
          onPressed: _noop,
          icon: const Icon(AppIcons.handshake),
          label: Text(l.boardProxyMark),
        ),
      ],
      menu: menu,
    ),
  ];
}

Widget _focused(BuildContext context) => const _Focused();

/// The buttons are drawn focused and the case card takes the keyboard focus. Keyboard highlighting is on while the
/// section shows: a phone starts in touch mode, which hides every ring.
class _Focused extends StatefulWidget {
  const _Focused();

  @override
  State<_Focused> createState() => _FocusedState();
}

class _FocusedState extends State<_Focused> {
  final FocusHighlightStrategy _was = FocusManager.instance.highlightStrategy;
  final List<WidgetStatesController> _states = [
    for (var i = 0; i < 4; i++) WidgetStatesController({WidgetState.focused}),
  ];

  @override
  void initState() {
    super.initState();
    // After the frame: a mode change rebuilds every ink well, which can't happen mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      setState(() {}); // the buttons read the mode when they build
    });
  }

  @override
  void dispose() {
    for (final s in _states) {
      s.dispose();
    }
    final was = _was;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => FocusManager.instance.highlightStrategy = was,
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return _col([
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          FilledButton(
            statesController: _states[0],
            onPressed: _noop,
            child: Text(l.continueButton),
          ),
          OutlinedButton(
            statesController: _states[1],
            onPressed: _noop,
            child: Text(l.cancel),
          ),
          TextButton(
            statesController: _states[2],
            onPressed: _noop,
            child: Text(l.retry),
          ),
          IconButton(
            statesController: _states[3],
            tooltip: l.sunlightToggle,
            icon: const Icon(AppIcons.sun),
            onPressed: _noop,
          ),
        ],
      ),
      CaseCard(
        CaseCardData(
          caseNumber: 'CRA 455/2023',
          title: 'Mohan Lal v. State of MP',
          court: 'MPHC Indore',
          courtNo: '7',
          nextDate: _nov5,
        ),
        variant: CaseCardVariant.compact,
        today: kitToday,
        onTap: _noop,
        autofocus: true,
      ),
    ]);
  }
}

/// The shell picks its layout from MediaQuery, so size it to the section box.
Widget _scaffold(BuildContext context) => LayoutBuilder(
  builder: (context, box) => MediaQuery(
    data: MediaQuery.of(context).copyWith(size: box.biggest),
    child: _shell(context),
  ),
);

Widget _shell(BuildContext context) {
  final l = context.l10n;
  final dests = [
    NavDest('/today', AppIcons.sun, AppIcons.sunFill, l.navToday),
    NavDest('/cases', AppIcons.briefcase, AppIcons.briefcaseFill, l.navCases),
    NavDest(
      '/more',
      AppIcons.dotsThreeCircle,
      AppIcons.dotsThreeCircleFill,
      l.navMore,
    ),
  ];
  return AppScaffold(
    location: '/today',
    phoneDestinations: dests,
    railDestinations: [
      ...dests.take(2),
      NavDest('/settings', AppIcons.gear, AppIcons.gearFill, l.navSettings),
    ],
    onNavigate: (_) {},
    onCenterAction: _noop,
    onCommandPalette: _noop,
    banner: const OfflineBanner(),
    child: EmptyState(message: l.todayEmpty),
  );
}

/// Debug-only route /dev/kitchen-sink (spec §5.11).
class KitchenSinkScreen extends StatelessWidget {
  const KitchenSinkScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Component kit')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final s in kitSections) ...[
          SectionHeader(s.id),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: SizedBox(
              width: s.width,
              height: s.height,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: context.colors.line),
                ),
                child: s.build(context),
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

/// A stand-in for [PdfrxPages], as PDFium doesn't run under flutter test: [texts] as plain pages, searched like a
/// PDF's text (ignoring case), stopping at the first and last match as pdfrx does. Widget tests use it too.
class SamplePdfPages extends PdfPages {
  SamplePdfPages([
    this.texts = const [
      'IN THE HIGH COURT OF MADHYA PRADESH AT INDORE\nWP 1234/2024\nRamesh Sharma v. State of MP',
      'ORDER\nHeard counsel for the petitioner. Reply within four weeks.',
      'List after four weeks. Interim order to continue.',
    ],
  ]);

  final List<String> texts;
  var _page = 1;
  var _matches = const <int>[];
  int? _match;

  /// Zoom steps taken (in minus out).
  int zoomed = 0;

  @override
  int get pageCount => texts.length;

  @override
  int get page => _page;

  @override
  int get matchCount => _matches.length;

  @override
  int? get match => _match;

  @override
  bool get searching => false;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      for (final text in texts)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Container(
            constraints: const BoxConstraints(minHeight: 200),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: context.colors.line),
            ),
            // A page is paper whatever the theme.
            child: Text(text, style: const TextStyle(color: Colors.black)),
          ),
        ),
    ],
  );

  @override
  void goTo(int page) {
    _page = page;
    notifyListeners();
  }

  @override
  void find(String text) {
    final q = text.trim().toLowerCase();
    _matches = [
      if (q.isNotEmpty)
        for (final (i, t) in texts.indexed)
          ...List.filled(q.allMatches(t.toLowerCase()).length, i + 1),
    ];
    _match = _matches.isEmpty ? null : 0;
    if (_matches.isNotEmpty) _page = _matches.first;
    notifyListeners();
  }

  void _show(int i) {
    if (i < 0 || i >= _matches.length) return;
    _match = i;
    _page = _matches[i];
    notifyListeners();
  }

  @override
  void nextMatch() => _show((_match ?? -1) + 1);

  @override
  void previousMatch() => _show((_match ?? _matches.length) - 1);

  @override
  void zoom(int step) {
    zoomed += step;
    notifyListeners();
  }
}

/// The PDF viewer section: one [SamplePdfPages] for the section's life.
class _SamplePdf extends StatefulWidget {
  const _SamplePdf();

  @override
  State<_SamplePdf> createState() => _SamplePdfState();
}

class _SamplePdfState extends State<_SamplePdf> {
  final _pages = SamplePdfPages();

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppPdfViewer(_pages);
}
