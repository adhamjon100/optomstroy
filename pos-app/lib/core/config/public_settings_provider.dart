// Публичные настройки и флаги функций `GET /settings/public` (ядро §19.2, §24.2, §24.4; 08 §4.23.1;
// RM-D-015 — Flutter-часть).
//
// Источник несекретных настроек для клиента всех ролей: слоты доставки, контакты поддержки и ПДн,
// порог «мало», версии клиента, режим показа остатков клиенту (`customerStockDisplay`) и флаги
// `features` (скрытие недоступных действий — не защита: сервер проверяет права на каждой операции).
//
// Жизненный цикл (08 §4.23.1 «кэшируется в app_meta и обновляется после каждого входа и при возврате
// в foreground»):
// - старт: значения по умолчанию (флаги сборки `FEATURE_*`, 06 §6.9) → копия из `app_meta` текущего
//   пользователя (если БД открыта);
// - сессия стала активной (вход / разблокировка) → `GET /settings/public`;
// - возврат в foreground → запрос, если копия старше `max-age` (300 с, 08 §2.8);
// - ETag: `EtagInterceptor` отправляет `If-None-Match`, `304` → сохранённое тело. После перезапуска
//   процесса запись ETag-кэша восстанавливается из `app_meta` ([PublicSettingsApi.seedEtag]).
// Ошибка запроса (401 до входа, офлайн) не стирает известные значения — остаётся кэш/умолчания.
//
// Приоритет флагов: сервер (`features`) важнее локальных `FEATURE_*` (environment.dart).
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/database/daos/app_meta_dao.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/core/network/etag_cache.dart';
import 'package:optomstroy/core/network/models/public_settings.dart';
import 'package:optomstroy/core/session/session_controller.dart';

export 'package:optomstroy/core/network/models/public_settings.dart'
    show DeliverySlot, PublicFeatures, PublicSettings, SupportContact;

final Logger _log = Logger('public_settings');

/// Откуда взяты текущие значения.
enum PublicSettingsSource {
  /// Встроенные значения по умолчанию (до входа / до первого ответа).
  defaults,

  /// Копия из `app_meta` (последний успешный ответ).
  cache,

  /// Ответ сервера в этом процессе (`200` или `304` с телом из ETag-кэша).
  network,
}

/// Снимок публичных настроек.
@immutable
final class PublicSettingsSnapshot {
  const PublicSettingsSnapshot({
    required this.settings,
    required this.source,
    this.fetchedAt,
    this.etag,
    this.refreshing = false,
    this.lastFailure,
  });

  /// До входа: пустые настройки, флаги — из сборки.
  static const PublicSettingsSnapshot initial = PublicSettingsSnapshot(
    settings: PublicSettings(),
    source: PublicSettingsSource.defaults,
  );

  /// `Cache-Control: private, max-age=300` (08 §2.8).
  static const Duration maxAge = Duration(minutes: 5);

  final PublicSettings settings;
  final PublicSettingsSource source;

  /// Время последнего успешного ответа (UTC).
  final DateTime? fetchedAt;

  /// `ETag` последнего ответа.
  final String? etag;

  /// Идёт запрос.
  final bool refreshing;

  /// Ошибка последнего запроса (значения при этом остаются прежними).
  final Failure? lastFailure;

  /// Значения моложе `max-age`.
  bool isFresh(DateTime now) => fetchedAt != null && now.difference(fetchedAt!) < maxAge;

  PublicSettingsSnapshot copyWith({bool? refreshing, Failure? lastFailure, bool clearFailure = false}) =>
      PublicSettingsSnapshot(
        settings: settings,
        source: source,
        fetchedAt: fetchedAt,
        etag: etag,
        refreshing: refreshing ?? this.refreshing,
        lastFailure: clearFailure ? null : (lastFailure ?? this.lastFailure),
      );

  @override
  bool operator ==(Object other) =>
      other is PublicSettingsSnapshot &&
      other.settings == settings &&
      other.source == source &&
      other.fetchedAt == fetchedAt &&
      other.etag == etag &&
      other.refreshing == refreshing &&
      other.lastFailure == lastFailure;

  @override
  int get hashCode => Object.hash(settings, source, fetchedAt, etag, refreshing, lastFailure);

  @override
  String toString() => 'PublicSettingsSnapshot(${source.name}, fetchedAt: $fetchedAt, refreshing: $refreshing)';
}

