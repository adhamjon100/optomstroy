// Открытие карточки SCR-14 из локального кэша drift (RM-E-008 п. 3, NFR-PERF-003, AC-UI-14-016:
// ≤ 200 мс). Замер — на тестовом DAO (SQLite в памяти, 2 000 товаров в кэше), без устройства:
// интеграционный замер на устройстве — задача тестового этапа (12 T-PERF). Сеть не отвечает —
// карточка показывается из кэша, затем запрос к серверу (кэш-первый порядок). Синтетические данные.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/daos/catalog_dao.dart';
import 'package:optomstroy/core/database/search_norm.dart';
import 'package:optomstroy/core/enums.dart' show RoleCode;
import 'package:optomstroy/core/error/screen_state.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/data/draft/cart_draft_local_repository.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/data/datasources/catalog_remote_data_source.dart';
import 'package:optomstroy/features/catalog/data/repositories/catalog_repositories_impl.dart';
import 'package:optomstroy/features/product_details/presentation/notifiers/product_details_notifier.dart';

import '../../core/database/test_database.dart';
import '../../core/network/fake_adapter.dart';

const String ownerId = '00000000-0000-4000-8000-0000000000aa';
const int productsInCache = 2000;

LocalProductsCompanion productRow(String id, String name, String sku, {String? defaultVariantId, int? minQtyMilli}) =>
    LocalProductsCompanion.insert(
      id: id,
      sku: sku,
      skuNorm: SearchNorm.sku(sku),
      name: name,
      nameNorm: SearchNorm.text(name),
      brand: const Value('Frap'),
      baseUnitCode: '796',
      qtyPrecision: 0,
      defaultVariantId: Value(defaultVariantId),
      baseUnitId: const Value('u-pcs'),
      attributesJson: const Value('{"Бренд":"Frap","Материал":"латунь"}'),
      description: const Value('Однорычажный смеситель для кухни, керамический картридж 40 мм.'),
      minQtyMilli: Value(minQtyMilli),
      serverUpdatedAt: 1000,
    );

LocalProductVariantsCompanion variantRow(
  String id,
  String productId,
  String sku,
  String color, {
  bool def = false,
  int sort = 0,
}) => LocalProductVariantsCompanion.insert(
  id: id,
  productId: productId,
  isDefault: Value(def),
  name: color,
  sku: Value(sku),
  skuNorm: Value(SearchNorm.sku(sku)),
  attributesJson: Value('{"Цвет":"$color"}'),
  sortOrder: Value(sort),
  multiplicityMilli: const Value(1000),
  unitId: const Value('u-pcs'),
  serverUpdatedAt: 1000,
);

