// Интерсепторы основного Dio в режиме «Планшет магазина» (13 TAB-2-10; 08 §2.3, §2.4; 09 §8.9 п. 8; navigation.md
// §4.3; ADR-115 п. 26): `401 KIOSK_REVOKED` — без refresh и без переписывания кода в `REFRESH_REJECTED` (на запросе и
// на ответе самого `/auth/refresh`); истечение срока — `SESSION_REVOKED` и «Подключите заново»; `403 KIOSK_*` —
// состояние SCR-51 без отзыва сессии; заголовок `X-Kiosk-Lock` по `KioskLock.status` на каждом запросе сессии планшета.
// Трассировка: 12 T-KIOSK-060, T-KIOSK-068; 10 KIOSK-004, KIOSK-024, KIOSK-031; 02 AC-UI-51-012.
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/hardware/kiosk_lock.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/auth/token_refresher.dart';
import 'package:optomstroy/core/network/auth/token_store.dart';
import 'package:optomstroy/core/network/interceptors/auth_interceptor.dart';
import 'package:optomstroy/core/network/interceptors/client_meta_interceptor.dart';
import 'package:optomstroy/core/network/models/auth_token_pair.dart';
import 'package:optomstroy/core/session/kiosk_exit_code_hash.dart';
import 'package:optomstroy/core/session/kiosk_marker.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/session/session_overlay.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/core/session/session_status.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';

import '../../features/kiosk/kiosk_lifecycle_support.dart';
import '../storage/in_memory_secure_storage.dart';

/// Хуки сессии без контроллера: запоминают сигналы конца сессии и ответы планшету.
final class _RecordingHooks implements AuthSessionHooks, KioskSessionHooks {
  final List<SessionEndSignal> ended = <SessionEndSignal>[];
  final List<(String, String?)> forbidden = <(String, String?)>[];
  int succeeded = 0;
  final List<String> succeededPaths = <String>[];
  bool kiosk = true;

  @override
  bool get isLocked => false;

  @override
  Future<bool> waitUntilUnlocked() async => true;

  @override
  Future<bool> unlockRequired() async => false;

  @override
  void sessionEnded(SessionEndSignal signal) => ended.add(signal);

  @override
  String? stepUpTokenFor(String operation) => null;

  @override
  void discardStepUpToken(String operation, String token) {}

  @override
  Future<String?> requestStepUp(StepUpChallenge challenge) async => null;

  @override
  bool get isKioskSession => kiosk;

  @override
  void kioskForbidden(String code, String? reason) => forbidden.add((code, reason));

  @override
  void kioskRequestSucceeded(String path) {
    succeeded++;
    succeededPaths.add(path);
  }
}

/// Refresh-клиент со счётчиком вызовов.
final class _CountingRefresher implements TokenRefresher {
  _CountingRefresher(this._result);

  final RefreshResult _result;
  int calls = 0;

  @override
  Future<RefreshResult> refresh(String refreshToken) async {
    calls++;
    return _result;
  }
}

/// Dio с одним AuthInterceptor поверх [FakeAdapter].
(Dio, AuthInterceptor, FakeAdapter) _authDio(TokenStore tokens, TokenRefresher refresher, FakeHandler handler) {
  final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.test/api/v1'));
  final FakeAdapter adapter = FakeAdapter(handler);
  dio.httpClientAdapter = adapter;
  final AuthInterceptor auth = AuthInterceptor(dio: dio, tokens: tokens, refresher: refresher);
  dio.interceptors.add(auth);
  return (dio, auth, adapter);
}

