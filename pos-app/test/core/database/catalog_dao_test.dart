// CatalogDao (07 §11.2, §11.4; DATA-251, DATA-257, DATA-259, DATA-261): пакетная вставка страницы
// выгрузки вместе с курсором, обработка `deleted[]`, вычисление ссылок (product_id упаковок и
// штрихкодов, путь категорий), «полная замена», список с ценой/остатком варианта по умолчанию,
// поиск по кэшу (штрихкод → артикул → name_norm), карточка товара. Синтетические данные.
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/daos/catalog_dao.dart';
import 'package:optomstroy/core/database/search_norm.dart';

import 'test_database.dart';

const String catRoot = '00000000-0000-4000-8000-0000000000c1';
const String catChild = '00000000-0000-4000-8000-0000000000c2';
const String catOther = '00000000-0000-4000-8000-0000000000c3';

LocalProductsCompanion product(
  String id,
  String name,
  String sku, {
  String? categoryId,
  String? brand,
  String? defaultVariantId,
  String? attributesJson,
  int at = 1000,
}) => LocalProductsCompanion.insert(
  id: id,
  sku: sku,
  skuNorm: SearchNorm.sku(sku),
  name: name,
  nameNorm: SearchNorm.text(name),
  brand: Value(brand),
  categoryId: Value(categoryId),
  baseUnitCode: 'u-pcs',
  qtyPrecision: 0,
  defaultVariantId: Value(defaultVariantId),
  baseUnitId: const Value('u-pcs'),
  attributesJson: Value(attributesJson),
  serverUpdatedAt: at,
);

LocalProductVariantsCompanion variant(
  String id,
  String productId, {
  bool isDefault = false,
  String? sku,
  int sort = 0,
}) => LocalProductVariantsCompanion.insert(
  id: id,
  productId: productId,
  isDefault: Value(isDefault),
  name: 'Вариант $id',
  sku: Value(sku),
  skuNorm: Value(sku == null ? null : SearchNorm.sku(sku)),
  sortOrder: Value(sort),
  serverUpdatedAt: 1000,
);

LocalPricesCompanion price(String variantId, int tyiyn, {String list = 'pl-retail', String? packagingId}) =>
    LocalPricesCompanion.insert(
      variantId: variantId,
      priceListId: list,
      packagingId: Value(packagingId),
      priceTyiyn: tyiyn,
      serverSyncedAt: 1000,
    );

LocalStockBalancesCompanion stock(String variantId, int? availableMilli, String level, {String wh = 'wh-main'}) =>
    LocalStockBalancesCompanion.insert(
      variantId: variantId,
      warehouseId: wh,
      availableMilli: Value(availableMilli),
      stockLevel: Value(level),
      snapshotAt: 2000,
    );

LocalCategoriesCompanion category(String id, String name, {String? parentId}) => LocalCategoriesCompanion.insert(
  id: id,
  parentId: Value(parentId),
  name: name,
  nameNorm: SearchNorm.text(name),
  path: '/$id',
  depth: 0,
  serverUpdatedAt: 1000,
);

Future<void> seed(CatalogDao dao) async {
  await dao.upsertFromServer(
    CatalogRows(
      units: [LocalUnitsCompanion.insert(code: 'шт', name: 'штука', qtyPrecision: 0, id: const Value('u-pcs'))],
      warehouses: [
        LocalWarehousesCompanion.insert(id: 'wh-main', name: 'Основной', isDefault: const Value(true)),
        LocalWarehousesCompanion.insert(id: 'wh-2', name: 'Второй'),
      ],
      priceLists: [
        LocalPriceListsCompanion.insert(id: 'pl-retail', name: 'Розничная', isDefault: const Value(true)),
        LocalPriceListsCompanion.insert(id: 'pl-whole', name: 'Оптовая'),
      ],
      categories: [
        category(catChild, 'Смесители', parentId: catRoot),
        category(catRoot, 'Сантехника'),
        category(catOther, 'Цемент'),
      ],
      products: [
        product(
          'p-1',
          'Смеситель для кухни Grohe Eurosmart',
          'GR-33281',
          categoryId: catChild,
          brand: 'Grohe',
          defaultVariantId: 'v-1a',
          attributesJson: '{"color":"хром"}',
        ),
        product('p-2', 'Смеситель для ванны Frap F4252', 'F4252-CR', categoryId: catChild, brand: 'Frap'),
        product('p-3', 'Цемент М500 50 кг', 'CEM-500', categoryId: catOther),
      ],
      variants: [
        variant('v-1a', 'p-1', isDefault: true, sku: 'GR-33281-CH'),
        variant('v-1b', 'p-1', sku: 'GR-33281-BL', sort: 1),
        variant('v-2', 'p-2', sku: 'F4252-CR'),
        variant('v-3', 'p-3', sku: 'CEM-500'),
      ],
      prices: [
        price('v-1a', 1235050),
        price('v-1b', 1300000),
        price('v-2', 285000),
        price('v-3', 59000),
        price('v-3', 55000, list: 'pl-whole'),
      ],
      stock: [stock('v-1a', 24000, 'in_stock'), stock('v-2', null, 'unknown'), stock('v-3', 0, 'out')],
    ),
  );
}