/// Действующие флаги функций: сервер (`features`) → флаг сборки → безопасное умолчание.
///
/// Умолчания при неизвестном значении сервера: `customerSelfService` — флаг сборки
/// `FEATURE_CUSTOMER_SELF_SERVICE` (по умолчанию `true`, ядро §24.2); остальные действия скрыты
/// (`false` / `QrProviderMode.none`) до ответа сервера — скрытие не защита, сервер проверяет сам.
@immutable
final class PublicFeatureFlags {
  const PublicFeatureFlags({
    required this.customerSelfService,
    required this.returnsFromPos,
    required this.qrProvider,
    required this.qrWebhook,
    required this.debtPaymentsFromPos,
    required this.fromServer,
  });

  /// Сводка из ответа сервера [server] и конфигурации сборки [config].
  factory PublicFeatureFlags.resolve(PublicFeatures? server, AppConfig config) => PublicFeatureFlags(
    customerSelfService:
        server?.customerSelfService ??
        config.features[FeatureFlag.customerSelfService] ??
        FeatureFlag.defaults[FeatureFlag.customerSelfService]!,
    returnsFromPos: server?.returnsFromPos ?? false,
    qrProvider: QrProviderMode.tryParse(server?.qrProvider) ?? QrProviderMode.none,
    qrWebhook: server?.qrWebhook ?? false,
    debtPaymentsFromPos: server?.debtPaymentsFromPos ?? false,
    fromServer: server != null,
  );

  /// `features.customerSelfService` — режим клиента (SCR-06, SCR-50, вкладка «Привязки» SCR-45).
  final bool customerSelfService;

  /// `features.returnsFromPos` — SCR-39 и действия возврата (Q-018).
  final bool returnsFromPos;

  /// `features.qrProvider` — способ «QR» показывается клиенту только при значении ≠ `none` (ядро §24.4).
  final QrProviderMode qrProvider;

  /// `features.qrWebhook` (R2, Q-014).
  final bool qrWebhook;

  /// `features.debtPaymentsFromPos` (Q-152).
  final bool debtPaymentsFromPos;

  /// Флаги получены от сервера (из ответа или его копии в `app_meta`).
  final bool fromServer;

  @override
  bool operator ==(Object other) =>
      other is PublicFeatureFlags &&
      other.customerSelfService == customerSelfService &&
      other.returnsFromPos == returnsFromPos &&
      other.qrProvider == qrProvider &&
      other.qrWebhook == qrWebhook &&
      other.debtPaymentsFromPos == debtPaymentsFromPos &&
      other.fromServer == fromServer;

  @override
  int get hashCode =>
      Object.hash(customerSelfService, returnsFromPos, qrProvider, qrWebhook, debtPaymentsFromPos, fromServer);

  @override
  String toString() =>
      'PublicFeatureFlags(selfService: $customerSelfService, returns: $returnsFromPos, qr: ${qrProvider.value}, '
      'qrWebhook: $qrWebhook, debt: $debtPaymentsFromPos, fromServer: $fromServer)';
}

/// Ответ `GET /settings/public`.
final class PublicSettingsResponse {
  const PublicSettingsResponse({required this.json, this.etag, this.notModified = false});

  final Map<String, Object?> json;
  final String? etag;

  /// `304 Not Modified` — тело взято из ETag-кэша процесса.
  final bool notModified;
}

/// HTTP-вызов `GET /settings/public` поверх основного Dio (интерсепторы core: Bearer, ETag, повтор).
final class PublicSettingsApi {
  PublicSettingsApi(this._dio, this._etags);

  /// Путь относительно `/api/v1`.
  static const String path = '/settings/public';

  final Dio _dio;
  final EtagCache _etags;

  /// Фоновый GET (профиль повторов `background`, 08 §2.10).
  Future<PublicSettingsResponse> fetch() async {
    final Response<Object?> res = await _dio.get<Object?>(path, options: apiOptions(retry: RetryProfile.background));
    final Object? data = res.data;
    if (data is! Map) throw const FormatException('settings/public: ожидался объект');
    return PublicSettingsResponse(
      json: Map<String, Object?>.from(data),
      etag: res.headers.value(ApiHeaders.etag),
      notModified: res.extra[RequestExtra.etagCacheHit] == true,
    );
  }

  /// Ключ записи ETag-кэша — как у `EtagInterceptor` (`RequestOptions.uri`).
  String get etagKey => RequestOptions(baseUrl: _dio.options.baseUrl, path: path).uri.toString();