void main() {
  group('T-KIOSK-060 no second refresh, code preserved', () {
    test('T-KIOSK-060: 401 KIOSK_REVOKED на запрос → refresh не вызывается, сигнал с кодом KIOSK_REVOKED', () async {
      final TokenStore tokens = TokenStore(InMemorySecureStorage());
      await tokens.saveTokens(accessToken: kioskJwt(), refreshToken: 'rk1');
      final _CountingRefresher refresher = _CountingRefresher(RefreshSucceeded(_pair()));
      final (Dio dio, AuthInterceptor auth, FakeAdapter adapter) = _authDio(
        tokens,
        refresher,
        (RequestOptions o) async => json(401, problem('KIOSK_REVOKED', 401)),
      );
      final _RecordingHooks hooks = _RecordingHooks();
      auth.attachHooks(hooks);
      final DioException e = await fails(dio.get<Object?>('/cart'));
      expect(e.response?.statusCode, 401);
      expect(refresher.calls, 0, reason: 'refresh на KIOSK_REVOKED не вызывается');
      expect(adapter.requests, hasLength(1), reason: 'исходный запрос не повторяется');
      expect(hooks.ended.single.code, 'KIOSK_REVOKED');
      expect(await tokens.readRefreshToken(), isNull);
    });

    test(
      'T-KIOSK-060: access истёк → refresh отвечает 401 KIOSK_REVOKED → код сохранён (не REFRESH_REJECTED), второго refresh нет',
      () async {
        final TokenStore tokens = TokenStore(InMemorySecureStorage());
        // Access истёк (простой дольше 900 с) — заблаговременный refresh перед запросом.
        await tokens.saveTokens(
          accessToken: kioskJwt(exp: DateTime.now().toUtc().subtract(const Duration(minutes: 1))),
          refreshToken: 'rk1',
        );
        final _CountingRefresher refresher = _CountingRefresher(const RefreshSessionEnded(code: 'KIOSK_REVOKED'));
        final (Dio dio, AuthInterceptor auth, FakeAdapter _) = _authDio(
          tokens,
          refresher,
          (RequestOptions o) async => o.headers[ApiHeaders.authorization] == null
              ? json(401, problem('UNAUTHENTICATED', 401))
              : json(200, <String, Object?>{'ok': true}),
        );
        final _RecordingHooks hooks = _RecordingHooks();
        auth.attachHooks(hooks);
        await fails(dio.get<Object?>('/cart'));
        expect(refresher.calls, 1, reason: 'второго обращения к /auth/refresh нет');
        expect(hooks.ended.first.code, 'KIOSK_REVOKED');
        expect(hooks.ended.map((SessionEndSignal s) => s.code), isNot(contains('SESSION_REVOKED')));
      },
    );

    test('T-KIOSK-060: сессия планшета — refresh 401 KIOSK_REVOKED → «Планшет отключён», закрепление снято', () async {
      final FakeKioskLock lock = FakeKioskLock(locked: true);
      final SessionHarness h = kioskHarness((RequestOptions o) async {
        if (o.path.endsWith('/auth/refresh')) return json(401, problem('KIOSK_REVOKED', 401));
        return o.headers[ApiHeaders.authorization] == null
            ? json(401, problem('UNAUTHENTICATED', 401))
            : json(200, <String, Object?>{'ok': true});
      }, lock: lock);
      addTearDown(h.dispose);
      h.start();
      await h.container.read(sessionStatusProvider.future);
      await fails(h.dio.get<Object?>('/cart'));
      await settle();
      expect(h.adapter.countPath('/auth/refresh'), 1);
      expect(h.state.endReason, SessionEndReason.kioskRevoked);
      expect(h.state.kioskRevokedNotice, isTrue);
      expect(h.storage.values[SecureKey.kioskTabletId], isNull);
      expect(lock.count('disable'), 1);
    });

    test(
      'T-KIOSK-060: срок сессии вышел — refresh 401 SESSION_REVOKED expired → «Подключите заново», закрепление остаётся',
      () async {
        final FakeKioskLock lock = FakeKioskLock(locked: true);
        final SessionHarness h = kioskHarness((RequestOptions o) async {
          if (o.path.endsWith('/auth/refresh')) {
            return json(401, problem('SESSION_REVOKED', 401, extra: <String, Object?>{'reason': 'expired'}));
          }
          return o.headers[ApiHeaders.authorization] == null
              ? json(401, problem('UNAUTHENTICATED', 401))
              : json(200, <String, Object?>{'ok': true});
        }, lock: lock);
        addTearDown(h.dispose);
        h.start();
        await h.container.read(sessionStatusProvider.future);
        await fails(h.dio.get<Object?>('/cart'));
        await settle();
        expect(h.adapter.countPath('/auth/refresh'), 1);
        expect(h.state.endReason, SessionEndReason.expired);
        expect(h.state.kioskReconnectNeeded, isTrue);
        expect(h.storage.values[SecureKey.kioskTabletId], kioskTabletId);
        expect(lock.count('disable'), 0);
      },
    );

    test('прочие отказы refresh — по-прежнему REFRESH_REJECTED (паритет)', () async {
      final TokenStore tokens = TokenStore(InMemorySecureStorage());
      await tokens.saveTokens(
        accessToken: kioskJwt(exp: DateTime.utc(2020)),
        refreshToken: 'r1',
      );
      final _CountingRefresher refresher = _CountingRefresher(const RefreshSessionEnded(code: 'VALIDATION_FAILED'));
      final (Dio dio, AuthInterceptor auth, FakeAdapter _) = _authDio(
        tokens,
        refresher,
        (RequestOptions o) async => json(401, problem('UNAUTHENTICATED', 401)),
      );
      final _RecordingHooks hooks = _RecordingHooks();
      auth.attachHooks(hooks);
      await fails(dio.get<Object?>('/me'));
      expect(hooks.ended.first.code, SessionEndSignal.refreshRejected);
    });
  });

  group('403 KIOSK_* — состояние SCR-51 без отзыва сессии', () {
    test(
      'KIOSK_NETWORK_DENIED / KIOSK_DISABLED / FORBIDDEN kiosk_warehouse_unavailable → доступ планшета; 200 → снова витрина',
      () async {
        var answer = json(403, problem('KIOSK_NETWORK_DENIED', 403));
        final SessionHarness h = kioskHarness((RequestOptions o) async {
          if (o.path.endsWith('/auth/refresh')) return json(200, tokenPair(kioskJwt(tag: 'r'), 'rk2'));
          return answer;
        }, lock: FakeKioskLock());
        addTearDown(h.dispose);
        h.start();
        await h.container.read(sessionStatusProvider.future);
        await fails(h.dio.get<Object?>('/cart'));
        expect(h.container.read(kioskAccessProvider), KioskAccess.networkDenied);
        expect(h.state.isKioskSession, isTrue, reason: 'сессия не отзывается');
        expect(h.storage.values[SecureKey.refreshToken], isNotNull);

        answer = json(200, <String, Object?>{'ok': true});
        await h.dio.get<Object?>('/cart');
        expect(h.container.read(kioskAccessProvider), KioskAccess.allowed, reason: 'первый успешный ответ — витрина');

        answer = json(403, problem('KIOSK_DISABLED', 403));
        await fails(h.dio.get<Object?>('/cart'));
        expect(h.container.read(kioskAccessProvider), KioskAccess.disabled);

        answer = json(200, <String, Object?>{'ok': true});
        await h.dio.get<Object?>('/cart');
        answer = json(
          403,
          problem('FORBIDDEN', 403, extra: <String, Object?>{'reason': 'kiosk_warehouse_unavailable'}),
        );
        await fails(h.dio.get<Object?>('/catalog/products'));
        expect(h.container.read(kioskAccessProvider), KioskAccess.warehouseUnavailable);

        // Прочий 403 (например, `kiosk_closed_list`) — ошибка экрана, а не состояние планшета.
        answer = json(200, <String, Object?>{'ok': true});
        await h.dio.get<Object?>('/cart');
        answer = json(403, problem('FORBIDDEN', 403, extra: <String, Object?>{'reason': 'kiosk_closed_list'}));
        await fails(h.dio.get<Object?>('/orders'));
        expect(h.container.read(kioskAccessProvider), KioskAccess.allowed);
      },
    );

    test('SCR-51.7: «склад планшета недоступен» снимает только запрос по складу — 2xx /settings/public и /me его не '
        'снимают, 2xx /catalog/categories снимает; KIOSK_DISABLED и KIOSK_NETWORK_DENIED снимает любой 2xx', () async {
      ResponseBody Function() answer = () =>
          json(403, problem('FORBIDDEN', 403, extra: <String, Object?>{'reason': 'kiosk_warehouse_unavailable'}));
      final SessionHarness h = kioskHarness((RequestOptions o) async {
        if (o.path.endsWith('/auth/refresh')) return json(200, tokenPair(kioskJwt(tag: 'r'), 'rk2'));
        return answer();
      }, lock: FakeKioskLock());
      addTearDown(h.dispose);
      h.start();
      await h.container.read(sessionStatusProvider.future);
      await fails(h.dio.get<Object?>('/cart'));
      expect(h.container.read(kioskAccessProvider), KioskAccess.warehouseUnavailable);
      expect(h.container.read(kioskStatusProvider), KioskStatus.unavailable);

      answer = () => json(200, <String, Object?>{'ok': true});
      await h.dio.get<Object?>('/settings/public');
      await h.dio.get<Object?>('/me');
      await h.dio.get<Object?>('/catalog/units');
      expect(
        h.container.read(kioskAccessProvider),
        KioskAccess.warehouseUnavailable,
        reason: 'heartbeat GET /settings/public не возвращает витрину каждые 4 мин',
      );
      await h.dio.get<Object?>('/catalog/categories', queryParameters: <String, Object?>{'depth': 1});
      expect(h.container.read(kioskAccessProvider), KioskAccess.allowed);

      for (final String code in <String>['KIOSK_DISABLED', 'KIOSK_NETWORK_DENIED']) {
        await settle();
        answer = () => json(403, problem(code, 403));
        await fails(h.dio.get<Object?>('/cart'));
        expect(h.container.read(kioskAccessProvider), isNot(KioskAccess.allowed), reason: code);
        answer = () => json(200, <String, Object?>{'ok': true});
        await h.dio.get<Object?>('/settings/public');
        expect(h.container.read(kioskAccessProvider), KioskAccess.allowed, reason: '$code: первый успешный ответ');
      }
    });

    test('пути по складу планшета: каталог, поиск, остатки, корзина, сброс, заявка — да; настройки, /me, единицы, '
        'склады — нет', () {
      for (final String path in <String>[
        '/catalog/categories',
        '/catalog/products',
        '/catalog/products/p-1',
        '/search/products',
        '/search/suggest',
        '/inventory/balances',
        '/cart',
        '/cart/items/v-1',
        '/cart/checkout-preview',
        '/kiosk/reset',
        '/kiosk/orders',
        'https://api.test/api/v1/catalog/products?limit=50',
      ]) {
        expect(kioskWarehouseScopedPath(path), isTrue, reason: path);
      }
      for (final String path in <String>[
        '/settings/public',
        '/me',
        '/catalog/units',
        '/catalog/warehouses',
        '/kiosk/order-otp',
        '/kiosk/exit',
        '/auth/refresh',
        '/carts',
      ]) {
        expect(kioskWarehouseScopedPath(path), isFalse, reason: path);
      }
    });

    test('сотрудник: 403 KIOSK_DISABLED не меняет доступ планшета (паритет)', () async {
      final SessionHarness h = SessionHarness(
        (RequestOptions o) async => json(403, problem('KIOSK_DISABLED', 403)),
        overrides: kioskOverrides(FakeKioskLock()),
      );
      addTearDown(h.dispose);
      await h.start().establish(accessToken: fakeJwt(), refreshToken: 'r1');
      await fails(h.dio.get<Object?>('/admin/store-tablets'));
      expect(h.container.read(kioskAccessProvider), KioskAccess.allowed);
      expect(h.state.status, SessionStatus.authenticated);
    });

    test('хуки интерсептора: 403 и 2xx сообщаются только для сессии планшета', () async {
      final TokenStore tokens = TokenStore(InMemorySecureStorage());
      await tokens.saveTokens(accessToken: kioskJwt(), refreshToken: 'rk1');
      var status = 403;
      final (Dio dio, AuthInterceptor auth, FakeAdapter _) = _authDio(
        tokens,
        _CountingRefresher(
          RefreshTransientFailure(DioException(requestOptions: RequestOptions(path: '/auth/refresh'))),
        ),
        (RequestOptions o) async =>
            status == 403 ? json(403, problem('KIOSK_DISABLED', 403)) : json(200, <String, Object?>{'ok': true}),
      );
      final _RecordingHooks hooks = _RecordingHooks();
      auth.attachHooks(hooks);
      await fails(dio.get<Object?>('/kiosk/orders'));
      status = 200;
      await dio.get<Object?>('/cart');
      expect(hooks.forbidden, <(String, String?)>[('KIOSK_DISABLED', null)]);
      expect(hooks.succeeded, 1);
      hooks.kiosk = false;
      await dio.get<Object?>('/cart');
      status = 403;
      await fails(dio.get<Object?>('/cart'));
      expect(hooks.succeeded, 1);
      expect(hooks.forbidden, hasLength(1));
    });
  });

  group('T-KIOSK-068 X-Kiosk-Lock from KioskLock.status (NoKioskLock → off)', () {
    test('T-KIOSK-068: NoKioskLock → X-Kiosk-Lock: off на каждом запросе сессии планшета', () async {
      final SessionHarness h = SessionHarness(
        (RequestOptions o) async => o.path.endsWith('/auth/refresh')
            ? json(200, tokenPair(kioskJwt(tag: 'r'), 'rk2'))
            : json(200, <String, Object?>{'ok': true}),
        refresh: 'rk1',
        // Порт по умолчанию — NoKioskLock (Windows, веб, тесты).
        overrides: <Override>[kioskExitCodeStoreProvider.overrideWith(fastExitStore)],
      );
      writeKioskMarker(h.storage.values);
      addTearDown(h.dispose);
      final SessionController c = h.start();
      expect(ClientMetaInterceptor.of(h.dio)!.kioskLock, isNotNull, reason: 'источник подключён контроллером');
      await h.container.read(sessionStatusProvider.future);
      await settle();
      for (final String path in <String>['/settings/public', '/catalog/products', '/cart', '/kiosk/exit']) {
        await h.dio.get<Object?>(path);
        expect(h.adapter.requests.last.headers[ApiHeaders.kioskLock], 'off', reason: path);
      }
      expect(const NoKioskLock(), isA<KioskLock>());
      // Конец режима — заголовка больше нет.
      await c.endKiosk(SessionEndReason.kioskExited);
      await h.dio.get<Object?>('/settings/public');
      expect(h.adapter.requests.last.headers.containsKey(ApiHeaders.kioskLock), isFalse);
    });

    test('T-KIOSK-068: полное закрепление → on; снимок обновляется по refreshKioskLockStatus', () async {
      final FakeKioskLock lock = FakeKioskLock(locked: true);
      final SessionHarness h = kioskHarness(
        (RequestOptions o) async => o.path.endsWith('/auth/refresh')
            ? json(200, tokenPair(kioskJwt(tag: 'r'), 'rk2'))
            : json(200, <String, Object?>{'ok': true}),
        lock: lock,
      );
      addTearDown(h.dispose);
      final SessionController c = h.start();
      await h.container.read(sessionStatusProvider.future);
      await settle();
      await h.dio.get<Object?>('/cart');
      expect(h.adapter.requests.last.headers[ApiHeaders.kioskLock], 'on');
      lock.locked = false;
      await c.refreshKioskLockStatus();
      await h.dio.get<Object?>('/cart');
      expect(h.adapter.requests.last.headers[ApiHeaders.kioskLock], 'off');
    });

    test('T-KIOSK-068: до первого снимка и у сотрудника заголовка нет', () async {
      final ClientMetaInterceptor meta = ClientMetaInterceptor(
        () => throw StateError('метаданные не нужны для проверки источника'),
      );
      expect(meta.kioskLock, isNull);

      final SessionHarness staff = SessionHarness(
        (RequestOptions o) async => json(200, <String, Object?>{'ok': true}),
        overrides: kioskOverrides(FakeKioskLock(locked: true)),
      );
      addTearDown(staff.dispose);
      await staff.start().establish(accessToken: fakeJwt(), refreshToken: 'r1');
      await staff.dio.get<Object?>('/me');
      expect(staff.adapter.requests.last.headers.containsKey(ApiHeaders.kioskLock), isFalse);

      // Планшет без сессии («Подключите заново») — заголовка нет.
      final SessionHarness reconnect = kioskHarness(
        (RequestOptions o) async => json(200, <String, Object?>{'ok': true}),
        lock: FakeKioskLock(locked: true),
        refresh: null,
      );
      addTearDown(reconnect.dispose);
      reconnect.start();
      await reconnect.container.read(sessionStatusProvider.future);
      await reconnect.dio.get<Object?>('/settings/public');
      expect(reconnect.adapter.requests.last.headers.containsKey(ApiHeaders.kioskLock), isFalse);
    });
  });
}

AuthTokenPair _pair() => AuthTokenPair.fromJson(tokenPair(kioskJwt(tag: 'n'), 'rk2'));
