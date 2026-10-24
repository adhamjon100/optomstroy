// Композиция «кэш → сеть» каталога (RM-E-009 критерий 1, unit-уровень; D-32; 07 §11.4): офлайн — каталог,
// карточка, поиск, штрихкод и остатки из drift без сетевого ожидания (`source = cache`, `asOf`); сбой сети
// онлайн — тот же запрос из кэша; ошибка сервера кэшем не подменяется; адаптеры портов core/sync.
// Фейковый транспорт Dio, drift в памяти, синтетический каталог (не реальная интеграция).
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/screen_state.dart';
import 'package:optomstroy/features/catalog/data/local/catalog_sync_port_adapters.dart';
import 'package:optomstroy/features/catalog/data/repositories/catalog_repositories_impl.dart';
import 'package:optomstroy/features/catalog/data/repositories/offline_first_repositories.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/search.dart';

import '../../../../core/network/fake_adapter.dart';
import '../../../../core/sync/sync_test_support.dart';

void main() {
  late SyncStack stack;
  late OnlineStatus online;
  late OfflineFirstCatalogRepository catalog;
  late OfflineFirstSearchRepository search;
  late OfflineFirstInventoryRepository inventory;
  late bool networkDown;

  setUp(() async {
    stack = SyncStack(FakeCatalogServer(syntheticCatalog(6)));
    await stack.engine().ensureLoaded();
    online = OnlineStatus.online;
    networkDown = false;
    stack.server.fault = (o, entity, since) => null;
    stack.server.routes['/catalog/products'] = (o) =>
        networkDown ? transportError(o, DioExceptionType.connectionError) : json(500, problem('INTERNAL', 500));
    stack.server.routes['/catalog/products/p-2'] = (o) => transportError(o, DioExceptionType.receiveTimeout);
    stack.server.routes['/search/products'] = (o) => transportError(o, DioExceptionType.connectionError);
    stack.server.routes['/search/barcode/4600000000002'] = (o) => transportError(o, DioExceptionType.connectionError);
    stack.server.routes['/inventory/balances'] = (o) => transportError(o, DioExceptionType.connectionError);
    OnlineStatus probe() => online;
    catalog = OfflineFirstCatalogRepository(
      base: CatalogRepositoryImpl(remote: stack.remote, dao: () => stack.db.catalogDao),
      online: probe,
    );
    search = OfflineFirstSearchRepository(
      base: SearchRepositoryImpl(remote: stack.remote, dao: () => stack.db.catalogDao),
      online: probe,
    );
    inventory = OfflineFirstInventoryRepository(
      base: InventoryRepositoryImpl(remote: stack.remote, dao: () => stack.db.catalogDao),
      online: probe,
    );
    stack.adapter.requests.clear();
  });
  tearDown(() => stack.db.close());

  test('офлайн: каталог и карточка из кэша без сетевых запросов, с меткой данных', () async {
    online = OnlineStatus.offline;
    final page = (await catalog.products(const CatalogQuery(limit: 4))).valueOrNull!;
    expect(page.source, DataSource.cache);
    expect(page.items, hasLength(4));
    expect(page.asOf, DateTime.parse(serverTime));
    expect(page.nextCursor, '4');
    final next = (await catalog.products(const CatalogQuery(limit: 4, cursor: '4'))).valueOrNull!;
    expect(next.items, hasLength(2));
    final tree = (await catalog.categories()).valueOrNull!;
    expect(tree.roots.single.name, 'Смесители');
    final product = (await catalog.product('p-3')).valueOrNull!;
    expect(product.name, 'Смеситель p-3');
    expect(product.variants.single.id, 'v-p-3');
    final variants = (await catalog.variants('p-3')).valueOrNull!;
    expect(variants.items.single.id, 'v-p-3');
    expect(stack.adapter.requests, isEmpty, reason: 'офлайн — без ожидания сети');
  });

  test('офлайн: нет товара в кэше → NetworkFailure(offline), а не «не найдено»', () async {
    online = OnlineStatus.offline;
    expect((await catalog.product('p-404')).failureOrNull, isA<NetworkFailure>());
  });

  test('онлайн, сеть оборвалась: тот же запрос из кэша; ошибка сервера 500 не подменяется', () async {
    networkDown = true;
    final page = await catalog.products(const CatalogQuery(limit: 3));
    expect(page.valueOrNull!.source, DataSource.cache);
    expect(stack.adapter.countPath('/catalog/products'), 1);
    networkDown = false;
    expect((await catalog.products(const CatalogQuery())).failureOrNull, isA<ServerFailure>());
    final card = await catalog.product('p-2');
    expect(card.valueOrNull?.id, 'p-2', reason: 'таймаут карточки → кэш');
  });

  test('поиск, штрихкод, остатки: сбой сети → кэш; подсказки офлайн — пусто', () async {
    final found = (await search.searchProducts(const SearchQuery(q: 'p-5'))).valueOrNull!;
    expect(found.page.source, DataSource.cache);
    expect(found.page.items.map((p) => p.id), contains('p-5'));
    final scan = (await search.barcode('4600000000002')).valueOrNull!;
    expect(scan.product.id, 'p-2');
    expect(scan.source, DataSource.cache);
    final stock = (await inventory.balances(['v-p-1'])).valueOrNull!;
    expect(stock.origin, DataSource.cache);
    expect(stock.items.single.variantId, 'v-p-1');
    online = OnlineStatus.offline;
    expect((await search.suggest('см')).valueOrNull, isEmpty);
  });

  test('адаптер CatalogCachePort: сущность вне кэша (attributes) → ошибка; прогресс страниц', () async {
    final port = CatalogCachePortAdapter(stack.syncRepo);
    expect((await port.syncEntity('attributes')).failureOrNull, isA<UnknownFailure>());
    expect((await port.syncEntity('nope')).failureOrNull, isA<UnknownFailure>());
    final pages = <int>[];
    final r = await port.syncEntity('products', restart: true, onPage: (p) => pages.add(p.pages));
    expect(r.valueOrNull!.fullReload, isTrue);
    expect(pages, [1]);
    expect((await port.fullLoadedAt()).valueOrNull, isNotNull);
  });

  test('адаптер SyncStatusPort: статус, пороги устаревания в sync_meta, запуск с Idempotency-Key и step-up', () async {
    stack.server.routes['/sync/status'] = (o) => json(200, {
      'onecReachable': true,
      'checkedAt': '2026-10-19T09:30:00Z',
      'overall': 'degraded',
      'entities': [
        {
          'entity': 'stock',
          'lastSuccessAt': '2026-10-19T09:20:00Z',
          'running': false,
          'consecutiveErrors': 2,
          'intervalSec': 600,
          'ageSec': 600,
          'isStale': false,
        },
      ],
      'outbox': {'pending': 2, 'failed': 1, 'dead': 0},
    });
    stack.server.routes['POST /sync/runs'] = (o) => json(202, {
      'id': 'run-1',
      'entity': 'products',
      'mode': 'full',
      'trigger': 'manual',
      'status': 'queued',
      'startedAt': null,
    });
    final port = SyncStatusPortAdapter(status: SyncStatusRepositoryImpl(stack.remote), cache: stack.syncRepo);
    final status = (await port.status()).valueOrNull!;
    expect((status.overall, status.onecReachable), ('degraded', true));
    expect(status.entity(SyncEntity.stock)!.consecutiveErrors, 2);
    expect(status.outbox!.pending, 2);
    expect((await stack.db.catalogDao.syncMetaOf('stock'))!.staleAfterSec, 1200, reason: '2 × intervalSec');
    final run = await port.startRun(
      entity: SyncEntity.products,
      mode: SyncMode.full,
      idempotencyKey: 'k-1',
      stepUpToken: 'tok',
    );
    expect(run.valueOrNull?.id, 'run-1', reason: '${run.failureOrNull}');
    final post = stack.adapter.requests.lastWhere((r) => r.method == 'POST');
    expect(post.headers['Idempotency-Key'], 'k-1');
    expect(post.headers['X-Step-Up-Token'], 'tok');
    expect(post.data, {'entity': 'products', 'mode': 'full'});
  });
}
