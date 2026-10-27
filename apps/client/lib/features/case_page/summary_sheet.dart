import 'dart:async';

import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/device.dart';
import 'package:advocate_app/data/jobs.dart';
import 'package:advocate_app/data/order_summary.dart';
import 'package:advocate_app/ui/ai_answer_card.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/section_header.dart';
import 'package:advocate_app/ui/sheets.dart';
import 'package:advocate_app/ui/source_chip.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// The summary languages, named as the language switch names them (the same words in both UIs).
const _languages = {'hi': 'हिंदी', 'en': 'English'};

/// An order's AI summary (spec §4.4 F07; the §5.3 wireframe's Summary): a court order of the case [matterId]
/// ([order]), or an uploaded order ([document]). A Hindi/English switch (the app's language when that summary
/// exists, else the one that does); each point with the pages it rests on, which open the order at that page;
/// authorities "As cited in this order — not verified"; the check-it footer. A language not made yet has "Summarise
/// in …", on demand (spec §12.14): free when cached, else it asks before spending credits. Under a court order, the
/// tasks and deadlines the AI proposed from it, confirmed or dismissed with one tap (or Confirm all) and Undo, or
/// "Find actions" when it has a summary and none (owners, advocates and juniors; F13). Snackbars show inside the
/// sheet, so Undo can be reached.
Future<void> showOrderSummarySheet(
  BuildContext context,
  String? matterId, {
  CaseOrder? order,
  CaseDocument? document,
}) {
  assert((order == null) != (document == null), 'an order or a document');
  assert(order == null || matterId != null, 'an order opens over its case');
  return showAppBottomSheet<void>(
    context,
    builder: (sheet) => SizedBox(
      height: MediaQuery.sizeOf(sheet).height * 0.85,
      child: ScaffoldMessenger(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SingleChildScrollView(
            child: _SummarySheet(matterId, order: order, document: document),
          ),
        ),
      ),
    ),
  );
}

class _SummarySheet extends ConsumerStatefulWidget {
  const _SummarySheet(this.matterId, {this.order, this.document});

  final String? matterId;
  final CaseOrder? order;
  final CaseDocument? document;

  @override
  ConsumerState<_SummarySheet> createState() => _SummarySheetState();
}

class _SummarySheetState extends ConsumerState<_SummarySheet> {
  /// Summaries the API gave, by language: an upload's never sync, and an order's may not have yet.
  final _fetched = <String, Map<String, Object?>>{};

  late String _language = _firstLanguage();

  /// What the last request says under its button (`intel`: Find actions): its progress while `busy`, then its
  /// outcome or error.
  ({bool intel, bool busy, String text})? _note;

  ProviderSubscription<AsyncValue<Job>>? _job;

  String _firstLanguage() {
    final app = Localizations.localeOf(context).languageCode == 'hi'
        ? 'hi'
        : 'en';
    final other = app == 'hi' ? 'en' : 'hi';
    final o = widget.order;
    return o != null && o.summary(app) == null && o.summary(other) != null
        ? other
        : app;
  }

  void _say(bool intel, String? text, {bool busy = false}) {
    if (!mounted) return;
    setState(
      () =>
          _note = text == null ? null : (intel: intel, busy: busy, text: text),
    );
  }

  /// Sends an on-demand request (spec §12.14) until it has an answer: AI_CREDITS_NEEDED asks the user before
  /// spending (null if they decline), ORDER_TEXT_PENDING tries again every 5 s for a minute while the order is
  /// read, and a job it starts is followed to its end. Returns the cached result, or the job's (its id, and
  /// `proposed` from its result); a failed job throws its error code.
  Future<AiResult?> _request(
    Future<AiResult> Function(
      ApiClient api,
      String orgId,
      String key,
      int credits,
    )
    call, {
    required bool intel,
    required String working,
    required String Function(int credits, int left) spend,
    required String confirm,
  }) async {
    final l = context.l10n;
    final api = ref.read(apiClientProvider);
    final org = ref.read(currentOrgIdProvider);
    if (org == null) throw const ApiException('NOT_A_MEMBER');
    final key = uuidV4();
    var (credits, waits) = (0, 0);
    _say(intel, working, busy: true);
    while (true) {
      final AiResult r;
      try {
        r = await call(api, org, key, credits);
      } on ApiException catch (e) {
        if (!mounted) return null;
        if (e.code == 'AI_CREDITS_NEEDED' && credits == 0) {
          final price = e.details['credits'] as int? ?? 0;
          final left = e.details['left'] as int? ?? 0;
          _say(intel, null);
          if (!await _spend(spend(price, left), confirm) || !mounted) {
            return null;
          }
          credits = price;
          _say(intel, working, busy: true);
          continue;
        }
        if (e.code != 'ORDER_TEXT_PENDING' || waits++ >= 12) rethrow;
        _say(intel, l.summaryReading, busy: true);
        await Future<void>.delayed(const Duration(seconds: 5));
        if (!mounted) return null;
        continue;
      }
      // Closed meanwhile: nothing to show, and its ref is gone.
      if (!mounted) return null;
      final id = r.jobId;
      if (id == null) return r;
      final job = await _finished(id);
      if (job.status != JobStatus.done) {
        throw ApiException(job.error ?? 'AI_FAILED');
      }
      return AiResult(jobId: id, proposed: job.result?['proposed'] as int?);
    }
  }

