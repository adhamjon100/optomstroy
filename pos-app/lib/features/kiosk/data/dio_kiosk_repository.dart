// `KioskRepository` поверх основного Dio (Bearer планшета, `X-Kiosk-Lock`, `X-Device-Id`): `POST /kiosk/order-otp`,
// `POST /kiosk/orders`, `GET /kiosk/orders?idempotencyKey=` (08 §4.25.1–§4.25.3; OpenAPI 1.3.0; P-002 §8.5 п. 6, 10;
// 13 TAB-2-04) и `POST /kiosk/reset` (08 §4.25.4; FLOW-045; 13 TAB-2-05).
//
// Автоповтора нет (`RetryProfile.none`): ключ идемпотентности у `POST /kiosk/orders` — свой на каждую попытку, тот же —
// только для повтора той же попытки, и это решает контроллер оформления (RetryInterceptor повторил бы и `409
// IDEMPOTENCY_IN_PROGRESS`, и `429`). Таймаут ответа заявки — `ApiTimeouts.orderCreate` (30 с: два поиска в 1С и
// `/check` по 6 с — ADR-115, «Последствия»). Номер и код — только в теле запроса; тела запросов и ответов
// LoggingInterceptor не пишет, здесь они в сообщения и исключения не передаются (11 PRIV-033).
// Сброс — без `Idempotency-Key` (повтор по `cartId` идемпотентен и без него, 08 §4.25.4) и без автоповтора: повторы
// сброса без сети (5, 15, 60 с, затем раз в минуту) выполняет оркестратор сброса; ответ — `Cart` (кодек фичи cart).
import 'package:dio/dio.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/dto_json.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_json_decoder.dart';
import 'package:optomstroy/features/kiosk/domain/kiosk_checkout.dart';
import 'package:optomstroy/features/kiosk/domain/kiosk_repository.dart';

/// Пути API оформления планшета (относительно `/api/v1`).
abstract final class KioskApiPaths {
  static const String orderOtp = '/kiosk/order-otp';
  static const String orders = '/kiosk/orders';
  static const String reset = '/kiosk/reset';
}

/// Реализация [KioskRepository].
final class DioKioskRepository implements KioskRepository {
  /// [cart] — разбор `Cart` ответа `POST /kiosk/reset` (`cartJsonDecoderProvider` фичи cart); без него сброс
  /// недоступен (`UnknownFailure`), остальные операции работают.
  DioKioskRepository(this._dio, {CartJsonDecoder? cart}) : _cart = cart;

  final Dio _dio;
  final CartJsonDecoder? _cart;

  /// Ключи тела `POST /kiosk/reset` (`KioskResetRequest`, `additionalProperties: false`).
  static const Set<String> resetKeys = <String>{'cartId'};

  /// Ключи тела `POST /kiosk/order-otp` (`KioskOrderOtpRequest`, `additionalProperties: false`).
  static const Set<String> orderOtpKeys = <String>{'phone', 'cartId', 'noticeVersion'};

  /// Ключи тела `POST /kiosk/orders` (`KioskOrdersCreateRequest`, `additionalProperties: false`).
  static const Set<String> orderKeys = <String>{'challengeId', 'code', 'cartId', 'cartRowVersion', 'previewToken'};

  /// Тело `POST /kiosk/orders`.
  static Map<String, Object?> orderBody(KioskOrderRequest r) => <String, Object?>{
    'challengeId': r.challengeId,
    'code': r.code,
    'cartId': r.cartId,
    'cartRowVersion': r.cartRowVersion,
    'previewToken': r.previewToken,
  };

  @override
  Future<Result<KioskOtpChallenge>> requestOrderOtp({
    required String phoneE164,
    required String cartId,
    required String noticeVersion,
  }) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.post<Object?>(
      KioskApiPaths.orderOtp,
      data: <String, Object?>{'phone': phoneE164, 'cartId': cartId, 'noticeVersion': noticeVersion},
      options: apiOptions(retry: RetryProfile.none),
    );
    final JsonMap json = jsonObject(r.data);
    return KioskOtpChallenge(
      challengeId: jReq<String>(json, 'challengeId'),
      resendAfter: Duration(seconds: jReqInt(json, 'resendAfterSec')),
    );
  });

  @override
  Future<Result<KioskOrderAccepted>> submitOrder(KioskOrderRequest request, {required String idempotencyKey}) =>
      ErrorMapper.guard(() async {
        final Response<Object?> r = await _dio.post<Object?>(
          KioskApiPaths.orders,
          data: orderBody(request),
          options: apiOptions(
            retry: RetryProfile.none,
            idempotencyKey: idempotencyKey,
            receiveTimeout: ApiTimeouts.orderCreate,
          ),
        );
        return KioskOrderAccepted(jReq<String>(jsonObject(r.data), 'publicNumber'));
      });

  @override
  Future<Result<KioskOrderAccepted?>> findOrder(String idempotencyKey) async {
    final Result<KioskOrderAccepted?> r = await ErrorMapper.guard(() async {
      final Response<Object?> response = await _dio.get<Object?>(
        KioskApiPaths.orders,
        queryParameters: <String, Object?>{'idempotencyKey': idempotencyKey},
        options: apiOptions(retry: RetryProfile.none),
      );
      return KioskOrderAccepted(jReq<String>(jsonObject(response.data), 'publicNumber'));
    });
    // `404 NOT_FOUND` — заявки с этим ключом у планшета нет (или запрос ещё выполняется): не ошибка восстановления.
    return switch (r) {
      FailureResult<KioskOrderAccepted?>(failure: ServerFailure(problemCode: ProblemCode.notFound)) =>
        const Success<KioskOrderAccepted?>(null),
      _ => r,
    };
  }

  @override
  Future<Result<Cart>> reset(String cartId) {
    final CartJsonDecoder? decoder = _cart;
    if (decoder == null) return Future<Result<Cart>>.value(const FailureResult<Cart>(UnknownFailure()));
    return ErrorMapper.guard(() async {
      final Response<Object?> r = await _dio.post<Object?>(
        KioskApiPaths.reset,
        data: <String, Object?>{'cartId': cartId},
        options: apiOptions(retry: RetryProfile.none),
      );
      return decoder.cart(jsonObject(r.data));
    });
  }
}
