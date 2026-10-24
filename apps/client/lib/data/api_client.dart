import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/config.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/auth.dart';
import 'package:advocate_app/data/case_label.dart';
import 'package:advocate_app/data/jobs.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Error from the API's `{"error": {...}}` shape (spec §10.1), or a network failure (`NETWORK`).
/// `lib/core/errors.dart` turns it into text; never show [code] itself.
class ApiException implements Exception {
  const ApiException(
    this.code, {
    this.retryable = false,
    this.status,
    this.details = const {},
  });

  final String code;
  final bool retryable;
  final int? status;

  /// e.g. `{limit, remaining}` for TRACKED_CASE_LIMIT, `{missing}` for PROFILE_INCOMPLETE.
  final Map<String, dynamic> details;

  @override
  String toString() => 'ApiException($code, status: $status)';
}

/// Result of POST /v1/found-cases/add, summed over chunks.
typedef AddResult = ({int added, int alreadyTracked, List<String> matterIds});

/// One hit of POST /v1/search/cases (spec §11.7). Party and advocate names: never log them.
@immutable
class CaseHit {
  const CaseHit({
    required this.cnr,
    required this.title,
    required this.status,
    this.courtCode,
    this.caseType,
    this.caseNumber,
    this.caseYear,
    this.nextHearingDate,
    this.petitioners = const [],
    this.respondents = const [],
    this.advocates = const [],
    this.tracked = false,
  });

  factory CaseHit.fromJson(Map<String, dynamic> j) => CaseHit(
    cnr: j['cnr'] as String,
    title: j['title'] as String,
    status: j['status'] as String,
    courtCode: j['court_code'] as String?,
    caseType: j['case_type'] as String?,
    caseNumber: j['case_number'] as String?,
    caseYear: j['case_year'] as int?,
    nextHearingDate: parseDay(j['next_hearing_date']),
    petitioners: (j['petitioners'] as List? ?? const []).cast(),
    respondents: (j['respondents'] as List? ?? const []).cast(),
    advocates: [
      for (final a in j['advocates'] as List? ?? const [])
        (name: (a as Map)['name'] as String, side: a['side'] as String),
    ],
    tracked: j['tracked'] as bool? ?? false,
  );

  final String cnr;

  /// The provider's court code (not a courts row id).
  final String? courtCode;
  final String? caseType;
  final String? caseNumber;
  final int? caseYear;
  final String title;

  /// The provider's status text, e.g. `pending` or `disposed`.
  final String status;

  /// IST day.
  final DateTime? nextHearingDate;
  final List<String> petitioners;
  final List<String> respondents;

  /// `side` is `petitioner` or `respondent`.
  final List<({String name, String side})> advocates;

  /// The org already tracks this CNR (a live matter): "Tracking", opens that case.
  final bool tracked;

  String get caseLabel => caseLabelOf(
    caseType: caseType,
    caseNumber: caseNumber,
    caseYear: caseYear,
    cnr: cnr,
  );
}

/// One page of POST /v1/search/cases.
@immutable
class CaseSearchPage {
  const CaseSearchPage({
    required this.items,
    required this.total,
    required this.page,
    required this.hasNext,
    this.cached = false,
    this.postFiltered = false,
    this.ignoredCourtIds = const [],
  });

  factory CaseSearchPage.fromJson(Map<String, dynamic> j) => CaseSearchPage(
    items: [
      for (final h in j['items'] as List) CaseHit.fromJson((h as Map).cast()),
    ],
    total: j['total'] as int,
    page: j['page'] as int,
    hasNext: j['has_next'] as bool,
    cached: j['cached'] as bool? ?? false,
    postFiltered: j['post_filtered'] as bool? ?? false,
    ignoredCourtIds: (j['ignored_court_ids'] as List? ?? const []).cast(),
  );

  final List<CaseHit> items;

  /// The provider's count; overstates when [postFiltered].
  final int total;
  final int page;
  final bool hasNext;
  final bool cached;

  /// Case type or year removed hits from this page (say the results are narrowed).
  final bool postFiltered;

  /// Chosen courts the provider can't search yet (say they were left out).
  final List<String> ignoredCourtIds;
}

