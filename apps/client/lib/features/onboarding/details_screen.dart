import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/courts.dart';
import 'package:advocate_app/data/device.dart';
import 'package:advocate_app/data/jobs.dart';
import 'package:advocate_app/features/onboarding/onboarding_layout.dart';
import 'package:advocate_app/ui/fields.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// /onboarding/details, `?kind=chamber` for a chamber owner (spec §4.1 step 6, §11.4 inputs). "Find my cases"
/// saves the Bar Council details, creates the organisation if there is none (named after the advocate unless a
/// chamber owner types a name) and starts the search; the router then moves on to Finding.
class DetailsScreen extends ConsumerStatefulWidget {
  const DetailsScreen({this.chamber = false, super.key});

  /// Chosen "Chamber owner": the organisation to create is a chamber (else solo).
  final bool chamber;

  @override
  ConsumerState<DetailsScreen> createState() => _DetailsScreenState();
}

class _DetailsScreenState extends ConsumerState<DetailsScreen> {
  late final Account? _account = ref.read(accountProvider).value;
  late final _name = TextEditingController(text: _account?.fullName);
  late final _enrolment = TextEditingController(text: _account?.enrolmentNo);
  final _chamberName = TextEditingController();
  late String _state = _account?.barCouncilState ?? 'MP';
  late final Set<String> _courts = {...?_account?.practiceCourtIds};
  bool _otherCourt = false;
  String? _nameError;
  String? _enrolmentError;
  String? _error;
  bool _busy = false;

  /// One key for this screen's search: a retry replays it instead of starting another paid search.
  final String _key = uuidV4();

  @override
  void dispose() {
    _name.dispose();
    _enrolment.dispose();
    _chamberName.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return; // Enter while busy: one organisation, one search
    final l = context.l10n;
    final name = _name.text.trim();
    final enrolment = _enrolment.text.trim();
    setState(() {
      _nameError = name.isEmpty ? l.onboardingDetailsNameError : null;
      _enrolmentError = enrolment.isEmpty
          ? l.onboardingDetailsEnrolmentError
          : null;
      _error = null;
    });
    final invalid = _nameError ?? _enrolmentError;
    if (invalid != null) return announce(context, invalid);
    setState(() => _busy = true);
    try {
      final api = ref.read(apiClientProvider);
      final me = await api.patchMe({
        'full_name': name,
        'enrolment_no': enrolment,
        'bar_council_state': _state,
        'practice_court_ids': _courts.toList(),
      });
      final chamberName = _chamberName.text.trim();
      // The org from this response, never a snapshot: after a createOrg whose response was lost, or after going
      // back to the role screen, the retry finds the org already made (POST /v1/orgs would make a second).
      final orgId =
          me.org?.orgId ??
          await api.createOrg(
            name: widget.chamber && chamberName.isNotEmpty ? chamberName : name,
            kind: widget.chamber ? 'chamber' : 'solo',
          );
      await ref
          .read(findJobIdProvider.notifier)
          .start(orgId: orgId, idempotencyKey: _key);
      await ref.read(accountProvider.notifier).refresh();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = errorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final locale = Localizations.localeOf(context);
    final courts = ref.watch(courtsProvider).value ?? const <Court>[];
    // ponytail: only states with seeded courts are offered (MP in the beta); add the State Bar Council list and
    // names when P7 seeds other states.
    final states = {...courts.map((c) => c.state).nonNulls, _state}.toList()
      ..sort();
    final stateCourts = courts.where(
      (c) => c.state == null || c.state == _state,
    );
    return OnboardingLayout(
      title: l.detailsTitle,
      subtitle: l.onboardingDetailsSubtitle,
      showBack: context.canPop(),
      notice: _error,
      primary: BusyButton(
        label: l.onboardingDetailsSubmit,
        busy: _busy,
        onPressed: _submit,
      ),
      children: [
        AppTextField(
          controller: _name,
          label: l.onboardingDetailsName,
          error: _nameError,
          autofillHints: const [AutofillHints.name],
          textInputAction: TextInputAction.next,
        ),
        if (widget.chamber && _account?.org == null) ...[
          const SizedBox(height: 16),
          AppTextField(
            controller: _chamberName,
            label: l.onboardingDetailsChamber,
            hint: l.onboardingDetailsChamberHint,
            textInputAction: TextInputAction.next,
          ),
        ],
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: _state,
          isExpanded: true,
          decoration: InputDecoration(labelText: l.onboardingDetailsState),
          style: context.text.bodyLarge,
          items: [
            for (final s in states)
              DropdownMenuItem(
                value: s,
                child: Text(s == 'MP' ? l.onboardingDetailsStateMp : s),
              ),
          ],
          onChanged: (s) => setState(() => _state = s ?? _state),
        ),
        const SizedBox(height: 16),
        AppTextField(
          controller: _enrolment,
          label: l.onboardingDetailsEnrolment,
          hint: l.onboardingDetailsEnrolmentHint,
          error: _enrolmentError,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
        ),
        if (stateCourts.isNotEmpty) ...[
          const SizedBox(height: 24),
          Semantics(
            header: true,
            child: Text(
              l.onboardingDetailsCourts,
              style: context.text.titleSmall,
            ),
          ),
          Text(
            l.onboardingDetailsCourtsHint,
            style: context.text.bodyMedium?.copyWith(
              color: context.colors.ink2,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final c in stateCourts)
                FilterChip(
                  label: Text(c.label(locale)),
                  selected: _courts.contains(c.id),
                  onSelected: (on) => setState(
                    () => on ? _courts.add(c.id) : _courts.remove(c.id),
                  ),
                ),
              // Courts the provider doesn't cover: stores nothing (the state's courts are searched as usual).
              FilterChip(
                label: Text(l.onboardingDetailsCourtOther),
                selected: _otherCourt,
                onSelected: (on) => setState(() => _otherCourt = on),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