void main() {
  configureSqliteForTests();
  late AppDatabase db;
  late CatalogDao dao;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    dao = db.catalogDao;
  });
  tearDown(() => db.close());

  group('applySyncPage — пакетная вставка страницы выгрузки (08 §4.24)', () {
    test('200 строк одной страницы и курсор записываются в одной транзакции', () async {
      final rows = [for (var i = 0; i < 200; i++) product('p-$i', 'Товар $i', 'SKU-$i')];
      await dao.applySyncPage(
        entity: 'products',
        rows: CatalogRows(products: rows),
        deletedIds: const <String>[],
        cursor: 'cursor-1',
        asOfMs: 5000,
        nowMs: 6000,
        completed: false,
      );
      expect(await dao.productCount(), 200);
      final meta = await dao.syncMetaOf('products');
      expect((meta!.serverCursor, meta.asOf, meta.lastSuccessAt), ('cursor-1', 5000, null));

      await dao.applySyncPage(
        entity: 'products',
        rows: CatalogRows(products: [product('p-0', 'Товар 0 (новое имя)', 'SKU-0')]),
        deletedIds: const ['p-1', 'p-2'],
        cursor: 'cursor-2',
        asOfMs: 7000,
        nowMs: 8000,
        completed: true,
      );
      expect(await dao.productCount(), 198, reason: 'удалённые товары помечены deletion_mark');
      final again = await dao.syncMetaOf('products');
      expect((again!.serverCursor, again.lastSuccessAt), ('cursor-2', 8000));
      final renamed = await (db.select(db.localProducts)..where((t) => t.id.equals('p-0'))).getSingle();
      expect(renamed.name, 'Товар 0 (новое имя)');
    });

    test('повтор той же страницы не создаёт дублей (upsert по ключу)', () async {
      for (var i = 0; i < 2; i++) {
        await dao.applySyncPage(
          entity: 'prices',
          rows: CatalogRows(
            prices: [
              price('v-1', 100),
              price('v-1', 600, packagingId: 'pk-6'),
            ],
          ),
          deletedIds: const <String>[],
          cursor: 'c',
          asOfMs: 1,
          nowMs: 1,
          completed: true,
        );
      }
      final rows = await db.select(db.localPrices).get();
      expect(rows, hasLength(2), reason: 'NULL в составном ключе prices не даёт дублей');
    });

    test('ошибка внутри страницы откатывает и строки, и курсор', () async {
      await expectLater(
        dao.applySyncPage(
          entity: 'packagings',
          rows: CatalogRows(
            packagings: [
              LocalPackagingsCompanion.insert(id: 'pk', productId: '', unitCode: 'u', name: 'x', factorMilli: 0),
            ],
          ),
          deletedIds: const <String>[],
          cursor: 'bad',
          asOfMs: 1,
          nowMs: 1,
          completed: true,
        ),
        throwsA(isA<SqliteException>()),
      );
      expect(await db.select(db.localPackagings).get(), isEmpty);
      expect(await dao.syncMetaOf('packagings'), isNull);
    });

    test('product_id упаковок и штрихкодов вычисляется по варианту; unit_code — по units.id', () async {
      await seed(dao);
      await dao.applySyncPage(
        entity: 'packagings',
        rows: CatalogRows(
          packagings: [
            LocalPackagingsCompanion.insert(
              id: 'pk-box',
              productId: '',
              unitCode: 'u-pcs',
              name: 'Коробка',
              factorMilli: 6000,
              variantId: const Value('v-1a'),
              unitId: const Value('u-pcs'),
            ),
          ],
        ),
        deletedIds: const <String>[],
        cursor: 'c1',
        asOfMs: 1,
        nowMs: 1,
        completed: true,
      );
      await dao.applySyncPage(
        entity: 'barcodes',
        rows: CatalogRows(
          barcodes: [
            LocalBarcodesCompanion.insert(
              value: '4600000000017',
              productId: '',
              variantId: const Value('v-2'),
              barcodeType: const Value('EAN13'),
            ),
          ],
        ),
        deletedIds: const <String>[],
        cursor: 'c2',
        asOfMs: 1,
        nowMs: 1,
        completed: true,
      );
      final pk = await db.select(db.localPackagings).getSingle();
      expect((pk.productId, pk.unitCode), ('p-1', 'шт'));
      final bc = await dao.barcodeByValue('4600000000017');
      expect((bc!.productId, bc.barcodeType), ('p-2', 'EAN13'));
    });

    test('путь и глубина категорий вычисляются по parent_id (родитель — на другой странице)', () async {
      await dao.applySyncPage(
        entity: 'categories',
        rows: CatalogRows(categories: [category(catChild, 'Смесители', parentId: catRoot)]),
        deletedIds: const <String>[],
        cursor: 'c1',
        asOfMs: 1,
        nowMs: 1,
        completed: false,
      );
      var child = await (db.select(db.localCategories)..where((t) => t.id.equals(catChild))).getSingle();
      expect((child.path, child.depth), ('/$catChild', 0), reason: 'родителя ещё нет — временно корень');
      await dao.applySyncPage(
        entity: 'categories',
        rows: CatalogRows(categories: [category(catRoot, 'Сантехника')]),
        deletedIds: const <String>[],
        cursor: 'c2',
        asOfMs: 1,
        nowMs: 1,
        completed: true,
      );
      child = await (db.select(db.localCategories)..where((t) => t.id.equals(catChild))).getSingle();
      expect((child.path, child.depth), ('/$catRoot/$catChild', 1));
    });

    test('deleted[] prices/barcodes/images — по uuid строки сервера (EQ-CSYNC-02); stock — по variantId', () async {
      const priceId = '11111111-1111-4111-8111-111111111111';
      const otherPriceId = '11111111-1111-4111-8111-111111111112';
      const barcodeId = '22222222-2222-4222-8222-222222222222';
      const imageId = '33333333-3333-4333-8333-333333333333';
      await seed(dao);
      await dao.applySyncPage(
        entity: 'prices',
        rows: CatalogRows(
          prices: [
            price('v-3', 59000).copyWith(serverId: const Value(priceId)),
            price('v-3', 55000, list: 'pl-whole').copyWith(serverId: const Value(otherPriceId)),
          ],
        ),
        deletedIds: const <String>[],
        cursor: 'c',
        asOfMs: 1,
        nowMs: 1,
        completed: true,
      );
      await dao.applySyncPage(
        entity: 'prices',
        rows: const CatalogRows(),
        deletedIds: const [priceId],
        cursor: 'c2',
        asOfMs: 2,
        nowMs: 2,
        completed: true,
      );
      final left = await (db.select(db.localPrices)..where((t) => t.variantId.equals('v-3'))).get();
      expect([for (final r in left) (r.priceListId, r.serverId)], [('pl-whole', otherPriceId)]);

      await dao.applySyncPage(
        entity: 'barcodes',
        rows: CatalogRows(
          barcodes: [
            LocalBarcodesCompanion.insert(
              value: '4600000000001',
              productId: '',
              variantId: const Value('v-3'),
              serverId: const Value(barcodeId),
            ),
          ],
        ),
        deletedIds: const <String>[],
        cursor: 'c',
        asOfMs: 1,
        nowMs: 1,
        completed: true,
      );
      expect(await dao.barcodeByValue('4600000000001'), isNotNull);
      await dao.applySyncPage(
        entity: 'barcodes',
        rows: const CatalogRows(),
        deletedIds: const [barcodeId],
        cursor: 'c2',
        asOfMs: 2,
        nowMs: 2,
        completed: true,
      );
      expect(
        await db.select(db.localBarcodes).get(),
        isEmpty,
        reason: 'удалённый штрихкод не находит товар (DATA-259)',
      );

      await dao.applySyncPage(
        entity: 'images',
        rows: CatalogRows(
          images: [LocalProductImagesMetaCompanion.insert(productId: 'p-3', sha: 'ab', serverId: const Value(imageId))],
        ),
        deletedIds: const <String>[],
        cursor: 'c',
        asOfMs: 1,
        nowMs: 1,
        completed: true,
      );
      await dao.applySyncPage(
        entity: 'images',
        rows: const CatalogRows(),
        deletedIds: const [imageId],
        cursor: 'c2',
        asOfMs: 2,
        nowMs: 2,
        completed: true,
      );
      expect(await db.select(db.localProductImagesMeta).get(), isEmpty);

      await dao.applySyncPage(
        entity: 'stock',
        rows: const CatalogRows(),
        deletedIds: const ['v-1a'],
        cursor: 'c',
        asOfMs: 1,
        nowMs: 1,
        completed: true,
      );
      expect(await dao.stockFor(['v-1a']), isEmpty);
    });

    test('строка с тем же uuid, но новым ключом заменяет прежнюю (штрихкод, цена)', () async {
      const barcodeId = '22222222-2222-4222-8222-222222222222';
      const priceId = '11111111-1111-4111-8111-111111111111';
      await seed(dao);
      for (final value in <String>['4600000000001', '4600000000002']) {
        await dao.applySyncPage(
          entity: 'barcodes',
          rows: CatalogRows(
            barcodes: [
              LocalBarcodesCompanion.insert(
                value: value,
                productId: '',
                variantId: const Value('v-3'),
                serverId: const Value(barcodeId),
              ),
            ],
          ),
          deletedIds: const <String>[],
          cursor: 'c',
          asOfMs: 1,
          nowMs: 1,
          completed: true,
        );
      }
      expect([for (final r in await db.select(db.localBarcodes).get()) r.value], ['4600000000002']);
      for (final pk in <String?>[null, 'pk-6']) {
        await dao.applySyncPage(
          entity: 'prices',
          rows: CatalogRows(
            prices: [price('v-2', 1000, packagingId: pk).copyWith(serverId: const Value(priceId))],
          ),
          deletedIds: const <String>[],
          cursor: 'c',
          asOfMs: 1,
          nowMs: 1,
          completed: true,
        );
      }
      final v2 = await (db.select(db.localPrices)..where((t) => t.variantId.equals('v-2'))).get();
      expect([for (final r in v2) r.packagingId], ['pk-6']);
    });

    test('неизвестная сущность отклоняется (attributes в кэш не загружаются)', () {
      expect(
        () => dao.applySyncPage(
          entity: 'attributes',
          rows: const CatalogRows(),
          deletedIds: const <String>[],
          cursor: 'c',
          asOfMs: 1,
          nowMs: 1,
          completed: true,
        ),
        throwsArgumentError,
      );
    });
  });

  test('еженедельное обслуживание (07 §11.2, §11.4): deletion_mark старше сроков удаляется, затем VACUUM', () async {
    const int day = 24 * 3600 * 1000;
    const int t0 = 100 * day;
    await dao.upsertFromServer(
      CatalogRows(
        categories: [
          category(catRoot, 'Старая').copyWith(deletionMark: const Value(true), serverUpdatedAt: const Value(t0 - day)),
          category(catOther, 'Недавняя').copyWith(deletionMark: const Value(true), serverUpdatedAt: const Value(t0)),
        ],
        products: [
          product('p-old', 'Старый', 'OLD', at: t0 - 25 * day).copyWith(deletionMark: const Value(true)),
          product('p-new', 'Недавний', 'NEW', at: t0).copyWith(deletionMark: const Value(true)),
          product('p-live', 'Живой', 'LIVE', at: t0 - 90 * day),
        ],
      ),
    );
    expect(await dao.runMaintenance(nowMs: t0), isFalse, reason: 'первый запуск — только отсчёт недели');
    expect(await dao.runMaintenance(nowMs: t0 + 6 * day), isFalse, reason: 'неделя не прошла');

    expect(await dao.runMaintenance(nowMs: t0 + 7 * day), isTrue);
    final cats = [for (final r in await db.select(db.localCategories).get()) r.id];
    expect(cats, [catOther], reason: 'категория с deletion_mark ≥ 7 дней удалена');
    final prods = [for (final r in await db.select(db.localProducts).get()) r.id]..sort();
    expect(prods, ['p-live', 'p-new'], reason: 'товар с deletion_mark ≥ 30 дней удалён, живой — нет');
    expect(await db.appMetaDao.read('catalog_maintenance_at'), '${t0 + 7 * day}');
    expect(await dao.runMaintenance(nowMs: t0 + 8 * day), isFalse);
  });

  test('retainOnly: полная замена — не пришедшие товары помечаются, штрихкоды удаляются', () async {
    await seed(dao);
    final marked = await dao.retainOnly('products', {'p-1', 'p-3'}, nowMs: 9000);
    expect(marked, 1);
    expect(await dao.productCount(), 2);
    await dao.upsertFromServer(
      CatalogRows(
        barcodes: [
          LocalBarcodesCompanion.insert(value: 'A1', productId: 'p-1'),
          LocalBarcodesCompanion.insert(value: 'B2', productId: 'p-2'),
        ],
      ),
    );
    expect(await dao.retainOnly('barcodes', {'A1'}, nowMs: 1), 1);
    expect((await db.select(db.localBarcodes).get()).map((b) => b.value), ['A1']);
    final prices = {
      CatalogDao.syncKeyOf('prices', ['v-3', 'pl-whole', null]),
    };
    expect(await dao.retainOnly('prices', prices, nowMs: 1), 4);
  });

  test('resetSyncCursor / recordSyncError / saveStaleThreshold', () async {
    await dao.applySyncPage(
      entity: 'stock',
      rows: const CatalogRows(),
      deletedIds: const <String>[],
      cursor: 'c-9',
      asOfMs: 1,
      nowMs: 1,
      completed: true,
    );
    await dao.recordSyncError('stock', 'NETWORK_offline');
    await dao.saveStaleThreshold('stock', 1200);
    await dao.resetSyncCursor('stock');
    final meta = await dao.syncMetaOf('stock');
    expect((meta!.serverCursor, meta.lastError, meta.staleAfterSec), (null, 'NETWORK_offline', 1200));
  });

  group('listProducts — список из кэша', () {
    setUp(() => seed(dao));

    test('цена и остаток варианта по умолчанию на складе по умолчанию; диапазон цен вариантов', () async {
      final page = await dao.listProducts();
      expect(page.total, 3);
      final p1 = page.rows.firstWhere((r) => r.product.id == 'p-1');
      expect((p1.variantId, p1.priceTyiyn, p1.priceListId), ('v-1a', 1235050, 'pl-retail'));
      expect((p1.availableMilli, p1.stockLevel, p1.warehouseId), (24000, 'in_stock', 'wh-main'));
      expect((p1.variantCount, p1.minPriceTyiyn, p1.maxPriceTyiyn), (2, 1235050, 1300000));
      expect(p1.unit?.code, 'шт');
      final p2 = page.rows.firstWhere((r) => r.product.id == 'p-2');
      expect((p2.stockLevel, p2.availableMilli), ('unknown', null), reason: 'неизвестный остаток — как есть');
    });

    test('вид цены по запросу (оптовая)', () async {
      final page = await dao.listProducts(filter: const CatalogLocalFilter(priceListId: 'pl-whole'));
      final p3 = page.rows.firstWhere((r) => r.product.id == 'p-3');
      expect(p3.priceTyiyn, 55000);
      expect(page.rows.firstWhere((r) => r.product.id == 'p-1').priceTyiyn, isNull);
    });

    test('категория с подкатегориями, бренд, характеристика, «в наличии», цена от/до', () async {
      await dao.rebuildCategoryPaths();
      Future<List<String>> ids(CatalogLocalFilter f) async => [
        for (final r in (await dao.listProducts(filter: f)).rows) r.product.id,
      ];
      expect(await ids(const CatalogLocalFilter(categoryId: catRoot)), unorderedEquals(['p-1', 'p-2']));
      expect(await ids(const CatalogLocalFilter(categoryId: catRoot, includeSubcategories: false)), isEmpty);
      expect(await ids(const CatalogLocalFilter(brands: ['Frap'])), ['p-2']);
      expect(await ids(const CatalogLocalFilter(attrs: {'color': 'хром'})), ['p-1']);
      expect(await ids(const CatalogLocalFilter(inStock: true)), ['p-1']);
      expect(await ids(const CatalogLocalFilter(priceMinTyiyn: 100000, priceMaxTyiyn: 300000)), ['p-2']);
    });

    test('сортировки price:asc, available:desc (без снимка — в конце), sku:asc; LIMIT/OFFSET', () async {
      Future<List<String>> ids(String sort, {int limit = 40, int offset = 0}) async => [
        for (final r in (await dao.listProducts(sort: sort, limit: limit, offset: offset)).rows) r.product.id,
      ];
      expect(await ids(CatalogLocalSort.priceAsc), ['p-3', 'p-2', 'p-1']);
      expect(await ids(CatalogLocalSort.priceDesc), ['p-1', 'p-2', 'p-3']);
      expect(await ids(CatalogLocalSort.availableDesc), ['p-1', 'p-3', 'p-2']);
      expect(await ids(CatalogLocalSort.skuAsc), ['p-3', 'p-2', 'p-1']);
      expect(await ids(CatalogLocalSort.nameAsc, limit: 1, offset: 1), ['p-1']);
      final page = await dao.listProducts(limit: 2);
      expect((page.total, page.rows.length, page.hasMore), (3, 2, true));
    });

    test('избранное: favoriteOnly и признак isFavorite (с учётом pending_op)', () async {
      await db.favoritesDao.markFavoritePending('p-3', add: true, nowMs: 1);
      final page = await dao.listProducts(filter: const CatalogLocalFilter(favoriteOnly: true));
      expect(page.rows.map((r) => (r.product.id, r.isFavorite)), [('p-3', true)]);
      await db.favoritesDao.markFavoritePending('p-3', add: false, nowMs: 2);
      expect((await dao.listProducts(filter: const CatalogLocalFilter(favoriteOnly: true))).rows, isEmpty);
    });
  });

  group('searchProducts — поиск по кэшу (D-31)', () {
    setUp(() async {
      await seed(dao);
      await dao.upsertFromServer(
        CatalogRows(
          barcodes: [
            LocalBarcodesCompanion.insert(value: '4600000000017', productId: 'p-3', variantId: const Value('v-3')),
          ],
        ),
      );
    });

    test('штрихкод точно → matchType barcode', () async {
      final page = await dao.searchProducts('4600000000017');
      expect(page.rows.map((r) => (r.product.id, r.matchType)), [('p-3', 'barcode')]);
    });

    test('артикул префиксом (без разделителей) → sku, раньше совпадений по имени', () async {
      final page = await dao.searchProducts('f4252');
      expect(page.rows.first.product.id, 'p-2');
      expect(page.rows.first.matchType, 'sku');
      final variantSku = await dao.searchProducts('GR 33281 BL');
      expect(variantSku.rows.map((r) => r.product.id), ['p-1']);
    });

    test('«смеситель фрап» — все слова в name_norm; ё/регистр/пунктуация нормализуются', () async {
      final page = await dao.searchProducts('Смеситель, FRAP!');
      expect(page.rows.map((r) => (r.product.id, r.matchType)), [('p-2', 'fts')]);
      expect((await dao.searchProducts('смеситель')).total, 2);
      expect((await dao.searchProducts('100%_нет')).total, 0, reason: 'LIKE-символы экранируются');
    });

    test('фильтры и сортировка применяются к найденному', () async {
      final page = await dao.searchProducts(
        'смеситель',
        filter: const CatalogLocalFilter(inStock: true),
        sort: CatalogLocalSort.priceAsc,
      );
      expect(page.rows.map((r) => r.product.id), ['p-1']);
    });
  });

  test('productCard: варианты, цены всех видов, остатки, единицы, избранное', () async {
    await seed(dao);
    await dao.upsertFromServer(
      CatalogRows(
        images: [
          LocalProductImagesMetaCompanion.insert(
            productId: 'p-1',
            sha: 'a' * 64,
            isPrimary: const Value(true),
            sizesJson: const Value('{"cardUrl":"/api/v1/images/aaa/card"}'),
          ),
        ],
      ),
    );
    final card = await dao.productCard('p-1');
    expect(card, isNotNull);
    expect(card!.variants.map((v) => v.id), ['v-1a', 'v-1b']);
    expect(card.prices, hasLength(2));
    expect(card.stock.map((s) => s.variantId), ['v-1a']);
    expect(card.units.single.code, 'шт');
    expect(card.images.single.isPrimary, isTrue);
    expect(card.priceLists, hasLength(2));
    expect(card.isFavorite, isFalse);
    expect(await dao.productCard('нет-такого'), isNull);
  });

  test('purgeDeletionMarked удаляет только давно помеченные строки', () async {
    await seed(dao);
    await dao.retainOnly('products', {'p-1'}, nowMs: 1000);
    await dao.purgeDeletionMarked(categoriesBeforeMs: 0, productsBeforeMs: 1001);
    expect((await db.select(db.localProducts).get()).map((p) => p.id), ['p-1']);
  });
}
