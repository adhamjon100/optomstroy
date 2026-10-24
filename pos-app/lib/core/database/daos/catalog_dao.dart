// DAO кэша каталога (07 §11.2, §11.4; DATA-251, DATA-257, DATA-259, DATA-261).
//
// Запись — только из ответов API (`GET /catalog/sync/{entity}`, 08 §4.24, и экранных ответов):
// публичные методы записи принимают строки сервера и метку синхронизации, локальных правок нет.
// Страница выгрузки применяется атомарно вместе с курсором `sync_meta.server_cursor` —
// прерванная загрузка продолжается с сохранённого курсора без дублей (AC-DATA-257).
// Пакетная вставка — `batch` (одна транзакция на страницу ≤ 200 строк).
//
// Чтение: дерево категорий, список товаров с ценой/остатком варианта по умолчанию,
// поиск по локальному кэшу (штрихкод → артикул → `name_norm`, D-31), карточка товара.
// Клиент не вычисляет `available` (D-22): остаток — значение сервера как есть.
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/daos/app_meta_dao.dart';
import 'package:optomstroy/core/database/search_norm.dart';
import 'package:optomstroy/core/database/tables/catalog_tables.dart';
import 'package:optomstroy/core/database/tables/local_tables.dart';

part 'catalog_dao.g.dart';

/// Сущности `sync_meta.entity` кэша каталога в порядке первичной загрузки (07 §11.4, 08 §4.24).
///
/// Сущность API `attributes` локальной таблицы не имеет (свойства — `products.attributes_json`)
/// и в кэш не загружается.
const List<String> catalogSyncLoadOrder = <String>[
  'units',
  'categories',
  'warehouses',
  'price_lists',
  'products',
  'variants',
  'packagings',
  'barcodes',
  'prices',
  'stock',
  'images',
];

/// Строки сервера для пакетной записи (по таблицам кэша).
final class CatalogRows {
  const CatalogRows({
    this.categories = const <LocalCategoriesCompanion>[],
    this.products = const <LocalProductsCompanion>[],
    this.variants = const <LocalProductVariantsCompanion>[],
    this.units = const <LocalUnitsCompanion>[],
    this.packagings = const <LocalPackagingsCompanion>[],
    this.barcodes = const <LocalBarcodesCompanion>[],
    this.warehouses = const <LocalWarehousesCompanion>[],
    this.priceLists = const <LocalPriceListsCompanion>[],
    this.prices = const <LocalPricesCompanion>[],
    this.stock = const <LocalStockBalancesCompanion>[],
    this.images = const <LocalProductImagesMetaCompanion>[],
  });

  final List<LocalCategoriesCompanion> categories;
  final List<LocalProductsCompanion> products;
  final List<LocalProductVariantsCompanion> variants;
  final List<LocalUnitsCompanion> units;

  /// `product_id` может быть `''` — DAO вычислит его по `variant_id` после вставки.
  final List<LocalPackagingsCompanion> packagings;

  /// `product_id` может быть `''` — DAO вычислит его по `variant_id` после вставки.
  final List<LocalBarcodesCompanion> barcodes;
  final List<LocalWarehousesCompanion> warehouses;
  final List<LocalPriceListsCompanion> priceLists;
  final List<LocalPricesCompanion> prices;
  final List<LocalStockBalancesCompanion> stock;
  final List<LocalProductImagesMetaCompanion> images;

  int get length =>
      categories.length +
      products.length +
      variants.length +
      units.length +
      packagings.length +
      barcodes.length +
      warehouses.length +
      priceLists.length +
      prices.length +
      stock.length +
      images.length;
}

/// Сортировки локального списка — значения API `sort` (08 §4.4.2, §4.5.1).
abstract final class CatalogLocalSort {
  static const String nameAsc = 'name:asc';
  static const String nameDesc = 'name:desc';
  static const String priceAsc = 'price:asc';
  static const String priceDesc = 'price:desc';
  static const String availableDesc = 'available:desc';
  static const String skuAsc = 'sku:asc';
  static const String updatedAtDesc = 'updatedAt:desc';
  static const String popularityDesc = 'popularity:desc';
  static const String relevanceDesc = 'relevance:desc';
}

/// Фильтры локального списка (подмножество фильтров `GET /catalog/products`, 08 §4.4.2).
final class CatalogLocalFilter {
  const CatalogLocalFilter({
    this.categoryId,
    this.includeSubcategories = true,
    this.priceListId,
    this.warehouseId,
    this.inStock = false,
    this.priceMinTyiyn,
    this.priceMaxTyiyn,
    this.brands = const <String>[],
    this.attrs = const <String, String>{},
    this.favoriteOnly = false,
    this.hasImage = false,
    this.productIds,
  });

  final String? categoryId;
  final bool includeSubcategories;

  /// Вид цены; `null` — вид по умолчанию (`price_lists.is_default`, иначе первый видимый).
  final String? priceListId;

  /// Склад остатка; `null` — склад по умолчанию (`warehouses.is_default`, иначе первый активный).
  final String? warehouseId;
  final bool inStock;
  final int? priceMinTyiyn;
  final int? priceMaxTyiyn;
  final List<String> brands;
  final Map<String, String> attrs;
  final bool favoriteOnly;
  final bool hasImage;

  /// Ограничить выборку этими товарами (поиск, избранное, недавние).
  final List<String>? productIds;
}

/// Строка локального списка: товар + вариант по умолчанию + цена + остаток на складе.
final class CachedProductListRow {
  const CachedProductListRow({
    required this.product,
    required this.variantId,
    required this.variantSku,
    required this.priceListId,
    required this.priceTyiyn,
    required this.minPriceTyiyn,
    required this.maxPriceTyiyn,
    required this.warehouseId,
    required this.availableMilli,
    required this.stockLevel,
    required this.stockSnapshotAt,
    required this.variantCount,
    required this.imageSha,
    required this.imageSizesJson,
    required this.isFavorite,
    required this.unit,
    this.matchType,
  });

  final ProductRow product;
  final String? variantId;
  final String? variantSku;

