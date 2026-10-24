import 'dart:async';

import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/core/theme/motion.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/courts.dart';
import 'package:advocate_app/data/device.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:advocate_app/features/cases/add_case.dart';
import 'package:advocate_app/features/onboarding/onboarding_layout.dart';
import 'package:advocate_app/ui/court_badge.dart';
import 'package:advocate_app/ui/fields.dart';
import 'package:advocate_app/ui/hearing_chip.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/section_header.dart';
import 'package:advocate_app/ui/skeleton.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:advocate_app/ui/status_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Courts by the search provider's court code (`courts.provider_codes`, the code the API searches with), to name
/// a hit's court. Empty in builds without sync.
final courtsByCodeProvider = StreamProvider<Map<String, Court>>((ref) {
  final db = ref.watch(syncDatabaseProvider);
  if (db == null) return Stream.value(const {});
  const code = r"json_extract(provider_codes, '$.ecourtsindia')";
  return db
      .watch(
        'select id, level, name, name_hi, short_name, short_name_hi, state, district, $code as code '
        'from courts where $code is not null',
      )
      .map((rows) => {for (final r in rows) '${r['code']}': Court.fromRow(r)});
});

/// The search a results list is for; Load more repeats it.
typedef _Query = ({
  String party,
  String advocate,
  String judge,
  String text,
  List<String> courtIds,
  String caseType,
  int? year,
});

/// `/cases/search` (spec §4.1 "By search", §11.7): party, advocate, judge or free text (at least one), courts, case
/// type and year → POST /v1/search/cases, with coverage notes; each hit offers "Track this case" (by-cnr, then the
/// case opens) or, when the org tracks it already, opens it. Needs the network; the form is kept on any error.
class SearchCasesScreen extends ConsumerStatefulWidget {
  const SearchCasesScreen({super.key});

  @override
  ConsumerState<SearchCasesScreen> createState() => _SearchCasesScreenState();
}

class _SearchCasesScreenState extends ConsumerState<SearchCasesScreen> {
  final _party = TextEditingController();
  final _advocate = TextEditingController();
  final _judge = TextEditingController();
  final _text = TextEditingController();
  final _caseType = TextEditingController();
  final _year = TextEditingController();
  final _courts = <String>{};
  final GlobalKey _resultsKey = GlobalKey();

  _Query? _query;
  var _pages = <CaseSearchPage>[];
  String? _error;
  String? _yearError;
  bool _busy = false;
  bool _loadingMore = false;

  /// The CNR "Track this case" is adding.
  String? _tracking;

  /// One idempotency key per CNR the user tracks, reused when they retry the same one.
  ({String cnr, String key})? _attempt;