  /// Восстановить запись ETag-кэша процесса из сохранённой копии, если её нет.
  void seedEtag(String etag, Map<String, Object?> json) {
    final String key = etagKey;
    if (_etags.get(key) == null) _etags.put(key, EtagEntry(etag: etag, data: json));
  }
}

/// Сохранённая копия ответа.
final class StoredPublicSettings {
  const StoredPublicSettings({required this.json, required this.fetchedAt, this.etag});

  /// Разбор строки `app_meta`; повреждённая строка — `null`.
  static StoredPublicSettings? tryDecode(String raw) {
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final Object? body = decoded['body'];
      final DateTime? at = DateTime.tryParse('${decoded['fetchedAt']}');
      if (body is! Map || at == null) return null;
      final Object? etag = decoded['etag'];
      return StoredPublicSettings(
        json: Map<String, Object?>.from(body),
        fetchedAt: at.toUtc(),
        etag: etag is String ? etag : null,
      );
    } on FormatException {
      return null;
    }
  }

  final Map<String, Object?> json;
  final DateTime fetchedAt;
  final String? etag;

  String encode() =>
      jsonEncode(<String, Object?>{'etag': etag, 'fetchedAt': fetchedAt.toUtc().toIso8601String(), 'body': json});
}

/// Хранилище копии ответа (несекретные данные; ПДн нет).
abstract interface class PublicSettingsStore {
  Future<StoredPublicSettings?> read();

  Future<void> write(StoredPublicSettings value);
}

/// Копия в `app_meta` локальной БД пользователя (07 §11.2; 08 §4.23.1).
final class AppMetaPublicSettingsStore implements PublicSettingsStore {
  const AppMetaPublicSettingsStore(this._dao);

  /// Ключ `app_meta`.
  static const String key = 'settings_public';

  final AppMetaDao _dao;

  @override
  Future<StoredPublicSettings?> read() async {
    final String? raw = await _dao.read(key);
    return raw == null ? null : StoredPublicSettings.tryDecode(raw);
  }

  @override
  Future<void> write(StoredPublicSettings value) => _dao.write(key, value.encode());
}

/// HTTP-вызов настроек.
final publicSettingsApiProvider = Provider<PublicSettingsApi>(
  (ref) => PublicSettingsApi(ref.watch(dioProvider), ref.watch(etagCacheProvider)),
);

/// Хранилище копии: `app_meta` открытой БД пользователя; `null` — БД ещё нет (до входа).
final publicSettingsStoreProvider = Provider<PublicSettingsStore?>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return db == null ? null : AppMetaPublicSettingsStore(db.appMetaDao);
});

/// Автообновление после входа/разблокировки и при возврате в foreground; тесты выключают.
final publicSettingsAutoRefreshProvider = Provider<bool>((ref) => true);

/// Публичные настройки (снимок). Обновить вручную — `ref.read(publicSettingsProvider.notifier).refresh()`.
final publicSettingsProvider = NotifierProvider<PublicSettingsController, PublicSettingsSnapshot>(
  PublicSettingsController.new,
);

/// Действующие флаги функций (сервер → сборка → умолчание).
final publicFeatureFlagsProvider = Provider<PublicFeatureFlags>(
  (ref) => PublicFeatureFlags.resolve(
    ref.watch(publicSettingsProvider.select((PublicSettingsSnapshot s) => s.settings.features)),
    ref.watch(appConfigProvider),
  ),
);

/// `features.customerSelfService` (по умолчанию — флаг сборки, `true`).
final publicCustomerSelfServiceProvider = Provider<bool>(
  (ref) => ref.watch(publicFeatureFlagsProvider.select((PublicFeatureFlags f) => f.customerSelfService)),
);

/// `customerStockDisplay` — показ остатков клиенту: `status` (по умолчанию) — только «в наличии / мало / нет»,
/// `quantity` — плюс доступное количество (ядро §24.2; 08 API-180). Используется режимом клиента.
final customerStockDisplayProvider = Provider<CustomerStockDisplay>(
  (ref) =>
      CustomerStockDisplay.tryParse(
        ref.watch(publicSettingsProvider.select((PublicSettingsSnapshot s) => s.settings.customerStockDisplay)),
      ) ??
      CustomerStockDisplay.status,
);

/// `lowStockThreshold` — порог «мало» (`null` — неизвестен).
final lowStockThresholdProvider = Provider<int?>(
  (ref) => ref.watch(publicSettingsProvider.select((PublicSettingsSnapshot s) => s.settings.lowStockThreshold)),
);

