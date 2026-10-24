// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'catalog_dao.dart';

// ignore_for_file: type=lint
mixin _$CatalogDaoMixin on DatabaseAccessor<AppDatabase> {
  $LocalCategoriesTable get localCategories => attachedDatabase.localCategories;
  $LocalProductsTable get localProducts => attachedDatabase.localProducts;
  $LocalProductVariantsTable get localProductVariants =>
      attachedDatabase.localProductVariants;
  $LocalUnitsTable get localUnits => attachedDatabase.localUnits;
  $LocalPackagingsTable get localPackagings => attachedDatabase.localPackagings;
  $LocalBarcodesTable get localBarcodes => attachedDatabase.localBarcodes;
  $LocalWarehousesTable get localWarehouses => attachedDatabase.localWarehouses;
  $LocalPriceListsTable get localPriceLists => attachedDatabase.localPriceLists;
  $LocalPricesTable get localPrices => attachedDatabase.localPrices;
  $LocalStockBalancesTable get localStockBalances =>
      attachedDatabase.localStockBalances;
  $LocalProductImagesMetaTable get localProductImagesMeta =>
      attachedDatabase.localProductImagesMeta;
  $LocalFavoritesProductsTable get localFavoritesProducts =>
      attachedDatabase.localFavoritesProducts;
  $SyncMetaTable get syncMeta => attachedDatabase.syncMeta;
  $AppMetaTable get appMeta => attachedDatabase.appMeta;
  CatalogDaoManager get managers => CatalogDaoManager(this);
}

class CatalogDaoManager {
  final _$CatalogDaoMixin _db;
  CatalogDaoManager(this._db);
  $$LocalCategoriesTableTableManager get localCategories =>
      $$LocalCategoriesTableTableManager(
        _db.attachedDatabase,
        _db.localCategories,
      );
  $$LocalProductsTableTableManager get localProducts =>
      $$LocalProductsTableTableManager(_db.attachedDatabase, _db.localProducts);
  $$LocalProductVariantsTableTableManager get localProductVariants =>
      $$LocalProductVariantsTableTableManager(
        _db.attachedDatabase,
        _db.localProductVariants,
      );
  $$LocalUnitsTableTableManager get localUnits =>
      $$LocalUnitsTableTableManager(_db.attachedDatabase, _db.localUnits);
  $$LocalPackagingsTableTableManager get localPackagings =>
      $$LocalPackagingsTableTableManager(
        _db.attachedDatabase,
        _db.localPackagings,
      );
  $$LocalBarcodesTableTableManager get localBarcodes =>
      $$LocalBarcodesTableTableManager(_db.attachedDatabase, _db.localBarcodes);
  $$LocalWarehousesTableTableManager get localWarehouses =>
      $$LocalWarehousesTableTableManager(
        _db.attachedDatabase,
        _db.localWarehouses,
      );
  $$LocalPriceListsTableTableManager get localPriceLists =>
      $$LocalPriceListsTableTableManager(
        _db.attachedDatabase,
        _db.localPriceLists,
      );
  $$LocalPricesTableTableManager get localPrices =>
      $$LocalPricesTableTableManager(_db.attachedDatabase, _db.localPrices);
  $$LocalStockBalancesTableTableManager get localStockBalances =>
      $$LocalStockBalancesTableTableManager(
        _db.attachedDatabase,
        _db.localStockBalances,
      );
  $$LocalProductImagesMetaTableTableManager get localProductImagesMeta =>
      $$LocalProductImagesMetaTableTableManager(
        _db.attachedDatabase,
        _db.localProductImagesMeta,
      );
  $$LocalFavoritesProductsTableTableManager get localFavoritesProducts =>
      $$LocalFavoritesProductsTableTableManager(
        _db.attachedDatabase,
        _db.localFavoritesProducts,
      );
  $$SyncMetaTableTableManager get syncMeta =>
      $$SyncMetaTableTableManager(_db.attachedDatabase, _db.syncMeta);
  $$AppMetaTableTableManager get appMeta =>
      $$AppMetaTableTableManager(_db.attachedDatabase, _db.appMeta);
}