/// Typed client for the FastAPI endpoints (spec §7.1 allows "generated or typed").
///
/// Org-scoped calls take the organisation as `orgId` (sent as `X-Org-Id`). Calls that start a job or spend
/// money take an `idempotencyKey` (spec §10.1): make one UUID per user action (`uuidV4()`) and pass the same
/// one when that action is retried, so a retry never runs twice.
class ApiClient {
  ApiClient(this._dio);

  final Dio _dio;

  /// The API's limit on ids per add request.
  static const addChunk = 500;

  Future<Account> me() async =>
      Account.fromJson(await _send(() => _dio.get('/v1/me')));

  Future<Account> patchMe(Map<String, Object?> fields) async =>
      Account.fromJson(await _send(() => _dio.patch('/v1/me', data: fields)));

  Future<void> postConsents({
    required String version,
    required Map<String, bool> decisions,
  }) => _send(
    () => _dio.post(
      '/v1/consents',
      data: {
        'version': version,
        'items': [
          for (final e in decisions.entries)
            {'purpose': e.key, 'granted': e.value},
        ],
      },
    ),
  );

  Future<void> registerDevice({
    required String id,
    required String platform,
    String? appVersion,
    String? pushToken,
  }) => _send(
    () => _dio.post(
      '/v1/devices',
      data: {
        'id': id,
        'platform': platform,
        'app_version': appVersion,
        'push_token': pushToken,
      },
    ),
  );

  /// Creates the caller's organisation; the caller becomes its owner (spec §9.2). Returns its id.
  Future<String> createOrg({required String name, required String kind}) async {
    final org = await _send<Map<String, dynamic>>(
      () => _dio.post('/v1/orgs', data: {'name': name, 'kind': kind}),
    );
    return org['id'] as String;
  }

  /// Joins a team with an invite or join code. INVITE_INVALID, ALREADY_MEMBER, TEAM_LIMIT, RATE_LIMITED.
  Future<({String orgId, String role})> acceptInvite(String code) async {
    final r = await _send<Map<String, dynamic>>(
      () => _dio.post('/v1/invites/${Uri.encodeComponent(code)}/accept'),
    );
    return (orgId: r['org_id'] as String, role: r['role'] as String);
  }

  /// Starts the "find my cases" search (spec §11.4), or returns the one already running. Returns the job id.
  /// PROFILE_INCOMPLETE, RATE_LIMITED.
  Future<String> findCases({
    required String orgId,
    required String idempotencyKey,
  }) async {
    final r = await _send<Map<String, dynamic>>(
      () => _dio.post(
        '/v1/onboarding/find-cases',
        options: _org(orgId, idempotencyKey),
      ),
    );
    return r['job_id'] as String;
  }

  Future<Job> job(String id) async =>
      Job.fromJson(await _send(() => _dio.get('/v1/jobs/$id')));

  /// Stops a job; what it found so far is kept. JOB_FINISHED if it already ended.
  Future<Job> cancelJob(String id) async =>
      Job.fromJson(await _send(() => _dio.post('/v1/jobs/$id/cancel')));

  /// "Add all" (spec §4.1): every pending found case the server holds. Disposed ones are never included.
  /// TRACKED_CASE_LIMIT with details `{limit, remaining}`.
  Future<AddResult> addAllFoundCases({
    required String orgId,
    required String idempotencyKey,
  }) => _add(orgId, idempotencyKey, {'all': true});

  /// "Add selected": [ids] in chunks of [addChunk]. Chunk i uses `'$idempotencyKey.$i'`, so retrying the
  /// action with the same key replays the chunks that already went through.
  Future<AddResult> addFoundCases({
    required String orgId,
    required String idempotencyKey,
    required List<String> ids,
  }) async {
    var total = (added: 0, alreadyTracked: 0, matterIds: <String>[]);
    for (var i = 0; i * addChunk < ids.length; i++) {
      final chunk = ids.skip(i * addChunk).take(addChunk).toList();
      final r = await _add(orgId, '$idempotencyKey.$i', {'ids': chunk});
      total = (
        added: total.added + r.added,
        alreadyTracked: total.alreadyTracked + r.alreadyTracked,
        matterIds: [...total.matterIds, ...r.matterIds],
      );
    }
    return total;
  }