  /// Вид цены, по которому взята цена (или `null`, если видов цен нет).
  final String? priceListId;
  final int? priceTyiyn;
  final int? minPriceTyiyn;
  final int? maxPriceTyiyn;
  final String? warehouseId;
  final int? availableMilli;

  /// `in_stock|low|out|unknown`; `null` — снимка остатка нет.
  final String? stockLevel;
  final int? stockSnapshotAt;
  final int variantCount;
  final String? imageSha;
  final String? imageSizesJson;
  final bool isFavorite;

  /// Базовая единица (по `products.base_unit_code`), если загружена.
  final UnitRow? unit;

  /// `barcode|sku|fts` — только для результатов локального поиска.
  final String? matchType;

  CachedProductListRow withMatchType(String type) => CachedProductListRow(
    product: product,
    variantId: variantId,
    variantSku: variantSku,
    priceListId: priceListId,
    priceTyiyn: priceTyiyn,
    minPriceTyiyn: minPriceTyiyn,
    maxPriceTyiyn: maxPriceTyiyn,
    warehouseId: warehouseId,
    availableMilli: availableMilli,
    stockLevel: stockLevel,
    stockSnapshotAt: stockSnapshotAt,
    variantCount: variantCount,
    imageSha: imageSha,
    imageSizesJson: imageSizesJson,
    isFavorite: isFavorite,
    unit: unit,
    matchType: type,
  );
}

/// Страница локального списка: строки и общее число подходящих товаров («Найдено: N»).
final class CachedProductPage {
  const CachedProductPage({required this.rows, required this.total, required this.offset});

  final List<CachedProductListRow> rows;
  final int total;
  final int offset;

  bool get hasMore => offset + rows.length < total;
}

/// Карточка товара из кэша (SCR-14 офлайн, 07 §11.4 «Открытие карточки товара»).
final class CachedProductCard {
  const CachedProductCard({
    required this.product,
    required this.variants,
    required this.packagings,
    required this.barcodes,
    required this.prices,
    required this.stock,
    required this.images,
    required this.units,
    required this.priceLists,
    required this.warehouses,
    required this.isFavorite,
  });

  final ProductRow product;
  final List<ProductVariantRow> variants;
  final List<PackagingRow> packagings;
  final List<BarcodeRow> barcodes;

  /// Цены всех вариантов по всем загруженным видам цен (только виды цен роли — DATA-262).
  final List<PriceRow> prices;

  /// Остатки всех вариантов по всем складам.
  final List<StockBalanceRow> stock;
  final List<ProductImageMetaRow> images;

  /// Единицы, на которые ссылаются товар, варианты и упаковки.
  final List<UnitRow> units;
  final List<PriceListRow> priceLists;
  final List<WarehouseRow> warehouses;
  final bool isFavorite;
}

@DriftAccessor(
  tables: [
    LocalCategories,
    LocalProducts,
    LocalProductVariants,
    LocalUnits,
    LocalPackagings,
    LocalBarcodes,
    LocalWarehouses,
    LocalPriceLists,
    LocalPrices,
    LocalStockBalances,
    LocalProductImagesMeta,
    LocalFavoritesProducts,
    SyncMeta,
    AppMeta,
  ],
)
class CatalogDao extends DatabaseAccessor<AppDatabase> with _$CatalogDaoMixin {
  CatalogDao(super.attachedDatabase);

  // ---------------------------------------------------------------------------
  // Запись (только из ответов сервера)
  // ---------------------------------------------------------------------------

  /// Пакетный upsert строк сервера (экранные ответы, догрузка карточки). Одна транзакция.
  Future<void> upsertFromServer(CatalogRows rows) => transaction(() async {
    await _upsert(rows);
    await _fixUpReferences(rows);
  });

  /// Применить страницу `GET /catalog/sync/{entity}` (08 §4.24) атомарно с курсором:
  /// upsert [rows], обработка [deletedIds] (товары/варианты/категории — `deletion_mark`, прочие — удаление),
  /// `sync_meta`: `server_cursor = cursor`, `as_of = asOfMs`; при [completed] — `last_success_at = nowMs`.
  Future<void> applySyncPage({
    required String entity,
    required CatalogRows rows,
    required List<String> deletedIds,
    required String cursor,
    required int asOfMs,
    required int nowMs,
    required bool completed,
  }) {
    _checkEntity(entity);
    return transaction(() async {
      await _upsert(rows);
      if (deletedIds.isNotEmpty) await _applyDeleted(entity, deletedIds, asOfMs);
      await _fixUpReferences(rows, entity: entity);
      await into(syncMeta).insertOnConflictUpdate(
        SyncMetaCompanion(
          entity: Value(entity),
          serverCursor: Value(cursor),
          asOf: Value(asOfMs),
          lastError: const Value(null),
          lastSuccessAt: completed ? Value(nowMs) : const Value.absent(),
        ),
      );
    });
  }

  /// Полная выгрузка сущности завершена: строки, не пришедшие в ней, удаляются
  /// (товары, варианты, категории — помечаются `deletion_mark`; 07 §11.2 «полная замена при `full`»).
  /// [keys] — ключи строк выгрузки ([syncKeyOf] для составных ключей).
  Future<int> retainOnly(String entity, Set<String> keys, {required int nowMs}) {
    _checkEntity(entity);
    return transaction(() async {
      await customStatement('CREATE TEMP TABLE IF NOT EXISTS catalog_keep_keys (k TEXT PRIMARY KEY)');
      await customStatement('DELETE FROM catalog_keep_keys');
      final list = keys.toList(growable: false);
      for (var i = 0; i < list.length; i += _chunk) {
        final part = list.sublist(i, i + _chunk > list.length ? list.length : i + _chunk);
        await customStatement(
          'INSERT OR IGNORE INTO catalog_keep_keys (k) VALUES ${List.filled(part.length, '(?)').join(',')}',
          part,
        );
      }
      final key = _keyExpression(entity);
      final notKept = '$key NOT IN (SELECT k FROM catalog_keep_keys)';
      final int affected;
      switch (entity) {
        case 'categories' || 'products' || 'variants':
          affected = await customUpdate(
            'UPDATE ${_tableOf(entity)} SET deletion_mark = 1, server_updated_at = ? '
            'WHERE deletion_mark = 0 AND $notKept',
            variables: [Variable.withInt(nowMs)],
            updates: {_tableInfoOf(entity)},
            updateKind: UpdateKind.update,
          );
        default:
          affected = await customUpdate(
            'DELETE FROM ${_tableOf(entity)} WHERE $notKept',
            updates: {_tableInfoOf(entity)},
            updateKind: UpdateKind.delete,
          );
      }
      await customStatement('DELETE FROM catalog_keep_keys');
      return affected;
    });
  }