  /// [id]'s job once it has finished; the wait ends with the sheet.
  Future<Job> _finished(String id) {
    final done = Completer<Job>();
    _job?.close();
    _job = ref.listenManual(jobProvider(id), (_, next) {
      if (next.value case final job? when job.finished && !done.isCompleted) {
        done.complete(job);
      }
    });
    return done.future;
  }

  /// "Summarising uses 4 credits. 96 left." (spec §12.14): the user agrees before credits are spent.
  Future<bool> _spend(String body, String confirm) async {
    final l = context.l10n;
    return await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: Text(l.summaryCreditsTitle),
            content: Text(body),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: Text(l.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: Text(confirm),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _summarise() async {
    final l = context.l10n;
    final language = _language;
    final (o, d) = (widget.order, widget.document);
    Future<AiResult> call(ApiClient api, String org, String key, int n) =>
        o != null
        ? api.summariseOrder(
            orgId: org,
            orderId: o.id,
            language: language,
            credits: n,
            idempotencyKey: key,
          )
        : api.summariseDocument(
            orgId: org,
            documentId: d!.id,
            language: language,
            credits: n,
            idempotencyKey: key,
          );
    Future<AiResult?> ask() => _request(
      call,
      intel: false,
      working: l.summaryWorking,
      spend: l.summaryCredits,
      confirm: l.summarySummarise,
    );
    String? said;
    try {
      var r = await ask();
      // A finished job's summary is cached: asking again gets it, free (an order's also comes by sync).
      if (r?.jobId != null) r = await ask();
      if (r?.summary case final s?) _fetched[language] = s;
    } on ApiException catch (e) {
      said = errorText(l, e);
    }
    _say(false, said);
  }

  /// Order intelligence (spec F13): its proposals come by sync.
  Future<void> _findActions(CaseOrder o) async {
    final l = context.l10n;
    String? said;
    try {
      final r = await _request(
        (api, org, key, n) => api.orderIntel(
          orgId: org,
          orderId: o.id,
          credits: n,
          idempotencyKey: key,
        ),
        intel: true,
        working: l.summaryFinding,
        spend: l.summaryIntelCredits,
        confirm: l.summaryFindActions,
      );
      if (r != null) said = l.summaryActionsFound(r.proposed ?? 0);
    } on ApiException catch (e) {
      said = errorText(l, e);
    }
    _say(true, said);
  }

  /// The order at [page] (spec §5.1.4: a source opens its page), over the sheet: Back returns here.
  void _open(int page) {
    final o = widget.order;
    unawaited(
      context.push(
        o != null
            ? '/cases/${widget.matterId}/orders/${o.id}?page=$page'
            : '/documents/${widget.document!.id}?page=$page',
      ),
    );
  }

  /// The summary's sections in the spec's order (F07), each point with its pages.
  List<AnswerLine> _lines(AppLocalizations l, OrderSummaryView s) {
    final f = Formats(Localizations.localeOf(context));
    List<SourceChip> pages(List<int> pages) => [
      for (final p in pages)
        SourceChip(l.casePageOrder, page: p, onTap: () => _open(p)),
    ];
    AnswerLine line(SummaryPoint p) {
      final note = [
        if (p.who case final who?) l.summaryWho(who),
        if (p.byWhen case final by?) l.summaryByWhen(by),
      ].join(' · ');
      return AnswerLine(
        p.text,
        sources: pages(p.pages),
        note: note.isEmpty ? null : note,
      );
    }

    List<AnswerLine> section(
      String title,
      List<SummaryPoint> points, {
      String? note,
    }) => [
      if (points.isNotEmpty) AnswerLine.heading(title, note: note),
      for (final p in points) line(p),
    ];
    final header = [
      ?s.court,
      if (s.orderDate case final d?) f.date(d),
      ...s.judges,
    ].join(' · ');
    return [
      if (header.isNotEmpty) AnswerLine(header, sources: pages(s.headerPages)),
      ...section(l.summaryGist, [?s.gist]),
      ...section(l.summaryOutcome, [?s.outcome]),
      ...section(l.summaryDirections, s.directions),
      if (s.nextDate case final d?) ...[
        AnswerLine.heading(l.nextDate),
        AnswerLine(f.date(d), sources: pages(s.nextDatePages)),
      ],
      ...section(l.summaryRelief, [?s.relief]),
      ...section(l.summaryReasons, s.keyReasons),
      ...section(l.summaryAuthorities, s.authorities, note: l.summaryAsCited),
      ...section(l.summaryNextSteps, s.nextSteps),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final o = widget.order;
    final order = o == null
        ? null
        : ref.watch(
                caseOrdersProvider(widget.matterId!).select(
                  (a) => a.value?.where((x) => x.id == o.id).firstOrNull,
                ),
              ) ??
              o;
    final json = order?.summary(_language) ?? _fetched[_language];
    final summary = json == null ? null : OrderSummaryView.fromJson(json);
    final proposals = [
      if (order != null)
        for (final p
            in ref.watch(caseProposalsProvider(widget.matterId!)).value ??
                const <CaseProposal>[])
          if (p.orderId == order.id) p,
    ];
    final summarised =
        order?.summaryEn != null ||
        order?.summaryHi != null ||
        _fetched.isNotEmpty;
    final mayFind = ref.watch(currentOrgProvider)?.role != 'clerk';
    final note = _note;
    final busy = note?.busy ?? false;
    final name = _languages[_language]!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(l.summaryTitle, style: context.text.titleLarge),
        ),
        const SizedBox(height: 16),
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: [
            for (final MapEntry(:key, :value) in _languages.entries)
              ButtonSegment(value: key, label: Text(value)),
          ],
          selected: {_language},
          onSelectionChanged: (v) => setState(() => _language = v.first),
        ),
        const SizedBox(height: 16),
        if (summary != null)
          AIAnswerCard(title: summary.title, lines: _lines(l, summary))
        else ...[
          Text(l.summaryNone(name), style: context.text.bodyLarge),
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.icon(
              onPressed: busy ? null : () => unawaited(_summarise()),
              icon: const Icon(AppIcons.sparkle),
              label: Text(l.summariseIn(name)),
            ),
          ),
        ],
        if (note != null && !note.intel) _Said(note),
        if (order != null && proposals.isNotEmpty) ...[
          SectionHeader(
            l.summaryActions,
            count: proposals.length,
            actionLabel: l.proposalsConfirmAll,
            onAction: () => confirmWithUndo(context, ref, proposals),
          ),
          for (final p in proposals) ProposalRow(p, key: ValueKey(p.id)),
        ] else if (order != null && summarised && mayFind) ...[
          const SizedBox(height: 16),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              onPressed: busy ? null : () => unawaited(_findActions(order)),
              icon: const Icon(AppIcons.checks),
              label: Text(l.summaryFindActions),
            ),
          ),
        ],
        if (note != null && note.intel) _Said(note),
      ],
    );
  }
}

