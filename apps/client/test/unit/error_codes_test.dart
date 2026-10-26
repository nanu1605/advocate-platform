import 'dart:io';

import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every error code the server can send (the API, the workers, and the court-data codes both pass on) has its own
/// text (spec §5.4: never a raw code, and never the generic message for a known failure). Codes are read from the
/// source, so a new one fails here until it has text.
void main() {
  /// The codes in `*.py` under [dir] (relative to the repo root) that match [patterns]' first group.
  Set<String> codes(String dir, List<String> patterns) => {
    for (final f in Directory('../../$dir').listSync(recursive: true))
      if (f is File && f.path.endsWith('.py'))
        for (final p in patterns)
          for (final m in RegExp(
            p,
            multiLine: true,
          ).allMatches(f.readAsStringSync()))
            m[1]!,
  };

  final api = codes('services/api/src', [
    r'ApiError\(\s*\d{3},\s*"([A-Z_]+)"', // raise ApiError(409, "CODE", ...)
    r'^\s*"([A-Z_]+)": \(\d{3},', // DB_RULES: SQL business rules
    r'body\(\s*"([A-Z_]+)"', // a response built directly (courts.py's provider errors, errors.py's handlers)
    r'^\s*\d{3}: "([A-Z_]+)",', // HTTP_CODES: Starlette's own errors
    r'HTTP_CODES\.get\([^,]+, "([A-Z_]+)"\)', // and their fallback
  ]);
  final workers = codes('services/workers/src', [
    r'(?:JobFailed|RetryLater)\(\s*"([A-Z_]+)"', // a job body's failure
    r'fail\(\w+, "([A-Z_]+)"\)', // the runner's own
    "error = '([A-Z_]+)'", // SQL that fails jobs
    r'^[A-Z_]+ = "([A-Z]+_[A-Z_]+)"\s*$', // a code kept in a constant (scan's UNAVAILABLE)
  ]);
  // The runner fails a job with a court-data ProviderError's own code (jobs.py), and the API answers with them.
  final providers = {
    for (final dir in ['packages/court_data/src', 'packages/shared/src'])
      ...codes(dir, [
        r'ProviderError\(\s*"([A-Z_]+)"', // raise ProviderError("CODE", ...)
        r'super\(\)\.__init__\(\s*"([A-Z_]+)"', // a subclass's fixed code (CaseNotFound)
      ]),
  };
  // Ours to fix, not the user's: the generic text is right.
  const generic = {
    'INTERNAL',
    'INTERNAL_ERROR',
    'METHOD_NOT_ALLOWED',
    'HTTP_ERROR',
  };
  final all = {...api, ...workers, ...providers};

  test('the source scan finds the codes', () {
    expect(
      api,
      containsAll([
        'TEAM_LIMIT',
        'OWNER_LOCKED',
        'MATTER_NOT_FOUND',
        'CASE_NOT_FOUND',
        'COURT_PROVIDER_ERROR',
        'METHOD_NOT_ALLOWED',
        'HTTP_ERROR',
      ]),
    );
    expect(
      workers,
      containsAll([
        'NO_SEARCHABLE_COURTS',
        'JOB_EXPIRED',
        'SCANNER_UNAVAILABLE',
      ]),
    );
    expect(providers, containsAll(['CASE_NOT_FOUND', 'ORDER_PDF_UNAVAILABLE']));
  });

  for (final locale in ['en', 'hi']) {
    final l = lookupAppLocalizations(Locale(locale));
    test('every API and job error code has its own text ($locale)', () {
      final missing = [
        for (final code in all.difference(generic))
          if (errorText(l, code) == l.errorGeneric) code,
      ];
      expect(missing, isEmpty, reason: 'add these to lib/core/errors.dart');
      for (final code in all) {
        expect(errorText(l, code), isNot(contains(code)), reason: code);
      }
    });
  }
}
