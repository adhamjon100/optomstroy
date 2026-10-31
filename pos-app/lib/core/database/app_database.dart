// Локальная БД drift / SQLite (07 §11; D-04, D-32; DATA-250…DATA-264).
//
// Состав таблиц — ровно 07 §11.2 (канон; ядро §18.1, §18.2 п.1); сверка —
// test/core/database/schema_tables_test.dart. Таблиц `cart_drafts`,
// `pending_operations`, `receivables_cache`, `customers_cache` нет.
// Один файл на пользователя: `pos_<user_id>.db` в каталоге поддержки приложения.
// Секреты (токены, deviceId) в drift не пишутся (07 §11.1 п.4).
//
// Миграции (07 §11.5): пошаговые (`stepByStep`), снимки схем —
// lib/core/database/schemas/drift_schema_v<N>.json (`drift_dev schema dump`),
// шаги — migrations/schema_versions.dart (`drift_dev schema steps`), тесты —
// test/core/database/schema_migration_test.dart. Версия схемы дублируется в
// `app_meta.schema_version`.
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:logging/logging.dart';
import 'package:optomstroy/core/database/daos/app_meta_dao.dart';
import 'package:optomstroy/core/database/daos/catalog_dao.dart';
import 'package:optomstroy/core/database/daos/favorites_dao.dart';
import 'package:optomstroy/core/database/migrations/schema_versions.dart';
import 'package:optomstroy/core/database/tables/catalog_tables.dart';
import 'package:optomstroy/core/database/tables/local_tables.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'app_database.g.dart';

