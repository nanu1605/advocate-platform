import 'package:advocate_app/core/config.dart';
import 'package:advocate_app/data/auth.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Error from the API's `{"error": {...}}` shape (spec §10.1), or a network failure (`NETWORK`).
class ApiException implements Exception {
  const ApiException(this.code, {this.retryable = false, this.status});

  final String code;
  final bool retryable;
  final int? status;

  @override
  String toString() => 'ApiException($code, status: $status)';
}

/// Typed client for the FastAPI endpoints (spec §7.1 allows "generated or typed"). P0 covers /v1/me,
/// /v1/consents and /v1/devices; later phases add endpoints here as they ship.
class ApiClient {
  ApiClient(this._dio);

  final Dio _dio;

  Future<Map<String, dynamic>> me() => _send(() => _dio.get('/v1/me'));

  Future<Map<String, dynamic>> patchMe(Map<String, Object?> fields) =>
      _send(() => _dio.patch('/v1/me', data: fields));

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
