// DAO избранного товаров и недавних (07 §11.2: `favorites_products`, `recent_products`; D-32, FAV-).
//
// `favorites_products` — серверная копия; `pending_op` (`add|remove`) — локальное действие до
// подтверждения очередью `outbox_actions` (`favorite.add` / `favorite.remove`; очередь — core/sync).
// `recent_products` — не больше [FavoritesDao.recentLimit] строк; «Очистить» — локально +
// `DELETE /catalog/products/recent` (офлайн — `recent.clear`, 07 §11.2).
import 'package:drift/drift.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/tables/local_tables.dart';

part 'favorites_dao.g.dart';

@DriftAccessor(tables: [LocalFavoritesProducts, LocalRecentProducts])
class FavoritesDao extends DatabaseAccessor<AppDatabase> with _$FavoritesDaoMixin {
  FavoritesDao(super.attachedDatabase);

  /// Предел `recent_products` (07 §11.2: ≤ 50 строк).
  static const int recentLimit = 50;

  // ---------------------------------------------------------------------------
  // Избранное
  // ---------------------------------------------------------------------------

  /// Товары в избранном с учётом неподтверждённых действий (`add` — есть, `remove` — нет).
  Future<Set<String>> favoriteProductIds() async {
    final rows = await (select(
      localFavoritesProducts,
    )..where((t) => t.pendingOp.isNull() | t.pendingOp.equals('add'))).get();
    return {for (final r in rows) r.productId};
  }

  Stream<Set<String>> watchFavoriteProductIds() =>
      (select(localFavoritesProducts)..where((t) => t.pendingOp.isNull() | t.pendingOp.equals('add'))).watch().map(
        (rows) => {for (final r in rows) r.productId},
      );

  /// Строки с неподтверждённым действием (для отправки очередью).
  Future<List<FavoriteProductRow>> pendingFavorites() =>
      (select(localFavoritesProducts)..where((t) => t.pendingOp.isNotNull())).get();

  /// Заменить серверную копию списком [productIds] (полный ответ `GET /favorites/products`).
  /// Строки с `pending_op` не трогаются — локальное действие ещё не подтверждено сервером.
  Future<void> replaceFavoritesFromServer(List<String> productIds, {required int nowMs}) => transaction(() async {
    await (delete(localFavoritesProducts)..where((t) => t.pendingOp.isNull())).go();
    final pending = {for (final r in await pendingFavorites()) r.productId};
    await batch((b) {
      b.insertAll(localFavoritesProducts, [
        for (final id in productIds)
          if (!pending.contains(id)) LocalFavoritesProductsCompanion.insert(productId: id, createdAt: nowMs),
      ], mode: InsertMode.insertOrIgnore);
    });
  });

  /// Локальное действие пользователя до подтверждения сервером (`add` / `remove`).
  Future<void> markFavoritePending(String productId, {required bool add, required int nowMs}) =>
      into(localFavoritesProducts).insertOnConflictUpdate(
        LocalFavoritesProductsCompanion(
          productId: Value(productId),
          createdAt: Value(nowMs),
          pendingOp: Value(add ? 'add' : 'remove'),
        ),
      );

  /// Сервер подтвердил действие: `add` → обычная строка, `remove` → строка удаляется.
  Future<void> confirmFavorite(String productId) => transaction(() async {
    final row = await (select(localFavoritesProducts)..where((t) => t.productId.equals(productId))).getSingleOrNull();
    if (row == null) return;
    if (row.pendingOp == 'remove') {
      await (delete(localFavoritesProducts)..where((t) => t.productId.equals(productId))).go();
    } else {
      await (update(localFavoritesProducts)..where((t) => t.productId.equals(productId))).write(
        const LocalFavoritesProductsCompanion(pendingOp: Value(null)),
      );
    }
  });

  // ---------------------------------------------------------------------------
  // Недавние
  // ---------------------------------------------------------------------------

  /// Просмотр карточки: `last_viewed_at = now`, `view_count + 1`; лишние строки сверх [recentLimit] удаляются.
  Future<void> touchRecent(String productId, {required int nowMs}) => transaction(() async {
    await customInsert(
      'INSERT INTO recent_products (product_id, last_viewed_at, view_count) VALUES (?, ?, 1) '
      'ON CONFLICT(product_id) DO UPDATE SET last_viewed_at = excluded.last_viewed_at, '
      'view_count = recent_products.view_count + 1',
      variables: [Variable.withString(productId), Variable.withInt(nowMs)],
      updates: {localRecentProducts},
    );
    await _trimRecent();
  });

  /// Недавние — новые первыми.
  Future<List<RecentProductRow>> recentProducts({int limit = recentLimit}) =>
      (select(localRecentProducts)
            ..orderBy([(t) => OrderingTerm.desc(t.lastViewedAt), (t) => OrderingTerm.asc(t.productId)])
            ..limit(limit))
          .get();

  Stream<List<RecentProductRow>> watchRecentProducts({int limit = recentLimit}) =>
      (select(localRecentProducts)
            ..orderBy([(t) => OrderingTerm.desc(t.lastViewedAt), (t) => OrderingTerm.asc(t.productId)])
            ..limit(limit))
          .watch();

  /// Заменить локальный список ответом `GET /catalog/products/recent` (`viewedAt` → `last_viewed_at`).
  Future<void> replaceRecentFromServer(List<({String productId, int viewedAtMs})> items) => transaction(() async {
    await delete(localRecentProducts).go();
    await batch((b) {
      b.insertAll(localRecentProducts, [
        for (final i in items) LocalRecentProductsCompanion.insert(productId: i.productId, lastViewedAt: i.viewedAtMs),
      ], mode: InsertMode.insertOrReplace);
    });
    await _trimRecent();
  });

  /// «Очистить» недавние локально (серверная очистка — `DELETE /catalog/products/recent` / outbox `recent.clear`).
  Future<void> clearRecent() => delete(localRecentProducts).go();

  Future<int> _trimRecent() => customUpdate(
    'DELETE FROM recent_products WHERE product_id NOT IN '
    '(SELECT product_id FROM recent_products ORDER BY last_viewed_at DESC, product_id LIMIT ?)',
    variables: [Variable.withInt(recentLimit)],
    updates: {localRecentProducts},
    updateKind: UpdateKind.delete,
  );
}