  /// Сбросить курсор сущности (`409 VERSION_CONFLICT`, `reason: cursor_expired` → загрузка без `since`).
  Future<void> resetSyncCursor(String entity) {
    _checkEntity(entity);
    return (update(
      syncMeta,
    )..where((t) => t.entity.equals(entity))).write(const SyncMetaCompanion(serverCursor: Value(null)));
  }

  /// Ошибка последней загрузки сущности (машинный код без ПДн).
  Future<void> recordSyncError(String entity, String code) {
    _checkEntity(entity);
    return into(syncMeta).insertOnConflictUpdate(SyncMetaCompanion(entity: Value(entity), lastError: Value(code)));
  }

  /// Порог устаревания из `GET /sync/status` (`maxAgeWarningSec` / `2 × intervalSec`, 07 §11.2).
  Future<void> saveStaleThreshold(String entity, int? staleAfterSec) {
    _checkEntity(entity);
    return into(
      syncMeta,
    ).insertOnConflictUpdate(SyncMetaCompanion(entity: Value(entity), staleAfterSec: Value(staleAfterSec)));
  }

  /// Удалить строки с `deletion_mark`, помеченные раньше границ (07 §11.2: категории — 7 дней, товары — 30).
  Future<void> purgeDeletionMarked({required int categoriesBeforeMs, required int productsBeforeMs}) =>
      transaction(() async {
        await (delete(
          localCategories,
        )..where((t) => t.deletionMark.equals(true) & t.serverUpdatedAt.isSmallerThanValue(categoriesBeforeMs))).go();
        await (delete(
          localProductVariants,
        )..where((t) => t.deletionMark.equals(true) & t.serverUpdatedAt.isSmallerThanValue(productsBeforeMs))).go();
        await (delete(
          localProducts,
        )..where((t) => t.deletionMark.equals(true) & t.serverUpdatedAt.isSmallerThanValue(productsBeforeMs))).go();
      });

  /// Период обслуживания кэша (07 §11.4: «Еженедельно: локальный VACUUM; удаление строк с deletion_mark»).
  static const Duration maintenancePeriod = Duration(days: 7);

  /// Срок хранения категорий с `deletion_mark` (07 §11.2 categories: 7 дней).
  static const Duration categoriesRetention = Duration(days: 7);

  /// Срок хранения товаров и вариантов с `deletion_mark` (07 §11.2 products: 30 дней).
  static const Duration productsRetention = Duration(days: 30);

  /// Еженедельное обслуживание: строки с `deletion_mark` старше сроков 07 §11.2 удаляются, затем `VACUUM`;
  /// метка — `app_meta.catalog_maintenance_at`. Возвращает `true`, если обслуживание выполнено.
  Future<bool> runMaintenance({required int nowMs}) async {
    final AppMetaDao meta = attachedDatabase.appMetaDao;
    final int? last = int.tryParse(await meta.read(AppMetaDao.catalogMaintenanceAtKey) ?? '');
    if (last == null) {
      // Первый запуск на этой БД (обычно сразу после первичной загрузки) — только отсчёт недели.
      await meta.write(AppMetaDao.catalogMaintenanceAtKey, '$nowMs');
      return false;
    }
    if (nowMs - last < maintenancePeriod.inMilliseconds) return false;
    await purgeDeletionMarked(
      categoriesBeforeMs: nowMs - categoriesRetention.inMilliseconds,
      productsBeforeMs: nowMs - productsRetention.inMilliseconds,
    );
    // VACUUM вне транзакции (SQLite не выполняет его внутри транзакции).
    await customStatement('VACUUM');
    await meta.write(AppMetaDao.catalogMaintenanceAtKey, '$nowMs');
    return true;
  }

  // ---------------------------------------------------------------------------
  // Чтение: метки синхронизации
  // ---------------------------------------------------------------------------

  Future<SyncMetaRow?> syncMetaOf(String entity) =>
      (select(syncMeta)..where((t) => t.entity.equals(entity))).getSingleOrNull();

  Future<List<SyncMetaRow>> allSyncMeta() => select(syncMeta).get();

  Stream<List<SyncMetaRow>> watchSyncMeta() => select(syncMeta).watch();

  // ---------------------------------------------------------------------------
  // Чтение: справочники
  // ---------------------------------------------------------------------------

  /// Видимые категории без `deletion_mark` в порядке дерева (глубина, `sort_order`, имя).
  Future<List<CategoryRow>> visibleCategories() =>
      (select(localCategories)
            ..where((t) => t.deletionMark.equals(false) & t.isVisible.equals(true))
            ..orderBy([
              (t) => OrderingTerm.asc(t.depth),
              (t) => OrderingTerm.asc(t.sortOrder),
              (t) => OrderingTerm.asc(t.nameNorm),
            ]))
          .get();

  Future<List<UnitRow>> allUnits() => select(localUnits).get();

  Future<List<WarehouseRow>> allWarehouses() => (select(
    localWarehouses,
  )..orderBy([(t) => OrderingTerm.desc(t.isDefault), (t) => OrderingTerm.asc(t.name)])).get();

  Future<List<PriceListRow>> allPriceLists() => (select(
    localPriceLists,
  )..orderBy([(t) => OrderingTerm.desc(t.isDefault), (t) => OrderingTerm.asc(t.name)])).get();

