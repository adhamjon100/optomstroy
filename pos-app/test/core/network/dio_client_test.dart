// Интерсепторы DioClient (06 §6.7; 08 §2.2–§2.11): RequestId, ClientMeta, Auth
// (single-flight refresh), Retry (идемпотентность, без автоповтора приёма денег —
// ядро §22.6), ETag, AppVersion (RM-C-015), OnlineStatus, Logging без ПДн.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/app_version/app_version_controller.dart';
import 'package:optomstroy/core/network/auth/token_store.dart';
import 'package:optomstroy/core/network/client_meta.dart';
import 'package:optomstroy/core/network/dio_client.dart';
import 'package:optomstroy/core/network/etag_cache.dart';
import 'package:optomstroy/core/network/interceptors/auth_interceptor.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';

import '../storage/in_memory_secure_storage.dart';
import 'fake_adapter.dart';

const deviceId = '1b4e28ba-2d11-4d4f-9f4a-0c3a6f6e7d01';
const meta = ClientMeta(appVersion: '1.4.2+87', platform: ClientPlatform.android, deviceId: deviceId);
final config = AppConfig.fromMap(const {'API_BASE_URL': 'https://api.test/api/v1', 'ENV': 'staging'});

Map<String, Object?> tokenPair(String access, String refresh) => {
  'accessToken': access,
  'accessExpiresIn': 900,
  'refreshToken': refresh,
  'refreshExpiresAt': '2026-10-28T00:00:00.000Z',
  'sid': '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f55',
};

final class Harness {
  Harness(FakeHandler handler, {String? access, String? refresh, String appVersion = '1.4.2+87'}) {
    adapter = FakeAdapter(handler);
    storage = InMemorySecureStorage({SecureKey.refreshToken: ?refresh}); // check-secrets: allow (тест)
    tokens = TokenStore(storage);
    if (access != null) unawaited(tokens.saveTokens(accessToken: access, refreshToken: refresh ?? 'r0'));
    appVersionController = AppVersionController(
      currentVersion: appVersion,
      platform: 'android',
      sink: (k, v) async => persisted[k] = v,
    );
    dio = DioClient.create(
      DioClientDeps(
        config: config,
        meta: () => meta,
        tokens: tokens,
        appVersion: appVersionController,
        etagCache: etagCache,
        onOutcome: outcomes.add,
        onSessionEvent: events.add,
        adapter: adapter,
        sleep: (d) async => sleeps.add(d),
      ),
    );
  }

  late final FakeAdapter adapter;
  late final InMemorySecureStorage storage;
  late final TokenStore tokens;
  late final AppVersionController appVersionController;
  late final Dio dio;
  final EtagCache etagCache = EtagCache(maxEntries: 2);
  final List<RequestOutcome> outcomes = [];
  final List<SessionEvent> events = [];
  final List<Duration> sleeps = [];
  final Map<String, String> persisted = {};
}

Future<DioException> fails(Future<Object?> call) async {
  try {
    await call;
  } on DioException catch (e) {
    return e;
  }
  fail('ожидалась DioException');
}

