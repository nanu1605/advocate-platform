import 'dart:async';

import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/documents.dart';
import 'package:advocate_app/features/case_page/case_page_text.dart';
import 'package:advocate_app/features/case_page/sheet_form.dart';
import 'package:advocate_app/features/onboarding/onboarding_layout.dart';
import 'package:advocate_app/ui/fields.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/sheets.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:advocate_app/ui/tiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Timeline (spec §4.3): hearings and orders, newest first. A hearing shows the court's values, the user's where
/// they differ ("You noted"), and its note, which can be added on every hearing. Manual cases add, edit and delete
/// their hearings ("Add next date" adds one). An order says "New" until the user opens it in the viewer (the court's
/// copy, else its uploaded document), and "Available offline" when its file is on the device. Order summaries are
/// P2. A sliver for the case page.
class TimelineTab extends ConsumerWidget {
  const TimelineTab(this.c, {super.key});

  final CaseInfo c;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final timeline = ref.watch(caseTimelineProvider(c.id));
    void addDate() => unawaited(showHearingSheet(context, matterId: c.id));
    final waiting = tabWaiting(
      context,
      [timeline],
      onRetry: () => ref
        ..invalidate(caseHearingsProvider(c.id))
        ..invalidate(caseOrdersProvider(c.id)),
    );
    if (waiting != null) return waiting;
    final hidden = ref.watch(hiddenRowsProvider);
    final entries = [
      for (final e in timeline.requireValue)
        if (e is! CaseHearing || !hidden.contains(e.id)) e,
    ];
    if (entries.isEmpty) {
      return SliverToBoxAdapter(
        child: EmptyState(
          icon: AppIcons.gavel,
          message: c.manual
              ? l.casePageTimelineEmptyManual
              : l.casePageTimelineEmpty,
          actionLabel: c.manual ? l.casePageAddNextDate : null,
          onAction: addDate,
        ),
      );
    }
    return SliverList.list(
      children: [
        if (c.manual)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                onPressed: addDate,
                icon: const Icon(AppIcons.plus),
                label: Text(l.casePageAddNextDate),
              ),
            ),
          ),
        for (final (i, e) in entries.indexed)
          switch (e) {
            CaseHearing() => _Hearing(
              e,
              matterId: c.id,
              last: i == entries.length - 1,
            ),
            CaseOrder() => _Order(
              e,
              matterId: c.id,
              last: i == entries.length - 1,
            ),
          },
      ],
    );
  }
}

class _Hearing extends ConsumerWidget {
  const _Hearing(this.h, {required this.matterId, required this.last});

  final CaseHearing h;
  final String matterId;
  final bool last;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final locale = Localizations.localeOf(context);
    final lines = hearingLines(l, locale, h);
    return TimelineItem(
      date: timelineDate(locale, h.date),
      kind: TimelineKind.hearing,
      title: hearingTitle(l, h),
      detail: lines.isEmpty ? null : lines.join('\n'),
      isLast: last,
      action: Wrap(
        spacing: 8,
        children: [
          TextButton(
            onPressed: () {
              // Read now: sync may rebuild the timeline (and drop this row's ref) while the sheet is open.
              final writer = ref.read(caseWriterProvider);
              unawaited(
                showTextSheet(
                  context,
                  title: l.casePageHearingNote,
                  label: l.casePageHearingNote,
                  initial: h.userNote,
                  onSave: (text, {required private}) =>
                      writer.setHearingNote(h.id, text),
                ),
              );
            },
            child: Text(
              h.userNote == null ? l.casePageAddNote : l.casePageEditNote,
            ),
          ),
          if (h.manual) ...[
            TextButton(
              onPressed: () => unawaited(
                showHearingSheet(context, matterId: matterId, hearing: h),
              ),
              child: Text(l.casePageEdit),
            ),
            TextButton(
              onPressed: () => deleteWithUndo(
                context,
                ref,
                h.id,
                (w) => w.deleteHearing(h.id),
              ),
              child: Text(l.delete),
            ),
          ],
        ],
      ),
    );
  }
}

class _Order extends ConsumerWidget {
  const _Order(this.o, {required this.matterId, required this.last});