/// Контроллер публичных настроек.
class PublicSettingsController extends Notifier<PublicSettingsSnapshot> {
  Future<void>? _inflight;

  @override
  PublicSettingsSnapshot build() {
    final PublicSettingsStore? store = ref.watch(publicSettingsStoreProvider);
    if (ref.watch(publicSettingsAutoRefreshProvider)) {
      // Вход / разблокировка → обновить (сессия сотрудника до установки PIN тоже читает настройки, 08 API-181).
      ref.listen<bool>(sessionControllerProvider.select((s) => s.isAuthenticated && !s.isLocked), (
        bool? previous,
        bool next,
      ) {
        // Вне build: при `fireImmediately` состояние провайдера ещё не создано.
        if (next && previous != true) {
          scheduleMicrotask(() {
            if (ref.mounted) unawaited(refresh());
          });
        }
      }, fireImmediately: true);
      final AppLifecycleListener lifecycle = AppLifecycleListener(onResume: () => unawaited(refreshIfStale()));
      ref.onDispose(lifecycle.dispose);
    }
    if (store != null) unawaited(_loadCache(store));
    return PublicSettingsSnapshot.initial;
  }

  /// Запросить настройки (параллельные вызовы — один запрос).
  Future<void> refresh() => _inflight ??= _refresh().whenComplete(() => _inflight = null);

  /// Запросить, если значения старше `max-age` или неизвестны.
  Future<void> refreshIfStale() async {
    if (state.isFresh(ref.read(clockProvider).nowUtc())) return;
    await refresh();
  }

  Future<void> _loadCache(PublicSettingsStore store) async {
    final StoredPublicSettings? stored;
    try {
      stored = await store.read();
    } on Object catch (e) {
      _log.warning('чтение копии: ${e.runtimeType}');
      return;
    }
    if (stored == null || !ref.mounted || state.source != PublicSettingsSource.defaults) return;
    final PublicSettings? parsed = _parse(stored.json);
    if (parsed == null) return;
    state = PublicSettingsSnapshot(
      settings: parsed,
      source: PublicSettingsSource.cache,
      fetchedAt: stored.fetchedAt,
      etag: stored.etag,
      refreshing: state.refreshing,
    );
    final String? etag = stored.etag;
    if (etag != null) {
      try {
        ref.read(publicSettingsApiProvider).seedEtag(etag, stored.json);
      } on Object catch (e) {
        // Без clientMetaProvider (виджет-тесты) Dio не создаётся: ETag восстановится при первом ответе.
        _log.fine('ETag не восстановлен: ${e.runtimeType}');
      }
    }
  }

  Future<void> _refresh() async {
    final PublicSettingsApi api;
    try {
      api = ref.read(publicSettingsApiProvider);
    } on Object catch (e) {
      _log.warning('dio недоступен: ${e.runtimeType}');
      return;
    }
    state = state.copyWith(refreshing: true);
    final Result<PublicSettingsResponse> result = await ErrorMapper.guard(api.fetch);
    if (!ref.mounted) return;
    switch (result) {
      case Success<PublicSettingsResponse>(:final value):
        final PublicSettings? parsed = _parse(value.json);
        if (parsed == null) {
          state = state.copyWith(refreshing: false, lastFailure: const UnknownFailure(cause: 'settings_public_format'));
          return;
        }
        final DateTime now = ref.read(clockProvider).nowUtc();
        final String? etag = value.etag ?? state.etag;
        state = PublicSettingsSnapshot(
          settings: parsed,
          source: PublicSettingsSource.network,
          fetchedAt: now,
          etag: etag,
        );
        final PublicSettingsStore? store = ref.read(publicSettingsStoreProvider);
        if (store != null) {
          try {
            await store.write(StoredPublicSettings(json: value.json, fetchedAt: now, etag: etag));
          } on Object catch (e) {
            _log.warning('запись копии: ${e.runtimeType}');
          }
        }
      case FailureResult<PublicSettingsResponse>(:final failure):
        _log.info('GET /settings/public: $failure');
        state = state.copyWith(refreshing: false, lastFailure: failure);
    }
  }

  static PublicSettings? _parse(Map<String, Object?> json) {
    try {
      return PublicSettings.fromJson(Map<String, dynamic>.from(json));
    } on Object catch (e) {
      _log.warning('разбор settings/public: ${e.runtimeType}');
      return null;
    }
  }
}