void main() {
  group('RequestId + ClientMeta', () {
    test('заголовки X-Request-Id (UUIDv7), X-Device-Id, X-App-Version, X-Platform, Accept-Language', () async {
      final h = Harness((o) async => json(200, {'ok': true}));
      await h.dio.get<Object?>('/health', options: apiOptions(skipAuth: true));
      final headers = h.adapter.requests.single.headers;
      expect(headers[ApiHeaders.requestId], matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-')));
      expect(headers[ApiHeaders.deviceId], deviceId);
      expect(headers[ApiHeaders.appVersion], '1.4.2+87');
      expect(headers[ApiHeaders.platform], 'android');
      expect(headers[ApiHeaders.acceptLanguage], 'ru');
      expect(headers.containsKey(ApiHeaders.authorization), isFalse);
    });

    test('без платформы R1 заголовок X-Platform не отправляется', () async {
      final adapter = FakeAdapter((o) async => json(200, {}));
      final dio = DioClient.create(
        DioClientDeps(
          config: config,
          meta: () => const ClientMeta(appVersion: '1.0.0', platform: null, deviceId: deviceId, languageCode: 'ky'),
          tokens: TokenStore(InMemorySecureStorage()),
          appVersion: AppVersionController(currentVersion: '1.0.0', platform: null),
          etagCache: EtagCache(),
          adapter: adapter,
        ),
      );
      await dio.get<Object?>('/health', options: apiOptions(skipAuth: true));
      expect(adapter.requests.single.headers.containsKey(ApiHeaders.platform), isFalse);
      expect(adapter.requests.single.headers[ApiHeaders.acceptLanguage], 'ky');
      expect(ClientPlatform.of(TargetPlatform.windows), ClientPlatform.windows);
      expect(ClientPlatform.of(TargetPlatform.iOS), ClientPlatform.ios);
      expect(ClientPlatform.of(TargetPlatform.linux), isNull);
      expect(meta.copyWith(languageCode: 'en').languageCode, 'en');
      expect(meta.copyWith().languageCode, 'ru');
    });
  });

  group('AuthInterceptor', () {
    test('Bearer из памяти', () async {
      final h = Harness((o) async => json(200, {}), access: 'a1', refresh: 'r1');
      await h.dio.get<Object?>('/me');
      expect(h.adapter.requests.single.headers[ApiHeaders.authorization], 'Bearer a1');
    });

    test('401 TOKEN_STALE на 3 параллельных запросах → один refresh, повтор с новым токеном', () async {
      var refreshCalls = 0;
      final h = Harness(
        (o) async {
          if (o.path.endsWith('/auth/refresh')) {
            refreshCalls++;
            await Future<void>.delayed(const Duration(milliseconds: 10));
            return json(200, tokenPair('a2', 'r2'));
          }
          final auth = o.headers[ApiHeaders.authorization];
          return auth == 'Bearer a2' ? json(200, {'ok': true}) : json(401, problem('TOKEN_STALE', 401));
        },
        access: 'a1',
        refresh: 'r1',
      );
      final results = await Future.wait([for (var i = 0; i < 3; i++) h.dio.get<Object?>('/orders')]);
      expect(results.map((r) => r.statusCode), [200, 200, 200]);
      expect(refreshCalls, 1);
      expect(h.tokens.accessToken, 'a2');
      expect(await h.storage.read(SecureKey.refreshToken), 'r2');
      final refreshRequest = h.adapter.requests.firstWhere((r) => r.path == '/auth/refresh');
      expect(refreshRequest.data, {'refreshToken': 'r1'});
      expect(refreshRequest.headers.containsKey(ApiHeaders.authorization), isFalse);
    });

    test('холодный старт: access нет, refresh есть → refresh до запроса', () async {
      final h = Harness((o) async {
        if (o.path.endsWith('/auth/refresh')) return json(200, tokenPair('a9', 'r9'));
        return json(200, {});
      }, refresh: 'r1');
      await h.dio.get<Object?>('/me');
      expect(h.adapter.requests.map((r) => r.path), ['/auth/refresh', '/me']);
      expect(h.adapter.requests.last.headers[ApiHeaders.authorization], 'Bearer a9');
    });

    test('401 SESSION_REVOKED → токены удалены (deviceId сохранён), событие ended, без refresh', () async {
      final h = Harness((o) async => json(401, problem('SESSION_REVOKED', 401)), access: 'a1', refresh: 'r1');
      await h.storage.write(SecureKey.deviceId, deviceId);
      final e = await fails(h.dio.get<Object?>('/me'));
      expect(e.response?.statusCode, 401);
      expect(h.events, [SessionEvent.ended]);
      expect(h.tokens.accessToken, isNull);
      expect(await h.storage.read(SecureKey.refreshToken), isNull);
      expect(await h.storage.read(SecureKey.deviceId), deviceId);
      expect(h.adapter.countPath('/auth/refresh'), 0);
    });

    test('401 UNLOCK_REQUIRED → событие unlockRequired, refresh сохранён', () async {
      final h = Harness((o) async => json(401, problem('UNLOCK_REQUIRED', 401)), access: 'a1', refresh: 'r1');
      await fails(h.dio.get<Object?>('/me'));
      expect(h.events, [SessionEvent.unlockRequired]);
      expect(await h.storage.read(SecureKey.refreshToken), 'r1');
    });

    test('401 PIN_INVALID → refresh не вызывается (ядро §18.2 п.5)', () async {
      final h = Harness(
        (o) async => json(401, problem('PIN_INVALID', 401, extra: {'attemptsLeft': 2})),
        access: 'a1',
        refresh: 'r1',
      );
      await fails(h.dio.post<Object?>('/auth/step-up', data: {'method': 'pin'}));
      expect(h.adapter.countPath('/auth/refresh'), 0);
      expect(h.events, isEmpty);
    });

    test('refresh отклонён (401 SESSION_REVOKED) → выход', () async {
      final h = Harness(
        (o) async {
          if (o.path.endsWith('/auth/refresh')) return json(401, problem('SESSION_REVOKED', 401));
          return json(401, problem('UNAUTHENTICATED', 401));
        },
        access: 'a1',
        refresh: 'r1',
      );
      await fails(h.dio.get<Object?>('/me'));
      expect(h.events, [SessionEvent.ended]);
      expect(await h.storage.read(SecureKey.refreshToken), isNull);
    });

    test('refresh → UNLOCK_REQUIRED (Windows, D-48)', () async {
      final h = Harness(
        (o) async {
          if (o.path.endsWith('/auth/refresh')) return json(401, problem('UNLOCK_REQUIRED', 401));
          return json(401, problem('TOKEN_STALE', 401));
        },
        access: 'a1',
        refresh: 'r1',
      );
      await fails(h.dio.get<Object?>('/me'));
      expect(h.events, [SessionEvent.unlockRequired]);
      expect(await h.storage.read(SecureKey.refreshToken), 'r1');
    });

    test('refresh недоступен (сеть) → исходная ошибка, токены сохранены', () async {
      final h = Harness(
        (o) async {
          if (o.path.endsWith('/auth/refresh')) transportError(o, DioExceptionType.connectionError);
          return json(401, problem('TOKEN_STALE', 401));
        },
        access: 'a1',
        refresh: 'r1',
      );
      final e = await fails(h.dio.get<Object?>('/me', options: apiOptions(retry: RetryProfile.none)));
      expect(e.response?.statusCode, 401);
      expect(h.events, isEmpty);
      expect(await h.storage.read(SecureKey.refreshToken), 'r1');
    });

    test('нет refresh-токена → ended', () async {
      final h = Harness((o) async => json(401, problem('UNAUTHENTICATED', 401)), access: 'a1');
      await h.storage.delete(SecureKey.refreshToken);
      await fails(h.dio.get<Object?>('/me'));
      expect(h.events, [SessionEvent.ended]);
    });

    test('повтор после refresh снова 401 → без второго refresh', () async {
      final h = Harness(
        (o) async {
          if (o.path.endsWith('/auth/refresh')) return json(200, tokenPair('a2', 'r2'));
          return json(401, problem('TOKEN_STALE', 401));
        },
        access: 'a1',
        refresh: 'r1',
      );
      await fails(h.dio.get<Object?>('/me'));
      expect(h.adapter.countPath('/auth/refresh'), 1);
      expect(h.adapter.countPath('/me'), 2);
    });

    test('токен уже обновлён параллельно → повтор без нового refresh', () async {
      late Harness h;
      h = Harness(
        (o) async {
          if (o.headers[ApiHeaders.authorization] == 'Bearer a1') {
            await h.tokens.saveTokens(accessToken: 'a3', refreshToken: 'r3');
            return json(401, problem('TOKEN_STALE', 401));
          }
          return json(200, {});
        },
        access: 'a1',
        refresh: 'r1',
      );
      final r = await h.dio.get<Object?>('/me');
      expect(r.statusCode, 200);
      expect(h.adapter.countPath('/auth/refresh'), 0);
      expect(h.adapter.requests.last.headers[ApiHeaders.authorization], 'Bearer a3');
    });

    test('публичный эндпоинт: 401 без обработки', () async {
      final h = Harness((o) async => json(401, problem('UNAUTHENTICATED', 401)), access: 'a1', refresh: 'r1');
      await fails(h.dio.post<Object?>('/auth/otp/verify', options: apiOptions(skipAuth: true)));
      expect(h.adapter.countPath('/auth/refresh'), 0);
      expect(h.adapter.requests.single.headers.containsKey(ApiHeaders.authorization), isFalse);
    });
  });

  group('RetryInterceptor', () {
    test('GET 503 без problem → повтор с backoff, тот же X-Request-Id', () async {
      var n = 0;
      final h = Harness((o) async => ++n < 3 ? json(503, null) : json(200, {}), access: 'a');
      final r = await h.dio.get<Object?>('/catalog/categories');
      expect(r.statusCode, 200);
      expect(h.adapter.requests, hasLength(3));
      expect(h.sleeps, hasLength(2));
      expect(h.sleeps[0].inMilliseconds, inInclusiveRange(1000, 1200));
      expect(h.sleeps[1].inMilliseconds, inInclusiveRange(2000, 2400));
      expect(h.adapter.requests.map((r) => r.headers[ApiHeaders.requestId]).toSet(), hasLength(1));
    });

    test('интерактивный профиль — не более 2 повторов; фоновый — 4', () async {
      final h = Harness((o) async => transportError(o, DioExceptionType.connectionError), access: 'a');
      await fails(h.dio.get<Object?>('/catalog/products'));
      expect(h.adapter.requests, hasLength(3));
      final bg = Harness((o) async => transportError(o, DioExceptionType.connectionTimeout), access: 'a');
      await fails(bg.dio.get<Object?>('/catalog/products', options: apiOptions(retry: RetryProfile.background)));
      expect(bg.adapter.requests, hasLength(5));
      expect(bg.sleeps.last.inMilliseconds, inInclusiveRange(8000, 9600));
    });

    test('POST без Idempotency-Key не повторяется', () async {
      final h = Harness((o) async => transportError(o, DioExceptionType.receiveTimeout), access: 'a');
      await fails(h.dio.post<Object?>('/auth/otp/request', data: {}));
      expect(h.adapter.requests, hasLength(1));
    });

    test('POST /orders с ключом — повтор с тем же ключом (DATA-263)', () async {
      var n = 0;
      final h = Harness(
        (o) async => ++n == 1 ? transportError(o, DioExceptionType.receiveTimeout) : json(201, {}),
        access: 'a',
      );
      const key = '0f8fad5b-d9cb-469f-a165-70867728950e';
      await h.dio.post<Object?>(
        '/orders',
        data: {},
        options: apiOptions(idempotencyKey: key),
      );
      expect(h.adapter.requests.map((r) => r.headers[ApiHeaders.idempotencyKey]), [key, key]);
    });

    test('приём денег не повторяется автоматически даже с ключом (ядро §22.6)', () async {
      for (final path in ['/orders/o1/payments', '/payments', '/payments/p1/confirm-manual', '/payments/p1/void']) {
        final h = Harness((o) async => transportError(o, DioExceptionType.receiveTimeout), access: 'a');
        await fails(
          h.dio.post<Object?>(
            path,
            data: {},
            options: apiOptions(idempotencyKey: 'k'),
          ),
        );
        expect(h.adapter.requests, hasLength(1), reason: path);
      }
    });

    test('PUT /cart/items mode=increment без ключа не повторяется; mode=set — повторяется', () async {
      final inc = Harness((o) async => json(502, null), access: 'a');
      await fails(inc.dio.put<Object?>('/cart/items/v1', data: {'mode': 'increment'}));
      expect(inc.adapter.requests, hasLength(1));
      final set = Harness((o) async => json(502, null), access: 'a');
      await fails(set.dio.put<Object?>('/cart/items/v1', data: {'mode': 'set'}));
      expect(set.adapter.requests, hasLength(3));
      final incKey = Harness((o) async => json(504, null), access: 'a');
      await fails(
        incKey.dio.put<Object?>(
          '/cart/items/v1',
          data: {'mode': 'increment'},
          options: apiOptions(idempotencyKey: 'k'),
        ),
      );
      expect(incKey.adapter.requests, hasLength(3));
    });

    test('429 и 409 IDEMPOTENCY_IN_PROGRESS — по Retry-After; слишком долгий Retry-After не выжидается', () async {
      var n = 0;
      final h = Harness(
        (o) async => ++n == 1 ? json(429, problem('RATE_LIMITED', 429), headers: {'Retry-After': '3'}) : json(200, {}),
        access: 'a',
      );
      await h.dio.get<Object?>('/catalog/products');
      expect(h.sleeps, [const Duration(seconds: 3)]);

      var m = 0;
      final idem = Harness(
        (o) async =>
            ++m == 1 ? json(409, problem('IDEMPOTENCY_IN_PROGRESS', 409, extra: {'retryAfter': 2})) : json(201, {}),
        access: 'a',
      );
      await idem.dio.post<Object?>(
        '/orders',
        data: {},
        options: apiOptions(idempotencyKey: 'k'),
      );
      expect(idem.sleeps, [const Duration(seconds: 2)]);

      final long = Harness(
        (o) async => json(429, problem('RATE_LIMITED', 429), headers: {'Retry-After': '120'}),
        access: 'a',
      );
      await fails(long.dio.get<Object?>('/catalog/products'));
      expect(long.adapter.requests, hasLength(1));
    });

    test('не повторяются: 4xx бизнес, 409 VERSION_CONFLICT, 503 ONEC_UNAVAILABLE, отмена, long-poll таймаут', () async {
      for (final body in [
        json(422, problem('PRICE_CHANGED', 422)),
        json(409, problem('VERSION_CONFLICT', 409)),
        json(503, problem('ONEC_UNAVAILABLE', 503)),
        json(500, problem('INTERNAL', 500)),
      ]) {
        final h = Harness((o) async => body, access: 'a');
        await fails(h.dio.get<Object?>('/cart'));
        expect(h.adapter.requests, hasLength(1));
      }
      final lp = Harness((o) async => transportError(o, DioExceptionType.receiveTimeout), access: 'a');
      await fails(lp.dio.get<Object?>('/payments/p1', options: apiOptions(longPoll: true)));
      expect(lp.adapter.requests, hasLength(1));
      final cancel = Harness((o) async => transportError(o, DioExceptionType.cancel), access: 'a');
      await fails(cancel.dio.get<Object?>('/search/products'));
      expect(cancel.adapter.requests, hasLength(1));
      final none = Harness((o) async => json(502, null), access: 'a');
      await fails(none.dio.get<Object?>('/x', options: apiOptions(retry: RetryProfile.none)));
      expect(none.adapter.requests, hasLength(1));
    });

    test('прочие методы не повторяются', () async {
      final h = Harness((o) async => json(502, null), access: 'a');
      await fails(h.dio.request<Object?>('/x', options: Options(method: 'TRACE')));
      expect(h.adapter.requests, hasLength(1));
    });
  });

  group('EtagInterceptor', () {
    test('ETag сохраняется, If-None-Match отправляется, 304 → тело из кэша', () async {
      var n = 0;
      final h = Harness((o) async {
        n++;
        if (n == 1) {
          return json(
            200,
            {
              'items': [1],
            },
            headers: {'ETag': '"v1"'},
          );
        }
        expect(o.headers[ApiHeaders.ifNoneMatch], '"v1"');
        return json(304, null);
      }, access: 'a');
      await h.dio.get<Object?>('/catalog/categories');
      final r = await h.dio.get<Object?>('/catalog/categories');
      expect(r.statusCode, 200);
      expect(r.data, {
        'items': [1],
      });
      expect(r.extra[RequestExtra.etagCacheHit], isTrue);
    });

    test('/me и no-store не кэшируются; LRU ограничен', () async {
      final h = Harness((o) async {
        final noStore = o.path.contains('nostore');
        return json(200, {'p': o.path}, headers: {'ETag': '"e"', if (noStore) 'Cache-Control': 'no-store'});
      }, access: 'a');
      await h.dio.get<Object?>('/me');
      await h.dio.get<Object?>('/catalog/nostore');
      expect(h.etagCache.length, 0);
      await h.dio.get<Object?>('/catalog/a');
      await h.dio.get<Object?>('/catalog/b');
      await h.dio.get<Object?>('/catalog/c');
      expect(h.etagCache.length, 2);
      h.etagCache.clear();
      expect(h.etagCache.length, 0);
    });

    test('304 без записи в кэше → повтор без If-None-Match', () async {
      var n = 0;
      final h = Harness((o) async => ++n == 1 ? json(304, null) : json(200, {'fresh': true}), access: 'a');
      final r = await h.dio.get<Object?>('/catalog/units');
      expect(r.data, {'fresh': true});
      expect(h.adapter.requests.last.headers.containsKey(ApiHeaders.ifNoneMatch), isFalse);
    });

    test('ответ 200 без ETag удаляет старую запись', () async {
      var n = 0;
      final h = Harness((o) async => ++n == 1 ? json(200, {}, headers: {'ETag': '"x"'}) : json(200, {}), access: 'a');
      await h.dio.get<Object?>('/settings/public', options: apiOptions(skipAuth: true));
      expect(h.etagCache.length, 1);
      await h.dio.get<Object?>('/settings/public', options: apiOptions(skipAuth: true));
      expect(h.etagCache.length, 0);
    });

    test('304 для не-каталога передаётся вызывающему', () async {
      final h = Harness((o) async => json(304, null), access: 'a');
      final e = await fails(h.dio.get<Object?>('/orders/o1/documents/invoice.pdf'));
      expect(e.response?.statusCode, 304);
    });
  });

  group('AppVersionInterceptor (RM-C-015)', () {
    test('X-Recommended-App-Version выше текущей → мягкий баннер; значения сохраняются в app_meta', () async {
      final h = Harness(
        (o) async => json(
          200,
          {},
          headers: {'X-Min-App-Version': 'android=1.2.0', 'X-Recommended-App-Version': 'android=1.5.0'},
        ),
        access: 'a',
      );
      await h.dio.get<Object?>('/me');
      expect(h.appVersionController.value.status, AppVersionStatus.updateRecommended);
      expect(h.appVersionController.value.recommended, '1.5.0');
      expect(h.persisted, {'min_app_version_seen': '1.2.0', 'recommended_app_version_seen': '1.5.0'});
    });

    test('426 APP_UPDATE_REQUIRED → требуется обновление (блокирующий SCR-90)', () async {
      final h = Harness(
        (o) async => json(
          426,
          problem('APP_UPDATE_REQUIRED', 426, extra: {'minVersion': '2.0.0'}),
          headers: {'X-Min-App-Version': 'android=2.0.0'},
        ),
        access: 'a',
      );
      final e = await fails(h.dio.get<Object?>('/catalog/products'));
      expect(h.adapter.requests, hasLength(1), reason: '426 не повторяется');
      expect(e.response?.statusCode, 426);
      expect(
        h.appVersionController.value,
        const AppVersionState(status: AppVersionStatus.updateRequired, minimum: '2.0.0'),
      );
      expect(h.persisted['min_app_version_seen'], '2.0.0');
    });

    test('426 без заголовка — версия из тела; ошибка с заголовками версии тоже учитывается', () async {
      final h = Harness(
        (o) async => json(426, problem('APP_UPDATE_REQUIRED', 426, extra: {'minVersion': 'android=1.9.0'})),
        access: 'a',
      );
      await fails(h.dio.get<Object?>('/me'));
      expect(h.appVersionController.value.minimum, '1.9.0');
      final h2 = Harness(
        (o) async => json(404, problem('NOT_FOUND', 404), headers: {'X-Min-App-Version': 'android=1.0.0'}),
        access: 'a',
      );
      await fails(h2.dio.get<Object?>('/me'));
      expect(h2.appVersionController.value.status, AppVersionStatus.ok);
      expect(h2.persisted['min_app_version_seen'], '1.0.0');
    });
  });

  group('OnlineStatusInterceptor', () {
    test('ответ → responded; нет соединения → connectionFailed; 504/таймаут → serverUnavailable', () async {
      final h = Harness((o) async => json(200, {}), access: 'a');
      await h.dio.get<Object?>('/me');
      expect(h.outcomes, [RequestOutcome.responded]);

      final off = Harness((o) async => transportError(o, DioExceptionType.connectionError), access: 'a');
      await fails(off.dio.get<Object?>('/me', options: apiOptions(retry: RetryProfile.none)));
      expect(off.outcomes, [RequestOutcome.connectionFailed]);

      final gw = Harness((o) async => json(504, null), access: 'a');
      await fails(gw.dio.get<Object?>('/me', options: apiOptions(retry: RetryProfile.none)));
      expect(gw.outcomes, [RequestOutcome.serverUnavailable]);

      final onec = Harness((o) async => json(503, problem('ONEC_UNAVAILABLE', 503)), access: 'a');
      await fails(onec.dio.get<Object?>('/me'));
      expect(onec.outcomes, [RequestOutcome.responded]);

      final timeout = Harness((o) async => transportError(o, DioExceptionType.receiveTimeout), access: 'a');
      await fails(timeout.dio.get<Object?>('/payments/p', options: apiOptions(longPoll: true)));
      expect(timeout.outcomes, isEmpty, reason: 'long-poll таймаут не меняет статус');
      await fails(timeout.dio.get<Object?>('/me', options: apiOptions(retry: RetryProfile.none)));
      expect(timeout.outcomes, [RequestOutcome.serverUnavailable]);
    });
  });

  group('LoggingInterceptor', () {
    test('в журнале нет тел, токенов, телефонов и значений query', () async {
      final records = <LogRecord>[];
      Logger.root.level = Level.ALL;
      final sub = Logger.root.onRecord.listen(records.add);
      final h = Harness(
        (o) async {
          if (o.path.endsWith('/auth/otp/request')) return json(422, problem('OTP_INVALID', 422));
          return json(200, {'phone': '+996555123456'});
        },
        access: 'secret-access-token',
        refresh: 'r1',
      );
      await h.dio.get<Object?>('/search/customers', queryParameters: {'q': '+996555123456', 'limit': 5});
      await fails(h.dio.post<Object?>('/auth/otp/request', data: {'phone': '+996555123456', 'code': '123456'}));
      await sub.cancel();
      final text = records.map((r) => r.message).join('\n');
      expect(text, contains('/search/customers ?[limit,q]'));
      expect(text, contains('OTP_INVALID'));
      for (final secret in ['555123456', 'secret-access-token', '123456', 'Bearer']) {
        expect(text, isNot(contains(secret)));
      }
    });
  });
}