  Future<AddResult> _add(
    String orgId,
    String key,
    Map<String, Object> body,
  ) async {
    final r = await _send<Map<String, dynamic>>(
      () => _dio.post(
        '/v1/found-cases/add',
        data: body,
        options: _org(orgId, key),
      ),
    );
    return (
      added: r['added'] as int,
      alreadyTracked: r['already_tracked'] as int,
      matterIds: (r['matter_ids'] as List).cast<String>(),
    );
  }

  /// [decision] is `skipped`, `not_mine` or `pending`. FOUND_CASE_ADDED if the case is already tracked.
  Future<void> decideFoundCase({
    required String orgId,
    required String id,
    required String decision,
  }) => _send(
    () => _dio.post(
      '/v1/found-cases/$id/decision',
      data: {'decision': decision},
      options: _org(orgId),
    ),
  );

  /// Tracks a case by CNR (spec §4.1); the server normalises it too. INVALID_CNR, TRACKED_CASE_LIMIT.
  Future<({String matterId, bool created})> addByCnr({
    required String orgId,
    required String idempotencyKey,
    required String cnr,
  }) async {
    final r = await _send<Map<String, dynamic>>(
      () => _dio.post(
        '/v1/matters/by-cnr',
        data: {'cnr': cnr},
        options: _org(orgId, idempotencyKey),
      ),
    );
    return (matterId: r['matter_id'] as String, created: r['created'] as bool);
  }

  /// On-demand refresh of an auto-tracked case (spec §11.5 pull-to-refresh / F5); returns the job id. At most one
  /// per case per 6 h per org: a case refreshed recently throws RATE_LIMITED (429, details `{retry_after_s}`),
  /// which means "already up to date", not a failure. MANUAL_CASE, TRACKING_OFF (409), NOT_FOUND.
  Future<String> refreshMatter({
    required String orgId,
    required String matterId,
    required String idempotencyKey,
  }) async {
    final r = await _send<Map<String, dynamic>>(
      () => _dio.post(
        '/v1/matters/$matterId/refresh',
        options: _org(orgId, idempotencyKey),
      ),
    );
    return r['job_id'] as String;
  }

  /// Court case search (spec §11.7): at least one of [party], [advocate], [judge], [text] (else
  /// SEARCH_TERMS_REQUIRED). Names go in the JSON body, never the URL. RATE_LIMITED, SEARCH_DAILY_CAP (details
  /// `{limit}`), COURT_PROVIDER_UNAVAILABLE.
  Future<CaseSearchPage> searchCases({
    required String orgId,
    String? party,
    String? advocate,
    String? judge,
    String? text,
    List<String> courtIds = const [],
    String? caseType,
    int? year,
    int page = 1,
    int pageSize = 20,
  }) async {
    String? term(String? v) => (v ?? '').trim().isEmpty ? null : v!.trim();
    final r = await _send<Map<String, dynamic>>(
      () => _dio.post(
        '/v1/search/cases',
        data: {
          'party': ?term(party),
          'advocate': ?term(advocate),
          'judge': ?term(judge),
          'text': ?term(text),
          if (courtIds.isNotEmpty) 'court_ids': courtIds,
          'case_type': ?term(caseType),
          'year': ?year,
          'page': page,
          'page_size': pageSize,
        },
        options: _org(orgId),
      ),
    );
    return CaseSearchPage.fromJson(r);
  }

  /// A case the provider doesn't cover (spec §4.1 "Manual case"); returns its matter id. [nextDate] is an IST day.
  /// COURT_REQUIRED (neither [courtId] nor [courtName]), UNKNOWN_COURT, VALIDATION_ERROR.
  Future<String> addManual({
    required String orgId,
    required String title,
    String? courtId,
    String? courtName,
    String? caseType,
    String? caseNumber,
    int? caseYear,
    String? ourSide,
    String? fileNo,
    DateTime? nextDate,
  }) async {
    String? field(String? v) => (v ?? '').trim().isEmpty ? null : v!.trim();
    final r = await _send<Map<String, dynamic>>(
      () => _dio.post(
        '/v1/matters/manual',
        data: {
          'title': title.trim(),
          'court_id': ?courtId,
          'court_name': ?field(courtName),
          'case_type': ?field(caseType),
          'case_number': ?field(caseNumber),
          'case_year': ?caseYear,
          'our_side': ?field(ourSide),
          'file_no': ?field(fileNo),
          if (nextDate != null) 'next_date': isoDate(nextDate),
        },
        options: _org(orgId),
      ),
    );
    return r['id'] as String;
  }

