import 'package:advocate_app/core/config.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/auth.dart';
import 'package:advocate_app/data/jobs.dart';
import 'package:dio/dio.dart';
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
