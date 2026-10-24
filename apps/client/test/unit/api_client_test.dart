import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/jobs.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

/// Answers requests from [reply] and records them; no network.
class _Adapter implements HttpClientAdapter {
  _Adapter(this.reply);

  final (int, Object?) Function(RequestOptions r) reply;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final (status, body) = reply(options);
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Storage behind signed URLs: records each request and its body's bytes; answers bytes, JSON or nothing.
class _FileAdapter implements HttpClientAdapter {
  _FileAdapter(this.reply);

  final (int, Object?) Function(RequestOptions r) reply;
  final requests = <RequestOptions>[];
  final bodies = <List<int>>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (requestStream != null) {
      bodies.add([for (final chunk in await requestStream.toList()) ...chunk]);
    }
    final (status, body) = reply(options);
    return body is Uint8List
        ? ResponseBody.fromBytes(
            body,
            status,
            headers: {
              Headers.contentLengthHeader: ['${body.length}'],
            },
          )
        : ResponseBody.fromString(
            body == null ? '' : jsonEncode(body),
            status,
            headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            },
          );
  }

  @override
  void close({bool force = false}) {}
}

/// Storage whose connection stalls: a download's body sends one chunk and then nothing, a PUT never gets an answer.
class _StallAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    if (options.method == 'PUT') return Completer<ResponseBody>().future;
    final body = StreamController<Uint8List>()..add(Uint8List(100));
    return Future.value(
      ResponseBody(
        body.stream,
        200,
        headers: {
          Headers.contentLengthHeader: ['5000'],
        },
      ),
    );
  }

  @override
  void close({bool force = false}) {}
}

(ApiClient, _Adapter) _client((int, Object?) Function(RequestOptions r) reply) {
  final adapter = _Adapter(reply);
  final dio = Dio(BaseOptions(baseUrl: 'http://api.test'))
    ..httpClientAdapter = adapter;
  return (ApiClient(dio), adapter);
}