Future<void> seedCatalog(CatalogDao dao) async {
  final List<LocalProductsCompanion> products = <LocalProductsCompanion>[
    productRow('p-target', 'Смеситель для ванны Frap F4252', 'F4252', defaultVariantId: 'v-cr', minQtyMilli: 1000),
    for (int i = 0; i < productsInCache; i++) productRow('p-$i', 'Товар $i', 'SKU-$i', defaultVariantId: 'v-$i'),
  ];
  final List<LocalProductVariantsCompanion> variants = <LocalProductVariantsCompanion>[
    variantRow('v-cr', 'p-target', 'F4252-CR', 'Хром', def: true),
    variantRow('v-bk', 'p-target', 'F4252-BK', 'Чёрный', sort: 1),
    variantRow('v-wh', 'p-target', 'F4252-WH', 'Белый', sort: 2),
    for (int i = 0; i < productsInCache; i++) variantRow('v-$i', 'p-$i', 'SKU-$i', 'Хром', def: true),
  ];
  await dao.upsertFromServer(
    CatalogRows(
      units: <LocalUnitsCompanion>[
        LocalUnitsCompanion.insert(
          code: '796',
          name: 'штука',
          qtyPrecision: 0,
          id: const Value('u-pcs'),
          shortName: const Value('шт'),
        ),
      ],
      warehouses: <LocalWarehousesCompanion>[
        LocalWarehousesCompanion.insert(id: 'wh-main', name: 'Основной склад', isDefault: const Value(true)),
        LocalWarehousesCompanion.insert(id: 'wh-2', name: 'Склад №2'),
      ],
      priceLists: <LocalPriceListsCompanion>[
        LocalPriceListsCompanion.insert(id: 'pl-retail', name: 'Розничная', isDefault: const Value(true)),
      ],
      products: products,
      variants: variants,
      packagings: <LocalPackagingsCompanion>[
        LocalPackagingsCompanion.insert(
          id: 'pk-box',
          productId: 'p-target',
          unitCode: '796',
          name: 'кор',
          factorMilli: 6000,
        ),
      ],
      barcodes: <LocalBarcodesCompanion>[
        LocalBarcodesCompanion.insert(value: '4600000000015', productId: 'p-target', variantId: const Value('v-cr')),
      ],
      prices: <LocalPricesCompanion>[
        for (final String v in <String>['v-cr', 'v-bk', 'v-wh'])
          LocalPricesCompanion.insert(variantId: v, priceListId: 'pl-retail', priceTyiyn: 285000, serverSyncedAt: 1000),
        for (int i = 0; i < productsInCache; i++)
          LocalPricesCompanion.insert(
            variantId: 'v-$i',
            priceListId: 'pl-retail',
            priceTyiyn: 10000 + i,
            serverSyncedAt: 1000,
          ),
      ],
      stock: <LocalStockBalancesCompanion>[
        for (final String v in <String>['v-cr', 'v-bk', 'v-wh']) ...<LocalStockBalancesCompanion>[
          LocalStockBalancesCompanion.insert(
            variantId: v,
            warehouseId: 'wh-main',
            availableMilli: const Value(24000),
            stockLevel: const Value('in_stock'),
            snapshotAt: 2000,
          ),
          LocalStockBalancesCompanion.insert(
            variantId: v,
            warehouseId: 'wh-2',
            availableMilli: const Value(3000),
            stockLevel: const Value('low'),
            snapshotAt: 2000,
          ),
        ],
        for (int i = 0; i < productsInCache; i++)
          LocalStockBalancesCompanion.insert(
            variantId: 'v-$i',
            warehouseId: 'wh-main',
            availableMilli: Value(i * 1000),
            stockLevel: const Value('in_stock'),
            snapshotAt: 2000,
          ),
      ],
    ),
  );
}

