// SyncScheduler и провайдеры core/sync (06 §6.12; RM-E-009): вход → первичная загрузка; офлайн-действие →
// восстановление сети → GET /health → flush outbox → refreshStale; «офлайн/онлайн + возраст данных»
// (DataFreshness, SyncIndicatorInfo). Riverpod ProviderContainer, фейковые сеть/транспорт, drift в памяти.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/sync/sync_models.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/core/sync/sync_run_policy.dart';
import 'package:optomstroy/features/catalog/data/local/catalog_sync_port_adapters.dart';
import 'package:optomstroy/features/catalog/data/repositories/catalog_repositories_impl.dart';

import '../../support/fake_backend_health.dart';
import '../network/fake_adapter.dart';
import 'sync_test_support.dart';

void main() {
  group('SyncScheduler + провайдеры', () {
    late SyncStack stack;
    late FakeNetworkSource net;
    late ConnectivityWatcher watcher;
    late ProviderContainer container;
    late FakeBackendHealthProbe health;

    setUp(() async {
      stack = SyncStack(FakeCatalogServer(syntheticCatalog(3)));
      stack.server.routes['PUT /favorites/products/p-1'] = (o) => json(204, null);
      net = FakeNetworkSource(network: false);
      watcher = ConnectivityWatcher(net);
      await watcher.start();
      health = FakeBackendHealthProbe();
      container = ProviderContainer(
        overrides: [
          connectivityWatcherProvider.overrideWithValue(watcher),
          dioProvider.overrideWithValue(stack.dio),
          appDatabaseProvider.overrideWithValue(stack.db),
          clockProvider.overrideWithValue(stack.clock),
          outboxOwnerProvider.overrideWithValue('user-1'),
          backendHealthProbeProvider.overrideWithValue(health),
          syncPeriodProvider.overrideWithValue(null),
          catalogCachePortProvider.overrideWithValue(stack.port),
          syncNowProvider.overrideWith((ref) => Stream<DateTime>.value(stack.clock.nowUtc())),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await watcher.dispose();
      await stack.db.close();
    });

    test('офлайн: «в избранное» ждёт; сеть восстановлена → health → один PUT → загрузка кэша', () async {
      // Транспорт «без сети», пока интерфейса нет.
      stack.server.fault = (o, entity, since) =>
          net.network ? null : transportError(o, DioExceptionType.connectionError);
      container.read(syncSchedulerProvider);
      await pumpEventQueue();
      expect(stack.server.syncRequests, isEmpty, reason: 'офлайн — первичная загрузка не начинается');

      final r = await container.read(offlineActionsProvider).setFavorite('p-1', favorite: true);
      expect(r.isSuccess, isTrue);
      await pumpEventQueue();
      expect(stack.adapter.requests.where((x) => x.method == 'PUT'), isEmpty);
      expect(await container.read(outboxQueueProvider).pendingCount(), 1);

      net.set(true); // networkRestored
      await pumpEventQueue(times: 200);
      for (var i = 0; i < 50 && container.read(catalogSyncEngineProvider).state.phase != CatalogLoadPhase.ready; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(health.calls, greaterThanOrEqualTo(1), reason: 'GET /health перед отправкой (06 §6.12)');
      final puts = stack.adapter.requests.where((x) => x.method == 'PUT').toList();
      expect(puts, hasLength(1));
      expect(puts.single.headers['Idempotency-Key'], isNotNull);
      expect(await container.read(outboxQueueProvider).pendingCount(), 0);
      expect(container.read(catalogSyncEngineProvider).state.fullyLoaded, isTrue);
      expect(await stack.db.catalogDao.productCount(), 3);
    });

    test('вход онлайн: открытие БД запускает первичную загрузку; повторный вход — без перезагрузки', () async {
      net.set(true);
      watcher.report(RequestOutcome.responded);
      container.read(syncSchedulerProvider);
      for (var i = 0; i < 100 && !container.read(catalogSyncEngineProvider).state.fullyLoaded; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(container.read(catalogSyncEngineProvider).state.fullyLoaded, isTrue);
      final sub = container.listen(catalogLoadStateProvider, (_, _) {});
      addTearDown(sub.close);
      await pumpEventQueue();
      final freshness = container.read(catalogFreshnessProvider);
      expect(freshness.fullyLoaded, isTrue);
    });
  });

  group('старт приложения онлайн с загруженным кэшем (07 §11.4)', () {
    test('холодный старт → GET /sync/status и инкремент since= изменённой сущности', () async {
      // Кэш уже загружен прежним запуском приложения.
      final stack = SyncStack(FakeCatalogServer(syntheticCatalog(3)));
      addTearDown(stack.db.close);
      await stack.engine().ensureLoaded();
      final loadedAsOf = DateTime.parse(serverTime);
      stack.server.addLater['prices'] = [syncPrice('p-1', '1300.00')];
      stack.server.syncRequests.clear();
      var statusCalls = 0;
      Map<String, Object?> entity(String e, DateTime at) => {
        'entity': e,
        'lastSuccessAt': at.toIso8601String(),
        'running': false,
        'consecutiveErrors': 0,
        'isStale': false,
        'paused': false,
      };
      stack.server.routes['/sync/status'] = (o) {
        statusCalls++;
        return json(200, {
          'onecReachable': true,
          'checkedAt': '2026-10-19T10:00:00Z',
          'overall': 'ok',
          'entities': [
            entity('prices', loadedAsOf.add(const Duration(minutes: 30))),
            entity('products', loadedAsOf.subtract(const Duration(hours: 1))),
          ],
        });
      };
      final net = FakeNetworkSource();
      final watcher = ConnectivityWatcher(net);
      await watcher.start();
      watcher.report(RequestOutcome.responded);
      final container = ProviderContainer(
        overrides: [
          connectivityWatcherProvider.overrideWithValue(watcher),
          dioProvider.overrideWithValue(stack.dio),
          appDatabaseProvider.overrideWithValue(stack.db),
          clockProvider.overrideWithValue(stack.clock),
          outboxOwnerProvider.overrideWithValue('user-1'),
          backendHealthProbeProvider.overrideWithValue(FakeBackendHealthProbe()),
          syncPeriodProvider.overrideWithValue(null),
          catalogCachePortProvider.overrideWithValue(stack.port),
          syncStatusPortProvider.overrideWithValue(
            SyncStatusPortAdapter(status: SyncStatusRepositoryImpl(stack.remote), cache: stack.syncRepo),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await watcher.dispose();
      });

      container.read(syncSchedulerProvider);
      for (var i = 0; i < 200 && stack.server.countFor('prices') == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      for (var i = 0; i < 100 && container.read(catalogSyncEngineProvider).state.phase != CatalogLoadPhase.ready; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(statusCalls, 1, reason: 'GET /sync/status при старте онлайн');
      expect(stack.server.syncRequests.map((r) => (r.entity, r.since)), [
        ('price_lists', 'price_lists#1'),
        ('prices', 'prices#1'),
      ]);
      final price = await (stack.db.select(
        stack.db.localPrices,
      )..where((t) => t.variantId.equals('v-p-1'))).getSingle();
      expect(price.priceTyiyn, 130000);
    });
  });

  group('DataFreshness / SyncIndicatorInfo (DATA-256, 03 §9.40)', () {
    final now = DateTime.utc(2026, 10, 19, 10);
    LocalEntitySync l(String e, Duration age, {Duration? staleAfter, String? error}) => LocalEntitySync(
      entity: e,
      asOf: now.subtract(age),
      lastSuccessAt: now.subtract(age),
      staleAfter: staleAfter,
      lastError: error,
    );

    test('возраст — самая старая метка products/prices/stock; устаревание — по порогу цен/остатков', () {
      final f = freshnessOf(
        online: OnlineStatus.offline,
        local: [
          l('products', const Duration(minutes: 5)),
          l('prices', const Duration(minutes: 20)),
          l('stock', const Duration(minutes: 3)),
        ],
        load: const CatalogLoadState(),
        now: now,
      );
      expect(f.asOf, now.subtract(const Duration(minutes: 20)));
      expect(f.age, const Duration(minutes: 20));
      expect(f.stale, isTrue, reason: '20 мин > 15 мин по умолчанию (AC-DATA-256)');
      expect((f.isOffline, f.fromCache, f.hasCache), (true, true, true));
      expect(SyncIndicatorInfo.from(f).status, SyncIndicatorStatus.offline);
    });

    test('порог из /sync/status (stale_after_sec) отменяет устаревание; варианты индикатора', () {
      final fresh = freshnessOf(
        online: OnlineStatus.online,
        local: [
          l('products', const Duration(minutes: 5)),
          l('prices', const Duration(minutes: 20), staleAfter: const Duration(hours: 1)),
          l('stock', const Duration(minutes: 3)),
        ],
        load: const CatalogLoadState(phase: CatalogLoadPhase.ready, fullyLoaded: true),
        now: now,
      );
      expect(fresh.stale, isFalse);
      expect(SyncIndicatorInfo.from(fresh).status, SyncIndicatorStatus.ok);
      expect(
        SyncIndicatorInfo.from(
          freshnessOf(
            online: OnlineStatus.online,
            local: const [],
            load: const CatalogLoadState(phase: CatalogLoadPhase.initialLoading),
            now: now,
          ),
        ).status,
        SyncIndicatorStatus.syncing,
      );
      expect(
        SyncIndicatorInfo.from(
          freshnessOf(online: OnlineStatus.online, local: const [], load: const CatalogLoadState(), now: now),
        ).status,
        SyncIndicatorStatus.never,
      );
      expect(
        SyncIndicatorInfo.from(
          freshnessOf(
            online: OnlineStatus.online,
            local: [l('stock', const Duration(minutes: 1), error: 'NETWORK_offline')],
            load: const CatalogLoadState(),
            now: now,
          ),
        ).status,
        SyncIndicatorStatus.error,
      );
      expect(
        SyncIndicatorInfo.from(
          freshnessOf(
            online: OnlineStatus.online,
            local: [l('stock', const Duration(minutes: 40))],
            load: const CatalogLoadState(),
            now: now,
          ),
        ).status,
        SyncIndicatorStatus.stale,
      );
    });

    test('процент первичной загрузки: по весам сущностей, 100 только по завершении', () {
      const start = CatalogLoadState(phase: CatalogLoadPhase.initialLoading, totalEntities: 11);
      expect(start.percent, 0);
      final mid = start.copyWith(completedEntities: {'units', 'categories', 'warehouses', 'price_lists', 'products'});
      expect(mid.percent, inInclusiveRange(25, 40));
      expect(mid.uiReady, isTrue);
      final current = mid.copyWith(entity: 'variants', entityPages: 10);
      expect(current.percent, greaterThan(mid.percent));
      expect(current.copyWith(phase: CatalogLoadPhase.ready, fullyLoaded: true).percent, 100);
    });
  });

  group('SyncRunPolicy (ядро R0 §17.2; T-SYNC-023)', () {
    test('senior_seller — только incremental stock/prices/order_status без step-up', () {
      for (final e in SyncEntity.values) {
        for (final m in SyncRunPolicy.dialogModes) {
          final expected = m == SyncMode.incremental && SyncRunPolicy.quickEntities.contains(e);
          expect(SyncRunPolicy.canStart(RoleCode.seniorSeller, e, m), expected, reason: '${e.value} ${m.value}');
        }
      }
      expect(SyncRunPolicy.quickButtonsFor(RoleCode.seniorSeller), SyncRunPolicy.quickEntities);
      expect(SyncRunPolicy.requiresStepUp(SyncEntity.stock, SyncMode.incremental), isFalse);
    });

    test('admin/owner — любой запуск; step-up для всего, кроме трёх incremental; seller/cashier — нет', () {
      for (final role in [RoleCode.admin, RoleCode.owner]) {
        expect(SyncRunPolicy.canStart(role, SyncEntity.products, SyncMode.full), isTrue);
        expect(SyncRunPolicy.canOpenRunDialog(role), isTrue);
      }
      expect(SyncRunPolicy.requiresStepUp(SyncEntity.customers, SyncMode.incremental), isTrue);
      expect(SyncRunPolicy.requiresStepUp(SyncEntity.stock, SyncMode.full), isTrue);
      expect(SyncRunPolicy.requiresStepUp(SyncEntity.prices, SyncMode.reconcile), isTrue);
      for (final role in [RoleCode.seller, RoleCode.cashier, RoleCode.customer, null]) {
        expect(SyncRunPolicy.canStartAny(role), isFalse);
        expect(SyncRunPolicy.canViewJournal(role), isFalse);
        expect(SyncRunPolicy.canStart(role, SyncEntity.stock, SyncMode.incremental), isFalse);
      }
      expect(SyncRunPolicy.canManageOutbox(RoleCode.owner), isFalse);
      expect(SyncRunPolicy.canStart(RoleCode.admin, SyncEntity.stock, SyncMode.manual), isFalse);
      expect(SyncRunPolicy.stepUpOperation, 'sync.run.full');
    });
  });

  test('SyncStepUpOutcome', () {
    expect(const SyncStepUpOutcome.cancelled().cancelled, isTrue);
    expect(const SyncStepUpOutcome.granted('t').token, 't');
    expect(const SyncStepUpOutcome.unavailable().cancelled, isFalse);
    unawaited(Future<void>.value());
  });
}
