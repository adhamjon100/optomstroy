// RM-D-015 (Flutter): `GET /settings/public` — кэш в `app_meta`, ETag/304, обновление, флаги `features`
// важнее флагов сборки, `customerStockDisplay` (08 §4.23.1, API-157, API-180; ядро §19.2, §24.2).
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/app_version/app_version_controller.dart';
import 'package:optomstroy/core/network/auth/token_store.dart';
import 'package:optomstroy/core/network/client_meta.dart';
import 'package:optomstroy/core/network/dio_client.dart';
import 'package:optomstroy/core/network/etag_cache.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/core/session/session_status.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/core/utils/clock.dart';

import '../database/test_database.dart';
import '../network/fake_adapter.dart';
import '../storage/in_memory_secure_storage.dart';

const ClientMeta _meta = ClientMeta(
  appVersion: '1.4.2+87',
  platform: ClientPlatform.windows,
  deviceId: '1b4e28ba-2d11-4d4f-9f4a-0c3a6f6e7d01',
);

Map<String, Object?> _body({bool selfService = true, String stock = 'quantity', bool returns = true}) =>
    <String, Object?>{
      'deliverySlots': <Object?>[
        <String, Object?>{'from': '10:00', 'to': '14:00'},
      ],
      'supportContacts': <Object?>[
        <String, Object?>{'kind': 'phone', 'value': '+996700000005', 'label': 'Поддержка'},
      ],
      'privacyContact': null,
      'lowStockThreshold': 5,
      'minAppVersion': 'android=1.2.0,windows=1.2.0',
      'recommendedAppVersion': null,
      'customerStockDisplay': stock,
      'features': <String, Object?>{
        'customerSelfService': selfService,
        'returnsFromPos': returns,
        'qrProvider': 'onec',
        'qrWebhook': false,
        'debtPaymentsFromPos': true,
      },
    };

/// Хранилище копии в памяти.
final class _MemoryStore implements PublicSettingsStore {
  StoredPublicSettings? value;
  int writes = 0;

  @override
  Future<StoredPublicSettings?> read() async => value;

  @override
  Future<void> write(StoredPublicSettings v) async {
    value = v;
    writes++;
  }
}

/// Сессия без сети: состояние задаёт тест.
final class _FakeSession extends SessionController {
  @override
  SessionState build() => SessionState.initial;

  void set(SessionState s) => state = s;
}

final class _Env {
  _Env(FakeHandler handler, {AppConfig? config, PublicSettingsStore? store, EtagCache? etags, bool autoRefresh = false})
    : adapter = FakeAdapter(handler),
      etagCache = etags ?? EtagCache(),
      config = config ?? AppConfig.fromMap(const <String, String>{'API_BASE_URL': 'https://api.test/api/v1'}) {
    final SecureStorage storage = InMemorySecureStorage(<SecureKey, String>{SecureKey.refreshToken: 'r1'});
    final TokenStore tokens = TokenStore(storage);
    unawaited(tokens.saveTokens(accessToken: 'a1', refreshToken: 'r1'));
    dio = DioClient.create(
      DioClientDeps(
        config: this.config,
        meta: () => _meta,
        tokens: tokens,
        appVersion: AppVersionController(currentVersion: '1.4.2+87', platform: 'windows'),
        etagCache: etagCache,
        adapter: adapter,
        sleep: (_) async {},
      ),
    );
    container = ProviderContainer(
      overrides: [
        dioProvider.overrideWithValue(dio),
        etagCacheProvider.overrideWithValue(etagCache),
        appConfigProvider.overrideWithValue(this.config),
        clockProvider.overrideWithValue(clock),
        publicSettingsAutoRefreshProvider.overrideWithValue(autoRefresh),
        sessionControllerProvider.overrideWith(_FakeSession.new),
        publicSettingsStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);
  }

  final FakeAdapter adapter;
  final EtagCache etagCache;
  final AppConfig config;
  final FixedClock clock = FixedClock(DateTime.utc(2026, 10, 22, 9));
  late final Dio dio;
  late final ProviderContainer container;

  PublicSettingsSnapshot get snapshot => container.read(publicSettingsProvider);

  Future<void> refresh() => container.read(publicSettingsProvider.notifier).refresh();
}

Future<void> _pump() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  test('до ответа: значения по умолчанию, флаги — из сборки (customerSelfService=true по умолчанию)', () {
    final _Env env = _Env((RequestOptions o) async => json(200, _body()));
    expect(env.snapshot.source, PublicSettingsSource.defaults);
    final PublicFeatureFlags flags = env.container.read(publicFeatureFlagsProvider);
    expect(flags.customerSelfService, isTrue);
    expect(flags.fromServer, isFalse);
    expect(flags.returnsFromPos, isFalse, reason: 'неизвестный флаг — действие скрыто');
    expect(flags.qrProvider, QrProviderMode.none);
    expect(env.container.read(customerStockDisplayProvider), CustomerStockDisplay.status);
  });

