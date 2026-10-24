// Провайдеры core/sync (RM-E-009; 06 §6.10, §6.12). Без кодогенерации (шаблон этапа D).
//
// Порты, которые подключает фича catalog (адаптеры `features/catalog/data/local/**`, список
// `catalogOfflineFirstBindings` в `app/di/overrides.dart`):
//   [catalogCachePortProvider], [syncStatusPortProvider], [syncViewerRoleProvider].
// Для presentation (read-only, L-9):
//   [catalogFreshnessProvider] — «офлайн/онлайн + возраст данных» (OfflineBanner, метка «данные от HH:MM»);
//   [syncIndicatorProvider] — вариант `SyncIndicator` в шапке;
//   [catalogLoadStateProvider] — индикатор первичной загрузки (NFR-PERF-006);
//   [localSyncStatesProvider] — `sync_meta` устройства (SCR-43 офлайн);
//   [outboxPendingCountProvider] — неотправленные действия;
//   [offlineActionsProvider] — избранное / «очистить недавние» через outbox;
//   [syncSchedulerProvider] — запуск планировщика (смотрит корень приложения).
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/daos/catalog_dao.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/session/pending_logout.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/session/step_up_coordinator.dart';
import 'package:optomstroy/core/sync/auth_logout_outbox.dart';
import 'package:optomstroy/core/sync/catalog_sync_engine.dart';
import 'package:optomstroy/core/sync/offline_actions.dart';
import 'package:optomstroy/core/sync/outbox_handlers.dart';
import 'package:optomstroy/core/sync/outbox_queue.dart';
import 'package:optomstroy/core/sync/sync_journal.dart';
import 'package:optomstroy/core/sync/sync_models.dart';
import 'package:optomstroy/core/sync/sync_ports.dart';
import 'package:optomstroy/core/sync/sync_scheduler.dart';

// ---------------------------------------------------------------------------
// Порты (подключает композиционный корень)
// ---------------------------------------------------------------------------

/// Загрузка кэша каталога `GET /catalog/sync/{entity}`; `null` — фича catalog не подключена.
final catalogCachePortProvider = Provider<CatalogCachePort?>((ref) => null);

/// Статус обмена с 1С и ручной запуск (`/sync/status`, `/sync/runs`); `null` — не подключён.
final syncStatusPortProvider = Provider<SyncStatusPort?>((ref) => null);

/// Журнал SCR-43 в полном режиме: ошибки прогона и очередь «в 1С» с повтором (`/sync/runs/{id}/errors`,
/// `/sync/outbox`); `null` — не подключён (вкладки «Ошибки» и «Outbox» скрыты). Подставляет корень.
final syncJournalPortProvider = Provider<SyncJournalPort?>((ref) => null);

/// Роль текущего пользователя для SCR-43 (правило R0 §17.2); подставляет корень/адаптер catalog
/// из `catalogViewerRoleProvider`. `null` — неизвестна (до входа).
final syncViewerRoleProvider = Provider<RoleCode?>((ref) => null);

/// Владелец записей `outbox_actions` — пользователь сессии (07 §11.1 п.2: отправка только его сессией).
final outboxOwnerProvider = Provider<String?>((ref) => ref.watch(sessionControllerProvider.select((s) => s.userId)));

/// Дополнительные кэши для `refreshStale()` после восстановления сети (реестр `RefreshableCache`, 06 §6.12).
final refreshableCachesProvider = Provider<List<RefreshableCache>>((ref) => const <RefreshableCache>[]);

/// Интервал фонового `refreshStale()`; `null` — без таймера (тесты).
final syncPeriodProvider = Provider<Duration?>((ref) => const Duration(minutes: 5));

// ---------------------------------------------------------------------------
// Очередь, движок, планировщик
// ---------------------------------------------------------------------------

/// Обработчики очереди core/sync: избранное и «очистить недавние». Фичи дополняют список своими
/// (корзина `cart.sync` — RM-F) переопределением провайдера в корне.
final outboxHandlersProvider = Provider<List<OutboxActionHandler>>((ref) {
  Dio dio() => ref.read(dioProvider);
  return <OutboxActionHandler>[
    FavoriteOutboxHandler(dio: dio, database: () => ref.read(appDatabaseProvider)),
    RecentClearOutboxHandler(dio: dio),
    // Отложенный выход (ядро §19.4, RC-1/SS-07): запись владельца после его следующего входа.
    AuthLogoutOutboxHandler(service: () => ref.read(pendingLogoutServiceProvider), dio: dio),
  ];
});

final outboxQueueProvider = Provider<OutboxQueue>(
  (ref) => OutboxQueue(
    database: () => ref.read(appDatabaseProvider),
    owner: () => ref.read(outboxOwnerProvider),
    clock: ref.watch(clockProvider),
    handlers: ref.watch(outboxHandlersProvider),
  ),
);

