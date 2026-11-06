// `X-Device-Id`, `X-App-Version`, `X-Platform`, `Accept-Language` на всех запросах
// (08 §2.3; RM-C-015: интерсептор добавляет заголовки ко всем запросам).
// `X-Kiosk-Lock: on|off` — на каждом запросе сессии планшета магазина (08 §2.3; ADR-115 п. 26): значение даёт
// источник, который подключает core/session ([attachKioskLock]; последний снимок `KioskLock.status`). У других
// субъектов источника нет или он отвечает `null` — заголовок не ставится.
import 'package:dio/dio.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/client_meta.dart';

/// Значение `X-Kiosk-Lock` текущего запроса (`on` | `off`) или `null` — заголовка нет.
typedef KioskLockHeaderSource = String? Function();

final class ClientMetaInterceptor extends Interceptor {
  ClientMetaInterceptor(this._meta);

  /// Текущие метаданные (язык может меняться во время работы).
  final ClientMeta Function() _meta;

  KioskLockHeaderSource? _kioskLock;

  /// Интерсептор клиента [dio] (создаёт DioClient) — для подключения источника `X-Kiosk-Lock`.
  static ClientMetaInterceptor? of(Dio dio) {
    for (final interceptor in dio.interceptors) {
      if (interceptor is ClientMetaInterceptor) return interceptor;
    }
    return null;
  }

  /// Подключить (или снять — `null`) источник `X-Kiosk-Lock` (core/session, сессия планшета магазина).
  void attachKioskLock(KioskLockHeaderSource? source) => _kioskLock = source;

  /// Подключённый источник `X-Kiosk-Lock` (для проверок).
  KioskLockHeaderSource? get kioskLock => _kioskLock;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final meta = _meta();
    options.headers[ApiHeaders.deviceId] = meta.deviceId;
    options.headers[ApiHeaders.appVersion] = meta.appVersion;
    final platform = meta.platform;
    if (platform != null) options.headers[ApiHeaders.platform] = platform.name;
    options.headers.putIfAbsent(ApiHeaders.acceptLanguage, () => meta.languageCode);
    final kioskLock = _kioskLock?.call();
    if (kioskLock != null) options.headers[ApiHeaders.kioskLock] = kioskLock;
    handler.next(options);
  }
}