  /// Вид цены по умолчанию: `is_default`, иначе первый видимый по имени.
  Future<String?> defaultPriceListId() async {
    final row =
        await (select(localPriceLists)
              ..where((t) => t.visible.equals(true))
              ..orderBy([(t) => OrderingTerm.desc(t.isDefault), (t) => OrderingTerm.asc(t.name)])
              ..limit(1))
            .getSingleOrNull();
    return row?.id;
  }

  /// Склад по умолчанию: `is_default`, иначе первый активный по имени.
  Future<String?> defaultWarehouseId() async {
    final row =
        await (select(localWarehouses)
              ..where((t) => t.isActive.equals(true))
              ..orderBy([(t) => OrderingTerm.desc(t.isDefault), (t) => OrderingTerm.asc(t.name)])
              ..limit(1))
            .getSingleOrNull();
    return row?.id;
  }

  /// Число товаров кэша без `deletion_mark`.
  Future<int> productCount() async {
    final row = await customSelect(
      'SELECT COUNT(*) AS c FROM products WHERE deletion_mark = 0',
      readsFrom: {localProducts},
    ).getSingle();
    return row.read<int>('c');
  }

  /// Остатки вариантов (все склады или [warehouseId]).
  Future<List<StockBalanceRow>> stockFor(List<String> variantIds, {String? warehouseId}) async {
    if (variantIds.isEmpty) return const <StockBalanceRow>[];
    final out = <StockBalanceRow>[];
    for (final part in _chunks(variantIds)) {
      final q = select(localStockBalances)..where((t) => t.variantId.isIn(part));
      if (warehouseId != null) q.where((t) => t.warehouseId.equals(warehouseId));
      out.addAll(await q.get());
    }
    return out;
  }

  /// Штрихкод из кэша (офлайн-сканер, DATA-259).
  Future<BarcodeRow?> barcodeByValue(String value) =>
      (select(localBarcodes)..where((t) => t.value.equals(value))).getSingleOrNull();

  // ---------------------------------------------------------------------------
  // Чтение: список, поиск, карточка
  // ---------------------------------------------------------------------------

  /// Страница списка товаров из кэша (SCR-10/SCR-12 офлайн): фильтры, сортировка, `LIMIT/OFFSET`.
  Future<CachedProductPage> listProducts({
    CatalogLocalFilter filter = const CatalogLocalFilter(),
    String sort = CatalogLocalSort.nameAsc,
    int limit = 40,
    int offset = 0,
  }) async {
    final ctx = await _context(filter);
    final where = _where(filter, ctx);
    final total = await customSelect(
      'SELECT COUNT(*) AS c ${_from(ctx)} WHERE ${where.sql}',
      variables: [...ctx.joinVariables, ...where.variables],
      readsFrom: _listTables,
    ).getSingle();
    final rows = await customSelect(
      '$_select ${_from(ctx)} WHERE ${where.sql} ORDER BY ${_orderBy(sort)} LIMIT ? OFFSET ?',
      variables: [
        ...ctx.selectVariables,
        ...ctx.joinVariables,
        ...where.variables,
        Variable.withInt(limit),
        Variable.withInt(offset),
      ],
      readsFrom: _listTables,
    ).get();
    final units = await _unitsByCode();
    return CachedProductPage(
      rows: [for (final r in rows) _listRow(r, units, ctx)],
      total: total.read<int>('c'),
      offset: offset,
    );
  }

  /// Поиск по локальному кэшу (D-31, DATA-261): штрихкод точно → артикул (префикс `sku_norm`)
  /// → все слова запроса входят в `name_norm`. Порядок результатов — по ветке, затем по имени;
  /// при сортировке, отличной от `relevance:desc`, — по [sort]. Не больше [maxCandidates] совпадений.
  Future<CachedProductPage> searchProducts(
    String query, {
    CatalogLocalFilter filter = const CatalogLocalFilter(),
    String sort = CatalogLocalSort.relevanceDesc,
    int limit = 40,
    int offset = 0,
    int maxCandidates = 500,
  }) async {
    final ranked = <String, String>{}; // productId → matchType, в порядке релевантности
    final raw = query.trim();
    if (_barcodePattern.hasMatch(raw)) {
      final hits = await customSelect(
        'SELECT DISTINCT b.product_id AS id FROM barcodes b '
        "WHERE b.value = ? AND b.product_id <> ''",
        variables: [Variable.withString(raw)],
        readsFrom: {localBarcodes},
      ).get();
      for (final h in hits) {
        ranked.putIfAbsent(h.read<String>('id'), () => 'barcode');
      }
    }
    final sku = SearchNorm.sku(raw);
    if (sku.isNotEmpty) {
      final pattern = '${SearchNorm.escapeLike(sku)}%';
      final hits = await customSelect(
        r"SELECT id FROM (SELECT p.id AS id, p.name_norm AS n FROM products p WHERE p.deletion_mark = 0 AND p.sku_norm LIKE ? ESCAPE '\' "
        'UNION SELECT v.product_id AS id, p2.name_norm AS n FROM product_variants v JOIN products p2 ON p2.id = v.product_id '
        r"WHERE v.deletion_mark = 0 AND p2.deletion_mark = 0 AND v.sku_norm LIKE ? ESCAPE '\') ORDER BY n LIMIT ?",
        variables: [Variable.withString(pattern), Variable.withString(pattern), Variable.withInt(maxCandidates)],
        readsFrom: {localProducts, localProductVariants},
      ).get();
      for (final h in hits) {
        ranked.putIfAbsent(h.read<String>('id'), () => 'sku');
      }
    }
    final tokens = SearchNorm.tokens(raw);
    if (tokens.isNotEmpty && ranked.length < maxCandidates) {
      final conditions = List.filled(tokens.length, r"p.name_norm LIKE ? ESCAPE '\'").join(' AND ');
      final hits = await customSelect(
        'SELECT p.id AS id FROM products p WHERE p.deletion_mark = 0 AND $conditions ORDER BY p.name_norm LIMIT ?',
        variables: [
          for (final t in tokens) Variable.withString('%${SearchNorm.escapeLike(t)}%'),
          Variable.withInt(maxCandidates),
        ],
        readsFrom: {localProducts},
      ).get();
      for (final h in hits) {
        if (ranked.length >= maxCandidates) break;
        ranked.putIfAbsent(h.read<String>('id'), () => 'fts');
      }
    }
    if (ranked.isEmpty) return CachedProductPage(rows: const <CachedProductListRow>[], total: 0, offset: offset);

    final scoped = CatalogLocalFilter(
      categoryId: filter.categoryId,
      includeSubcategories: filter.includeSubcategories,
      priceListId: filter.priceListId,
      warehouseId: filter.warehouseId,
      inStock: filter.inStock,
      priceMinTyiyn: filter.priceMinTyiyn,
      priceMaxTyiyn: filter.priceMaxTyiyn,
      brands: filter.brands,
      attrs: filter.attrs,
      favoriteOnly: filter.favoriteOnly,
      hasImage: filter.hasImage,
      productIds: ranked.keys.toList(growable: false),
    );
    final all = await listProducts(
      filter: scoped,
      sort: sort == CatalogLocalSort.relevanceDesc ? CatalogLocalSort.nameAsc : sort,
      limit: ranked.length,
    );
    final rows = [for (final r in all.rows) r.withMatchType(ranked[r.product.id]!)];
    if (sort == CatalogLocalSort.relevanceDesc) {
      final rank = <String, int>{};
      var i = 0;
      for (final id in ranked.keys) {
        rank[id] = i++;
      }
      rows.sort((a, b) => rank[a.product.id]!.compareTo(rank[b.product.id]!));
    }
    final end = offset + limit > rows.length ? rows.length : offset + limit;
    return CachedProductPage(
      rows: offset >= rows.length ? const <CachedProductListRow>[] : rows.sublist(offset, end),
      total: rows.length,
      offset: offset,
    );
  }

