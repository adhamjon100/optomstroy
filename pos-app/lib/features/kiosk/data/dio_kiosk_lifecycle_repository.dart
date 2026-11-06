// `POST /kiosk/exit {code}` — аварийный выход планшета магазина со связью (08 §4.25.5; P-002 §8.9 п. 2; 09 §8.9 п. 4–5;
// 11 SEC-140 п. 3; ADR-115 п. 12, п. 28; OpenAPI 1.3.0 `kiosk_exit`; 13 TAB-2-10).
//
// Ключа идемпотентности у операции нет (`x-idempotent: false`): автоповтора нет (`RetryProfile.none`), повтор после
// потерянного `200` получает `401 KIOSK_REVOKED` — выход завершается так же. Сервер проверяет код только в ответах
// `200`, `422 KIOSK_EXIT_CODE_INVALID`, `423 KIOSK_EXIT_LOCKED` (и `401 KIOSK_REVOKED` повтора); всё остальное —
// нет сети, таймаут, `426`, `401 SESSION_REVOKED`, `403 KIOSK_DISABLED`, `403 KIOSK_NETWORK_DENIED`, `5xx` — значит
// «сервер код не проверил», и экран проверяет код на устройстве. Код в журнал не попадает (LoggingInterceptor тела не
// пишет; здесь код в сообщения и исключения не передаётся).
//
// Проверка склада планшета ([DioKioskLifecycleRepository.probeWarehouse]) — `GET /catalog/categories?depth=1` с токеном
// планшета: успешный ответ (через `AuthInterceptor`) снимает «Сервис временно недоступен» по складу (02 SCR-51.7).
import 'package:dio/dio.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/models/problem.dart';
import 'package:optomstroy/features/kiosk/kiosk_providers.dart';

/// Реализация [KioskLifecycleRepository] поверх основного Dio (Bearer планшета, `X-Kiosk-Lock`, `X-Device-Id`).
final class DioKioskLifecycleRepository implements KioskLifecycleRepository {
  DioKioskLifecycleRepository(this._dio);

  /// Путь относительно `/api/v1`.
  static const String exitPath = '/kiosk/exit';

  /// Запрос по складу планшета для [probeWarehouse].
  static const String warehouseProbePath = '/catalog/categories';

  final Dio _dio;

  @override
  Future<KioskServerExitResult> exit(String code) async {
    try {
      await _dio.post<Object?>(
        exitPath,
        data: <String, Object?>{'code': code},
        options: apiOptions(retry: RetryProfile.none),
      );
      return const KioskServerExitAccepted();
    } on DioException catch (e) {
      return _outcome(e);
    }
  }

  @override
  Future<void> probeWarehouse() async {
    try {
      await _dio.get<Object?>(
        warehouseProbePath,
        queryParameters: const <String, Object?>{'depth': 1},
        options: apiOptions(retry: RetryProfile.none),
      );
    } on DioException {
      // Отказ (`403` склада, нет сети) — состояние остаётся; следующая проверка — со следующим heartbeat.
    }
  }

  static KioskServerExitResult _outcome(DioException e) {
    final Response<Object?>? response = e.response;
    if (e.type != DioExceptionType.badResponse || response == null) return const KioskServerExitNotChecked();
    final int status = response.statusCode ?? 0;
    final Problem? problem = Problem.tryParse(response.data);
    switch ((status, problem?.code)) {
      case (401, 'KIOSK_REVOKED'):
        // Повтор после потерянного `200`: сессии уже отозваны — выход выполнен.
        return const KioskServerExitAccepted();
      case (422, 'KIOSK_EXIT_CODE_INVALID'):
        return KioskServerExitInvalid(problem?.attemptsLeft);
      case (423, 'KIOSK_EXIT_LOCKED'):
        final int? seconds = problem?.retryAfter ?? int.tryParse(response.headers.value(ApiHeaders.retryAfter) ?? '');
        return KioskServerExitLocked(seconds == null ? null : Duration(seconds: seconds));
      default:
        return const KioskServerExitNotChecked();
    }
  }
}
