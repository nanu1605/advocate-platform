import 'dart:async';

import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/diary.dart';
import 'package:advocate_app/data/diary_text.dart';
import 'package:advocate_app/features/board/assign_sheet.dart';
import 'package:advocate_app/features/board/board_share.dart';
import 'package:advocate_app/ui/board_table.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/sheets.dart';
import 'package:advocate_app/ui/skeleton.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Tomorrow's Board (spec §4.2), `/board/tomorrow`: tomorrow's diary (IST) by court, with clashes, and Share.
/// Owners and advocates can Assign to and Mark proxy arranged (RLS); juniors and clerks read it. Before the
/// evening build the known rows show with a note on when item numbers come. Windows: Tab moves row to row,
/// Enter opens the case.
class BoardScreen extends ConsumerWidget {
  const BoardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final locale = Localizations.localeOf(context);
    final f = Formats(locale);
    final tomorrow = ref.watch(istTomorrowProvider);
    final day = isoDate(tomorrow);
    final diary = ref.watch(diaryProvider(day));
    final switchAt =
        ref.watch(eveningSwitchProvider).value ?? defaultEveningSwitch;
    final evening = ref.watch(eveningProvider);
    final me = ref.watch(currentUserIdProvider);
    final manages = ref.watch(currentOrgProvider)?.managesBoard ?? false;
    final entries = diary.value ?? const <DiaryEntry>[];
    // Not built yet: before the switch, when item numbers come; after it, courts are late (retried at 20:30 and
    // 22:00, spec §11.5).
    final note = evening
        ? l.boardNotBuiltLate
        : l.boardNotBuilt(f.time(DateTime.utc(2000).add(switchAt)));

    BoardRow row(DiaryEntry e) {
      final assignee = e.assigneeId == null
          ? null
          : e.assigneeId == me
          ? l.boardYou
          : e.assigneeName;
      final stop = locale.languageCode == 'hi' ? '।' : '.';
      final board = manages ? e.boardEntryId : null;
      return BoardRow(
        caseNumber: e.caseLabel,
        court: e.court?.label(locale) ?? l.foundOtherCourt,
        title: e.title == e.caseLabel ? null : e.title,
        courtNo: e.courtNo,
        itemNo: e.itemNo,
        purpose: e.purpose,
        client: e.client,
        assignee: assignee,
        clash: e.clash,
        proxy: e.proxyArranged,
        note: clashExplanation(l, locale, e, entries),
        semanticsLabel: [
          diaryRowLabel(l, locale, e),
          for (final s in [
            ?(e.title == e.caseLabel ? null : e.title),
            ?e.purpose,
            if (e.client != null) l.boardClientIs(e.client!),
            if (assignee != null) l.boardAssigneeIs(assignee),
          ])
            '$s$stop',
        ].join(' '),
        onTap: () => unawaited(context.push('/cases/${e.matterId}')),
        actions: board == null || !e.clash
            ? const []
            : [
                OutlinedButton.icon(
                  onPressed: () => unawaited(_assign(context, ref, e)),
                  icon: const Icon(AppIcons.userSwitch),
                  label: Text(l.boardAssignTo),
                ),
                OutlinedButton.icon(
                  onPressed: () => unawaited(_proxy(context, ref, e)),
                  icon: const Icon(AppIcons.handshake),
                  label: Text(l.boardProxyMark),
                ),
              ],
        menu: board == null
            ? null
            : PopupMenuButton<bool>(
                tooltip: l.boardMoreActions(spokenCaseLabel(l, e.caseLabel)),
                icon: const Icon(AppIcons.dotsThreeVertical),
                onSelected: (proxy) => unawaited(
                  proxy ? _proxy(context, ref, e) : _assign(context, ref, e),
                ),
                itemBuilder: (_) => [
                  PopupMenuItem(value: false, child: Text(l.boardAssignTo)),
                  PopupMenuItem(
                    value: true,
                    child: Text(
                      e.proxyArranged ? l.boardProxyClear : l.boardProxyMark,
                    ),
                  ),
                ],
              ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l.boardTitle),
        actions: [
          IconButton(
            tooltip: l.boardShare,
            icon: const Icon(AppIcons.shareNetwork),
            onPressed: entries.isEmpty
                ? null
                : () => unawaited(
                    showBoardShareSheet(
                      context,
                      tomorrow,
                      entries,
                      note: entries.boardBuilt ? null : note,
                    ),
                  ),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The day the board covers sits in the body: the app bar would cut it off at 200% text (spec §5.9).
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(f.shortDate(tomorrow), style: context.text.titleMedium),
          ),
          Expanded(
            child: diary.when(
              loading: () => const _Loading(),
              error: (e, _) => ErrorState(
                message: errorText(l, e),
                onRetry: () => ref.invalidate(diaryProvider(day)),
              ),
              data: (_) => entries.isEmpty
                  ? Center(
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            EmptyState(
                              icon: AppIcons.calendarBlank,
                              message: l.boardEmpty,
                            ),
                            // Before the evening build an empty board may just not be built yet.
                            if (!evening) _Note(note),
                          ],
                        ),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      children: [
                        if (!entries.boardBuilt) _Note(note),
                        BoardTable([for (final e in entries) row(e)]),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// Assign to (spec §4.2): the write is local and re-applies the clash rule at once. Undo puts back who it was
  /// (or no one).
  Future<void> _assign(
    BuildContext context,
    WidgetRef ref,
    DiaryEntry e,
  ) async {
    final l = context.l10n;
    final writer = ref.read(diaryWriterProvider);
    final me = ref.read(currentUserIdProvider);
    final picked = (await showAssignSheet(
      context,
      caseLabel: e.caseLabel,
      currentId: e.assigneeId,
    ))?.member;
    if (picked == null || picked.userId == e.assigneeId) return;
    final id = e.boardEntryId!;
    await writer.assign(id, picked.userId);
    if (!context.mounted) return;
    showUndoSnackbar(
      context,
      message: l.boardAssignedSnack(
        e.caseLabel,
        picked.userId == me ? l.boardYou : memberName(l, picked),
      ),
      onUndo: () => unawaited(writer.assign(id, e.assigneeId)),
    );
  }

  /// Mark proxy arranged, or remove it, with Undo.
  Future<void> _proxy(BuildContext context, WidgetRef ref, DiaryEntry e) async {
    final l = context.l10n;
    final writer = ref.read(diaryWriterProvider);
    final id = e.boardEntryId!;
    final arranged = !e.proxyArranged;
    await writer.setProxy(id, arranged: arranged);
    if (!context.mounted) return;
    showUndoSnackbar(
      context,
      message: arranged
          ? l.boardProxyMarkedSnack(e.caseLabel)
          : l.boardProxyClearedSnack(e.caseLabel),
      onUndo: () => unawaited(writer.setProxy(id, arranged: !arranged)),
    );
  }
}

/// "Item numbers come after 6:30 pm, when courts publish tomorrow's lists."
class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(
            AppIcons.clock,
            size: inlineIconSize(context, 18),
            color: context.colors.ink2,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: context.text.bodyMedium)),
      ],
    ),
  );
}

/// Rows loading: skeleton lines shaped like the board.
class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      for (var i = 0; i < 4; i++)
        const Padding(
          padding: EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Skeleton(width: 160, height: 18),
              SizedBox(height: 6),
              Skeleton(width: 240, height: 14),
            ],
          ),
        ),
    ],
  );
}