final catalogSyncEngineProvider = Provider<CatalogSyncEngine>((ref) {
  final engine = CatalogSyncEngine(
    port: () => ref.read(catalogCachePortProvider),
    dao: () => ref.read(appDatabaseProvider)?.catalogDao,
    status: () => ref.read(syncStatusPortProvider),
    clock: ref.watch(clockProvider),
  );
  ref.onDispose(engine.dispose);
  return engine;
});

/// Область видимости остатков кэша `stock` для текущего пользователя: клиент — `customer:<customer_stock_display>`
/// (из `/settings/public`, пока настройки не получены — `null`); сотрудник — `null` (область не меняется).
final catalogStockScopeProvider = Provider<String?>((ref) {
  if (ref.watch(syncViewerRoleProvider) != RoleCode.customer) return null;
  final snapshot = ref.watch(publicSettingsProvider);
  if (snapshot.source == PublicSettingsSource.defaults) return null;
  final display = CustomerStockDisplay.tryParse(snapshot.settings.customerStockDisplay) ?? CustomerStockDisplay.status;
  return 'customer:${display.value}';
});

/// Планировщик; живёт всё время работы приложения (корень: `ref.watch(syncSchedulerProvider)`).
/// Открытие БД пользователя (`appDatabaseProvider` ≠ `null`) запускает первичную загрузку / продолжение.
final syncSchedulerProvider = Provider<SyncScheduler>((ref) {
  final watcher = ref.watch(connectivityWatcherProvider);
  final scheduler = SyncScheduler(
    onlineStatus: () => watcher.current,
    statusChanges: watcher.status,
    networkRestored: watcher.networkRestored,
    outbox: ref.watch(outboxQueueProvider),
    catalog: ref.watch(catalogSyncEngineProvider),
    caches: ref.watch(refreshableCachesProvider),
    backendReachable: () async {
      try {
        return (await ref.read(backendHealthProbeProvider).check()).ok;
      } on Object {
        return false;
      }
    },
    period: ref.watch(syncPeriodProvider),
  )..start();
  final engine = ref.watch(catalogSyncEngineProvider);
  // Отложенный выход (`pending_logout`, RC-1/SS-07): доставка без сессии — при старте и при появлении сети.
  final pendingLogout = ref.watch(pendingLogoutServiceProvider)..watchNetwork(watcher.networkRestored);
  unawaited(pendingLogout.deliver());
  // Смена `customer_stock_display` (или вход клиента с другой областью) — перезагрузка `stock` (DATA-262).
  void applyStockScope() {
    final scope = ref.read(catalogStockScopeProvider);
    if (scope != null && ref.read(appDatabaseProvider) != null) unawaited(engine.applyStockScope(scope));
  }

  ref
    ..listen(appDatabaseProvider, (previous, next) {
      if (next == null) {
        scheduler.onSignedOut();
      } else if (!identical(previous, next)) {
        unawaited(scheduler.onSignedIn().whenComplete(applyStockScope));
      }
    }, fireImmediately: true)
    ..listen(catalogStockScopeProvider, (_, _) => applyStockScope())
    ..onDispose(scheduler.dispose);
  return scheduler;
});

/// Избранное и «очистить недавние» — сразу локально + outbox (FavoriteToggle, SCR-10/14/50).
final offlineActionsProvider = Provider<OfflineActions>((ref) {
  final outbox = ref.watch(outboxQueueProvider);
  return OfflineActions(
    database: () => ref.read(appDatabaseProvider),
    outbox: outbox,
    clock: ref.watch(clockProvider),
    onEnqueued: () {
      if (ref.read(connectivityWatcherProvider).current != OnlineStatus.offline) unawaited(outbox.flush());
    },
  );
});

// ---------------------------------------------------------------------------
// Состояние для presentation (read-only)
// ---------------------------------------------------------------------------

/// Порядок сущностей кэша устройства (07 §11.4) — для presentation без импорта core/database (FL-02).
const List<String> catalogCacheEntityOrder = catalogSyncLoadOrder;

/// Состояние загрузки кэша каталога (страница за страницей).
final catalogLoadStateProvider = StreamProvider<CatalogLoadState>((ref) {
  final engine = ref.watch(catalogSyncEngineProvider);
  final controller = StreamController<CatalogLoadState>();
  controller.add(engine.state);
  final sub = engine.states.listen(controller.add);
  ref.onDispose(() async {
    await sub.cancel();
    await controller.close();
  });
  return controller.stream;
});

/// Метки `sync_meta` устройства (пустой список, пока БД пользователя не открыта).
final localSyncStatesProvider = StreamProvider<List<LocalEntitySync>>((ref) {
  final dao = ref.watch(appDatabaseProvider)?.catalogDao;
  if (dao == null) return Stream<List<LocalEntitySync>>.value(const <LocalEntitySync>[]);
  return dao.watchSyncMeta().map((rows) => [for (final r in rows) _local(r)]);
});