/// A request's progress (with a bar), outcome or error, read out as it changes.
class _Said extends StatelessWidget {
  const _Said(this.note);

  final ({bool intel, bool busy, String text}) note;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AnnouncedText(note.text, style: context.text.bodyMedium),
        if (note.busy) ...[
          const SizedBox(height: 8),
          const LinearProgressIndicator(),
        ],
      ],
    ),
  );
}

/// A task or deadline the AI proposed from an order (spec F13): what it is, its date marked "verify", the order it
/// was read in (a deadline's at its page), and Confirm and Dismiss, each with Undo. In the summary sheet and the Notes
/// tab.
class ProposalRow extends ConsumerWidget {
  const ProposalRow(this.proposal, {super.key});

  final CaseProposal proposal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final f = Formats(Localizations.localeOf(context));
    final p = proposal;
    final meta = [
      if (p.task) l.proposalTask else l.calendarDeadline,
      if (p.due case final due?) l.proposalDue(f.date(due)),
    ].join(' · ');
    final page = p.page;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(p.title, style: context.text.bodyLarge),
          Text(meta, style: context.text.bodySmall),
          const SizedBox(height: 4),
          SourceChip(
            p.orderTitle ??
                switch (p.orderDate) {
                  final d? => l.proposalSource(f.date(d)),
                  null => l.casePageOrder,
                },
            page: page,
            onTap: () => unawaited(
              context.push(
                '/cases/${p.matterId}/orders/${p.orderId}'
                '${page == null ? '' : '?page=$page'}',
              ),
            ),
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: () => confirmWithUndo(context, ref, [p]),
                child: Text(
                  l.proposalConfirm,
                  semanticsLabel: l.proposalConfirmFor(p.title),
                ),
              ),
              TextButton(
                onPressed: () {
                  final writer = ref.read(caseWriterProvider);
                  unawaited(writer.dismissProposal(p));
                  showUndoSnackbar(
                    context,
                    message: l.proposalDismissed,
                    onUndo: () => unawaited(writer.restoreProposals([p])),
                  );
                },
                child: Text(
                  l.proposalDismiss,
                  semanticsLabel: l.proposalDismissFor(p.title),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Confirms [ps] (one, or Confirm all) with Undo, which proposes them again.
void confirmWithUndo(
  BuildContext context,
  WidgetRef ref,
  List<CaseProposal> ps,
) {
  final writer = ref.read(caseWriterProvider);
  unawaited(writer.confirmProposals(ps));
  showUndoSnackbar(
    context,
    message: context.l10n.proposalsConfirmed(ps.length),
    onUndo: () => unawaited(writer.restoreProposals(ps)),
  );
}
