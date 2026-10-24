// Локальные данные пользователя при выходе / завершении сессии (07 §11.4 «Смена пользователя / выход»,
// «401 SESSION_REVOKED»; 09 §8.3, §8.6, SESS-035):
// - очищаются: `notifications_cache`, `checkout_draft`, `registration_draft`, `local_settings(scope=user)`;
// - НЕ удаляются: `cart_draft`, `cart_items_draft`, `outbox_actions` владельца (`owner_user_id` = пользователь
//   сессии) — отправятся при следующем входе того же пользователя; каталог остаётся (общие данные, не ПДн);
// - строки корзины/outbox чужого `owner_user_id` в файле пользователя отправлены быть не могут (только
//   сессией владельца, 07 §11.1 п.2) — удаляются, чтобы не остаться видимыми.
// Файл БД закрывает владелец `appDatabaseProvider` (app/), не этот класс.
import 'package:drift/drift.dart';
import 'package:optomstroy/core/database/app_database.dart';

/// Неотправленное перед выходом (предупреждение FLOW-009.E1, 07 §11.4).
final class PendingLocalChanges {
  const PendingLocalChanges({
    this.cartItems = 0,
    this.outboxActions = 0,
    this.submittedCheckout = false,
    this.cartDirty = false,
  });

  static const PendingLocalChanges none = PendingLocalChanges();

  /// Неотправленных строк корзины: `sync_state = pending` (в очереди) или `dead` («не отправлено», например после
  /// `409 VERSION_CONFLICT`).
  final int cartItems;

  /// Корзина владельца помечена `cart_draft.dirty = 1` — есть изменения, не подтверждённые сервером
  /// (AC-FLOW-009-07).
  final bool cartDirty;

  /// Действий `outbox_actions` в статусе `pending` / `sending` / `failed`.
  final int outboxActions;

  /// Оформление отправлено (`checkout_draft.submitted_at`), ответ не получен — проверить заказ на сервере.
  final bool submittedCheckout;

  bool get isEmpty => cartItems == 0 && outboxActions == 0 && !submittedCheckout && !cartDirty;

  @override
  String toString() =>
      'PendingLocalChanges(cart: $cartItems, dirty: $cartDirty, outbox: $outboxActions, checkout: $submittedCheckout)';
}

final class SessionLocalData {
  const SessionLocalData(this._db);

  final AppDatabase _db;

  /// Что не отправлено у владельца [ownerUserId] (для предупреждения перед «Выйти»).
  Future<PendingLocalChanges> pending(String? ownerUserId) async {
    if (ownerUserId == null) return PendingLocalChanges.none;
    final items = await (_db.select(
      _db.cartItemsDraft,
    )..where((t) => t.ownerUserId.equals(ownerUserId) & t.syncState.isIn(const <String>['pending', 'dead']))).get();
    final dirty = await (_db.select(
      _db.cartDraft,
    )..where((t) => t.ownerUserId.equals(ownerUserId) & t.dirty.equals(true))).get();
    final outbox =
        await (_db.select(_db.outboxActions)..where(
              (t) => t.ownerUserId.equals(ownerUserId) & t.status.isIn(const <String>['pending', 'sending', 'failed']),
            ))
            .get();
    final submitted = await (_db.select(_db.checkoutDraft)..where((t) => t.submittedAt.isNotNull())).get();
    return PendingLocalChanges(
      cartItems: items.length,
      outboxActions: outbox.length,
      submittedCheckout: submitted.isNotEmpty,
      cartDirty: dirty.isNotEmpty,
    );
  }

  /// Очистка при выходе / `SESSION_REVOKED` для владельца [ownerUserId] (`null` — владелец неизвестен:
  /// черновики корзины и outbox не трогаются).
  Future<void> clearOnSessionEnd(String? ownerUserId) => _db.transaction(() async {
    await _db.delete(_db.notificationsCache).go();
    await _db.delete(_db.checkoutDraft).go();
    await _db.delete(_db.registrationDraft).go();
    await (_db.delete(_db.localSettings)..where((t) => t.scope.equals('user'))).go();
    if (ownerUserId != null) {
      await (_db.delete(_db.cartItemsDraft)..where((t) => t.ownerUserId.equals(ownerUserId).not())).go();
      await (_db.delete(_db.cartDraft)..where((t) => t.ownerUserId.equals(ownerUserId).not())).go();
      await (_db.delete(_db.outboxActions)..where((t) => t.ownerUserId.equals(ownerUserId).not())).go();
    }
  });
}