  test('флаг сборки FEATURE_CUSTOMER_SELF_SERVICE=false действует до ответа сервера', () {
    final _Env env = _Env(
      (RequestOptions o) async => json(200, _body()),
      config: AppConfig.fromMap(const <String, String>{
        'API_BASE_URL': 'https://api.test/api/v1',
        'FEATURE_CUSTOMER_SELF_SERVICE': 'false',
      }),
    );
    expect(env.container.read(publicCustomerSelfServiceProvider), isFalse);
  });

  test('T-API-157: GET /settings/public → поля контракта, Bearer, копия в app_meta с ETag', () async {
    final _MemoryStore store = _MemoryStore();
    final _Env env = _Env(
      (RequestOptions o) async => json(200, _body(), headers: <String, String>{ApiHeaders.etag: 'W/"v1"'}),
      store: store,
    );
    await env.refresh();

    final FakeAdapterRequest req = env.adapter.requests.single;
    expect(req.path, '/settings/public');
    expect(req.method, 'GET');
    expect(req.headers[ApiHeaders.authorization], 'Bearer a1');

    final PublicSettingsSnapshot s = env.snapshot;
    expect(s.source, PublicSettingsSource.network);
    expect(s.etag, 'W/"v1"');
    expect(s.fetchedAt, env.clock.nowUtc());
    expect(s.settings.lowStockThreshold, 5);
    expect(s.settings.supportContacts!.single.value, '+996700000005');
    expect(env.container.read(customerStockDisplayProvider), CustomerStockDisplay.quantity);
    expect(env.container.read(lowStockThresholdProvider), 5);
    final PublicFeatureFlags flags = env.container.read(publicFeatureFlagsProvider);
    expect(flags.fromServer, isTrue);
    expect(flags.returnsFromPos, isTrue);
    expect(flags.qrProvider, QrProviderMode.onec);
    expect(flags.debtPaymentsFromPos, isTrue);

    expect(store.writes, 1);
    expect(store.value!.etag, 'W/"v1"');
    expect(store.value!.json['customerStockDisplay'], 'quantity');
  });

  test('серверный features.customerSelfService=false важнее флага сборки true (FA-08)', () async {
    final _Env env = _Env((RequestOptions o) async => json(200, _body(selfService: false)));
    expect(env.container.read(publicCustomerSelfServiceProvider), isTrue);
    await env.refresh();
    expect(env.container.read(publicCustomerSelfServiceProvider), isFalse);
  });

  test('ETag: повтор с If-None-Match → 304 → значения из ETag-кэша процесса', () async {
    int calls = 0;
    final _Env env = _Env((RequestOptions o) async {
      calls++;
      if (o.headers[ApiHeaders.ifNoneMatch] == 'W/"v1"') return json(304, null);
      return json(200, _body(), headers: <String, String>{ApiHeaders.etag: 'W/"v1"'});
    });
    await env.refresh();
    env.clock.advance(const Duration(minutes: 6));
    await env.refresh();
    expect(calls, 2);
    expect(env.adapter.requests.last.headers[ApiHeaders.ifNoneMatch], 'W/"v1"');
    expect(env.snapshot.source, PublicSettingsSource.network);
    expect(env.snapshot.settings.customerStockDisplay, 'quantity');
    expect(env.snapshot.fetchedAt, env.clock.nowUtc());
  });

  test('перезапуск: копия из app_meta сразу, ETag восстановлен → 304 без повторной выгрузки тела', () async {
    final _MemoryStore store = _MemoryStore()
      ..value = StoredPublicSettings(
        json: _body(stock: 'quantity', selfService: false),
        fetchedAt: DateTime.utc(2026, 10, 22, 8),
        etag: 'W/"v7"',
      );
    final _Env env = _Env((RequestOptions o) async {
      if (o.headers[ApiHeaders.ifNoneMatch] == 'W/"v7"') return json(304, null);
      return json(200, _body(), headers: <String, String>{ApiHeaders.etag: 'W/"v8"'});
    }, store: store);
    expect(env.snapshot.source, PublicSettingsSource.defaults);
    await _pump();
    expect(env.snapshot.source, PublicSettingsSource.cache);
    expect(env.container.read(publicCustomerSelfServiceProvider), isFalse);
    expect(env.container.read(customerStockDisplayProvider), CustomerStockDisplay.quantity);

    await env.refresh();
    expect(env.adapter.requests.single.headers[ApiHeaders.ifNoneMatch], 'W/"v7"');
    expect(env.snapshot.source, PublicSettingsSource.network);
    expect(env.container.read(publicCustomerSelfServiceProvider), isFalse);
  });

