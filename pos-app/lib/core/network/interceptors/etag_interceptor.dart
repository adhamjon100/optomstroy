// ETag / If-None-Match для каталога и публичных настроек (08 §2.8, 06 §6.7):
// `304 Not Modified` → сохранённое тело из [EtagCache] (ответ помечается
// `extra[RequestExtra.etagCacheHit] = true`). Если записи уже нет — один
// повтор без `If-None-Match`.
import 'package:dio/dio.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/etag_cache.dart';

final class EtagInterceptor extends Interceptor {
  EtagInterceptor(this._dio, this._cache);

  final Dio _dio;
  final EtagCache _cache;

  static bool _applies(RequestOptions o) =>
      o.method.toUpperCase() == 'GET' &&
      EtagCache.isCacheablePath(o.uri.path) &&
      o.extra[RequestExtra.etagBypass] != true;

  static String _key(RequestOptions o) => o.uri.toString();

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (_applies(options)) {
      final entry = _cache.get(_key(options));
      if (entry != null) options.headers[ApiHeaders.ifNoneMatch] = entry.etag;
    }
    handler.next(options);
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    final o = response.requestOptions;
    final etag = response.headers.value(ApiHeaders.etag);
    final noStore = response.headers.value(ApiHeaders.cacheControl)?.contains('no-store') ?? false;
    if (EtagCache.isCacheablePath(o.uri.path) && o.method.toUpperCase() == 'GET' && response.statusCode == 200) {
      if (etag != null && !noStore) {
        _cache.put(_key(o), EtagEntry(etag: etag, data: response.data));
      } else {
        _cache.remove(_key(o));
      }
    }
    handler.next(response);
  }

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final o = err.requestOptions;
    if (err.response?.statusCode != 304 || !_applies(o)) return handler.next(err);
    final entry = _cache.get(_key(o));
    if (entry != null) {
      return handler.resolve(
        Response<dynamic>(
          requestOptions: o,
          data: entry.data,
          statusCode: 200,
          headers: err.response!.headers,
          extra: {RequestExtra.etagCacheHit: true},
        ),
      );
    }
    o.headers.remove(ApiHeaders.ifNoneMatch);
    o.extra[RequestExtra.etagBypass] = true;
    try {
      handler.resolve(await _dio.fetch<dynamic>(o));
    } on DioException catch (e) {
      handler.next(e);
    }
  }
}