  /// The official portal for the case (spec §4.3), for the user to open; it may ask for a CAPTCHA. NO_CNR.
  Future<({String url, String cnr, bool verified})> officialLink({
    required String orgId,
    required String matterId,
  }) async {
    final r = await _send<Map<String, dynamic>>(
      () =>
          _dio.get('/v1/matters/$matterId/official-link', options: _org(orgId)),
    );
    return (
      url: r['url'] as String,
      cnr: r['cnr'] as String,
      verified: r['verified'] as bool,
    );
  }

  /// Soft-deletes the case and everything under it (owners and advocates; ROLE_NOT_ALLOWED otherwise).
  Future<void> deleteMatter({
    required String orgId,
    required String matterId,
  }) => _send(() => _dio.delete('/v1/matters/$matterId', options: _org(orgId)));

  /// Tracking on (`auto`) or off (`off`) for a CNR case (ADR 0015). Turning it on may start a fetch (its job id).
  /// MANUAL_CASE, NO_CNR (409); TRACKED_CASE_LIMIT (409, details `{limit}`).
  Future<({String tracking, String? jobId})> setTracking({
    required String orgId,
    required String matterId,
    required String tracking,
  }) async {
    final r = await _send<Map<String, dynamic>>(
      () => _dio.patch(
        '/v1/matters/$matterId',
        data: {'tracking': tracking},
        options: _org(orgId),
      ),
    );
    return (tracking: r['tracking'] as String, jobId: r['job_id'] as String?);
  }

  /// A short-lived link to a document's file (no title in it). DOCUMENT_NOT_READY (still being checked),
  /// DOCUMENT_QUARANTINED (failed the safety check).
  Future<String> documentUrl({
    required String orgId,
    required String documentId,
  }) => _url('/v1/documents/$documentId/download-url', orgId);

  /// A short-lived link to the court's copy of an order. ORDER_PDF_UNAVAILABLE, ORDER_PDF_FETCHING (retryable),
  /// COURT_PROVIDER_UNAVAILABLE.
  Future<String> orderPdfUrl({
    required String orgId,
    required String orderId,
  }) => _url('/v1/orders/$orderId/pdf-url', orgId);

  Future<String> _url(String path, String orgId) async {
    final r = await _send<Map<String, dynamic>>(
      () => _dio.get(path, options: _org(orgId)),
    );
    return r['url'] as String;
  }

  Options _org(String orgId, [String? idempotencyKey]) =>
      Options(headers: {'X-Org-Id': orgId, 'Idempotency-Key': ?idempotencyKey});

  Future<T> _send<T>(Future<Response<dynamic>> Function() call) async {
    try {
      return (await call()).data as T;
    } on DioException catch (e) {
      final data = e.response?.data;
      if (data is Map && data['error'] is Map) {
        final err = data['error'] as Map;
        throw ApiException(
          err['code'] as String? ?? 'HTTP_ERROR',
          retryable: err['retryable'] as bool? ?? false,
          status: e.response?.statusCode,
          details: (err['details'] as Map?)?.cast<String, dynamic>() ?? {},
        );
      }
      throw ApiException(
        e.response == null ? 'NETWORK' : 'HTTP_ERROR',
        retryable: true,
        status: e.response?.statusCode,
      );
    }
  }
}

final apiClientProvider = Provider<ApiClient>((ref) {
  final auth = ref.watch(authRepositoryProvider);
  final dio =
      Dio(
          BaseOptions(
            // ignore: avoid_redundant_argument_values, set by --dart-define at build time
            baseUrl: Config.apiUrl,
            connectTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 20),
          ),
        )
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              final token = auth.accessToken;
              if (token != null) {
                options.headers['Authorization'] = 'Bearer $token';
              }
              handler.next(options);
            },
          ),
        );
  return ApiClient(dio);
});