  test('ошибка запроса (401 до входа / офлайн) не стирает известные значения', () async {
    final _MemoryStore store = _MemoryStore()
      ..value = StoredPublicSettings(json: _body(), fetchedAt: DateTime.utc(2026, 10, 22, 8));
    final _Env env = _Env(
      (RequestOptions o) async => transportError(o, DioExceptionType.connectionError),
      store: store,
    );
    await _pump();
    await env.refresh();
    expect(env.snapshot.source, PublicSettingsSource.cache);
    expect(env.snapshot.lastFailure, isA<NetworkFailure>());
    expect(env.snapshot.refreshing, isFalse);
    expect(env.container.read(customerStockDisplayProvider), CustomerStockDisplay.quantity);
  });

  test('refreshIfStale: моложе max-age (300 с) — без запроса; старше — запрос', () async {
    final _Env env = _Env((RequestOptions o) async => json(200, _body()));
    await env.refresh();
    final PublicSettingsController c = env.container.read(publicSettingsProvider.notifier);
    env.clock.advance(const Duration(minutes: 4));
    await c.refreshIfStale();
    expect(env.adapter.requests, hasLength(1));
    env.clock.advance(const Duration(minutes: 2));
    await c.refreshIfStale();
    expect(env.adapter.requests, hasLength(2));
  });

  test('параллельные refresh → один запрос', () async {
    final Completer<void> gate = Completer<void>();
    final _Env env = _Env((RequestOptions o) async {
      await gate.future;
      return json(200, _body());
    });
    final Future<void> a = env.refresh();
    final Future<void> b = env.refresh();
    expect(env.snapshot.refreshing, isTrue);
    gate.complete();
    await Future.wait(<Future<void>>[a, b]);
    expect(env.adapter.requests, hasLength(1));
  });

  test('неверный тип поля в ответе → прежние значения, ошибка формата', () async {
    final _Env env = _Env((RequestOptions o) async => json(200, <String, Object?>{'lowStockThreshold': 'много'}));
    await env.refresh();
    expect(env.snapshot.source, PublicSettingsSource.defaults);
    expect(env.snapshot.lastFailure, isA<UnknownFailure>());
  });

  test('AppMetaPublicSettingsStore: запись и чтение копии в app_meta (drift)', () async {
    final AppDatabase db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final AppMetaPublicSettingsStore store = AppMetaPublicSettingsStore(db.appMetaDao);
    expect(await store.read(), isNull);
    await store.write(StoredPublicSettings(json: _body(), fetchedAt: DateTime.utc(2026, 10, 22, 9), etag: 'W/"x"'));
    final StoredPublicSettings? back = await store.read();
    expect(back!.etag, 'W/"x"');
    expect(back.fetchedAt, DateTime.utc(2026, 10, 22, 9));
    expect((back.json['features']! as Map<String, Object?>)['qrProvider'], 'onec');
    expect(await db.appMetaDao.read(AppMetaPublicSettingsStore.key), isNotNull);
    expect(StoredPublicSettings.tryDecode('не json'), isNull);
  });

  test('автообновление: сессия стала активной (вход / разблокировка) → GET /settings/public', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final _Env env = _Env((RequestOptions o) async => json(200, _body(stock: 'quantity')), autoRefresh: true);
    expect(env.snapshot.source, PublicSettingsSource.defaults);
    await _pump();
    expect(env.adapter.requests, isEmpty, reason: 'до входа запроса нет');
    final _FakeSession session = env.container.read(sessionControllerProvider.notifier) as _FakeSession;
    session.set(const SessionState(status: SessionStatus.authenticated, userKind: UserKind.staff));
    await _pump();
    await _pump();
    expect(env.adapter.requests, hasLength(1));
    expect(env.snapshot.source, PublicSettingsSource.network);
    // Блокировка и разблокировка — новый запрос.
    session.set(
      const SessionState(status: SessionStatus.authenticated, userKind: UserKind.staff, lock: SessionLockReason.manual),
    );
    await _pump();
    session.set(const SessionState(status: SessionStatus.authenticated, userKind: UserKind.staff));
    await _pump();
    await _pump();
    expect(env.adapter.requests, hasLength(2));
  });

  test(
    'сессия уже активна при первом чтении → запрос после build (без чтения неинициализированного состояния)',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final _Env env = _Env((RequestOptions o) async => json(200, _body()), autoRefresh: true);
      final _FakeSession session = env.container.read(sessionControllerProvider.notifier) as _FakeSession;
      session.set(const SessionState(status: SessionStatus.authenticated, userKind: UserKind.staff));
      expect(env.container.read(publicCustomerSelfServiceProvider), isTrue);
      await _pump();
      expect(env.adapter.requests, hasLength(1));
      expect(env.snapshot.source, PublicSettingsSource.network);
    },
  );

  test('seedEtag: ключ записи совпадает с ключом EtagInterceptor', () async {
    final _Env env = _Env((RequestOptions o) async => json(200, _body(), headers: <String, String>{'etag': 'W/"k"'}));
    await env.refresh();
    final PublicSettingsApi api = env.container.read(publicSettingsApiProvider);
    expect(env.etagCache.get(api.etagKey)?.etag, 'W/"k"');
  });
}

typedef FakeAdapterRequest = ({String method, String path, Map<String, Object?> headers, Object? data});
