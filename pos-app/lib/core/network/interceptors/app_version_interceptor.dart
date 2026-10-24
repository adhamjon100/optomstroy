// Контроль версии клиента — клиентская часть RM-C-015 (D-46; 08 §2.11):
// заголовки `X-Min-App-Version` / `X-Recommended-App-Version` любого ответа →
// [AppVersionController]; `426 APP_UPDATE_REQUIRED` → «требуется обновление» (SCR-90).
import 'package:dio/dio.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/app_version/app_version_controller.dart';

final class AppVersionInterceptor extends Interceptor {
  AppVersionInterceptor(this._controller);

  final AppVersionController _controller;

  @override
  Future<void> onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) async {
    await _observe(response);
    handler.next(response);
  }

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final response = err.response;
    if (response != null) {
      if (response.statusCode == 426) {
        final body = response.data;
        await _controller.onUpdateRequired(
          minHeader: response.headers.value(ApiHeaders.minAppVersion),
          minVersionBody: body is Map && body['minVersion'] is String ? body['minVersion'] as String : null,
          storeUrl: body is Map && body['storeUrl'] is String ? body['storeUrl'] as String : null,
        );
      } else {
        await _observe(response);
      }
    }
    handler.next(err);
  }

  Future<void> _observe(Response<dynamic> response) => _controller.onHeaders(
    minHeader: response.headers.value(ApiHeaders.minAppVersion),
    recommendedHeader: response.headers.value(ApiHeaders.recommendedAppVersion),
  );
}
