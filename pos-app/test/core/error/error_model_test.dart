// Failure / Result / ScreenState (06 §6.8, §6.11) и ErrorMapper (DioException → Failure).
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/error/screen_state.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/core/sync/outbox_queue.dart';

import '../network/fake_adapter.dart' show problem;

final _req = RequestOptions(path: '/x', method: 'POST', headers: {'X-Request-Id': 'sent-rid'});

DioException bad(int status, Object? body, {Map<String, List<String>> headers = const {}}) => DioException(
  requestOptions: _req,
  type: DioExceptionType.badResponse,
  response: Response<Object?>(requestOptions: _req, statusCode: status, data: body, headers: Headers.fromMap(headers)),
);

Failure mapCode(String code, int status, {Map<String, Object?> extra = const {}}) =>
    ErrorMapper.fromDio(bad(status, problem(code, status, extra: extra)));

void main() {
  group('Result', () {
    test('Success / FailureResult: fold, map, flatMap, геттеры', () async {
      const Result<int> ok = Success(2);
      const Result<int> err = FailureResult(NetworkFailure(NetworkFailureKind.offline));
      expect(ok.isSuccess, isTrue);
      expect(err.isSuccess, isFalse);
      expect(ok.valueOrNull, 2);
      expect(err.valueOrNull, isNull);
      expect(ok.failureOrNull, isNull);
      expect(err.failureOrNull, isA<NetworkFailure>());
      expect(ok.fold((v) => 'v$v', (f) => 'f'), 'v2');
      expect(err.fold((v) => 'v', (f) => 'f'), 'f');
      expect(ok.map((v) => v * 10), const Success(20));
      expect(err.map((v) => v * 10).failureOrNull, isA<NetworkFailure>());
      expect(await ok.flatMap((v) async => Success('$v')), const Success('2'));
      expect((await err.flatMap((v) async => Success('$v'))).isSuccess, isFalse);
      expect(const Success(1).hashCode, const Success(1).hashCode);
      expect(ok.toString(), 'Success<int>');
      expect(err.toString(), contains('NetworkFailure'));
    });
  });

  group('ScreenState.fromResult (06 §6.11)', () {
    final now = DateTime.utc(2026, 10, 21, 12);

    test('Success → Data / Empty', () {
      final data = ScreenState.fromResult<List<int>>(const Success([1]), now: now, snapshotAt: now);
      expect(data, isA<ScreenData<List<int>>>().having((s) => s.source, 'source', DataSource.network));
      expect(data.visibleValue, [1]);
      expect(
        ScreenState.fromResult<List<int>>(const Success([]), now: now, isEmpty: (v) => v.isEmpty),
        isA<ScreenEmpty<List<int>>>(),
      );
    });

    test('NetworkFailure: без кэша → Offline; свежий кэш → Data(cache); старый → Stale', () {
      const failure = FailureResult<int>(NetworkFailure(NetworkFailureKind.offline));
      expect(ScreenState.fromResult(failure, now: now), isA<ScreenOffline<int>>());
      final fresh = ScreenState.fromResult(
        failure,
        now: now,
        cached: 5,
        cachedAt: now.subtract(const Duration(minutes: 5)),
        staleAfter: const Duration(minutes: 30),
      );
      expect(fresh, isA<ScreenData<int>>().having((s) => s.source, 'source', DataSource.cache));
      final stale = ScreenState.fromResult(
        failure,
        now: now,
        cached: 5,
        cachedAt: now.subtract(const Duration(hours: 1)),
        staleAfter: const Duration(minutes: 30),
      );
      expect(stale, isA<ScreenStale<int>>());
      expect(stale.visibleValue, 5);
      expect(
        ScreenState.fromResult(failure, now: now, cached: 5),
        isA<ScreenStale<int>>(),
        reason: 'возраст неизвестен',
      );
    });

    test('PermissionFailure → NoPermission; прочее → Error', () {
      expect(
        ScreenState.fromResult(const FailureResult<int>(PermissionFailure()), now: now),
        isA<ScreenNoPermission<int>>().having((s) => s.reason, 'reason', PermissionReason.role),
      );
      expect(ScreenState.fromResult(const FailureResult<int>(UnknownFailure()), now: now), isA<ScreenError<int>>());
    });

    test('isBusy и visibleValue прочих состояний', () {
      expect(const ScreenLoading<int>().isBusy, isTrue);
      expect(const ScreenRetrying<int>(UnknownFailure()).isBusy, isTrue);
      expect(const ScreenOffline<int>(3).visibleValue, 3);
      expect(const ScreenError<int>(UnknownFailure()).visibleValue, isNull);
      expect(const ScreenData<int>(1).isBusy, isFalse);
    });
  });

  group('ErrorMapper', () {
    test('коды аутентификации → AuthFailure', () {
      final f = mapCode('OTP_INVALID', 422, extra: {'attemptsLeft': 2}) as AuthFailure;
      expect(f.reason, AuthReason.otpInvalid);
      expect(f.attemptsLeft, 2);
      expect(f.requestId, 'rid-OTP_INVALID');
      final stepUp =
          mapCode(
                'STEP_UP_REQUIRED',
                403,
                extra: {
                  'stepUp': {
                    'operation': 'payment.void',
                    'allowedMethods': ['pin'],
                  },
                },
              )
              as AuthFailure;
      expect(stepUp.stepUpOperation, 'payment.void');
      expect((mapCode('DEVICE_MISMATCH', 409) as AuthFailure).reason, AuthReason.deviceMismatch);
    });

    test('конфликты → ConflictFailure с деталями', () {
      final f =
          mapCode('ORDER_STATE_INVALID', 409, extra: {'currentStatus': 'shipped', 'reason': 'possible_duplicate'})
              as ConflictFailure;
      expect(f.kind, ConflictKind.orderStateInvalid);
      expect(f.currentStatus, 'shipped');
      expect(f.reason, 'possible_duplicate');
      expect(f.details['code'], 'ORDER_STATE_INVALID');
      expect((mapCode('PRICE_CHANGED', 422) as ConflictFailure).kind, ConflictKind.priceChanged);
    });

    test('валидация, права, 1С, обновление, прочие коды', () {
      final v =
          mapCode(
                'VALIDATION_FAILED',
                400,
                extra: {
                  'errors': [
                    {
                      'field': 'items[1].quantity',
                      'message': 'кратно 6',
                      'rule': 'qty_multiple',
                      'params': {'factor': '6'},
                    },
                  ],
                },
              )
              as ValidationFailure;
      expect(v.errors.single.rule, 'qty_multiple');
      expect(v.errors.single.params['factor'], '6');
      expect(v.errors.single.toString(), 'FieldError(items[1].quantity, qty_multiple)');
      expect(
        (mapCode('FORBIDDEN', 403, extra: {'reason': 'pin_not_set'}) as PermissionFailure).serverReason,
        'pin_not_set',
      );
      expect(mapCode('ONEC_UNAVAILABLE', 503), isA<OnecUnavailableFailure>());
      // OpenAPI 1.2.0 (08 §4.7.1 «Уточнения» п. 2): `GET /cart` → 503 catalog_not_loaded — причина сохраняется,
      // запись outbox корзины повторяется без счёта попытки (не уходит в dead до первичной загрузки каталога).
      final notLoaded = ErrorMapper.fromDio(
        bad(
          503,
          problem('ONEC_UNAVAILABLE', 503, extra: {'reason': 'catalog_not_loaded'}),
          headers: {
            'Retry-After': ['60'],
          },
        ),
      ) as OnecUnavailableFailure;
      expect(notLoaded.catalogNotLoaded, isTrue);
      expect(notLoaded.retryAfter, const Duration(seconds: 60));
      expect(outboxOutcomeOf(notLoaded), OutboxOutcome.retry);
      expect((mapCode('ONEC_UNAVAILABLE', 503) as OnecUnavailableFailure).catalogNotLoaded, isFalse);
      expect(outboxOutcomeOf(const OnecUnavailableFailure()), OutboxOutcome.failed);
      expect(
        (mapCode('APP_UPDATE_REQUIRED', 426, extra: {'minVersion': '2.0.0'}) as AppUpdateRequiredFailure).minVersion,
        '2.0.0',
      );
      final credit = mapCode('CREDIT_LIMIT_EXCEEDED', 422, extra: {'reason': 'limit'}) as ServerFailure;
      expect(credit.problemCode, ProblemCode.creditLimitExceeded);
      expect(credit.reason, 'limit');
      final unknown = mapCode('BRAND_NEW_CODE', 422) as ServerFailure;
      expect(unknown.problemCode, isNull, reason: 'неизвестный код — как INTERNAL того же класса');
      expect(unknown.status, 422);
    });

    test('ответ без problem+json: 502–504 → serverUnavailable, 426 → обновление, иначе INTERNAL', () {
      expect(
        ErrorMapper.fromDio(bad(504, '<html>')),
        isA<NetworkFailure>().having((f) => f.kind, 'kind', NetworkFailureKind.serverUnavailable),
      );
      expect(ErrorMapper.fromDio(bad(426, null)), isA<AppUpdateRequiredFailure>());
      final f =
          ErrorMapper.fromDio(
                bad(
                  500,
                  null,
                  headers: {
                    'retry-after': ['7'],
                    'x-request-id': ['resp-rid'],
                  },
                ),
              )
              as ServerFailure;
      expect(f.code, 'INTERNAL');
      expect(f.retryAfter, const Duration(seconds: 7));
      expect(f.requestId, 'resp-rid');
    });

    test('транспорт: offline, таймаут (результат неизвестен для записи), прочее', () {
      DioException t(DioExceptionType type, String method) => DioException(
        requestOptions: RequestOptions(path: '/x', method: method),
        type: type,
      );
      expect(
        (ErrorMapper.fromDio(t(DioExceptionType.connectionError, 'GET')) as NetworkFailure).kind,
        NetworkFailureKind.offline,
      );
      final post = ErrorMapper.fromDio(t(DioExceptionType.receiveTimeout, 'POST')) as NetworkFailure;
      expect((post.kind, post.outcomeUnknown), (NetworkFailureKind.timeout, true));
      final get = ErrorMapper.fromDio(t(DioExceptionType.sendTimeout, 'GET')) as NetworkFailure;
      expect(get.outcomeUnknown, isFalse);
      expect(ErrorMapper.fromDio(t(DioExceptionType.cancel, 'GET')), isA<UnknownFailure>());
      expect(ErrorMapper.fromDio(t(DioExceptionType.transformTimeout, 'GET')).requestId, isNull);
      expect(
        ErrorMapper.fromDio(DioException(requestOptions: _req, type: DioExceptionType.unknown)).requestId,
        'sent-rid',
      );
    });

    test('guard: успех, DioException, ошибка разбора', () async {
      expect(await ErrorMapper.guard(() async => 1), const Success(1));
      final dioErr = await ErrorMapper.guard<int>(() async => throw bad(404, problem('NOT_FOUND', 404)));
      expect((dioErr.failureOrNull! as ServerFailure).problemCode, ProblemCode.notFound);
      final parse = await ErrorMapper.guard<int>(() async => throw const FormatException('bad json'));
      expect(parse.failureOrNull, isA<UnknownFailure>());
    });

    test('retryAfterOf: заголовок, тело, отсутствие', () {
      expect(retryAfterOf(null), isNull);
      expect(retryAfterOf(bad(429, {'retryAfter': 4}).response), const Duration(seconds: 4));
      expect(retryAfterOf(bad(429, {}).response), isNull);
    });
  });

  test('toString ошибок без ПДн и текстов', () {
    final all = <Failure>[
      const NetworkFailure(NetworkFailureKind.timeout, requestId: 'r'),
      const ServerFailure(code: 'INTERNAL', status: 500),
      const AuthFailure(AuthReason.pinLocked),
      const ValidationFailure(
        errors: [FieldError(field: 'phone', rule: 'phone', message: '+996555123456')],
      ),
      const ConflictFailure(ConflictKind.versionConflict),
      const OnecUnavailableFailure(),
      const PermissionFailure(reason: PermissionReason.osPermission),
      const AppUpdateRequiredFailure(minVersion: '2.0.0'),
      const UnknownFailure(cause: 'x'),
    ];
    for (final f in all) {
      expect(f.toString(), isNot(contains('555123456')));
      expect(f.toString(), contains(f.runtimeType.toString()));
    }
  });
}