@DriftDatabase(
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
    LocalFavoritesCustomers,
    CartDraft,
    CartItemsDraft,
    OutboxActions,
    LocalRecentProducts,
    NotificationsCache,
    LocalSettings,
    RegistrationDraft,
    CheckoutDraft,
    SyncMeta,
    AppMeta,
  ],
  daos: [AppMetaDao, CatalogDao, FavoritesDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  /// Файл БД пользователя [userId] (UUID) — `pos_<user_id>.db` (07 §11.1 п.2).
  factory AppDatabase.forUser(String userId) => AppDatabase(openUserDatabase(userId));

  /// Текущая версия схемы.
  static const int latestSchemaVersion = 5;

  @override
  int get schemaVersion => latestSchemaVersion;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: stepByStep(
      // v1 → v2: `stock_balances.stock_level` (ядро v1.9 §24.2) и
      // `sync_meta.stale_after_sec` (08 §3.13 maxAgeWarningSec).
      from1To2: (m, schema) async {
        await m.addColumn(schema.stockBalances, schema.stockBalances.stockLevel);
        await m.addColumn(schema.syncMeta, schema.syncMeta.staleAfterSec);
      },
      // v2 → v3 (этап E, RM-E-009/RM-E-014): поля контракта 08 §4.24, которых не было в кэше —
      // `Variant.multiplicity`/`unitId`, `Product.defaultVariantId`/`baseUnit.id`/`description`,
      // `Unit.id`/`shortName`, `Packaging.variantId`/`unitId`, `barcodes.type`; индекс упаковок по варианту.
      // Черновики, очередь, настройки и `app_meta` не затрагиваются (07 §11.5).
      from2To3: (m, schema) async {
        await m.addColumn(schema.products, schema.products.defaultVariantId);
        await m.addColumn(schema.products, schema.products.baseUnitId);
        await m.addColumn(schema.products, schema.products.description);
        await m.addColumn(schema.productVariants, schema.productVariants.multiplicityMilli);
        await m.addColumn(schema.productVariants, schema.productVariants.unitId);
        await m.addColumn(schema.units, schema.units.id);
        await m.addColumn(schema.units, schema.units.shortName);
        await m.addColumn(schema.packagings, schema.packagings.variantId);
        await m.addColumn(schema.packagings, schema.packagings.unitId);
        await m.addColumn(schema.barcodes, schema.barcodes.barcodeType);
        await m.create(schema.packagingsVariantIdx);
      },
      // v3 → v4 (ревью E, EQ-CSYNC-02): серверный uuid строки `server_id` у `prices`, `barcodes`,
      // `product_images_meta` — по нему применяется `deleted[]` (08 §4.24). У строк, загруженных до v4,
      // `server_id` пуст: курсор и `as_of` этих сущностей сбрасываются — ближайший инкремент перезагрузит
      // их без `since` («полная замена», `retainOnly`) и заполнит `server_id`. Прочие таблицы не затрагиваются.
      from3To4: (m, schema) async {
        await m.addColumn(schema.prices, schema.prices.serverId);
        await m.addColumn(schema.barcodes, schema.barcodes.serverId);
        await m.addColumn(schema.productImagesMeta, schema.productImagesMeta.serverId);
        await m.create(schema.pricesServerIdIdx);
        await m.create(schema.barcodesServerIdIdx);
        await m.create(schema.productImagesMetaServerIdIdx);
        await m.database.customStatement(
          "UPDATE sync_meta SET server_cursor = NULL, as_of = NULL WHERE entity IN ('prices', 'barcodes', 'images')",
        );
      },
      // v4 → v5 (этап F, D-32): синхронизация черновика корзины с сервером — `cart_items_draft.unit_id`
      // (единица `Quantity` для `PUT /cart/items`, запись `cart.sync` `set_item.unitId`, 07 §11.2) и
      // `cart_draft.server_synced_at` (время последнего ответа сервера — «Данные от …» после перезапуска без сети).
      // Новые столбцы пустые; черновики, очередь, `checkout_draft`, настройки и кэш не затрагиваются (07 §11.5).
      from4To5: (m, schema) async {
        await m.addColumn(schema.cartDraft, schema.cartDraft.serverSyncedAt);
        await m.addColumn(schema.cartItemsDraft, schema.cartItemsDraft.unitId);
      },
    ),
    beforeOpen: (details) async {
      if (details.wasCreated || details.hadUpgrade) {
        await appMetaDao.write(AppMetaDao.schemaVersionKey, '${details.versionNow}');
      }
    },
  );

  /// Имя файла БД пользователя.
  static String fileNameFor(String userId) {
    if (!isUserId(userId)) throw ArgumentError.value(userId, 'userId', 'ожидается UUID');
    return 'pos_${userId.toLowerCase()}.db';
  }

  /// Идентификатор пользователя годится для имени файла БД ([fileNameFor]) — UUID.
  static bool isUserId(String userId) => _uuid.hasMatch(userId);

  /// Исполнитель для файла пользователя в `getApplicationSupportDirectory()`
  /// (фоновый изолят drift_flutter, D-04). В браузере (веб-демо, ADR-113) — [webOptions]: без них `driftDatabase`
  /// бросает `ArgumentError`, и БД пользователя не открывалась бы. [open] — подмена в тестах.
  static QueryExecutor openUserDatabase(String userId, {DriftDatabaseOpener open = driftDatabase}) {
    final fileName = fileNameFor(userId);
    return open(
      name: fileName,
      native: DriftNativeOptions(
        databasePath: () async => p.join((await getApplicationSupportDirectory()).path, fileName),
      ),
      web: webOptions(),
    );
  }

  /// Файл модуля SQLite WebAssembly рядом с `index.html` сайта (на native не используется).
  static const String webSqlite3Wasm = 'sqlite3.wasm';

  /// Скомпилированный воркер drift рядом с `index.html` сайта (на native не используется).
  static const String webDriftWorker = 'drift_worker.js';

  /// Опции drift для сборки в браузере: адреса относительно `<base href>` сайта; drift сам выбирает хранилище
  /// (OPFS или IndexedDB) по возможностям браузера — выбор пишется в журнал. На native опции игнорируются.
  static DriftWebOptions webOptions() => DriftWebOptions(
    sqlite3Wasm: Uri.parse(webSqlite3Wasm),
    driftWorker: Uri.parse(webDriftWorker),
    onResult: logWebResult,
  );

  /// Журнал выбора реализации drift в браузере (вместо `print` drift_flutter по умолчанию). Хранилище без
  /// гарантии сохранности (`unsafeIndexedDb`, `inMemory` — данные пропадут после перезагрузки) — предупреждение.
  static void logWebResult(WasmDatabaseResult result) {
    final WasmStorageImplementation chosen = result.chosenImplementation;
    final String missing = result.missingFeatures.map((MissingBrowserFeature f) => f.name).join(', ');
    final String text = 'drift web: ${chosen.name}${missing.isEmpty ? '' : ' (нет: $missing)'}';
    if (chosen == WasmStorageImplementation.unsafeIndexedDb || chosen == WasmStorageImplementation.inMemory) {
      _log.warning(text);
    } else {
      _log.info(text);
    }
  }
}

/// Сигнатура `driftDatabase` (drift_flutter) — подмена в тестах [AppDatabase.openUserDatabase].
typedef DriftDatabaseOpener =
    QueryExecutor Function({required String name, DriftWebOptions? web, DriftNativeOptions? native});

final Logger _log = Logger('database');

final RegExp _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