void main() {
  test('me parses the profile and memberships', () async {
    final (api, _) = _client(
      (_) => (
        200,
        {
          'id': 'u1',
          'full_name': 'Ramesh Sharma',
          'phone': '9876543210',
          'email': null,
          'preferred_language': 'hi',
          'enrolment_no': 'MP/1/2010',
          'bar_council_state': 'MP',
          'practice_court_ids': ['c1'],
          'memberships': [
            {
              'org_id': 'o1',
              'org_name': 'Sharma',
              'org_kind': 'solo',
              'role': 'owner',
            },
          ],
        },
      ),
    );
    final me = await api.me();
    expect(me.org?.orgId, 'o1');
    expect(me.practiceCourtIds, ['c1']);
    expect(me.stage, AccountStage.owner);
  });

  test(
    'org calls send X-Org-Id; job-starting calls send the Idempotency-Key',
    () async {
      final (api, adapter) = _client(
        (r) => (202, {'job_id': 'j1', 'status': 'queued'}),
      );
      expect(
        await api.findCases(orgId: 'o1', idempotencyKey: 'key-1234'),
        'j1',
      );
      final r = adapter.requests.single;
      expect(r.path, '/v1/onboarding/find-cases');
      expect(r.headers['X-Org-Id'], 'o1');
      expect(r.headers['Idempotency-Key'], 'key-1234');
    },
  );

  test('a decision is org-scoped without an idempotency key', () async {
    final (api, adapter) = _client(
      (_) => (200, {'id': 'f1', 'decision': 'not_mine'}),
    );
    await api.decideFoundCase(orgId: 'o1', id: 'f1', decision: 'not_mine');
    final r = adapter.requests.single;
    expect(r.path, '/v1/found-cases/f1/decision');
    expect(r.data, {'decision': 'not_mine'});
    expect(r.headers['X-Org-Id'], 'o1');
    expect(r.headers.containsKey('Idempotency-Key'), isFalse);
  });

  test('Add all sends {all: true}', () async {
    final (api, adapter) = _client(
      (_) => (
        200,
        {
          'added': 33,
          'already_tracked': 1,
          'matter_ids': ['m1'],
          'job_id': 'j2',
        },
      ),
    );
    final r = await api.addAllFoundCases(
      orgId: 'o1',
      idempotencyKey: 'key-1234',
    );
    expect(r.added, 33);
    expect(r.alreadyTracked, 1);
    expect(adapter.requests.single.data, {'all': true});
    expect(adapter.requests.single.headers['Idempotency-Key'], 'key-1234');
  });

  test(
    'a selection goes in chunks of 500, each with its own derived key',
    () async {
      final (api, adapter) = _client((r) {
        final ids = ((r.data as Map)['ids'] as List).cast<String>();
        return (
          200,
          {
            'added': ids.length,
            'already_tracked': 0,
            'matter_ids': ids.map((i) => 'm$i').toList(),
            'job_id': 'j',
          },
        );
      });
      final ids = [for (var i = 0; i < 1200; i++) '$i'];
      final r = await api.addFoundCases(
        orgId: 'o1',
        idempotencyKey: 'key',
        ids: ids,
      );
      expect(
        adapter.requests.map((r) => ((r.data as Map)['ids'] as List).length),
        [500, 500, 200],
      );
      expect(adapter.requests.map((r) => r.headers['Idempotency-Key']), [
        'key.0',
        'key.1',
        'key.2',
      ]);
      expect(r.added, 1200);
      expect(r.matterIds, hasLength(1200));
      expect(
        adapter.requests.expand((r) => (r.data as Map)['ids'] as List),
        ids,
      );
    },
  );

  test(
    'error bodies become ApiException with code, retryable and details',
    () async {
      final (api, _) = _client(
        (_) => (
          409,
          {
            'error': {
              'code': 'TRACKED_CASE_LIMIT',
              'message': 'Your plan tracks no more cases',
              'retryable': false,
              'details': {'limit': 100, 'remaining': 4},
            },
          },
        ),
      );
      await expectLater(
        api.addFoundCases(orgId: 'o1', idempotencyKey: 'key', ids: ['a']),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'TRACKED_CASE_LIMIT')
              .having((e) => e.status, 'status', 409)
              .having((e) => e.details['remaining'], 'remaining', 4),
        ),
      );
    },
  );

  test('refresh is org-scoped with an idempotency key', () async {
    final (api, adapter) = _client((_) => (202, {'job_id': 'j3'}));
    expect(
      await api.refreshMatter(
        orgId: 'o1',
        matterId: 'm1',
        idempotencyKey: 'key-5678',
      ),
      'j3',
    );
    final r = adapter.requests.single;
    expect((r.method, r.path), ('POST', '/v1/matters/m1/refresh'));
    expect(r.headers['X-Org-Id'], 'o1');
    expect(r.headers['Idempotency-Key'], 'key-5678');
  });

  test('a case refreshed in the last 6 h is RATE_LIMITED', () async {
    final (api, _) = _client(
      (_) => (
        429,
        {
          'error': {
            'code': 'RATE_LIMITED',
            'message': 'This case was refreshed recently',
            'retryable': true,
            'details': {'retry_after_s': 3600},
          },
        },
      ),
    );
    await expectLater(
      api.refreshMatter(orgId: 'o1', matterId: 'm1', idempotencyKey: 'key-1'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.code, 'code', 'RATE_LIMITED')
            .having((e) => e.status, 'status', 429)
            .having((e) => e.details['retry_after_s'], 'retry after', 3600),
      ),
    );
  });

  group('cases (spec §10.2)', () {
    test(
      'search sends only the terms given, in the body; parses the page',
      () async {
        final (api, adapter) = _client(
          (_) => (
            200,
            {
              'items': [
                {
                  'cnr': 'MPHC010012342024',
                  'court_code': 'MPHC-IND',
                  'case_type': 'WP',
                  'case_number': '1234',
                  'case_year': 2024,
                  'title': 'Sharma v. State of MP',
                  'status': 'pending',
                  'next_hearing_date': '2026-11-12',
                  'petitioners': ['Ramesh Sharma'],
                  'respondents': ['State of MP'],
                  'advocates': [
                    {'name': 'Neha Sharma', 'side': 'petitioner'},
                  ],
                  'tracked': true,
                },
              ],
              'total': 8,
              'page': 2,
              'has_next': true,
              'cached': true,
              'post_filtered': true,
              'ignored_court_ids': ['c1'],
            },
          ),
        );
        final page = await api.searchCases(
          orgId: 'o1',
          party: '  Sharma ',
          advocate: ' ',
          courtIds: ['c1', 'c2'],
          year: 2024,
          page: 2,
        );
        final r = adapter.requests.single;
        expect((r.method, r.path), ('POST', '/v1/search/cases'));
        expect(r.uri.query, isEmpty); // names never in the URL
        expect(r.data, {
          'party': 'Sharma',
          'court_ids': ['c1', 'c2'],
          'year': 2024,
          'page': 2,
          'page_size': 20,
        });
        expect(r.headers['X-Org-Id'], 'o1');
        expect(r.headers.containsKey('Idempotency-Key'), isFalse);
        final hit = page.items.single;
        expect(hit.caseLabel, 'WP 1234/2024');
        expect(hit.nextHearingDate, DateTime.utc(2026, 11, 12));
        expect(hit.advocates.single, (name: 'Neha Sharma', side: 'petitioner'));
        expect(hit.tracked, isTrue);
        expect(hit.petitioners, ['Ramesh Sharma']);
        expect(
          (page.total, page.page, page.hasNext, page.postFiltered),
          (8, 2, true, true),
        );
        expect(page.ignoredCourtIds, ['c1']);
      },
    );

    test('manual add sends the trimmed fields and the next date', () async {
      final (api, adapter) = _client((_) => (201, {'id': 'm9'}));
      final id = await api.addManual(
        orgId: 'o1',
        title: ' Demo v. State ',
        courtName: 'Family Court, Dewas',
        caseNumber: '12',
        caseYear: 2025,
        fileNo: ' ',
        nextDate: DateTime.utc(2026, 11, 20),
      );
      expect(id, 'm9');
      final r = adapter.requests.single;
      expect((r.method, r.path), ('POST', '/v1/matters/manual'));
      expect(r.data, {
        'title': 'Demo v. State',
        'court_name': 'Family Court, Dewas',
        'case_number': '12',
        'case_year': 2025,
        'next_date': '2026-11-20',
      });
    });

    test('official link, tracking, delete and file links', () async {
      final (api, adapter) = _client(
        (r) => switch ((r.method, r.path)) {
          ('GET', '/v1/matters/m1/official-link') => (
            200,
            {
              'url': 'https://hcservices.ecourts.gov.in/',
              'cnr': 'MPHC010012342024',
              'verified': false,
            },
          ),
          ('PATCH', '/v1/matters/m1') => (
            200,
            {'matter_id': 'm1', 'tracking': 'auto', 'job_id': 'j7'},
          ),
          ('DELETE', '/v1/matters/m1') => (204, null),
          ('GET', '/v1/documents/d1/download-url') => (
            200,
            {'url': 'https://files.test/d1', 'expires_in_s': 300},
          ),
          ('GET', '/v1/orders/o1/pdf-url') => (
            200,
            {'url': 'https://files.test/o1', 'expires_in_s': 300},
          ),
          _ => (404, null),
        },
      );
      expect(await api.officialLink(orgId: 'o1', matterId: 'm1'), (
        url: 'https://hcservices.ecourts.gov.in/',
        cnr: 'MPHC010012342024',
        verified: false,
      ));
      expect(
        await api.setTracking(orgId: 'o1', matterId: 'm1', tracking: 'auto'),
        (tracking: 'auto', jobId: 'j7'),
      );
      await api.deleteMatter(orgId: 'o1', matterId: 'm1');
      expect(
        await api.documentUrl(orgId: 'o1', documentId: 'd1'),
        'https://files.test/d1',
      );
      expect(
        await api.orderPdfUrl(orgId: 'o1', orderId: 'o1'),
        'https://files.test/o1',
      );
      expect(adapter.requests[1].data, {'tracking': 'auto'});
      expect(adapter.requests.map((r) => r.headers['X-Org-Id']).toSet(), {
        'o1',
      });
    });

    test(
      'turning tracking on over the allowance is TRACKED_CASE_LIMIT',
      () async {
        final (api, _) = _client(
          (_) => (
            409,
            {
              'error': {
                'code': 'TRACKED_CASE_LIMIT',
                'message': 'Your plan tracks no more cases',
                'retryable': false,
                'details': {'limit': 100},
              },
            },
          ),
        );
        await expectLater(
          api.setTracking(orgId: 'o1', matterId: 'm1', tracking: 'auto'),
          throwsA(
            isA<ApiException>()
                .having((e) => e.code, 'code', 'TRACKED_CASE_LIMIT')
                .having((e) => e.details['limit'], 'limit', 100),
          ),
        );
      },
    );
  });

  group('uploads and file downloads (spec §10.2 Documents)', () {
    test('upload-url sends the fields in the body, org-scoped', () async {
      final (api, adapter) = _client(
        (_) => (
          201,
          {
            'document_id': 'd1',
            'upload_url':
                'https://storage.test/upload/sign/documents/o1/d1?token=t',
            'expires_in_s': 7200,
          },
        ),
      );
      final r = await api.uploadUrl(
        orgId: 'o1',
        title: 'Writ petition',
        kind: 'pleading',
        mime: 'application/pdf',
        sizeBytes: 2048,
        matterId: 'm1',
      );
      expect(r.documentId, 'd1');
      expect(r.expiresInS, 7200);
      final req = adapter.requests.single;
      expect(req.path, '/v1/documents/upload-url');
      expect(req.headers['X-Org-Id'], 'o1');
      expect(req.data, {
        'title': 'Writ petition',
        'kind': 'pleading',
        'matter_id': 'm1',
        'mime': 'application/pdf',
        'size_bytes': 2048,
      });
    });

    test('complete carries the Idempotency-Key', () async {
      final (api, adapter) = _client(
        (_) => (
          202,
          {'document_id': 'd1', 'upload_status': 'pending', 'job_id': 'j'},
        ),
      );
      await api.completeUpload(
        orgId: 'o1',
        documentId: 'd1',
        idempotencyKey: 'key-1234',
      );
      final req = adapter.requests.single;
      expect(req.path, '/v1/documents/d1/complete');
      expect(req.method, 'POST');
      expect(req.headers['Idempotency-Key'], 'key-1234');
    });

    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('pairavi_api');
      addTearDown(() => dir.deleteSync(recursive: true));
    });

    test('the PUT sends the bytes with the declared type and progress, and '
        'nothing of the API', () async {
      final storage = _FileAdapter((_) => (200, null));
      final api = ApiClient(Dio(), Dio()..httpClientAdapter = storage);
      final file = File('${dir.path}/a.pdf')
        ..writeAsBytesSync(List.filled(3000, 7));
      final sent = <int>[];
      await api.putUpload(
        'https://storage.test/upload/sign/documents/o1/d1?token=t',
        file,
        mime: 'application/pdf',
        onProgress: (s, total) {
          expect(total, 3000);
          sent.add(s);
        },
      );
      final req = storage.requests.single;
      expect(req.method, 'PUT');
      expect(
        req.uri.toString(),
        'https://storage.test/upload/sign/documents/o1/d1?token=t',
      );
      expect(req.headers[Headers.contentTypeHeader], 'application/pdf');
      expect(req.headers[Headers.contentLengthHeader], 3000);
      expect(
        req.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('authorization')),
      );
      expect(req.headers.keys, isNot(contains('X-Org-Id')));
      expect(storage.bodies.single, hasLength(3000));
      expect(sent.last, 3000);
    });

    test(
      'a PUT already stored counts as sent; other refusals say what to do',
      () async {
        final file = File('${dir.path}/a.pdf')..writeAsBytesSync([1, 2, 3]);
        Future<void> put((int, Object?) reply) => ApiClient(
          Dio(),
          Dio()..httpClientAdapter = _FileAdapter((_) => reply),
        ).putUpload('https://storage.test/u', file, mime: 'application/pdf');

        await put((409, {'statusCode': '409', 'error': 'Duplicate'}));
        await put((400, {'statusCode': '409', 'error': 'Duplicate'}));
        for (final (reply, code, retryable) in [
          ((413, {'statusCode': '413'}), 'FILE_TOO_LARGE', false),
          ((400, {'statusCode': '413'}), 'FILE_TOO_LARGE', false),
          (
            (400, {'statusCode': '400', 'error': 'InvalidJWT'}),
            'UPLOAD_URL_EXPIRED',
            true,
          ),
          ((403, null), 'UPLOAD_URL_EXPIRED', true),
          ((503, null), 'STORAGE_UNAVAILABLE', true),
        ]) {
          await expectLater(
            put(reply),
            throwsA(
              isA<ApiException>()
                  .having((e) => e.code, 'code', code)
                  .having((e) => e.retryable, 'retryable', retryable),
            ),
            reason: '$reply',
          );
        }
        final offline = Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (o, h) => h.reject(
                DioException.connectionError(
                  requestOptions: o,
                  reason: 'offline',
                ),
              ),
            ),
          );
        await expectLater(
          ApiClient(
            Dio(),
            offline,
          ).putUpload('https://storage.test/u', file, mime: 'application/pdf'),
          throwsA(isA<ApiException>().having((e) => e.code, 'code', 'NETWORK')),
        );
      },
    );

    test(
      'a download streams to the file with progress; a failed or cancelled one '
      'leaves no file',
      () async {
        final bytes = List.generate(5000, (i) => i % 256);
        final storage = _FileAdapter(
          (r) => r.uri.path.endsWith('gone')
              ? (400, null)
              : (200, Uint8List.fromList(bytes)),
        );
        final api = ApiClient(Dio(), Dio()..httpClientAdapter = storage);
        final path = '${dir.path}/d1.pdf';
        final got = <int>[];
        await api.download(
          'https://storage.test/object/sign/documents/d1',
          path,
          onProgress: (r, _) => got.add(r),
        );
        expect(File(path).readAsBytesSync(), bytes);
        expect(File('$path.part').existsSync(), isFalse);
        expect(got.last, 5000);
        expect(
          storage.requests.single.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('authorization')),
        );

        final other = '${dir.path}/d2.pdf';
        await expectLater(
          api.download('https://storage.test/gone', other),
          throwsA(
            isA<ApiException>()
                .having((e) => e.code, 'code', 'DOWNLOAD_FAILED')
                .having((e) => e.retryable, 'retryable', isTrue),
          ),
        );
        await expectLater(
          api.download(
            'https://storage.test/object/sign/documents/d2',
            other,
            cancel: CancelToken()..cancel(),
          ),
          throwsA(
            isA<ApiException>().having((e) => e.code, 'code', 'CANCELLED'),
          ),
        );
        expect(File(other).existsSync(), isFalse);
        expect(File('$other.part').existsSync(), isFalse);

        // The device can't store it (here: a folder where the file goes).
        final blocked = Directory('${dir.path}/d3.pdf')..createSync();
        await expectLater(
          api.download(
            'https://storage.test/object/sign/documents/d3',
            blocked.path,
          ),
          throwsA(
            isA<ApiException>()
                .having((e) => e.code, 'code', 'SAVE_FAILED')
                .having((e) => e.retryable, 'retryable', isFalse),
          ),
        );
      },
    );

    test(
      'a transfer that stalls is dropped as NETWORK (retryable); a cancelled '
      'PUT says CANCELLED',
      () async {
        final api = ApiClient(
          Dio(),
          Dio()..httpClientAdapter = _StallAdapter(),
          const Duration(milliseconds: 50),
        );
        final path = '${dir.path}/d1.pdf';
        final file = File('${dir.path}/a.pdf')..writeAsBytesSync([1, 2, 3]);
        for (final transfer in [
          () => api.download(
            'https://storage.test/object/sign/documents/d1',
            path,
          ),
          () => api.putUpload(
            'https://storage.test/u',
            file,
            mime: 'application/pdf',
          ),
        ]) {
          await expectLater(
            transfer(),
            throwsA(
              isA<ApiException>()
                  .having((e) => e.code, 'code', 'NETWORK')
                  .having((e) => e.retryable, 'retryable', isTrue),
            ),
          );
        }
        expect(File(path).existsSync(), isFalse);
        expect(File('$path.part').existsSync(), isFalse);

        await expectLater(
          api.putUpload(
            'https://storage.test/u',
            file,
            mime: 'application/pdf',
            cancel: CancelToken()..cancel(),
          ),
          throwsA(
            isA<ApiException>().having((e) => e.code, 'code', 'CANCELLED'),
          ),
        );
      },
    );
  });

  test('no response at all is NETWORK, retryable', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://api.test'))
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) => h.reject(
            DioException.connectionError(requestOptions: o, reason: 'offline'),
          ),
        ),
      );
    await expectLater(
      ApiClient(dio).job('j1'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.code, 'code', 'NETWORK')
            .having((e) => e.retryable, 'retryable', isTrue),
      ),
    );
  });

  test(
    'a job parses find_cases progress from the API and from the synced row',
    () {
      const progress = {
        'groups': [
          {'key': 'HC', 'state': 'done', 'found': 21},
          {'key': 'DC', 'state': 'running', 'found': 3},
        ],
        'found': 24,
      };
      final fromApi = Job.fromJson(const {
        'id': 'j1',
        'kind': 'find_cases',
        'status': 'running',
        'progress': progress,
        'result': null,
        'error': null,
      });
      final fromRow = Job.fromJson({
        'id': 'j1',
        'kind': 'find_cases',
        'status': 'failed',
        'progress': jsonEncode(progress),
        'result': jsonEncode({
          'found': 24,
          'pending': 20,
          'disposed': 4,
          'low': 2,
        }),
        'error': 'COURT_PROVIDER_UNAVAILABLE',
      });
      for (final job in [fromApi, fromRow]) {
        expect(job.groups.first, (key: 'HC', state: 'done', found: 21));
        expect(job.found, 24);
      }
      expect(fromApi.finished, isFalse);
      expect(fromRow.finished, isTrue);
      expect(fromRow.result?['pending'], 20);
    },
  );

  test(
    'watchJob polls the API until the job finishes, carrying on after errors',
    () async {
      const running = Job(
        id: 'j1',
        kind: 'find_cases',
        status: JobStatus.running,
      );
      const done = Job(id: 'j1', kind: 'find_cases', status: JobStatus.done);
      final api = _ScriptedApi([running, const ApiException('NETWORK'), done]);
      final events = <Object>[];
      await watchJob(
        'j1',
        api: api,
        every: Duration.zero,
      ).handleError(events.add).forEach((j) => events.add(j.status));
      expect(events, [JobStatus.running, isA<ApiException>(), JobStatus.done]);
    },
  );

  testWidgets('a screen leaving a running job leaves no polling timer behind', (
    tester,
  ) async {
    final api = FakeApi()
      ..jobs['j1'] = const Job(
        id: 'j1',
        kind: 'find_cases',
        status: JobStatus.running,
      );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: Consumer(
          builder: (_, ref, _) {
            ref.watch(jobProvider('j1'));
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 5));
    expect(api.callNames.where((n) => n == 'job').length, greaterThan(1));
    await tester.pumpWidget(const SizedBox());
  });
}

/// job() answers from [script] in order: a Job, or an ApiException to throw.
class _ScriptedApi extends FakeApi {
  _ScriptedApi(this.script);

  final List<Object> script;

  @override
  Future<Job> job(String id) async => switch (script.removeAt(0)) {
    final ApiException e => throw e,
    final Object job => job as Job,
  };
}
