import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/courts.dart';
import 'package:advocate_app/features/cases/add_case.dart';
import 'package:advocate_app/features/onboarding/onboarding_layout.dart';
import 'package:advocate_app/ui/fields.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The court picker's "Other court" choice: the court is typed instead.
const _otherCourt = '';

/// `/cases/manual` (spec §4.1 "Manual case"): a case in a court the provider doesn't cover, kept up to date by hand.
/// Parties, court (a synced court or "Other court" typed), case type, number and year, our side, file no. and next
/// date → POST /v1/matters/manual, then the case opens. Errors are inline and read out (spec §5.9); needs the
/// network, and the form is kept on any error.
class ManualCaseScreen extends ConsumerStatefulWidget {
  const ManualCaseScreen({super.key});

  @override
  ConsumerState<ManualCaseScreen> createState() => _ManualCaseScreenState();
}

class _ManualCaseScreenState extends ConsumerState<ManualCaseScreen> {
  final _title = TextEditingController();
  final _courtName = TextEditingController();
  final _caseType = TextEditingController();
  final _number = TextEditingController();
  final _year = TextEditingController();
  final _ourSide = TextEditingController();
  final _fileNo = TextEditingController();
  final _next = TextEditingController();

  /// A court id, or [_otherCourt].
  String? _court;
  String? _titleError;
  String? _courtError;
  String? _yearError;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [
      _title,
      _courtName,
      _caseType,
      _number,
      _year,
      _ourSide,
      _fileNo,
      _next,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return; // a second tap while busy: one case
    final l = context.l10n;
    final title = _title.text.trim();
    final courtName = _courtName.text.trim();
    final nextText = _next.text.trim();
    final next = Formats.parseEntry(nextText);
    setState(() {
      _titleError = title.isEmpty ? l.addCasePartiesRequired : null;
      _courtError = switch (_court) {
        null => l.errorCourtRequired,
        _otherCourt when courtName.isEmpty => l.addCaseCourtNameRequired,
        _ => null,
      };
      _yearError = caseYearError(l, _year.text);
      _error = null;
    });
    // The date field shows its own error; it's read out here with the others.
    final invalid =
        _titleError ??
        _courtError ??
        _yearError ??
        (nextText.isNotEmpty && next == null ? l.dateInvalid : null);
    if (invalid != null) return announce(context, invalid);
    final org = ref.read(currentOrgIdProvider);
    if (org == null) {
      return _fail(
        errorText(l, ref.read(accountProvider).error ?? 'NOT_A_MEMBER'),
      );
    }
    setState(() => _busy = true);
    try {
      final other = _court == _otherCourt;
      final id = await ref
          .read(apiClientProvider)
          .addManual(
            orgId: org,
            title: title,
            courtId: other ? null : _court,
            courtName: other ? courtName : null,
            caseType: _caseType.text,
            caseNumber: _number.text,
            caseYear: int.tryParse(_year.text.trim()),
            ourSide: _ourSide.text,
            fileNo: _fileNo.text,
            nextDate: next == null
                ? null
                : DateTime.utc(next.year, next.month, next.day),
          );
      if (!mounted) return;
      showSnack(ScaffoldMessenger.of(context), l.addCaseAdded);
      openAddedCase(context, id);
    } on ApiException catch (e) {
      if (!mounted) return;
      final message = errorText(l, e);
      if (e.code == 'COURT_REQUIRED' || e.code == 'UNKNOWN_COURT') {
        setState(() => _courtError = message);
        announce(context, message);
      } else {
        _fail(message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _fail(String message) => setState(() => _error = message);

  /// A field; [max] is the API's length limit (`ManualIn`), so a long entry can't fail the request.
  Widget _field(
    TextEditingController controller,
    String label, {
    int? max,
    String? hint,
    String? error,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: AppTextField(
      controller: controller,
      label: label,
      hint: hint,
      error: error,
      keyboardType: keyboardType,
      inputFormatters: [
        ...?inputFormatters,
        if (max != null) CodePointLimit(max),
      ],
      textInputAction: TextInputAction.next,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final locale = Localizations.localeOf(context);
    final courts = ref.watch(courtsProvider).value ?? const <Court>[];
    final other = _court == _otherCourt;
    return Scaffold(
      appBar: AppBar(title: Text(l.casesAddManual)),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          l.addCaseManualIntro,
                          style: context.text.bodyLarge?.copyWith(
                            color: context.colors.ink2,
                          ),
                        ),
                        const SizedBox(height: 16),
                        _field(
                          _title,
                          l.addCaseParties,
                          max: 300,
                          hint: l.addCasePartiesHint,
                          error: _titleError,
                        ),
                        DropdownButtonFormField<String>(
                          initialValue: _court,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: l.addCaseCourt,
                            errorText: other ? null : _courtError,
                            errorMaxLines: 3,
                          ),
                          style: context.text.bodyLarge,
                          items: [
                            for (final c in courts)
                              DropdownMenuItem(
                                value: c.id,
                                child: Text(c.label(locale)),
                              ),
                            DropdownMenuItem(
                              value: _otherCourt,
                              child: Text(l.foundOtherCourt),
                            ),
                          ],
                          onChanged: (v) => setState(() {
                            _court = v;
                            _courtError = null;
                          }),
                        ),
                        const SizedBox(height: 16),
                        if (other)
                          _field(
                            _courtName,
                            l.addCaseCourtName,
                            max: 200,
                            error: _courtError,
                          ),
                        _field(
                          _caseType,
                          l.addCaseCaseType,
                          max: 50,
                          hint: l.addCaseCaseTypeHint,
                        ),
                        _field(_number, l.addCaseNumber, max: 50),
                        _field(
                          _year,
                          l.addCaseYear,
                          error: _yearError,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(4),
                          ],
                        ),
                        _field(
                          _ourSide,
                          l.addCaseOurSide,
                          max: 100,
                          hint: l.addCaseOurSideHint,
                        ),
                        _field(_fileNo, l.addCaseFileNo, max: 100),
                        DateField(
                          label: l.nextDate,
                          controller: _next,
                          onChanged: (_) {},
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // Pinned, so the error is on screen (and read out) even when 200% text pushes the form off it.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_error != null) StepNotice(_error!),
                    BusyButton(
                      label: l.addCase,
                      busy: _busy,
                      onPressed: _submit,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