  /// Карточка товара из кэша; `null` — товара нет или он помечен на удаление.
  Future<CachedProductCard?> productCard(String productId) async {
    final product = await (select(
      localProducts,
    )..where((t) => t.id.equals(productId) & t.deletionMark.equals(false))).getSingleOrNull();
    if (product == null) return null;
    final variants =
        await (select(localProductVariants)
              ..where((t) => t.productId.equals(productId) & t.deletionMark.equals(false))
              ..orderBy([
                (t) => OrderingTerm.desc(t.isDefault),
                (t) => OrderingTerm.asc(t.sortOrder),
                (t) => OrderingTerm.asc(t.id),
              ]))
            .get();
    final variantIds = [for (final v in variants) v.id];
    final packagings =
        await (select(localPackagings)
              ..where((t) => t.productId.equals(productId))
              ..orderBy([(t) => OrderingTerm.desc(t.isDefault), (t) => OrderingTerm.asc(t.factorMilli)]))
            .get();
    final barcodes = await (select(localBarcodes)..where((t) => t.productId.equals(productId))).get();
    final prices = <PriceRow>[];
    for (final part in _chunks(variantIds)) {
      prices.addAll(await (select(localPrices)..where((t) => t.variantId.isIn(part))).get());
    }
    final stock = await stockFor(variantIds);
    final images =
        await (select(localProductImagesMeta)
              ..where((t) => t.productId.equals(productId))
              ..orderBy([(t) => OrderingTerm.desc(t.isPrimary), (t) => OrderingTerm.asc(t.sortOrder)]))
            .get();
    final unitCodes = <String>{product.baseUnitCode, for (final p in packagings) p.unitCode};
    final unitIds = <String>{
      ?product.baseUnitId,
      for (final v in variants) ?v.unitId,
      for (final p in packagings) ?p.unitId,
    };
    final units = await (select(localUnits)..where((t) => t.code.isIn(unitCodes) | t.id.isIn(unitIds.toList()))).get();
    final favorite =
        await (select(localFavoritesProducts)
              ..where((t) => t.productId.equals(productId) & (t.pendingOp.isNull() | t.pendingOp.equals('add'))))
            .getSingleOrNull();
    return CachedProductCard(
      product: product,
      variants: variants,
      packagings: packagings,
      barcodes: barcodes,
      prices: prices,
      stock: stock,
      images: images,
      units: units,
      priceLists: await allPriceLists(),
      warehouses: await allWarehouses(),
      isFavorite: favorite != null,
    );
  }

  /// Ключ строки для [retainOnly] (составные ключи — через `|`, `NULL` → пустая строка).
  static String syncKeyOf(String entity, List<String?> parts) => switch (entity) {
    'prices' || 'stock' || 'images' => parts.map((p) => p ?? '').join('|'),
    _ => parts.first ?? '',
  };

  // ---------------------------------------------------------------------------
  // Внутреннее
  // ---------------------------------------------------------------------------

  static const int _chunk = 400;
  static final RegExp _barcodePattern = RegExp(r'^[0-9A-Za-z-]{3,64}$');

  Set<ResultSetImplementation<dynamic, dynamic>> get _listTables => {
    localProducts,
    localProductVariants,
    localPrices,
    localStockBalances,
    localProductImagesMeta,
    localFavoritesProducts,
    localCategories,
    localPriceLists,
    localWarehouses,
  };

  static Iterable<List<String>> _chunks(List<String> values) sync* {
    for (var i = 0; i < values.length; i += _chunk) {
      yield values.sublist(i, i + _chunk > values.length ? values.length : i + _chunk);
    }
  }

  static void _checkEntity(String entity) {
    if (!catalogSyncLoadOrder.contains(entity)) {
      throw ArgumentError.value(entity, 'entity', 'ожидается сущность кэша каталога (07 §11.4)');
    }
  }

  static String _tableOf(String entity) => switch (entity) {
    'variants' => 'product_variants',
    'stock' => 'stock_balances',
    'images' => 'product_images_meta',
    _ => entity,
  };

