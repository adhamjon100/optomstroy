// CatalogSyncEngine (RM-E-009; 07 §11.4; 08 §4.24; DATA-257; T-SYNC клиентская часть): первичная загрузка
// страницами по курсору, обрыв на середине и продолжение без дублей, deleted[], инкремент по статусу/порогу.
// Фейковый транспорт Dio и drift в памяти; синтетические данные (не реальная интеграция).
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/daos/catalog_dao.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/sync/catalog_sync_engine.dart';
import 'package:optomstroy/core/sync/sync_models.dart';
import 'package:optomstroy/core/sync/sync_ports.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/features/catalog/data/datasources/catalog_remote_data_source.dart';
import 'package:optomstroy/features/catalog/data/local/catalog_sync_port_adapters.dart';
import 'package:optomstroy/features/catalog/data/repositories/catalog_repositories_impl.dart';

import '../database/test_database.dart';
import '../network/fake_adapter.dart';
import 'sync_test_support.dart';

final class _StatusPort implements SyncStatusPort {
  _StatusPort(this.value);

  SyncServerStatus? value;
  int calls = 0;

  @override
  Future<Result<SyncServerStatus>> status() async {
    calls++;
    final v = value;
    return v == null ? const FailureResult(PermissionFailure()) : Success(v);
  }

  @override
  Future<Result<SyncRunsPage>> runs({SyncEntity? entity, int limit = 50, String? cursor}) async =>
      const Success(SyncRunsPage(items: []));

  @override
  Future<Result<SyncRunInfo>> run(String runId) async => throw UnimplementedError();

  @override
  Future<Result<SyncRunInfo>> startRun({
    required SyncEntity entity,
    required SyncMode mode,
    required String idempotencyKey,
    String? stepUpToken,
  }) async => throw UnimplementedError();
}

