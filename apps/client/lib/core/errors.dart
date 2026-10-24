import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/data/api_client.dart';

/// API and job error codes as "What happened. What we're doing. What you can do." (spec §5.4, §5.10): the one
/// place codes become text, so a raw code never reaches the screen. [error] is an [ApiException], a code string
/// (a job's `error`), or anything else, which gets the generic message.
String errorText(AppLocalizations l, Object? error) {
  final (code, details) = switch (error) {
    ApiException(:final code, :final details) => (code, details),
    final String code => (code, const <String, dynamic>{}),
    _ => ('', const <String, dynamic>{}),
  };
  return switch (code) {
    'NETWORK' => l.errorNeedsNetwork,
    'UNAUTHENTICATED' => l.errorSignInAgain,
    'RATE_LIMITED' => l.errorTooMany,
    'IDEMPOTENCY_IN_PROGRESS' => l.errorInProgress,
    'VALIDATION_ERROR' => l.errorInvalidInput,
    'NOT_FOUND' => l.errorNotFound,
    'FORBIDDEN' || 'ROLE_NOT_ALLOWED' => l.errorForbidden,
    'PROFILE_INCOMPLETE' => l.errorProfileIncomplete,
    'INVITE_INVALID' => l.errorInviteInvalid,
    'ALREADY_MEMBER' => l.errorAlreadyMember,
    'TEAM_LIMIT' => l.errorTeamLimit(details['limit'] as int? ?? 10),
    'NOT_A_MEMBER' => l.errorNotAMember,
    'TRACKED_CASE_LIMIT' => l.errorTrackedCaseLimit(
      details['remaining'] as int? ?? 0,
    ),
    'FOUND_CASE_ADDED' => l.errorFoundCaseAdded,
    'JOB_FINISHED' => l.errorJobFinished,
    'INVALID_CNR' => l.errorInvalidCnr,
    'COURT_PROVIDER_UNAVAILABLE' => l.errorProviderDown,
    'NO_SEARCHABLE_COURTS' => l.errorNoSearchableCourts,
    'COURT_DATA_PAUSED' => l.errorCourtDataPaused,
    'COURT_DATA_BUDGET_REACHED' => l.errorCourtDataBudget,
    'SEARCH_TERMS_REQUIRED' => l.errorSearchTerms,
    'SEARCH_DAILY_CAP' => l.errorSearchDailyCap,
    'COURT_REQUIRED' => l.errorCourtRequired,
    'UNKNOWN_COURT' => l.errorUnknownCourt,
    'MANUAL_CASE' => l.errorManualCase,
    'TRACKING_OFF' => l.errorTrackingOff,
    'NO_CNR' => l.errorNoCnr,
    'DOCUMENT_NOT_READY' => l.errorDocumentNotReady,
    'DOCUMENT_QUARANTINED' => l.errorDocumentQuarantined,
    'ORDER_PDF_UNAVAILABLE' => l.errorOrderPdfUnavailable,
    'ORDER_PDF_FETCHING' => l.errorOrderPdfFetching,
    _ => l.errorGeneric,
  };
}

/// [errorText] for tracking one case (Add by CNR, search's "Track this case", the case page's tracking on):
/// TRACKED_CASE_LIMIT names the allowance (these endpoints send `{limit}` only) instead of the wording about a
/// selection.
String trackErrorText(AppLocalizations l, ApiException e) =>
    e.code == 'TRACKED_CASE_LIMIT'
    ? l.casesTrackingLimit(e.details['limit'] as int? ?? 0)
    : errorText(l, e);
