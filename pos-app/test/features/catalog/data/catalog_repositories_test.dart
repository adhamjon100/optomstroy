// Репозитории каталога поверх Dio (фейковый транспорт) и drift (SQLite в памяти):
// загрузка офлайн-кэша `GET /catalog/sync/{entity}` (курсор, `cursor_expired`, «полная замена»,
// ошибка сети), чтение кэша (список, карточка, поиск, штрихкод офлайн), параметры запросов
// каталога/поиска/остатков, заголовки `POST /sync/runs`. Синтетические данные, на фикстурах.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/error/screen_state.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/catalog/data/datasources/catalog_remote_data_source.dart';
import 'package:optomstroy/features/catalog/data/repositories/catalog_repositories_impl.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/inventory.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/domain/entities/search.dart';
import 'package:optomstroy/features/catalog/domain/entities/sync.dart';
import 'package:optomstroy/features/catalog/domain/repositories/catalog_repository.dart';

import '../../../core/database/test_database.dart';
import '../../../core/network/fake_adapter.dart';

const String unitId = '00000000-0000-4000-8000-00000000000a';
const String catId = '00000000-0000-4000-8000-0000000000c1';

Map<String, Object?> page(
  List<Object?> items, {
  List<String> deleted = const [],
  String cursor = 'c',
  bool more = false,
}) => {'items': items, 'deleted': deleted, 'nextCursor': cursor, 'hasMore': more, 'serverTime': '2026-10-19T09:00:00Z'};

Map<String, Object?> syncProduct(String id, String name, String sku) => {
  'id': id,
  'name': name,
  'sku': sku,
  'categoryId': catId,
  'brand': 'Frap',
  'hasVariants': false,
  'defaultVariantId': 'v-$id',
  'baseUnit': {'id': unitId, 'code': 'шт', 'name': 'штука', 'qtyPrecision': 0},
  'attributes': {'color': 'хром'},
  'imageIds': <String>[],
  'deletionMark': false,
  'updatedAt': '2026-10-18T10:00:00Z',
};

