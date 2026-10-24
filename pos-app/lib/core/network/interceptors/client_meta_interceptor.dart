// `X-Device-Id`, `X-App-Version`, `X-Platform`, `Accept-Language` на всех запросах
// (08 §2.3; RM-C-015: интерсептор добавляет заголовки ко всем запросам).
import 'package:dio/dio.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/client_meta.dart';

final class ClientMetaInterceptor extends Interceptor {
  ClientMetaInterceptor(this._meta);

  /// Текущие метаданные (язык может меняться во время работы).
  final ClientMeta Function() _meta;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final meta = _meta();
    options.headers[ApiHeaders.deviceId] = meta.deviceId;
    options.headers[ApiHeaders.appVersion] = meta.appVersion;
    final platform = meta.platform;
    if (platform != null) options.headers[ApiHeaders.platform] = platform.name;
    options.headers.putIfAbsent(ApiHeaders.acceptLanguage, () => meta.languageCode);
    handler.next(options);
  }
}
