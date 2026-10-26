import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/device.dart';
import 'package:advocate_app/features/onboarding/onboarding_layout.dart';
import 'package:advocate_app/ui/fields.dart';
import 'package:advocate_app/ui/sheets.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A CNR as typed or pasted, without spaces or hyphens and uppercased; null unless it is 4 letters + 12 digits
/// (spec §4.1 "By CNR").
String? normalizeCnr(String input) {
  final s = input.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();
  return RegExp(r'^[A-Z]{4}\d{12}$').hasMatch(s) ? s : null;
}

/// "Add by CNR" sheet (spec §4.1): tracks the case and returns its matter id, or null if dismissed. Used by the
/// Found cases empty and error states, and later by Cases.
Future<String?> showAddByCnrSheet(BuildContext context) =>
    showAppBottomSheet<String>(context, builder: (_) => const _AddByCnr());

class _AddByCnr extends ConsumerStatefulWidget {
  const _AddByCnr();

  @override
  ConsumerState<_AddByCnr> createState() => _AddByCnrState();
}

class _AddByCnrState extends ConsumerState<_AddByCnr> {
  final _cnr = TextEditingController();
  String? _error;
  bool _busy = false;

  /// One idempotency key per CNR the user tries, reused when they retry the same one.
  ({String cnr, String key})? _attempt;

  @override
  void dispose() {
    _cnr.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return; // Enter while busy: one request, one pop
    final l = context.l10n;
    final cnr = normalizeCnr(_cnr.text);
    if (cnr == null) return _fail(l.errorInvalidCnr);
    final org = ref.read(currentOrgIdProvider);
    if (org == null) {
      return _fail(
        errorText(l, ref.read(accountProvider).error ?? 'NOT_A_MEMBER'),
      );
    }
    final key = _attempt?.cnr == cnr ? _attempt!.key : uuidV4();
    _attempt = (cnr: cnr, key: key);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final added = await ref
          .read(apiClientProvider)
          .addByCnr(orgId: org, idempotencyKey: key, cnr: cnr);
      if (!mounted) return;
      // Not created: the CNR was already a live matter, so nothing was added or fetched.
      showSnack(
        ScaffoldMessenger.of(context),
        added.created ? l.foundCnrAdded : l.errorFoundCaseAdded,
      );
      Navigator.pop(context, added.matterId);
    } on ApiException catch (e) {
      if (mounted) _fail(trackErrorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Shows [message] on the field and reads it out where the platform doesn't on its own (Windows, §5.9).
  void _fail(String message) {
    setState(() => _error = message);
    announce(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(l.foundCnrTitle, style: context.text.titleLarge),
          ),
          const SizedBox(height: 16),
          AppTextField(
            controller: _cnr,
            label: l.foundCnrLabel,
            hint: l.foundCnrHint,
            error: _error,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 16),
          BusyButton(label: l.addCase, busy: _busy, onPressed: _submit),
        ],
      ),
    );
  }
}
