import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/ui/app_scaffold.dart';
import 'package:advocate_app/ui/board_table.dart';
import 'package:advocate_app/ui/case_card.dart';
import 'package:advocate_app/ui/command_palette.dart';
import 'package:advocate_app/ui/court_badge.dart';
import 'package:advocate_app/ui/fields.dart';
import 'package:advocate_app/ui/hearing_chip.dart';
import 'package:advocate_app/ui/icons.dart';
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
  KitSection('board_phone', (_) => const BoardTable(_board)),
  KitSection('board_desktop', (_) => const BoardTable(_board), width: 1000),
  KitSection(
    'dialogs',
    (context) => _col([
      ConfirmDialog(
        title: context.l10n.confirmDeleteTitle,
        body: context.l10n.confirmDeleteBody,
        confirmLabel: context.l10n.delete,
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

const _board = [
  BoardRow(
    caseNumber: 'WP 1234/2024',
    court: 'MPHC Indore',
    courtNo: '12',
    itemNo: '23',
    purpose: 'Hearing',
    client: 'R. Sharma',
    assignee: 'Priya',
  ),
  BoardRow(
    caseNumber: 'CRA 455/2023',
    court: 'MPHC Indore',
    courtNo: '7',
    itemNo: '41',
    purpose: 'Arguments',
    client: 'M. Lal',
    assignee: 'Self',
  ),
  BoardRow(
    caseNumber: 'CS 210/2022',
    court: 'District Court Indore',
    courtNo: '5',
    itemNo: '8',
    purpose: 'Evidence',
    client: 'A. Gupta',
    clash: true,
  ),
];

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
