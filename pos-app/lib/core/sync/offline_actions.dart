// Действия «сразу локально + outbox» (D-32; 07 §11.2; ядро §19.4; T-FAV-004, T-FAV-008):
//   избранное товара — отметка `favorites_products.pending_op` + запись `favorite.add|remove`;
//   «Очистить недавние» — локальная очистка `recent_products` + запись `recent.clear`.
// UI видит результат сразу (оптимистично), сервер получает действие ровно один раз после восстановления
// сети (идемпотентный ключ записи). Повторное переключение до отправки заменяет запись очереди.
import 'dart:async';

import 'package:drift/drift.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/sync/outbox_queue.dart';
import 'package:optomstroy/core/utils/clock.dart';

/// Причина `UnknownFailure`, когда БД пользователя не открыта или пользователь неизвестен.
final class OfflineStoreUnavailable {
  const OfflineStoreUnavailable();

  @override
  String toString() => 'OfflineStoreUnavailable';
}

final class OfflineActions {
  OfflineActions({
    required AppDatabase? Function() database,
    required OutboxQueue outbox,
    required Clock clock,
    void Function()? onEnqueued,
  }) : _database = database,
       _outbox = outbox,
       _clock = clock,
       _onEnqueued = onEnqueued;

  final AppDatabase? Function() _database;
  final OutboxQueue _outbox;
  final Clock _clock;

  /// Сигнал планировщику «есть что отправить» (попытка отправки, если сеть есть).
  final void Function()? _onEnqueued;

  static const Failure _unavailable = UnknownFailure(cause: OfflineStoreUnavailable());

  /// Добавить товар в избранное или убрать из него (FavoriteToggle, 03 §9.23).
  Future<Result<void>> setFavorite(String productId, {required bool favorite}) async {
    final db = _database();
    if (db == null) return const FailureResult(_unavailable);
    try {
      await db
          .into(db.localFavoritesProducts)
          .insertOnConflictUpdate(
            LocalFavoritesProductsCompanion(
              productId: Value(productId),
              createdAt: Value(_clock.nowUtc().millisecondsSinceEpoch),
              pendingOp: Value(favorite ? 'add' : 'remove'),
            ),
          );
      final key = await _outbox.enqueue(
        favorite ? OutboxTypes.favoriteAdd : OutboxTypes.favoriteRemove,
        {'productId': productId},
        supersedes: {OutboxTypes.favoriteAdd, OutboxTypes.favoriteRemove},
      );
      if (key == null) return const FailureResult(_unavailable);
      _onEnqueued?.call();
      return const Success(null);
    } on Object catch (e) {
      return FailureResult(UnknownFailure(cause: e));
    }
  }

  /// «Очистить» недавние: локально сразу, на сервер — `DELETE /catalog/products/recent` через очередь.
  Future<Result<void>> clearRecent() async {
    final db = _database();
    if (db == null) return const FailureResult(_unavailable);
    try {
      await db.delete(db.localRecentProducts).go();
      final key = await _outbox.enqueue(OutboxTypes.recentClear, const {}, coalesce: true);
      if (key == null) return const FailureResult(_unavailable);
      _onEnqueued?.call();
      return const Success(null);
    } on Object catch (e) {
      return FailureResult(UnknownFailure(cause: e));
    }
  }
}