LocalEntitySync _local(SyncMetaRow r) => LocalEntitySync(
  entity: r.entity,
  asOf: _utc(r.asOf),
  lastSuccessAt: _utc(r.lastSuccessAt),
  lastError: r.lastError,
  staleAfter: r.staleAfterSec == null ? null : Duration(seconds: r.staleAfterSec!),
  hasCursor: r.serverCursor != null,
);

DateTime? _utc(int? ms) => ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

/// Текущее время для возраста данных (тик 30 с; в тестах переопределяется).
final syncNowProvider = StreamProvider<DateTime>((ref) {
  final clock = ref.watch(clockProvider);
  return Stream<DateTime>.multi((c) {
    c.add(clock.nowUtc());
    final t = Timer.periodic(const Duration(seconds: 30), (_) => c.add(clock.nowUtc()));
    c.onCancel = t.cancel;
  });
});

/// «Офлайн/онлайн + возраст данных» каталога (OfflineBanner, `SyncIndicator`, метка «данные от HH:MM»).
final catalogFreshnessProvider = Provider<DataFreshness>((ref) {
  final online = ref.watch(onlineStatusProvider).value ?? OnlineStatus.unknown;
  final local = ref.watch(localSyncStatesProvider).value ?? const <LocalEntitySync>[];
  final load = ref.watch(catalogLoadStateProvider).value ?? const CatalogLoadState();
  final now = ref.watch(syncNowProvider).value ?? ref.read(clockProvider).nowUtc();
  return freshnessOf(online: online, local: local, load: load, now: now);
});

/// Вычисление [DataFreshness] (вынесено для unit-тестов).
DataFreshness freshnessOf({
  required OnlineStatus online,
  required List<LocalEntitySync> local,
  required CatalogLoadState load,
  required DateTime now,
}) {
  DateTime? asOf;
  DateTime? lastSuccess;
  String? error;
  var stale = false;
  final byEntity = {for (final l in local) l.entity: l};
  for (final e in DataFreshness.ageEntities) {
    final l = byEntity[e];
    if (l == null) continue;
    final a = l.asOf;
    if (a != null && (asOf == null || a.isBefore(asOf))) asOf = a;
    final s = l.lastSuccessAt;
    if (s != null && (lastSuccess == null || s.isAfter(lastSuccess))) lastSuccess = s;
    error ??= l.lastError;
    if ((e == 'prices' || e == 'stock') && a != null && l.isStale(now)) stale = true;
  }
  final allLoaded = local.isNotEmpty && catalogSyncLoadOrder.every((e) => byEntity[e]?.lastSuccessAt != null);
  return DataFreshness(
    online: online,
    now: now,
    asOf: asOf,
    lastSuccessAt: lastSuccess,
    stale: stale,
    fullyLoaded: load.fullyLoaded || allLoaded,
    load: load,
    lastError: error,
  );
}

/// Вариант `SyncIndicator` в шапке (03 §9.40).
final syncIndicatorProvider = Provider<SyncIndicatorInfo>(
  (ref) => SyncIndicatorInfo.from(ref.watch(catalogFreshnessProvider)),
);

/// Неотправленные действия очереди текущего пользователя.
final outboxPendingCountProvider = StreamProvider<int>((ref) {
  ref.watch(appDatabaseProvider);
  return ref.watch(outboxQueueProvider).watchPendingCount();
});

// ---------------------------------------------------------------------------
// SCR-43: step-up и вариант C-2
// ---------------------------------------------------------------------------

/// Итог запроса step-up для ручного запуска.
final class SyncStepUpOutcome {
  const SyncStepUpOutcome.granted(String this.token) : cancelled = false;
  const SyncStepUpOutcome.cancelled() : token = null, cancelled = true;

  /// Диалог не смонтирован — запрос уходит без токена (на `403 STEP_UP_REQUIRED` ответит AuthInterceptor).
  const SyncStepUpOutcome.unavailable() : token = null, cancelled = false;

  final String? token;
  final bool cancelled;
}

typedef SyncStepUp = Future<SyncStepUpOutcome> Function(String operation);

/// StepUpDialog до запроса (02 SCR-43, AC-UI-43-017: отмена — без запроса) через `StepUpCoordinator` core/session.
final syncStepUpProvider = Provider<SyncStepUp>((ref) {
  final coordinator = ref.watch(stepUpCoordinatorProvider);
  return (operation) async {
    if (!coordinator.hasPresenter) return const SyncStepUpOutcome.unavailable();
    final token = await coordinator.obtain(StepUpChallenge(operation: operation));
    return token == null ? const SyncStepUpOutcome.cancelled() : SyncStepUpOutcome.granted(token);
  };
});

/// Вариант C-2 (ядро §22.8): после первого `422 inbound_mode` ручной запуск неактивен до конца сеанса.
final manualSyncBlockedProvider = NotifierProvider<ManualSyncBlock, bool>(ManualSyncBlock.new);

final class ManualSyncBlock extends Notifier<bool> {
  @override
  bool build() => false;

  void block() => state = true;
}