void main() {
  group('первичная загрузка (07 §11.4, NFR-PERF-006)', () {
    test('все сущности страницами до hasMore=false в порядке 07 §11.4; курсоры и метка снимка сохранены', () async {
      final server = FakeCatalogServer(syntheticCatalog(5, pageSize: 2));
      final stack = SyncStack(server);
      addTearDown(stack.db.close);
      final engine = stack.engine(pageSize: 2);
      final states = <CatalogLoadState>[];
      final sub = engine.states.listen(states.add);
      addTearDown(sub.cancel);

      final result = await engine.ensureLoaded();

      expect(result.phase, CatalogLoadPhase.ready);
      expect(result.fullyLoaded, isTrue);
      expect(result.percent, 100);
      // Порядок первых запросов сущностей — канон 07 §11.4.
      final order = <String>[];
      for (final r in server.syncRequests) {
        if (!order.contains(r.entity)) order.add(r.entity);
      }
      expect(order, catalogSyncLoadOrder);
      // products: 3 страницы по 2 (5 товаров), каждая следующая — с since=<курсор предыдущей>.
      final productReqs = server.syncRequests.where((r) => r.entity == 'products').map((r) => r.since).toList();
      expect(productReqs, [null, 'products#1', 'products#2']);
      expect(stack.adapter.requests.first.path, '/catalog/sync/units');
      expect(await stack.db.catalogDao.productCount(), 5);
      final meta = await stack.db.catalogDao.syncMetaOf('products');
      expect(meta!.serverCursor, 'products#3');
      expect(meta.asOf, DateTime.parse(serverTime).millisecondsSinceEpoch);
      expect(meta.lastSuccessAt, isNotNull);
      expect(await stack.db.appMetaDao.read('catalog_full_loaded_at'), isNotNull);
      // Индикатор: прогресс растёт, UI доступен после categories + products раньше конца загрузки.
      final percents = [for (final s in states) s.percent];
      for (var i = 1; i < percents.length; i++) {
        expect(percents[i], greaterThanOrEqualTo(percents[i - 1]), reason: 'прогресс не убывает');
      }
      final firstUiReady = states.indexWhere((s) => s.uiReady);
      final firstStock = states.indexWhere((s) => s.entity == 'stock');
      expect(firstUiReady, greaterThanOrEqualTo(0));
      expect(firstUiReady, lessThan(firstStock));
      expect(states.where((s) => s.phase == CatalogLoadPhase.initialLoading), isNotEmpty);
    });

    test('повторный ensureLoaded после завершения — без запросов', () async {
      final server = FakeCatalogServer(syntheticCatalog(3));
      final stack = SyncStack(server);
      addTearDown(stack.db.close);
      await stack.engine().ensureLoaded();
      final before = server.syncRequests.length;
      final again = await stack.engine().ensureLoaded();
      expect(again.fullyLoaded, isTrue);
      expect(server.syncRequests.length, before);
    });

    test('обрыв на середине products → курсор сохранён; новый запуск продолжает с курсора без дублей', () async {
      final server = FakeCatalogServer(syntheticCatalog(7, pageSize: 2)); // products: 4 страницы
      final stack = SyncStack(server);
      addTearDown(stack.db.close);
      server.fault = (o, entity, since) =>
          entity == 'products' && since == 'products#2' ? transportError(o, DioExceptionType.connectionError) : null;

      final first = await stack.engine(pageSize: 2).ensureLoaded();

      expect(first.phase, CatalogLoadPhase.failed);
      expect(first.failure, isA<NetworkFailure>());
      expect(first.fullyLoaded, isFalse);
      expect(await stack.db.appMetaDao.read('catalog_full_loaded_at'), isNull);
      expect(await stack.db.catalogDao.productCount(), 4, reason: 'две применённые страницы');
      final meta = await stack.db.catalogDao.syncMetaOf('products');
      expect((meta!.serverCursor, meta.lastSuccessAt), ('products#2', null));
      expect(meta.lastError, 'NETWORK_offline');

      // «Перезапуск приложения»: новый движок, сеть восстановлена.
      server
        ..fault = null
        ..syncRequests.clear();
      final second = await stack.engine(pageSize: 2).ensureLoaded();

      expect(second.phase, CatalogLoadPhase.ready, reason: '${second.failure}');
      expect(second.fullyLoaded, isTrue);
      // Завершённые сущности не перезагружаются; products продолжаются с сохранённого курсора.
      for (final e in const ['units', 'categories', 'warehouses', 'price_lists']) {
        expect(server.countFor(e), 0, reason: e);
      }
      expect(server.syncRequests.where((r) => r.entity == 'products').map((r) => r.since), [
        'products#2',
        'products#3',
      ]);
      expect(await stack.db.catalogDao.productCount(), 7, reason: 'без дублей и потерь');
      final page = await stack.db.catalogDao.listProducts(
        filter: const CatalogLocalFilter(),
        sort: CatalogLocalSort.nameAsc,
        limit: 50,
        offset: 0,
      );
      expect(page.rows.map((r) => r.product.id).toSet(), hasLength(7));
    });

    test('без порта/БД — failed CatalogCacheNotReady, без исключений', () async {
      final engine = CatalogSyncEngine(port: () => null, dao: () => null, clock: const SystemClock());
      final r = await engine.ensureLoaded();
      expect(r.phase, CatalogLoadPhase.failed);
      expect((r.failure! as UnknownFailure).cause, isA<CatalogCacheNotReady>());
      await engine.refreshStale(); // без порта — без исключений
    });
  });

  group('инкремент: since, deleted[], refreshStale', () {
    test('deleted[] удаляет локально: товар — deletion_mark (скрыт), остатки варианта — удалены', () async {
      final server = FakeCatalogServer(syntheticCatalog(4));
      final stack = SyncStack(server);
      addTearDown(stack.db.close);
      final engine = stack.engine();
      await engine.ensureLoaded();
      expect(await stack.db.catalogDao.productCount(), 4);
      expect(await stack.db.catalogDao.stockFor(['v-p-2']), hasLength(1));

      server.deleteLater['products'] = ['p-2'];
      server.deleteLater['stock'] = ['v-p-2'];
      server.addLater['products'] = [syncProduct('p-5', name: 'Новый смеситель')];
      server.syncRequests.clear();
      final r = await engine.refresh(entities: {'products', 'stock'});

      expect(r.phase, CatalogLoadPhase.ready, reason: '${r.failure}');
      expect(server.syncRequests.map((x) => (x.entity, x.since)), [('products', 'products#1'), ('stock', 'stock#1')]);
      expect(await stack.db.catalogDao.productCount(), 4, reason: '−p-2 (deleted) +p-5 (новый)');
      final list = await stack.db.catalogDao.listProducts(
        filter: const CatalogLocalFilter(),
        sort: CatalogLocalSort.nameAsc,
        limit: 50,
        offset: 0,
      );
      expect(list.rows.map((x) => x.product.id), isNot(contains('p-2')));
      expect(list.rows.map((x) => x.product.id), contains('p-5'));
      expect(await stack.db.catalogDao.stockFor(['v-p-2']), isEmpty);
    });

    test('deleted[] prices/barcodes — uuid строк сервера: цена и штрихкод удалены из кэша (EQ-CSYNC-02)', () async {
      final server = FakeCatalogServer(syntheticCatalog(3));
      final stack = SyncStack(server);
      addTearDown(stack.db.close);
      final engine = stack.engine();
      await engine.ensureLoaded();
      final dao = stack.db.catalogDao;
      expect(await stack.db.select(stack.db.localPrices).get(), hasLength(3));
      final barcode = syncBarcode('p-1', 1)['barcode']! as String;
      expect(await dao.barcodeByValue(barcode), isNotNull);

      server.deleteLater['prices'] = ['price-p-1'];
      server.deleteLater['barcodes'] = ['bc-p-1'];
      final r = await engine.refresh(entities: {'prices', 'barcodes'});

      expect(r.phase, CatalogLoadPhase.ready, reason: '${r.failure}');
      final prices = await stack.db.select(stack.db.localPrices).get();
      expect([for (final p in prices) p.variantId]..sort(), ['v-p-2', 'v-p-3']);
      expect(await dao.barcodeByValue(barcode), isNull, reason: 'удалённый штрихкод не находит товар (DATA-259)');
      expect(await stack.db.select(stack.db.localBarcodes).get(), hasLength(2));
    });

    test(
      'смена customer_stock_display: stock перезагружается без since, количества становятся NULL (DATA-262)',
      () async {
        final server = FakeCatalogServer(syntheticCatalog(2));
        final stack = SyncStack(server);
        addTearDown(stack.db.close);
        final engine = stack.engine();
        await engine.ensureLoaded();
        expect(await engine.applyStockScope('customer:quantity'), isFalse, reason: 'первая запись области');
        expect(await engine.applyStockScope('customer:quantity'), isFalse);
        expect((await stack.db.catalogDao.stockFor(['v-p-1'])).single.availableMilli, 24000);

        // Сервер теперь отдаёт остатки без количеств (status).
        server.pages['stock'] = [
          [
            for (final id in ['p-1', 'p-2']) {'variantId': 'v-$id', 'warehouseId': whId, 'stockLevel': 'in_stock'},
          ],
        ];
        server.syncRequests.clear();
        expect(await engine.applyStockScope('customer:status'), isTrue);

        expect(server.syncRequests.map((r) => (r.entity, r.since)), [('stock', null)]);
        final row = (await stack.db.catalogDao.stockFor(['v-p-1'])).single;
        expect((row.availableMilli, row.quantityMilli, row.stockLevel), (null, null, 'in_stock'));
        expect(await stack.db.appMetaDao.read('catalog_stock_scope'), 'customer:status');
      },
    );

    test('refreshStale по GET /sync/status: только сущности, обновлённые на сервере позже as_of', () async {
      final server = FakeCatalogServer(syntheticCatalog(2));
      final stack = SyncStack(server);
      addTearDown(stack.db.close);
      final status = _StatusPort(null);
      final engine = stack.engine(status: status);
      await engine.ensureLoaded();
      final local = DateTime.parse(serverTime);
      status.value = SyncServerStatus(
        onecReachable: true,
        checkedAt: local.add(const Duration(minutes: 30)),
        overall: 'ok',
        entities: [
          SyncServerEntity(entityValue: 'stock', lastSuccessAt: local.add(const Duration(minutes: 20))),
          SyncServerEntity(entityValue: 'prices', lastSuccessAt: local.add(const Duration(minutes: 20))),
          SyncServerEntity(entityValue: 'products', lastSuccessAt: local.subtract(const Duration(hours: 1))),
          SyncServerEntity(entityValue: 'customers', lastSuccessAt: local.add(const Duration(minutes: 20))),
        ],
      );
      server.syncRequests.clear();
      await engine.refreshStale();
      expect(server.syncRequests.map((r) => r.entity).toSet(), {'price_lists', 'prices', 'stock'});
      expect(status.calls, 1);
    });

    test('refreshStale без статуса (403): сущности старше порога sync_meta.stale_after_sec / 15 мин', () async {
      final server = FakeCatalogServer(syntheticCatalog(2));
      final stack = SyncStack(server);
      addTearDown(stack.db.close);
      final engine = stack.engine(status: _StatusPort(null));
      await engine.ensureLoaded();
      await stack.db.catalogDao.saveStaleThreshold('stock', 24 * 3600);
      // serverTime 09:00, часы 10:00 → возраст 60 мин > 15 мин у всех, кроме stock (порог 24 ч).
      server.syncRequests.clear();
      await engine.refreshStale();
      final requested = server.syncRequests.map((r) => r.entity).toSet();
      expect(requested, isNot(contains('stock')));
      expect(requested, containsAll(<String>['products', 'prices', 'units']));
    });

    test('незавершённая первичная загрузка: refreshStale продолжает её', () async {
      final server = FakeCatalogServer(syntheticCatalog(3));
      final stack = SyncStack(server);
      addTearDown(stack.db.close);
      server.fault = (o, entity, since) => entity == 'variants' ? json(503, null) : null;
      final first = await stack.engine().ensureLoaded();
      expect(first.phase, CatalogLoadPhase.failed);
      server.fault = null;
      final engine = stack.engine();
      await engine.refreshStale();
      expect(engine.state.fullyLoaded, isTrue);
    });
  });

  group('смена пользователя во время загрузки (07 §11.1 п.2: данные не смешиваются)', () {
    late AppDatabase dbA;
    late AppDatabase dbB;
    AppDatabase? current;
    late FakeCatalogServer server;
    late CatalogSyncEngine engine;

    setUp(() {
      configureSqliteForTests();
      dbA = AppDatabase(NativeDatabase.memory());
      dbB = AppDatabase(NativeDatabase.memory());
      current = dbA;
      server = FakeCatalogServer(syntheticCatalog(5));
      final dio = Dio(BaseOptions(baseUrl: 'https://pos.test/api/v1'))..httpClientAdapter = FakeAdapter(server.handle);
      final clock = FixedClock(DateTime.utc(2026, 10, 19, 10));
      final repo = CatalogSyncRepositoryImpl(
        remote: CatalogRemoteDataSource(dio),
        dao: () => current?.catalogDao,
        appMeta: () => current?.appMetaDao,
        clock: clock,
      );
      final port = CatalogCachePortAdapter(repo);
      engine = CatalogSyncEngine(port: () => port, dao: () => current?.catalogDao, clock: clock);
    });

    tearDown(() async {
      await dbA.close();
      await dbB.close();
    });

    Future<Map<String, Object?>> snapshot(AppDatabase db) async => {
      'full_loaded_at': await db.appMetaDao.read('catalog_full_loaded_at'),
      'units': (await db.select(db.localUnits).get()).length,
      'products': await db.catalogDao.productCount(),
      'prices': (await db.select(db.localPrices).get()).length,
    };

    test('БД сменилась на variants: прогон A прерван, в B ничего не записано и метка загрузки не стоит', () async {
      server.fault = (o, entity, since) {
        if (entity == 'variants') current = dbB;
        return null;
      };
      final r = await engine.ensureLoaded();

      expect(r.phase, CatalogLoadPhase.idle, reason: 'прогон прежней БД не завершается ни ready, ни failed');
      expect(r.fullyLoaded, isFalse);
      final b = await snapshot(dbB);
      expect(b, {'full_loaded_at': null, 'units': 0, 'products': 0, 'prices': 0});
      expect((await snapshot(dbA))['full_loaded_at'], isNull);
    });

    test('вызов для новой БД во время прогона A получает свой прогон: B загружен полностью', () async {
      final switched = Completer<void>();
      server.fault = (o, entity, since) {
        if (entity == 'variants' && !switched.isCompleted) {
          current = dbB;
          switched.complete();
        }
        return null;
      };
      final runA = engine.ensureLoaded();
      await switched.future;
      final runB = engine.ensureLoaded();
      expect(identical(runA, runB), isFalse);

      final a = await runA;
      final b = await runB;

      expect(a.fullyLoaded, isFalse);
      expect((b.phase, b.fullyLoaded), (CatalogLoadPhase.ready, true));
      final snapB = await snapshot(dbB);
      expect(snapB['full_loaded_at'], isNotNull);
      expect((snapB['units'], snapB['products'], snapB['prices']), (1, 5, 5));
    });
  });
}
