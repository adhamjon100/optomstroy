// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'favorites_dao.dart';

// ignore_for_file: type=lint
mixin _$FavoritesDaoMixin on DatabaseAccessor<AppDatabase> {
  $LocalFavoritesProductsTable get localFavoritesProducts =>
      attachedDatabase.localFavoritesProducts;
  $LocalRecentProductsTable get localRecentProducts =>
      attachedDatabase.localRecentProducts;
  FavoritesDaoManager get managers => FavoritesDaoManager(this);
}

class FavoritesDaoManager {
  final _$FavoritesDaoMixin _db;
  FavoritesDaoManager(this._db);
  $$LocalFavoritesProductsTableTableManager get localFavoritesProducts =>
      $$LocalFavoritesProductsTableTableManager(
        _db.attachedDatabase,
        _db.localFavoritesProducts,
      );
  $$LocalRecentProductsTableTableManager get localRecentProducts =>
      $$LocalRecentProductsTableTableManager(
        _db.attachedDatabase,
        _db.localRecentProducts,
      );
}