  @override
  void dispose() {
    for (final c in [_party, _advocate, _judge, _text, _caseType, _year]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _search() async {
    if (_busy) return; // Enter while busy: one search
    final l = context.l10n;
    final terms = [
      _party,
      _advocate,
      _judge,
      _text,
    ].any((c) => c.text.trim().isNotEmpty);
    setState(() {
      _yearError = caseYearError(l, _year.text);
      _error = terms ? null : l.errorSearchTerms;
    });
    final invalid = _error ?? _yearError;
    if (invalid != null) return announce(context, invalid);
    final q = (
      party: _party.text,
      advocate: _advocate.text,
      judge: _judge.text,
      text: _text.text,
      courtIds: _courts.toList(),
      caseType: _caseType.text,
      year: int.tryParse(_year.text.trim()),
    );
    setState(() => _busy = true);
    final page = await _fetch(q, 1);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (page != null) {
        _query = q;
        _pages = [page];
      }
    });
    if (page == null) return;
    announce(context, _heading(l) ?? l.addCaseNoResults);
    // The form fills a phone screen: bring the results into view.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final results = _resultsKey.currentContext;
      if (results == null || !results.mounted) return;
      final motion = Motion.of(results);
      Scrollable.ensureVisible(
        results,
        duration: motion.base,
        curve: motion.standard,
      );
    });
  }

  Future<void> _loadMore() async {
    final q = _query;
    if (q == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    final page = await _fetch(q, _pages.length + 1);
    if (!mounted) return;
    setState(() {
      _loadingMore = false;
      // A new search while this page loaded replaced the results: the page belongs to the old one.
      if (page != null && identical(q, _query)) _pages = [..._pages, page];
    });
  }

  /// Page [page] of [q], or null after saying what went wrong: under the Search button for a new search, in a
  /// snackbar for Load more.
  Future<CaseSearchPage?> _fetch(_Query q, int page) async {
    final l = context.l10n;
    final org = ref.read(currentOrgIdProvider);
    final String message;
    if (org == null) {
      message = errorText(l, ref.read(accountProvider).error ?? 'NOT_A_MEMBER');
    } else {
      try {
        return await ref
            .read(apiClientProvider)
            .searchCases(
              orgId: org,
              party: q.party,
              advocate: q.advocate,
              judge: q.judge,
              text: q.text,
              courtIds: q.courtIds,
              caseType: q.caseType,
              year: q.year,
              page: page,
            );
      } on ApiException catch (e) {
        // errorText's provider-down text promises a notification, which a search never sends.
        message = e.code == 'COURT_PROVIDER_UNAVAILABLE'
            ? l.addCaseProviderDown
            : errorText(l, e);
      }
    }
    if (!mounted) return null;
    if (page == 1) {
      setState(() => _error = message);
      announce(context, message);
    } else {
      _say(message);
    }
    return null;
  }

  /// "Track this case", or open it: the org's case with this CNR if the device has it, else by-cnr (which answers
  /// with the existing case when the org tracks it already).
  Future<void> _open(CaseHit hit, List<CaseInfo> cases) async {
    if (_tracking != null) return;
    final local = cases.where((c) => c.cnr == hit.cnr).firstOrNull;
    if (local != null) return context.go('/cases/${local.id}');
    final l = context.l10n;
    final org = ref.read(currentOrgIdProvider);
    if (org == null) {
      return _say(
        errorText(l, ref.read(accountProvider).error ?? 'NOT_A_MEMBER'),
      );
    }
    final key = _attempt?.cnr == hit.cnr ? _attempt!.key : uuidV4();
    _attempt = (cnr: hit.cnr, key: key);
    setState(() => _tracking = hit.cnr);
    try {
      final added = await ref
          .read(apiClientProvider)
          .addByCnr(orgId: org, idempotencyKey: key, cnr: hit.cnr);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            added.created ? l.foundCnrAdded : l.errorFoundCaseAdded,
          ),
        ),
      );
      openAddedCase(context, added.matterId);
    } on ApiException catch (e) {
      if (mounted) _say(trackErrorText(l, e));
    } finally {
      if (mounted) setState(() => _tracking = null);
    }
  }

  void _say(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
    announce(context, message);
  }

  /// "12 cases found" (the hits loaded so far when case type or year narrowed the pages), or null for none.
  String? _heading(AppLocalizations l) {
    final hits = _pages.fold(0, (n, p) => n + p.items.length);
    if (hits == 0) return null;
    return l.addCaseFound(
      _pages.any((p) => p.postFiltered) ? hits : _pages.first.total,
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    String? hint,
    bool autofocus = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: AppTextField(
      controller: controller,
      label: label,
      hint: hint,
      autofocus: autofocus,
      textInputAction: TextInputAction.search,
      onSubmitted: (_) => _search(),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final locale = Localizations.localeOf(context);
    final courts = ref.watch(courtsProvider).value ?? const <Court>[];
    final byCode = ref.watch(courtsByCodeProvider).value ?? const {};
    final cases = ref.watch(casesProvider).value ?? const <CaseInfo>[];
    final today = ref.watch(istTodayProvider);
    final muted = context.text.bodyMedium?.copyWith(color: context.colors.ink2);
    String courtNames(List<String> ids) => [
      for (final c in courts)
        if (ids.contains(c.id)) c.spokenLabel(locale, l.highCourt),
    ].join(' + ');

    final q = _query;
    final hits = [for (final p in _pages) ...p.items];
    final heading = _heading(l);
    final ignored = _pages.firstOrNull?.ignoredCourtIds ?? const [];
    // The chosen courts the provider can search; with none of them left the API searched every court.
    final searched = [
      for (final id in q?.courtIds ?? const <String>[])
        if (!ignored.contains(id)) id,
    ];
    final results = <Widget>[
      if (_busy && q == null) ...[
        const SizedBox(height: 24),
        const SkeletonCaseList(),
      ],
      if (q != null) ...[
        SizedBox(key: _resultsKey, height: 16),
        if (heading != null) SectionHeader(heading),
        Text(
          searched.isEmpty
              ? l.addCaseCoverageAll
              : l.addCaseCoverage(courtNames(searched)),
          style: muted,
        ),
        if (ignored.isNotEmpty)
          Text(l.addCaseIgnored(courtNames(ignored)), style: muted),
        if (_pages.any((p) => p.postFiltered))
          Text(l.addCaseNarrowed, style: muted),
        const SizedBox(height: 8),
        if (hits.isEmpty)
          EmptyState(
            icon: AppIcons.magnifyingGlass,
            message: l.addCaseNoResults,
          ),
        for (final h in hits)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _HitCard(
              hit: h,
              court: byCode[h.courtCode],
              today: today,
              busy: _tracking == h.cnr,
              onOpen: _tracking == null && !_busy
                  ? () => unawaited(_open(h, cases))
                  : null,
            ),
          ),
        if (_pages.last.hasNext)
          Center(
            child: _loadingMore
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: CircularProgressIndicator(),
                  )
                : OutlinedButton(
                    onPressed: _busy ? null : () => unawaited(_loadMore()),
                    child: Text(l.addCaseLoadMore),
                  ),
          ),
      ],
    ];

    return Scaffold(
      appBar: AppBar(title: Text(l.casesAddSearch)),
      body: SingleChildScrollView(
        // A Column, not a lazy list, so Tab reaches every field and hit (a few pages of 20 at most).
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l.addCaseSearchIntro,
                  style: context.text.bodyLarge?.copyWith(
                    color: context.colors.ink2,
                  ),
                ),
                const SizedBox(height: 16),
                _field(_party, l.addCaseParty, autofocus: true),
                _field(_advocate, l.addCaseAdvocate),
                _field(_judge, l.addCaseJudge),
                _field(_text, l.addCaseWords),
                // ponytail: every synced court as a chip (five in the MP beta); a searchable picker when P7
                // seeds other states.
                if (courts.isNotEmpty) ...[
                  Semantics(
                    header: true,
                    child: Text(
                      l.addCaseCourts,
                      style: context.text.titleSmall,
                    ),
                  ),
                  Text(l.addCaseCourtsHint, style: muted),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final c in courts)
                        FilterChip(
                          label: Text(c.label(locale)),
                          selected: _courts.contains(c.id),
                          onSelected: (on) => setState(
                            () => on ? _courts.add(c.id) : _courts.remove(c.id),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
                _field(
                  _caseType,
                  l.addCaseCaseType,
                  hint: l.addCaseCaseTypeHint,
                ),
                AppTextField(
                  controller: _year,
                  label: l.addCaseYear,
                  error: _yearError,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(4),
                  ],
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                ),
                const SizedBox(height: 16),
                if (_error != null) StepNotice(_error!),
                BusyButton(
                  label: l.addCaseSearchAction,
                  busy: _busy,
                  onPressed: _search,
                ),
                ...results,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One search hit (spec §11.7): case number, title, court, next date, status and advocates, with "Track this
/// case", or "Tracking · Open" when the org tracks it already. The screen reader reads it as one row.
class _HitCard extends StatelessWidget {
  const _HitCard({
    required this.hit,
    required this.court,
    required this.today,
    required this.busy,
    required this.onOpen,
  });

  final CaseHit hit;
  final Court? court;
  final DateTime today;
  final bool busy;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final locale = Localizations.localeOf(context);
    final t = context.text;
    final status = hit.status.toLowerCase();
    final statusText = switch (status) {
      'pending' => l.foundPending,
      'disposed' => l.statusDisposed,
      'transferred' => l.foundTransferred,
      _ => l.foundStatusUnknown,
    };
    final advocates = hit.advocates.map((a) => a.name).join(', ');
    final next = hit.nextHearingDate;
    final spoken = [
      if (hit case CaseHit(
        :final caseType?,
        :final caseNumber?,
        :final caseYear?,
      ))
        l.foundCaseSpoken(caseType, caseNumber, '$caseYear')
      else
        hit.caseLabel,
      ?court?.spokenLabel(locale, l.highCourt),
      if (next == null)
        l.noDate
      else
        '${l.nextDate} ${Formats(locale).date(next)}',
      statusText,
      hit.title,
      if (advocates.isNotEmpty) l.addCaseAdvocates(advocates),
    ].join('. ');

    final Widget action;
    if (busy) {
      action = const OutlinedButton(
        onPressed: null,
        child: SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    } else if (hit.tracked) {
      action = TextButton.icon(
        onPressed: onOpen,
        icon: const Icon(AppIcons.checkCircleFill),
        label: Text(l.addCaseTracking),
      );
    } else {
      action = OutlinedButton.icon(
        onPressed: onOpen,
        icon: const Icon(AppIcons.plus),
        label: Text(l.addCaseTrack),
      );
    }

    return Card(
      child: MergeSemantics(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                label: spoken,
                excludeSemantics: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(hit.caseLabel, style: t.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      hit.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodyLarge?.copyWith(color: context.colors.ink2),
                    ),
                    if (court case final c?) ...[
                      const SizedBox(height: 8),
                      CourtBadge(court: c.label(locale)),
                    ],
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        HearingChip(date: next, today: today),
                        if (status == 'disposed')
                          const StatusPill(PillKind.disposed)
                        else
                          Text(statusText, style: t.bodySmall),
                      ],
                    ),
                    if (advocates.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        l.addCaseAdvocates(advocates),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: t.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
              action,
            ],
          ),
        ),
      ),
    );
  }
}