void main() {
  configureSqliteForTests();
  late AppDatabase db;
  late FakeAdapter adapter;
  late Dio dio;
  late CatalogRemoteDataSource remote;
  late Map<String, List<Object?>> responses; // путь → очередь ответов (ResponseBody или функция)

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    responses = {};
    adapter = FakeAdapter((options) async {
      final path = options.uri.path.replaceFirst('/api/v1', '');
      final queue = responses[path];
      if (queue == null || queue.isEmpty) return json(404, problem('NOT_FOUND', 404));
      final next = queue.length == 1 ? queue.first : queue.removeAt(0);
      if (next is ResponseBody Function(RequestOptions)) return next(options);
      return next! as ResponseBody;
    });
    dio = Dio(BaseOptions(baseUrl: 'https://pos.test/api/v1'))..httpClientAdapter = adapter;
    remote = CatalogRemoteDataSource(dio);
  });
  tearDown(() => db.close());

  CatalogSyncRepositoryImpl syncRepo() => CatalogSyncRepositoryImpl(
    remote: remote,
    dao: () => db.catalogDao,
    appMeta: () => db.appMetaDao,
    clock: FixedClock(DateTime.utc(2026, 10, 19, 10)),
  );

  Future<void> loadCatalog() async {
    responses['/catalog/sync/units'] = [
      json(
        200,
        page([
          {'id': unitId, 'code': 'шт', 'name': 'штука', 'shortName': 'шт', 'qtyPrecision': 0},
        ], cursor: 'u1'),
      ),
    ];
    responses['/catalog/sync/categories'] = [
      json(
        200,
        page([
          {'id': catId, 'name': 'Смесители', 'productCount': 2, 'sortOrder': 1},
        ], cursor: 'c1'),
      ),
    ];
    responses['/catalog/sync/warehouses'] = [
      json(
        200,
        page([
          {'id': 'wh-1', 'name': 'Основной', 'isActive': true},
        ], cursor: 'w1'),
      ),
    ];
    responses['/catalog/sync/price_lists'] = [
      json(
        200,
        page([
          {
            'id': 'pl-1',
            'name': 'Розничная',
            'isDefault': true,
            'visibleToRoles': ['seller'],
          },
        ], cursor: 'pl1'),
      ),
    ];
    responses['/catalog/sync/products'] = [
      json(200, page([syncProduct('p-1', 'Смеситель Frap F4252', 'F4252-CR')], cursor: 'p1', more: true)),
      json(200, page([syncProduct('p-2', 'Смеситель Frap F4300', 'F4300')], cursor: 'p2')),
    ];
    responses['/catalog/sync/variants'] = [
      json(
        200,
        page([
          {
            'id': 'v-p-1',
            'productId': 'p-1',
            'isDefault': true,
            'name': 'Хром',
            'sku': 'F4252-CR',
            'multiplicity': '1.000',
          },
          {'id': 'v-p-2', 'productId': 'p-2', 'isDefault': true, 'name': 'Хром', 'sku': 'F4300'},
        ], cursor: 'v1'),
      ),
    ];
    responses['/catalog/sync/packagings'] = [
      json(
        200,
        page([
          {'id': 'pk-1', 'variantId': 'v-p-1', 'unitId': unitId, 'name': 'Коробка', 'factor': '6.000'},
        ], cursor: 'pk1'),
      ),
    ];
    responses['/catalog/sync/barcodes'] = [
      json(
        200,
        page([
          {'barcode': '4600000000017', 'variantId': 'v-p-1', 'packagingId': null, 'type': 'EAN13'},
        ], cursor: 'b1'),
      ),
    ];
    responses['/catalog/sync/prices'] = [
      json(
        200,
        page([
          {
            'variantId': 'v-p-1',
            'priceListId': 'pl-1',
            'price': {'amount': '2850.00', 'currency': 'KGS'},
          },
          {
            'variantId': 'v-p-2',
            'priceListId': 'pl-1',
            'price': {'amount': '16007.50', 'currency': 'KGS'},
          },
        ], cursor: 'pr1'),
      ),
    ];
    responses['/catalog/sync/stock'] = [
      json(
        200,
        page([
          {'variantId': 'v-p-1', 'warehouseId': 'wh-1', 'available': '24.000', 'stockLevel': 'in_stock'},
          {'variantId': 'v-p-2', 'warehouseId': 'wh-1', 'stockLevel': 'unknown'},
        ], cursor: 's1'),
      ),
    ];
    responses['/catalog/sync/images'] = [json(200, page(const [], cursor: 'i1'))];
    final repo = syncRepo();
    for (final e in CatalogSyncEntity.cacheLoadOrder) {
      final r = await repo.syncEntity(e);
      expect(r.isSuccess, isTrue, reason: '${e.value}: ${r.failureOrNull}');
    }
  }

  group('CatalogSyncRepository — офлайн-кэш (08 §4.24, 07 §11.4)', () {
    test('первичная загрузка всех сущностей: страницы до hasMore=false, курсоры сохранены', () async {
      final pages = <int>[];
      responses['/catalog/sync/products'] = [
        json(200, page([syncProduct('p-1', 'A', 'A1')], cursor: 'p1', more: true)),
        json(200, page([syncProduct('p-2', 'B', 'B1')], cursor: 'p2')),
      ];
      final result = await syncRepo().syncEntity(CatalogSyncEntity.products, onPage: (p) => pages.add(p.pages));
      final progress = result.valueOrNull!;
      expect((progress.pages, progress.upserted, progress.completed, progress.fullReload), (2, 2, true, true));
      expect(pages, [1, 2]);
      final requests = adapter.requests.where((r) => r.path == '/catalog/sync/products').toList();
      expect(requests, hasLength(2));
      expect((await db.catalogDao.syncMetaOf('products'))!.serverCursor, 'p2');
      expect((await db.catalogDao.syncMetaOf('products'))!.lastSuccessAt, isNotNull);
    });

    test('инкремент идёт с since=<курсор>; deleted[] помечает товар', () async {
      await loadCatalog();
      responses['/catalog/sync/products'] = [
        (RequestOptions o) {
          expect(o.uri.queryParameters['since'], 'p2');
          expect(o.uri.queryParameters['limit'], '200');
          return json(200, page(const [], deleted: ['p-2'], cursor: 'p3'));
        },
      ];
      final r = await syncRepo().syncEntity(CatalogSyncEntity.products);
      expect((r.valueOrNull!.deleted, r.valueOrNull!.fullReload), (1, false));
      expect(await db.catalogDao.productCount(), 1);
    });

    test('409 VERSION_CONFLICT cursor_expired → повтор сущности без since и «полная замена»', () async {
      await loadCatalog();
      var calls = 0;
      responses['/catalog/sync/products'] = [
        (RequestOptions o) {
          calls++;
          if (o.uri.queryParameters.containsKey('since')) {
            return json(409, problem('VERSION_CONFLICT', 409, extra: {'reason': 'cursor_expired'}));
          }
          return json(200, page([syncProduct('p-1', 'Смеситель Frap F4252', 'F4252-CR')], cursor: 'fresh'));
        },
      ];
      final r = await syncRepo().syncEntity(CatalogSyncEntity.products);
      expect(r.isSuccess, isTrue, reason: '${r.failureOrNull}');
      expect(calls, 2);
      expect(r.valueOrNull!.fullReload, isTrue);
      expect(await db.catalogDao.productCount(), 1, reason: 'p-2 нет в полной выгрузке — помечен deletion_mark');
      expect((await db.catalogDao.syncMetaOf('products'))!.serverCursor, 'fresh');
    });

    test('ошибка сети: Failure наружу, курсор не сдвинут, last_error записан', () async {
      responses['/catalog/sync/stock'] = [(RequestOptions o) => transportError(o, DioExceptionType.connectionError)];
      final r = await syncRepo().pullPage(CatalogSyncEntity.stock);
      expect(r.failureOrNull, isA<NetworkFailure>());
      final meta = await db.catalogDao.syncMetaOf('stock');
      expect((meta!.serverCursor, meta.lastError), (null, 'NETWORK_offline'));
    });

    test('attributes в кэш не загружаются; без БД пользователя — CatalogCacheUnavailable', () async {
      final r = await syncRepo().syncEntity(CatalogSyncEntity.attributes);
      expect(r.failureOrNull, isA<UnknownFailure>());
      final noDb = CatalogSyncRepositoryImpl(
        remote: remote,
        dao: () => null,
        appMeta: () => null,
        clock: const SystemClock(),
      );
      final failure = (await noDb.syncEntity(CatalogSyncEntity.units)).failureOrNull;
      expect((failure! as UnknownFailure).cause, isA<CatalogCacheUnavailable>());
      expect((await noDb.fullLoadedAt()).isSuccess, isFalse);
    });

    test('catalog_full_loaded_at и пороги устаревания', () async {
      final repo = syncRepo();
      expect((await repo.fullLoadedAt()).valueOrNull, isNull);
      await repo.markFullLoaded(DateTime.utc(2026, 10, 19, 10));
      expect((await repo.fullLoadedAt()).valueOrNull, DateTime.utc(2026, 10, 19, 10));
      await repo.saveStaleThresholds(
        SyncStatusInfo(
          onecReachable: true,
          checkedAt: DateTime.utc(2026),
          overall: SyncOverall.ok,
          entities: const [SyncEntityStatus(entity: null, entityValue: 'stock', intervalSec: 300)],
        ),
      );
      final states = (await repo.localStates()).valueOrNull!;
      expect(states.single.entity, CatalogSyncEntity.stock);
      expect(states.single.staleAfter, const Duration(minutes: 10));
    });
  });

  group('чтение кэша после загрузки', () {
    setUp(loadCatalog);

    test('cachedProducts: цена в тыйынах, остаток, единица, источник cache', () async {
      final repo = CatalogRepositoryImpl(remote: remote, dao: () => db.catalogDao);
      final page = (await repo.cachedProducts(const CatalogQuery(sort: CatalogSort.priceAsc))).valueOrNull!;
      expect(page.source, DataSource.cache);
      expect(page.totalEstimate, 2);
      expect(page.asOf, DateTime.utc(2026, 10, 19, 9));
      final first = page.items.first;
      expect((first.id, first.price!.amount, first.baseUnit!.label), ('p-1', Money.som(2850), 'шт'));
      expect(first.stock!.available, Qty.units(24));
      expect(page.items.last.stockUnknown, isTrue, reason: 'INV-052: неизвестный остаток');
      final tree = (await repo.cachedCategories()).valueOrNull!;
      expect(tree.roots.single.productCount, 2);
    });

    test('cachedProducts: курсор-смещение и фильтр «в наличии»', () async {
      final repo = CatalogRepositoryImpl(remote: remote, dao: () => db.catalogDao);
      final first = (await repo.cachedProducts(const CatalogQuery(limit: 1))).valueOrNull!;
      expect((first.items.length, first.hasMore, first.nextCursor), (1, true, '1'));
      final second = (await repo.cachedProducts(const CatalogQuery(limit: 1).next(first.nextCursor))).valueOrNull!;
      expect((second.items.length, second.hasMore), (1, false));
      final inStock = (await repo.cachedProducts(
        const CatalogQuery(filter: CatalogFilter(inStock: true)),
      )).valueOrNull!;
      expect(inStock.items.map((p) => p.id), ['p-1']);
    });

    test('cachedProduct: варианты, кратность, упаковка, штрихкод, цена', () async {
      final repo = CatalogRepositoryImpl(remote: remote, dao: () => db.catalogDao);
      final product = (await repo.cachedProduct('p-1')).valueOrNull!;
      expect(product.defaultVariant!.multiplicity, Qty.units(1));
      expect(product.packagings.single.factor, Qty.units(6));
      expect(product.barcodes, ['4600000000017']);
      expect(product.summary.price!.amount.tyiyn, 285000);
      expect(product.attributes, {'color': 'хром'});
      expect((await repo.cachedProduct('нет')).valueOrNull, isNull);
    });

    test('поиск по кэшу и штрихкод офлайн (DATA-259)', () async {
      final repo = SearchRepositoryImpl(remote: remote, dao: () => db.catalogDao);
      final result = (await repo.searchCached(const SearchQuery(q: 'смеситель f4300'))).valueOrNull!;
      expect(result.items.map((p) => (p.id, p.matchType)), [('p-2', MatchType.fts)]);
      final lookup = (await repo.barcodeCached('4600000000017')).valueOrNull!;
      expect((lookup.product.id, lookup.variant.id, lookup.source), ('p-1', 'v-p-1', DataSource.cache));
      expect(lookup.product.matchType, MatchType.barcode);
      expect((await repo.barcodeCached('0000')).valueOrNull, isNull);
    });

    test('остатки из кэша', () async {
      final repo = InventoryRepositoryImpl(remote: remote, dao: () => db.catalogDao);
      final balances = (await repo.cachedBalances(['v-p-1', 'v-p-2'])).valueOrNull!;
      expect(balances.origin, DataSource.cache);
      expect(
        balances.items.map((b) => (b.variantId, b.stockLevel)),
        unorderedEquals([('v-p-1', StockLevel.inStock), ('v-p-2', StockLevel.unknown)]),
      );
      expect(balances.items.firstWhere((b) => b.variantId == 'v-p-1').warehouseName, 'Основной');
    });
  });

  group('сетевые методы: параметры и маппинг', () {
    Map<String, Object?> summary(String id) => {
      'id': id,
      'name': 'Товар $id',
      'price': {
        'priceListId': 'pl-1',
        'price': {'amount': '1234.50', 'currency': 'KGS'},
      },
      'stock': {'variantId': 'v', 'warehouseId': 'w', 'available': '-2.000', 'stockLevel': 'out'},
      'matchType': 'sku',
    };

    test('GET /catalog/products: фильтры через запятую, attr[ключ], Money-строки, sort, limit ≤ 200', () async {
      late Uri uri;
      responses['/catalog/products'] = [
        (RequestOptions o) {
          uri = o.uri;
          return json(
            200,
            {
              'items': [summary('p-1')],
              'nextCursor': 'n1',
              'hasMore': true,
              'facets': {
                'brands': [
                  {'value': 'Frap', 'count': 3},
                ],
              },
            },
            headers: {'X-Data-As-Of': '2026-10-19T08:00:00Z'},
          );
        },
      ];
      final repo = CatalogRepositoryImpl(remote: remote, dao: () => null);
      final r = await repo.products(
        CatalogQuery(
          filter: CatalogFilter(
            categoryId: catId,
            inStock: true,
            priceMin: Money.som(100),
            priceMax: const Money(500050),
            brands: const ['Frap', 'Grohe'],
            attrs: const {'color': 'хром'},
          ),
          sort: CatalogSort.availableDesc,
          limit: 500,
        ),
      );
      final p = r.valueOrNull!;
      expect(uri.queryParameters, {
        'categoryId': catId,
        'inStock': 'true',
        'priceMin': '100.00',
        'priceMax': '5000.50',
        'brand': 'Frap,Grohe',
        'attr[color]': 'хром',
        'sort': 'available:desc',
        'limit': '200',
      });
      expect((p.items.single.price!.amount.tyiyn, p.items.single.stock!.available!.milli), (123450, -2000));
      expect((p.nextCursor, p.hasMore, p.facets!.brands.single.count), ('n1', true, 3));
      expect(p.asOf, DateTime.utc(2026, 10, 19, 8));
    });

    test('новый поиск отменяет предыдущий запрос первой страницы (CancelToken, 06 §6.7, D-31)', () async {
      final gate = Completer<void>();
      final slow = FakeAdapter((o) async {
        if (o.uri.queryParameters['q'] == 'см') await gate.future;
        return json(200, {
          'items': [summary('p-9')],
          'nextCursor': null,
          'hasMore': false,
          'query': o.uri.queryParameters['q'],
          'matchTypes': {'barcode': 0, 'sku': 0, 'fts': 1, 'trgm': 0},
        });
      });
      final repo = SearchRepositoryImpl(
        remote: CatalogRemoteDataSource(Dio(BaseOptions(baseUrl: 'https://pos.test/api/v1'))..httpClientAdapter = slow),
        dao: () => null,
      );
      final first = repo.searchProducts(const SearchQuery(q: 'см'));
      await pumpEventQueue();
      final second = await repo.searchProducts(const SearchQuery(q: 'смес'));
      final stale = await first;
      gate.complete();

      expect(second.valueOrNull!.query, 'смес');
      expect((stale.failureOrNull! as UnknownFailure).cause, DioExceptionType.cancel, reason: 'прежний запрос отменён');
    });

    test('GET /search/products: q, сортировка поиска, matchTypes', () async {
      late Uri uri;
      responses['/search/products'] = [
        (RequestOptions o) {
          uri = o.uri;
          return json(200, {
            'items': [summary('p-9')],
            'nextCursor': null,
            'hasMore': false,
            'query': 'смес',
            'matchTypes': {'barcode': 0, 'sku': 1, 'fts': 0, 'trgm': 0},
          });
        },
      ];
      final repo = SearchRepositoryImpl(remote: remote, dao: () => null);
      final r = (await repo.searchProducts(const SearchQuery(q: 'смес', sort: CatalogSort.skuAsc))).valueOrNull!;
      expect((uri.queryParameters['q'], uri.queryParameters['sort']), ('смес', 'sku:asc'));
      expect((r.items.single.matchType, r.matchTypes.sku, r.query), (MatchType.sku, 1, 'смес'));
      final noDb = await repo.searchCached(const SearchQuery(q: 'x'));
      expect((noDb.failureOrNull! as UnknownFailure).cause, isA<CatalogCacheUnavailable>());
    });

    test('остатки: variantIds через запятую; POST /inventory/check с Idempotency-Key', () async {
      late RequestOptions checkRequest;
      responses['/inventory/balances'] = [
        (RequestOptions o) {
          expect(o.uri.queryParameters['variantIds'], 'v-1,v-2');
          return json(200, {
            'items': [
              {'variantId': 'v-1', 'warehouseId': 'w', 'available': '3.500', 'stockLevel': 'low'},
            ],
            'source': 'live',
          });
        },
      ];
      responses['/inventory/check'] = [
        (RequestOptions o) {
          checkRequest = o;
          return json(200, {
            'ok': false,
            'shortages': [
              {'variantId': 'v-1', 'available': '1.000', 'stockLevel': 'low'},
            ],
            'unavailable': <String>[],
          });
        },
      ];
      final repo = InventoryRepositoryImpl(remote: remote, dao: () => null);
      final balances = (await repo.balances(['v-1', 'v-2'], live: true)).valueOrNull!;
      expect((balances.source, balances.items.single.available), (InventorySource.live, const Qty(3500)));
      final check = await repo.check('w', [
        InventoryCheckLine(variantId: 'v-1', quantity: Qty.parseInput('2,5', precision: 3), unitId: 'u'),
      ], idempotencyKey: 'key-1');
      expect(check.valueOrNull!.shortages.single.available, Qty.units(1));
      expect(checkRequest.headers['Idempotency-Key'], 'key-1');
      expect(checkRequest.data, {
        'warehouseId': 'w',
        'items': [
          {
            'variantId': 'v-1',
            'quantity': {'value': '2.500', 'unitId': 'u'},
          },
        ],
      });
    });

    test('POST /sync/runs: Idempotency-Key и X-Step-Up-Token; GET /sync/status', () async {
      late RequestOptions runRequest;
      responses['/sync/runs'] = [
        (RequestOptions o) {
          runRequest = o;
          return json(202, {'id': 'r-1', 'entity': 'stock', 'mode': 'full', 'trigger': 'manual', 'status': 'queued'});
        },
      ];
      responses['/sync/status'] = [
        json(200, {
          'onecReachable': false,
          'checkedAt': '2026-10-19T09:00:00Z',
          'overall': 'degraded',
          'entities': [
            {'entity': 'stock', 'consecutiveErrors': 3, 'isStale': true, 'intervalSec': 600},
          ],
        }),
      ];
      final repo = SyncStatusRepositoryImpl(remote);
      final run = (await repo.startRun(
        entity: 'stock',
        mode: SyncRunRequestMode.full,
        idempotencyKey: 'idem-1',
        stepUpToken: 'su-1',
      )).valueOrNull!;
      expect((run.trigger, run.statusValue), (SyncTrigger.manual, 'queued'));
      expect(runRequest.headers['Idempotency-Key'], 'idem-1');
      expect(runRequest.headers['X-Step-Up-Token'], 'su-1');
      expect(runRequest.data, {'entity': 'stock', 'mode': 'full'});
      final status = (await repo.status()).valueOrNull!;
      expect((status.overall, status.entities.single.consecutiveErrors), (SyncOverall.degraded, 3));
    });

    test('ошибка сервера → Failure через ErrorMapper (403 FORBIDDEN → PermissionFailure)', () async {
      responses['/catalog/units'] = [json(403, problem('FORBIDDEN', 403))];
      final r = await CatalogRepositoryImpl(remote: remote, dao: () => null).units();
      expect(r.failureOrNull, isA<PermissionFailure>());
      expect(r, isA<FailureResult<Object?>>());
    });
  });
}
