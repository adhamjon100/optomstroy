// Локальные данные пользователя при выходе / завершении сессии (07 §11.4 «Смена пользователя / выход»,
// «401 SESSION_REVOKED»; 09 §8.3, §8.6, SESS-035):
// - очищаются: `notifications_cache`, `checkout_draft`, `registration_draft`, `local_settings(scope=user)`;
// - НЕ удаляются: `cart_draft`, `cart_items_draft`, `outbox_actions` владельца (`owner_user_id` = пользователь
//   сессии) — отправятся при следующем входе того же пользователя; каталог остаётся (общие данные, не ПДн);
// - строки корзины/outbox чужого `owner_user_id` в файле пользователя отправлены быть не могут (только
//   сессией владельца, 07 §11.1 п.2) — удаляются, чтобы не остаться видимыми.
// Файл БД закрывает владелец `appDatabaseProvider` (app/), не этот класс.
//
// Планшет магазина (ADR-115; 07 §11.2, DATA-304; 04 FLOW-045.A2; 11 PRIV-033 (2)):
// [SessionLocalData.clearKioskVolatile] при каждом запуске, до первого `POST /kiosk/reset`, удаляет из файла БД
// технического пользователя всё, что могло остаться от покупателя (корзина планшета — только на сервере, такие строки
// не создаются; это защита на случай ошибки). Кэш каталога, `sync_meta`, настройки устройства и метка сброса без сети
// `kiosk.pending_reset_cart_id` остаются.
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

  /// Ключи `settings`, которые на планшете между покупателями не сохраняются (07 §11.2, DATA-304; 10 KIOSK-021):
  /// история поиска и последний корень каталога. Имена — `CatalogSettingKeys` фичи catalog (core фичи не импортирует).
  static const List<String> kioskVolatileSettings = <String>['search_history', 'catalog_last_root'];

  /// Префиксы ключей `settings` вида списка и сортировки каталога (`catalog_view_mode.<класс окна>`,
  /// `catalog_sort.catalog|search`) — на планшете тоже не сохраняются.
  static const List<String> kioskVolatileSettingPrefixes = <String>['catalog_view_mode.', 'catalog_sort.'];

  /// Ключи `app_meta` очереди корзины сотрудника (`DriftCartSync.conflictMetaKey`, `replaceMetaKey`): у планшета
  /// конфликта версий в очереди и смены варианта через журнал нет.
  static const List<String> kioskVolatileMeta = <String>['cart_version_conflict', 'cart_variant_replace'];

  /// Очистка файла БД планшета магазина [ownerUserId] (технический пользователь `kind=kiosk`) при запуске, до первого
  /// `POST /kiosk/reset` (04 FLOW-045.A2; 07 §11.2, DATA-304; 10 KIOSK-020): строки `cart_draft`, `cart_items_draft`,
  /// `checkout_draft`, `recent_products`, `favorites_*`, `notifications_cache`, записи `outbox_actions` любого типа
  /// (в том числе `cart.sync` и `recent.touch`), ключи `settings` истории поиска, последнего корня, вида и сортировки
  /// каталога. Строки с чужим `owner_user_id` в файле планшета отправить нельзя (07 §11.1 п. 2) — удаляются тоже.
  /// Метка сброса без сети (`app_meta.kiosk.pending_reset_cart_id`), кэш каталога и `sync_meta` не трогаются.
  /// Вызывает корзина планшета (`KioskCartSync.prepare`) только для сессии `kind=kiosk`.
  Future<void> clearKioskVolatile(String ownerUserId) => _db.transaction(() async {
    await _db.delete(_db.cartItemsDraft).go();
    await _db.delete(_db.cartDraft).go();
    await _db.delete(_db.outboxActions).go();
    await _db.delete(_db.checkoutDraft).go();
    await _db.delete(_db.localRecentProducts).go();
    await _db.delete(_db.localFavoritesProducts).go();
    await _db.delete(_db.localFavoritesCustomers).go();
    await _db.delete(_db.notificationsCache).go();
    await (_db.delete(_db.localSettings)..where(
          (t) =>
              t.key.isIn(kioskVolatileSettings) |
              Expression.or(<Expression<bool>>[
                for (final String prefix in kioskVolatileSettingPrefixes)
                  t.key.like('${_escapeLike(prefix)}%', escapeChar: r'\'),
              ]),
        ))
        .go();
    await (_db.delete(_db.appMeta)..where((t) => t.key.isIn(kioskVolatileMeta))).go();
  });

  /// Префикс ключа для `LIKE` (`_` и `%` — буквально).
  static String _escapeLike(String s) => s.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');
}