  TableInfo<Table, dynamic> _tableInfoOf(String entity) => switch (entity) {
    'categories' => localCategories,
    'products' => localProducts,
    'variants' => localProductVariants,
    'units' => localUnits,
    'packagings' => localPackagings,
    'barcodes' => localBarcodes,
    'warehouses' => localWarehouses,
    'price_lists' => localPriceLists,
    'prices' => localPrices,
    'stock' => localStockBalances,
    'images' => localProductImagesMeta,
    _ => throw ArgumentError.value(entity, 'entity'),
  };

  static String _keyExpression(String entity) => switch (entity) {
    'units' => 'code',
    'barcodes' => 'value',
    'prices' => "variant_id || '|' || price_list_id || '|' || IFNULL(packaging_id, '')",
    'stock' => "variant_id || '|' || warehouse_id",
    'images' => "sha || '|' || product_id || '|' || IFNULL(variant_id, '')",
    _ => 'id',
  };

  Future<void> _upsert(CatalogRows rows) async {
    if (rows.length == 0) return;
    await batch((b) {
      // Строка сервера с тем же uuid, но другим локальным ключом (сменились значение штрихкода, упаковка цены,
      // вариант фото) — прежняя локальная строка удаляется, иначе она осталась бы навсегда (EQ-CSYNC-02).
      for (final bc in rows.barcodes) {
        final serverId = bc.serverId.present ? bc.serverId.value : null;
        if (serverId == null) continue;
        b.deleteWhere(localBarcodes, (t) => t.serverId.equals(serverId) & t.value.equals(bc.value.value).not());
      }
      b
        ..insertAllOnConflictUpdate(localCategories, rows.categories)
        ..insertAllOnConflictUpdate(localProducts, rows.products)
        ..insertAllOnConflictUpdate(localProductVariants, rows.variants)
        ..insertAllOnConflictUpdate(localUnits, rows.units)
        ..insertAllOnConflictUpdate(localPackagings, rows.packagings)
        ..insertAllOnConflictUpdate(localBarcodes, rows.barcodes)
        ..insertAllOnConflictUpdate(localWarehouses, rows.warehouses)
        ..insertAllOnConflictUpdate(localPriceLists, rows.priceLists)
        ..insertAllOnConflictUpdate(localStockBalances, rows.stock);
      // Первичный ключ с NULL-столбцом (`prices.packaging_id`, `product_images_meta.variant_id`)
      // не даёт конфликта в SQLite — прежняя строка удаляется явно.
      for (final p in rows.prices) {
        final packagingId = p.packagingId.present ? p.packagingId.value : null;
        final serverId = p.serverId.present ? p.serverId.value : null;
        b
          ..deleteWhere(localPrices, (t) {
            final sameKey =
                t.variantId.equals(p.variantId.value) &
                t.priceListId.equals(p.priceListId.value) &
                (packagingId == null ? t.packagingId.isNull() : t.packagingId.equals(packagingId));
            return serverId == null ? sameKey : sameKey | t.serverId.equals(serverId);
          })
          ..insert(localPrices, p);
      }
      for (final img in rows.images) {
        final variantId = img.variantId.present ? img.variantId.value : null;
        final serverId = img.serverId.present ? img.serverId.value : null;
        b
          ..deleteWhere(localProductImagesMeta, (t) {
            final sameKey =
                t.sha.equals(img.sha.value) &
                t.productId.equals(img.productId.value) &
                (variantId == null ? t.variantId.isNull() : t.variantId.equals(variantId));
            return serverId == null ? sameKey : sameKey | t.serverId.equals(serverId);
          })
          ..insert(localProductImagesMeta, img);
      }
    });
  }

  /// `deleted[]` страницы выгрузки (08 §4.24): uuid строк сервера (EQ-CSYNC-02). `prices`, `barcodes`,
  /// `images` удаляются по `server_id` (серверный `id` строки, схема v4); `price_lists` — вместе с ценами
  /// этого вида; `stock` — по `variantId` (у остатков удалений нет: сервер шлёт `deleted[]` пустым).
  Future<void> _applyDeleted(String entity, List<String> ids, int atMs) async {
    for (final part in _chunks(ids)) {
      switch (entity) {
        case 'categories':
          await (update(localCategories)..where((t) => t.id.isIn(part))).write(
            LocalCategoriesCompanion(deletionMark: const Value(true), serverUpdatedAt: Value(atMs)),
          );
        case 'products':
          await (update(localProducts)..where((t) => t.id.isIn(part))).write(
            LocalProductsCompanion(deletionMark: const Value(true), serverUpdatedAt: Value(atMs)),
          );
        case 'variants':
          await (update(localProductVariants)..where((t) => t.id.isIn(part))).write(
            LocalProductVariantsCompanion(deletionMark: const Value(true), serverUpdatedAt: Value(atMs)),
          );
        case 'units':
          await (delete(localUnits)..where((t) => t.id.isIn(part) | t.code.isIn(part))).go();
        case 'packagings':
          await (delete(localPackagings)..where((t) => t.id.isIn(part))).go();
        case 'barcodes':
          await (delete(localBarcodes)..where((t) => t.serverId.isIn(part))).go();
        case 'warehouses':
          await (delete(localWarehouses)..where((t) => t.id.isIn(part))).go();
          await (delete(localStockBalances)..where((t) => t.warehouseId.isIn(part))).go();
        case 'price_lists':
          await (delete(localPriceLists)..where((t) => t.id.isIn(part))).go();
          await (delete(localPrices)..where((t) => t.priceListId.isIn(part))).go();
        case 'prices':
          await (delete(localPrices)..where((t) => t.serverId.isIn(part))).go();
        case 'stock':
          await (delete(localStockBalances)..where((t) => t.variantId.isIn(part))).go();
        case 'images':
          await (delete(localProductImagesMeta)..where((t) => t.serverId.isIn(part))).go();
      }
    }
  }

