// Проверка `GET /health` в веб-демо (15 ADR-113 п. 1): тот же `DioBackendHealthProbe` (core/network/backend_health.dart),
// но его собственный Dio получает транспорт моста [DemoBridgeAdapter]. Иначе проверка ушла бы в сеть мимо сервера
// в Web Worker, и Splash показал бы «нет связи с сервером».
//
// Холодный старт: адаптер ждёт `ready` воркера, поэтому 5 с таймаута проверки отсчитываются от готовности сервера
// демо, а не от загрузки страницы.
import 'package:dio/dio.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/network/backend_health.dart';

/// `/health` через мост веб-демо.
final class DemoHealthProbe implements BackendHealthProbe {
  DemoHealthProbe(AppConfig config, HttpClientAdapter adapter, {Duration timeout = const Duration(seconds: 5)})
    : _probe = DioBackendHealthProbe(
        config,
        dio: Dio(
          BaseOptions(
            connectTimeout: timeout,
            receiveTimeout: timeout,
            sendTimeout: timeout,
            responseType: ResponseType.json,
          ),
        )..httpClientAdapter = adapter,
      );

  final DioBackendHealthProbe _probe;

  /// `<origin сайта>/health`.
  Uri get healthUri => _probe.healthUri;

  @override
  Future<BackendHealthReport> check() => _probe.check();

  /// Адаптер общий с основным Dio: `Dio.close()` без `force` его не выключает.
  @override
  void close() => _probe.close();
}