void main() {
  configureSqliteForTests();
  late AppDatabase db;
  late ProviderContainer container;
  late Completer<ResponseBody> network;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedCatalog(db.catalogDao);
    // Прогрев соединения (в приложении БД пользователя открыта до входа в каталог).
    await db.customSelect('SELECT 1').get();
    network = Completer<ResponseBody>();
    final Dio dio = Dio(BaseOptions(baseUrl: 'https://pos.test/api/v1'))
      ..httpClientAdapter = FakeAdapter((RequestOptions o) => network.future);
    container = ProviderContainer(
      overrides: [
        catalogRepositoryProvider.overrideWithValue(
          CatalogRepositoryImpl(remote: CatalogRemoteDataSource(dio), dao: () => db.catalogDao),
        ),
        cartDraftRepositoryProvider.overrideWithValue(
          CartDraftLocalRepository(
            database: () => db,
            ownerUserId: () => ownerId,
            clock: FixedClock(DateTime.utc(2026, 10, 22, 9)),
          ),
        ),
        catalogViewerRoleProvider.overrideWithValue(RoleCode.seller),
      ],
    );
  });

  tearDown(() async {
    if (!network.isCompleted) network.complete(json(503, problem('INTERNAL', 503)));
    container.dispose();
    await db.close();
  });

  Future<ProductDetailsState> openUntilShown(ProductDetailsArgs args) async {
    final Completer<ProductDetailsState> shown = Completer<ProductDetailsState>();
    final ProviderSubscription<ProductDetailsState> sub = container.listen<ProductDetailsState>(
      productDetailsProvider(args),
      (ProductDetailsState? prev, ProductDetailsState next) {
        if (next.product != null && !shown.isCompleted) shown.complete(next);
      },
      fireImmediately: true,
    );
    final ProductDetailsState s = await shown.future.timeout(const Duration(seconds: 5));
    sub.close();
    return s;
  }

  test('карточка из кэша ≤ 200 мс, до ответа сервера (NFR-PERF-003)', () async {
    // Первое открытие в процессе теста включает JIT-компиляцию кода карточки и маппинга (debug VM);
    // фиксируется отдельно и не является критерием: в приложении (AOT) этой стоимости нет.
    final Stopwatch cold = Stopwatch()..start();
    await openUntilShown((productId: 'p-1', variantId: null, qty: null));
    cold.stop();
    const ProductDetailsArgs args = (productId: 'p-target', variantId: null, qty: null);
    final Stopwatch sw = Stopwatch()..start();
    final ProductDetailsState s = await openUntilShown(args);
    sw.stop();
    // ignore: avoid_print — фиксируем замер в выводе теста (отчёт этапа).
    print(
      'SCR-14 из кэша: ${sw.elapsedMicroseconds / 1000} мс (DAO ${s.cacheOpenTime!.inMicroseconds / 1000} мс); '
      'первое открытие с JIT: ${cold.elapsedMilliseconds} мс; товаров в кэше: ${productsInCache + 1}',
    );
    expect(cold.elapsed, lessThan(const Duration(seconds: 1)));
    expect(s.source, DataSource.cache);
    expect(s.status, ProductLoadStatus.ready);
    expect(sw.elapsed, lessThan(const Duration(milliseconds: 200)));
    expect(s.cacheOpenTime, lessThan(const Duration(milliseconds: 200)));
    // Данные карточки из кэша: вариант по умолчанию, оси, цена, остатки по складам, упаковка.
    expect(s.variant!.id, 'v-cr');
    expect(s.axes, <String>['Цвет']);
    expect(s.price!.amount, Money.som(2850));
    expect(s.stock!.available, Qty.units(24));
    expect(s.variant!.stockByWarehouse.length, 2);
    expect(s.packagings.single.factor, Qty.units(6));
    expect(s.baseUnit!.label, 'шт');
    expect(s.cta, ProductCta.add);
    expect(s.refreshing, isTrue, reason: 'после кэша — запрос к серверу');
  });

  test('повторные открытия разных товаров из кэша — каждое ≤ 200 мс', () async {
    final List<int> times = <int>[];
    for (int i = 0; i < 20; i++) {
      final ProductDetailsArgs args = (productId: 'p-${i * 97}', variantId: null, qty: null);
      final Stopwatch sw = Stopwatch()..start();
      final ProductDetailsState s = await openUntilShown(args);
      sw.stop();
      times.add(sw.elapsedMicroseconds);
      expect(s.source, DataSource.cache);
      expect(s.product!.id, 'p-${i * 97}');
    }
    times.sort();
    // ignore: avoid_print — медиана/максимум в выводе теста.
    print('SCR-14 из кэша ×20: медиана ${times[10] / 1000} мс, максимум ${times.last / 1000} мс');
    expect(Duration(microseconds: times.last), lessThan(const Duration(milliseconds: 200)));
  });

  test('«В корзину» из кэша пишет строку в cart_items_draft (офлайн, AC-UI-14-017)', () async {
    const ProductDetailsArgs args = (productId: 'p-target', variantId: 'v-wh', qty: '2.000');
    final ProviderSubscription<ProductDetailsState> keep = container.listen(productDetailsProvider(args), (_, _) {});
    await openUntilShown(args);
    final ProductDetailsNotifier n = container.read(productDetailsProvider(args).notifier);
    expect(container.read(productDetailsProvider(args)).effectiveQuantity, Qty.units(2), reason: 'qty из маршрута');
    expect(await n.add(), isTrue);
    final List<CartItemDraftRow> rows = await db.select(db.cartItemsDraft).get();
    expect(rows.single.variantId, 'v-wh');
    expect(rows.single.quantityMilli, 2000);
    expect(rows.single.ownerUserId, ownerId);
    expect(rows.single.syncState, 'pending');
    expect(container.read(productDetailsProvider(args)).cta, ProductCta.addMore);
    keep.close();
  });
}
