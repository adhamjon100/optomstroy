// Обработчики очереди `outbox_actions` для избранного товаров и недавних (D-32, FAV-, ядро §19.4; 07 §11.2):
//   `favorite.add`    → `PUT /favorites/products/{id}` + `Idempotency-Key` записи → 204;
//   `favorite.remove` → `DELETE /favorites/products/{id}` → 204 (404 — уже нет, считается выполненным);
//   `recent.clear`    → `DELETE /catalog/products/recent` → 204.
// После ответа сервера локальная отметка `favorites_products.pending_op` снимается, только если она
// всё ещё соответствует отправленному действию (пользователь мог переключить звезду ещё раз).
// Сеть — общий Dio ядра (интерсепторы: Auth, Retry, OnlineStatus); пути совпадают с
// `FavoritesRemoteDataSource` фичи favorites (core не импортирует фичи, FL-04).
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/core/sync/outbox_queue.dart';

/// Пути API избранного и недавних (08 §4.13, §4.4).
abstract final class FavoritesApiPaths {
  static const String favorites = '/favorites/products';
  static const String recent = '/catalog/products/recent';

  static String favorite(String productId) => '$favorites/${Uri.encodeComponent(productId)}';
}

/// `favorite.add` / `favorite.remove` (payload `{productId}`).
final class FavoriteOutboxHandler implements OutboxActionHandler {
  FavoriteOutboxHandler({required Dio Function() dio, required AppDatabase? Function() database})
    : _dio = dio,
      _database = database;

  /// Dio берётся при отправке (ленивое создание сетевого клиента).
  final Dio Function() _dio;
  final AppDatabase? Function() _database;

  @override
  Set<String> get types => const {OutboxTypes.favoriteAdd, OutboxTypes.favoriteRemove};

  @override
  Future<OutboxOutcome> handle(OutboxAction action) async {
    final productId = action.payload['productId'];
    if (productId is! String || productId.isEmpty) return OutboxOutcome.dead;
    final add = action.type == OutboxTypes.favoriteAdd;
    // Фоновая отправка: автоповтор интерсептора — профиль background (08 §2.10).
    final options = apiOptions(idempotencyKey: action.idempotencyKey, retry: RetryProfile.background);
    try {
      if (add) {
        await _dio().put<Object?>(FavoritesApiPaths.favorite(productId), options: options);
      } else {
        await _dio().delete<Object?>(FavoritesApiPaths.favorite(productId), options: options);
      }
    } on DioException catch (e) {
      final failure = ErrorMapper.fromDio(e);
      if (!add && failure is ServerFailure && failure.status == 404) {
        await _confirm(action, productId, add: false);
        return OutboxOutcome.done;
      }
      final outcome = outboxOutcomeOf(failure);
      if (outcome == OutboxOutcome.dead) await _revert(action, productId, add: add);
      return outcome;
    }
    await _confirm(action, productId, add: add);
    return OutboxOutcome.done;
  }

  /// БД владельца записи (захвачена очередью на старте прохода), иначе — текущая.
  AppDatabase? _dbFor(OutboxAction action) => action.database ?? _database();

  /// Сервер подтвердил: `add` → обычная строка, `remove` → строка удалена (если отметка не сменилась).
  Future<void> _confirm(OutboxAction action, String productId, {required bool add}) async {
    final db = _dbFor(action);
    if (db == null) return;
    if (add) {
      await db.customUpdate(
        "UPDATE favorites_products SET pending_op = NULL WHERE product_id = ? AND pending_op = 'add'",
        variables: [Variable.withString(productId)],
        updates: {db.localFavoritesProducts},
      );
    } else {
      await db.customUpdate(
        "DELETE FROM favorites_products WHERE product_id = ? AND pending_op = 'remove'",
        variables: [Variable.withString(productId)],
        updates: {db.localFavoritesProducts},
        updateKind: UpdateKind.delete,
      );
    }
  }

  /// Постоянный отказ: локальное действие откатывается (`add` → строка удаляется, `remove` → возвращается).
  Future<void> _revert(OutboxAction action, String productId, {required bool add}) async {
    final db = _dbFor(action);
    if (db == null) return;
    if (add) {
      await db.customUpdate(
        "DELETE FROM favorites_products WHERE product_id = ? AND pending_op = 'add'",
        variables: [Variable.withString(productId)],
        updates: {db.localFavoritesProducts},
        updateKind: UpdateKind.delete,
      );
    } else {
      await db.customUpdate(
        "UPDATE favorites_products SET pending_op = NULL WHERE product_id = ? AND pending_op = 'remove'",
        variables: [Variable.withString(productId)],
        updates: {db.localFavoritesProducts},
      );
    }
  }
}

/// `recent.clear` → `DELETE /catalog/products/recent` (локальная очистка уже выполнена при постановке).
final class RecentClearOutboxHandler implements OutboxActionHandler {
  RecentClearOutboxHandler({required Dio Function() dio}) : _dio = dio;

  final Dio Function() _dio;

  @override
  Set<String> get types => const {OutboxTypes.recentClear};

  @override
  Future<OutboxOutcome> handle(OutboxAction action) async {
    try {
      await _dio().delete<Object?>(
        FavoritesApiPaths.recent,
        options: apiOptions(idempotencyKey: action.idempotencyKey, retry: RetryProfile.background),
      );
      return OutboxOutcome.done;
    } on DioException catch (e) {
      return outboxOutcomeOf(ErrorMapper.fromDio(e));
    }
  }
}