  /// Ссылки, которых нет в ответе API: `product_id` упаковок и штрихкодов (по варианту),
  /// `unit_code` упаковок (по `units.id`), путь и глубина категорий (по `parent_id`).
  Future<void> _fixUpReferences(CatalogRows rows, {String? entity}) async {
    final variantsChanged = rows.variants.isNotEmpty || entity == 'variants';
    if (rows.packagings.isNotEmpty || variantsChanged) {
      await customUpdate(
        'UPDATE packagings SET product_id = (SELECT v.product_id FROM product_variants v WHERE v.id = packagings.variant_id) '
        "WHERE product_id = '' AND variant_id IS NOT NULL "
        'AND EXISTS (SELECT 1 FROM product_variants v WHERE v.id = packagings.variant_id)',
        updates: {localPackagings},
        updateKind: UpdateKind.update,
      );
    }
    if (rows.packagings.isNotEmpty || rows.units.isNotEmpty) {
      await customUpdate(
        'UPDATE packagings SET unit_code = (SELECT u.code FROM units u WHERE u.id = packagings.unit_id) '
        'WHERE unit_id IS NOT NULL '
        'AND EXISTS (SELECT 1 FROM units u WHERE u.id = packagings.unit_id AND u.code <> packagings.unit_code)',
        updates: {localPackagings},
        updateKind: UpdateKind.update,
      );
    }
    if (rows.products.isNotEmpty || rows.units.isNotEmpty) {
      await customUpdate(
        'UPDATE products SET base_unit_code = (SELECT u.code FROM units u WHERE u.id = products.base_unit_id) '
        'WHERE base_unit_id IS NOT NULL '
        'AND EXISTS (SELECT 1 FROM units u WHERE u.id = products.base_unit_id AND u.code <> products.base_unit_code)',
        updates: {localProducts},
        updateKind: UpdateKind.update,
      );
    }
    if (rows.barcodes.isNotEmpty || variantsChanged) {
      await customUpdate(
        'UPDATE barcodes SET product_id = (SELECT v.product_id FROM product_variants v WHERE v.id = barcodes.variant_id) '
        "WHERE product_id = '' AND variant_id IS NOT NULL "
        'AND EXISTS (SELECT 1 FROM product_variants v WHERE v.id = barcodes.variant_id)',
        updates: {localBarcodes},
        updateKind: UpdateKind.update,
      );
    }
    if (rows.categories.isNotEmpty) await rebuildCategoryPaths();
  }

  /// Пересчитать `path` (`/root/…/id`, как на сервере) и `depth` категорий по `parent_id`.
  /// Родитель, которого ещё нет в кэше, считается корнем до следующей страницы.
  Future<void> rebuildCategoryPaths() async {
    final rows = await customSelect(
      'SELECT id, parent_id, path, depth FROM categories',
      readsFrom: {localCategories},
    ).get();
    final parent = <String, String?>{for (final r in rows) r.read<String>('id'): r.readNullable<String>('parent_id')};
    final computed = <String, (String, int)>{};
    (String, int) resolve(String id, Set<String> seen) {
      final known = computed[id];
      if (known != null) return known;
      final p = parent[id];
      final (String, int) result;
      if (p == null || !parent.containsKey(p) || seen.contains(p)) {
        result = ('/$id', 0);
      } else {
        final (pp, pd) = resolve(p, {...seen, id});
        result = ('$pp/$id', pd + 1);
      }
      computed[id] = result;
      return result;
    }

    final changes = <(String, String, int)>[];
    for (final r in rows) {
      final id = r.read<String>('id');
      final (path, depth) = resolve(id, {id});
      if (path != r.read<String>('path') || depth != r.read<int>('depth')) changes.add((id, path, depth));
    }
    if (changes.isEmpty) return;
    await batch((b) {
      for (final (id, path, depth) in changes) {
        b.update(
          localCategories,
          LocalCategoriesCompanion(path: Value(path), depth: Value(depth)),
          where: (t) => t.id.equals(id),
        );
      }
    });
  }

  Future<Map<String, UnitRow>> _unitsByCode() async => {for (final u in await allUnits()) u.code: u};

  Future<_ListContext> _context(CatalogLocalFilter filter) async => _ListContext(
    priceListId: filter.priceListId ?? await defaultPriceListId(),
    warehouseId: filter.warehouseId ?? await defaultWarehouseId(),
  );

  static const String _imageOrder = 'ORDER BY im.is_primary DESC, im.sort_order, im.sha LIMIT 1';

  static const String _select =
      'SELECT p.*, v.id AS v_id, v.sku AS v_sku, pr.price_tyiyn AS pr_price, '
      'sb.available_milli AS sb_available, sb.stock_level AS sb_level, sb.snapshot_at AS sb_snapshot, '
      '(SELECT MIN(p2.price_tyiyn) FROM prices p2 JOIN product_variants v2 ON v2.id = p2.variant_id '
      'WHERE v2.product_id = p.id AND v2.deletion_mark = 0 AND p2.price_list_id = ? AND p2.packaging_id IS NULL) AS pr_min, '
      '(SELECT MAX(p3.price_tyiyn) FROM prices p3 JOIN product_variants v3 ON v3.id = p3.variant_id '
      'WHERE v3.product_id = p.id AND v3.deletion_mark = 0 AND p3.price_list_id = ? AND p3.packaging_id IS NULL) AS pr_max, '
      '(SELECT COUNT(*) FROM product_variants vc WHERE vc.product_id = p.id AND vc.deletion_mark = 0) AS v_count, '
      'COALESCE(p.primary_image_sha, (SELECT im.sha FROM product_images_meta im WHERE im.product_id = p.id $_imageOrder)) AS img_sha, '
      '(SELECT im.sizes_json FROM product_images_meta im WHERE im.product_id = p.id '
      'AND im.sha = COALESCE(p.primary_image_sha, (SELECT im2.sha FROM product_images_meta im2 WHERE im2.product_id = p.id '
      'ORDER BY im2.is_primary DESC, im2.sort_order, im2.sha LIMIT 1)) $_imageOrder) AS img_sizes, '
      "EXISTS (SELECT 1 FROM favorites_products f WHERE f.product_id = p.id AND (f.pending_op IS NULL OR f.pending_op = 'add')) AS is_fav";