  final CaseOrder o;
  final String matterId;
  final bool last;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final date = o.date;
    final saved = ref.watch(
      offlineIdsProvider.select(
        (ids) =>
            ids.value?.contains(o.hasCourtCopy ? o.id : o.documentId) ?? false,
      ),
    );
    final success = context.colors.of(StatusKind.success).fg;
    return TimelineItem(
      date: date == null
          ? ''
          : timelineDate(Localizations.localeOf(context), date),
      kind: TimelineKind.order,
      title: o.title ?? l.casePageOrder,
      isNew: !o.read,
      isLast: last,
      action: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // The viewer marks it read once the file is here, so a failed open leaves it "New".
          TextButton(
            // Over the case, so Back returns to it and to wherever the case was opened from.
            onPressed: () =>
                unawaited(context.push('/cases/$matterId/orders/${o.id}')),
            child: Text(l.casePageOpenOrder),
          ),
          if (saved)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  AppIcons.downloadSimpleFill,
                  size: inlineIconSize(context, 16),
                  color: success,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    l.availableOffline,
                    style: context.text.bodySmall?.copyWith(color: success),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Add a hearing to a manual case ("Add next date"), or edit one ([hearing]): date (DD-MM-YYYY or the picker),
/// court and item numbers, purpose, outcome. Local; uploads with sync.
Future<void> showHearingSheet(
  BuildContext context, {
  required String matterId,
  CaseHearing? hearing,
}) => showAppBottomSheet<void>(
  context,
  builder: (_) => _HearingSheet(matterId: matterId, hearing: hearing),
);

class _HearingSheet extends ConsumerStatefulWidget {
  const _HearingSheet({required this.matterId, this.hearing});

  final String matterId;
  final CaseHearing? hearing;

  @override
  ConsumerState<_HearingSheet> createState() => _HearingSheetState();
}

class _HearingSheetState extends ConsumerState<_HearingSheet> {
  late final _date = TextEditingController(
    text: switch (widget.hearing) {
      final h? => Formats.entry(h.date),
      null => '',
    },
  );
  late final _courtNo = TextEditingController(text: widget.hearing?.courtNo);
  late final _itemNo = TextEditingController(text: widget.hearing?.itemNo);
  late final _purpose = TextEditingController(text: widget.hearing?.purpose);
  late final _outcome = TextEditingController(text: widget.hearing?.outcome);
  String? _error;

  @override
  void dispose() {
    for (final c in [_date, _courtNo, _itemNo, _purpose, _outcome]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final l = context.l10n;
    final date = Formats.parseEntry(_date.text);
    if (date == null) {
      // An invalid entry already shows the field's own error.
      setState(
        () => _error = _date.text.isEmpty ? l.casePageDateRequired : null,
      );
      announce(context, _error ?? l.dateInvalid);
      return;
    }
    final writer = ref.read(caseWriterProvider);
    final navigator = Navigator.of(context);
    final h = widget.hearing;
    if (h == null) {
      await writer.addHearing(
        widget.matterId,
        date: date,
        courtNo: _courtNo.text,
        itemNo: _itemNo.text,
        purpose: _purpose.text,
        outcome: _outcome.text,
      );
    } else {
      await writer.editHearing(
        h.id,
        date: date,
        courtNo: _courtNo.text,
        itemNo: _itemNo.text,
        purpose: _purpose.text,
        outcome: _outcome.text,
      );
    }
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return SheetForm(
      title: widget.hearing == null
          ? l.casePageAddNextDate
          : l.casePageEditHearing,
      onSave: () => unawaited(_save()),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DateField(
              controller: _date,
              onChanged: (_) => setState(() => _error = null),
            ),
            if (_error != null) FieldError(_error!),
          ],
        ),
        AppTextField(controller: _courtNo, label: l.casePageCourtNoLabel),
        AppTextField(controller: _itemNo, label: l.casePageItemNoLabel),
        AppTextField(controller: _purpose, label: l.boardPurpose),
        AppTextField(controller: _outcome, label: l.casePageOutcomeLabel),
      ],
    );
  }
}