  static String _from(_ListContext _) =>
      'FROM products p '
      'LEFT JOIN product_variants v ON v.id = COALESCE(p.default_variant_id, '
      '(SELECT vd.id FROM product_variants vd WHERE vd.product_id = p.id AND vd.deletion_mark = 0 '
      'ORDER BY vd.is_default DESC, vd.sort_order, vd.id LIMIT 1)) '
      'LEFT JOIN prices pr ON pr.variant_id = v.id AND pr.price_list_id = ? AND pr.packaging_id IS NULL '
      'LEFT JOIN stock_balances sb ON sb.variant_id = v.id AND sb.warehouse_id = ?';

  ({String sql, List<Variable<Object>> variables}) _where(CatalogLocalFilter f, _ListContext ctx) {
    final parts = <String>['p.deletion_mark = 0'];
    final vars = <Variable<Object>>[];
    if (f.productIds != null) {
      if (f.productIds!.isEmpty) return (sql: '0', variables: const <Variable<Object>>[]);
      parts.add('p.id IN (${List.filled(f.productIds!.length, '?').join(',')})');
      vars.addAll(f.productIds!.map(Variable.withString));
    }
    if (f.categoryId != null) {
      if (f.includeSubcategories) {
        parts.add(
          'p.category_id IN (SELECT c.id FROM categories c, categories root '
          "WHERE root.id = ? AND (c.id = root.id OR c.path LIKE root.path || '/%'))",
        );
      } else {
        parts.add('p.category_id = ?');
      }
      vars.add(Variable.withString(f.categoryId!));
    }
    if (f.inStock) {
      parts.add("(sb.available_milli > 0 OR (sb.available_milli IS NULL AND sb.stock_level IN ('in_stock', 'low')))");
    }
    if (f.priceMinTyiyn != null) {
      parts.add('pr.price_tyiyn >= ?');
      vars.add(Variable.withInt(f.priceMinTyiyn!));
    }
    if (f.priceMaxTyiyn != null) {
      parts.add('pr.price_tyiyn <= ?');
      vars.add(Variable.withInt(f.priceMaxTyiyn!));
    }
    if (f.brands.isNotEmpty) {
      parts.add('p.brand IN (${List.filled(f.brands.length, '?').join(',')})');
      vars.addAll(f.brands.map(Variable.withString));
    }
    // `attributes_json` пишет маппер слоя data через `jsonEncode` — пара «ключ: значение» ищется как подстрока.
    f.attrs.forEach((key, value) {
      parts.add(r"p.attributes_json LIKE ? ESCAPE '\'");
      vars.add(Variable.withString('%${SearchNorm.escapeLike('${jsonEncode(key)}:${jsonEncode(value)}')}%'));
    });
    if (f.favoriteOnly) {
      parts.add(
        'EXISTS (SELECT 1 FROM favorites_products f2 WHERE f2.product_id = p.id '
        "AND (f2.pending_op IS NULL OR f2.pending_op = 'add'))",
      );
    }
    if (f.hasImage) {
      parts.add(
        '(p.primary_image_sha IS NOT NULL OR EXISTS (SELECT 1 FROM product_images_meta im3 WHERE im3.product_id = p.id))',
      );
    }
    return (sql: parts.join(' AND '), variables: vars);
  }

  static String _orderBy(String sort) => switch (sort) {
    CatalogLocalSort.nameDesc => 'p.name_norm DESC, p.id',
    CatalogLocalSort.priceAsc => 'pr.price_tyiyn IS NULL, pr.price_tyiyn ASC, p.name_norm, p.id',
    CatalogLocalSort.priceDesc => 'pr.price_tyiyn IS NULL, pr.price_tyiyn DESC, p.name_norm, p.id',
    CatalogLocalSort.availableDesc => 'sb.available_milli IS NULL, sb.available_milli DESC, p.name_norm, p.id',
    CatalogLocalSort.skuAsc => 'p.sku_norm ASC, p.id',
    CatalogLocalSort.updatedAtDesc => 'p.server_updated_at DESC, p.id',
    _ => 'p.name_norm ASC, p.id',
  };

  CachedProductListRow _listRow(QueryRow r, Map<String, UnitRow> units, _ListContext ctx) {
    final product = localProducts.map(r.data);
    return CachedProductListRow(
      product: product,
      variantId: r.readNullable<String>('v_id'),
      variantSku: r.readNullable<String>('v_sku'),
      priceListId: r.readNullable<int>('pr_price') == null ? null : ctx.priceListId,
      priceTyiyn: r.readNullable<int>('pr_price'),
      minPriceTyiyn: r.readNullable<int>('pr_min'),
      maxPriceTyiyn: r.readNullable<int>('pr_max'),
      warehouseId: r.readNullable<String>('sb_level') == null ? null : ctx.warehouseId,
      availableMilli: r.readNullable<int>('sb_available'),
      stockLevel: r.readNullable<String>('sb_level'),
      stockSnapshotAt: r.readNullable<int>('sb_snapshot'),
      variantCount: r.read<int>('v_count'),
      imageSha: r.readNullable<String>('img_sha'),
      imageSizesJson: r.readNullable<String>('img_sizes'),
      isFavorite: r.read<int>('is_fav') == 1,
      unit: units[product.baseUnitCode],
    );
  }
}

final class _ListContext {
  _ListContext({required this.priceListId, required this.warehouseId});

  final String? priceListId;
  final String? warehouseId;

  /// Переменные подзапросов `pr_min`/`pr_max` в SELECT.
  List<Variable<Object>> get selectVariables => [_priceList, _priceList];

  /// Переменные JOIN `prices` и `stock_balances`.
  List<Variable<Object>> get joinVariables => [_priceList, _warehouse];

  Variable<Object> get _priceList => Variable<String>(priceListId ?? '');
  Variable<Object> get _warehouse => Variable<String>(warehouseId ?? '');
}
