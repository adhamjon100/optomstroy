// Локальные данные и черновики (07 §11.2): избранное, недавние, уведомления,
// настройки, корзина-черновик, очередь `outbox_actions`, черновики регистрации и
// оформления, метки синхронизации, `app_meta`.
//
// Ограничения ядра §18.2 п.1 / §19.4:
// - `registration_draft` — только состояние шагов, без ПДн (ФИО и год рождения —
//   в flutter_secure_storage, ключи `registration.*`), без PIN;
// - `checkout_draft` — без платёжных данных (сумм, QR, реквизитов) и без ПДн
//   получателя (имя, телефон, адрес — только в памяти формы);
// - заказы и платежи в `outbox_actions` не ставятся (DATA-254).
// Все `*_at` — INTEGER unix-ms UTC.
// DSL drift: `.check(column.isIn(...))` ссылается на собственный геттер — это не рекурсия.
// ignore_for_file: recursive_getters
import 'package:drift/drift.dart';

/// Значения `pending_op` (до подтверждения outbox).
const List<String> pendingOpValues = ['add', 'remove'];

/// Типы `outbox_actions.type` (07 §11.2, ядро §19.4).
const List<String> outboxActionTypes = [
  'cart.sync',
  'favorite.add',
  'favorite.remove',
  'recent.touch',
  'recent.clear',
  'notification.read',
  'auth.logout',
  'profile.settings',
];

/// Значения `sync_meta.entity` (07 §11.2).
const List<String> syncMetaEntities = [
  'categories',
  'products',
  'variants',
  'units',
  'packagings',
  'barcodes',
  'warehouses',
  'price_lists',
  'prices',
  'stock',
  'images',
  'favorites',
  'notifications',
];

@DataClassName('FavoriteProductRow')
class LocalFavoritesProducts extends Table {
  @override
  String get tableName => 'favorites_products';

  TextColumn get productId => text()();
  IntColumn get createdAt => integer()();
  TextColumn get pendingOp => text().nullable().check(pendingOp.isIn(pendingOpValues))();

  @override
  Set<Column<Object>> get primaryKey => {productId};
}

/// Только идентификаторы клиентов; имена — из сетевого ответа (07 §11.1 п.5).
@DataClassName('FavoriteCustomerRow')
class LocalFavoritesCustomers extends Table {
  @override
  String get tableName => 'favorites_customers';

  TextColumn get customerId => text()();
  IntColumn get createdAt => integer()();
  TextColumn get pendingOp => text().nullable().check(pendingOp.isIn(pendingOpValues))();

  @override
  Set<Column<Object>> get primaryKey => {customerId};
}

/// Корзина-черновик (одна `active`); `owner_user_id` — защита от ошибки выбора файла.
@DataClassName('CartDraftRow')
@TableIndex(name: 'cart_draft_status_idx', columns: {#status})
class CartDraft extends Table {
  @override
  String get tableName => 'cart_draft';

  TextColumn get localId => text()();
  TextColumn get serverId => text().nullable()();
  TextColumn get status => text().check(status.isIn(const ['active', 'parked', 'converted', 'cleared']))();
  TextColumn get name => text().nullable()();
  TextColumn get customerId => text().nullable()();
  TextColumn get warehouseId => text().nullable()();
  TextColumn get priceListId => text().nullable()();
  IntColumn get discountPercentHundredths =>
      integer().withDefault(const Constant(0)).check(discountPercentHundredths.isBetweenValues(0, 10000))();
  IntColumn get baseRowVersion => integer().nullable()();
  BoolColumn get dirty => boolean().withDefault(const Constant(false))();
  TextColumn get ownerUserId => text()();
  IntColumn get updatedAt => integer()();

  /// Момент последнего успешного ответа сервера по корзине (unix-ms UTC) — «Данные от {time}» (02 SCR-20,
  /// `cart_banner_stale`) после перезапуска без сети. Схема v5 (этап F, FQ-FND).
  IntColumn get serverSyncedAt => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {localId};
}

@DataClassName('CartItemDraftRow')
@TableIndex(name: 'cart_items_draft_cart_idx', columns: {#localCartId})
class CartItemsDraft extends Table {
  @override
  String get tableName => 'cart_items_draft';

  TextColumn get localItemId => text()();
  TextColumn get localCartId => text()();
  TextColumn get serverItemId => text().nullable()();
  TextColumn get variantId => text()();
  TextColumn get packagingId => text().nullable()();
  IntColumn get quantityMilli => integer().check(quantityMilli.isBiggerOrEqualValue(0))();

  /// Единица количества строки (`Quantity.unitId`: упаковки — её единица, иначе базовая) — нужна телу
  /// `PUT /cart/items/{variantId}` записи `cart.sync` (`set_item.unitId`, 07 §11.2). Схема v5 (этап F, FQ-FND).
  TextColumn get unitId => text().nullable()();
  IntColumn get priceSnapshotTyiyn => integer().nullable()();
  IntColumn get stockSnapshotMilli => integer().nullable()();
  BoolColumn get priceChanged => boolean().withDefault(const Constant(false))();
  BoolColumn get stockInsufficient => boolean().withDefault(const Constant(false))();
  IntColumn get lineNo => integer()();
  TextColumn get ownerUserId => text()();
  TextColumn get syncState =>
      text().withDefault(const Constant('pending')).check(syncState.isIn(const ['synced', 'pending', 'dead']))();

  @override
  Set<Column<Object>> get primaryKey => {localItemId};
}

/// Клиентская очередь некритичных идемпотентных действий (D-32, DATA-254, DATA-255).
@DataClassName('OutboxActionRow')
@TableIndex(name: 'outbox_actions_owner_status_next_idx', columns: {#ownerUserId, #status, #nextAttemptAt})
class OutboxActions extends Table {
  @override
  String get tableName => 'outbox_actions';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get type => text().check(type.isIn(outboxActionTypes))();
  TextColumn get payloadJson => text()();
  TextColumn get idempotencyKey => text().unique()();
  TextColumn get ownerUserId => text()();
  TextColumn get status => text()
      .withDefault(const Constant('pending'))
      .check(status.isIn(const ['pending', 'sending', 'done', 'failed', 'dead']))();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get nextAttemptAt => integer().nullable()();
}

@DataClassName('RecentProductRow')
@TableIndex(name: 'recent_products_viewed_idx', columns: {#lastViewedAt})
class LocalRecentProducts extends Table {
  @override
  String get tableName => 'recent_products';

  TextColumn get productId => text()();
  IntColumn get lastViewedAt => integer()();
  IntColumn get viewCount => integer().withDefault(const Constant(1))();

  @override
  Set<Column<Object>> get primaryKey => {productId};
}

/// Последние 100 уведомлений; для `credit_blocked`, `payment_status`, `return_status`
/// `body` не кэшируется (NULL), из `payload_json` — только идентификаторы (DATA-258).
@DataClassName('NotificationCacheRow')
@TableIndex(name: 'notifications_cache_read_idx', columns: {#readAt})
class NotificationsCache extends Table {
  @override
  String get tableName => 'notifications_cache';

  TextColumn get id => text()();
  TextColumn get kind => text()();
  TextColumn get severity => text()();
  TextColumn get title => text()();
  TextColumn get body => text().nullable()();
  TextColumn get payloadJson => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get readAt => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('SettingRow')
class LocalSettings extends Table {
  @override
  String get tableName => 'settings';

  TextColumn get key => text()();
  TextColumn get valueJson => text()();
  TextColumn get scope => text().check(scope.isIn(const ['user', 'device']))();
  IntColumn get updatedAt => integer()();
  BoolColumn get dirty => boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

/// Черновик регистрации: только состояние шагов (текущий шаг, отметки согласий,
/// выбранная сфера) — без значений ПДн и без PIN (ядро §18.2 п.1).
@DataClassName('RegistrationDraftRow')
class RegistrationDraft extends Table {
  @override
  String get tableName => 'registration_draft';

  TextColumn get key => text()();
  TextColumn get valueJson => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

/// Состояние SCR-21 «Оформление заказа»: одна строка на корзину; без платёжных
/// данных и ПДн получателя (ядро §19.4). `order_idempotency_key` — ключ
/// `POST /orders`, переживает перезапуск (DATA-263, ядро §22.6).
@DataClassName('CheckoutDraftRow')
class CheckoutDraft extends Table {
  @override
  String get tableName => 'checkout_draft';

  TextColumn get localCartId => text()();
  TextColumn get step => text().check(step.isIn(const ['customer', 'delivery', 'payment', 'review']))();
  TextColumn get customerId => text().nullable()();
  TextColumn get deliveryMethod => text().nullable().check(deliveryMethod.isIn(const ['pickup', 'delivery']))();
  TextColumn get receiverKind => text().nullable().check(receiverKind.isIn(const ['customer', 'other_person']))();
  TextColumn get paymentMethod => text().nullable().check(paymentMethod.isIn(const ['cash', 'qr_bakai', 'credit']))();
  TextColumn get orderIdempotencyKey => text().nullable()();
  IntColumn get submittedAt => integer().nullable()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {localCartId};
}

/// Метки синхронизации кэша по сущностям (NFR-OFFLINE-001, DATA-256).
@DataClassName('SyncMetaRow')
class SyncMeta extends Table {
  @override
  String get tableName => 'sync_meta';

  TextColumn get entity => text().check(entity.isIn(syncMetaEntities))();
  IntColumn get lastSuccessAt => integer().nullable()();
  TextColumn get serverCursor => text().nullable()();
  TextColumn get lastError => text().nullable()();
  IntColumn get asOf => integer().nullable()();

  /// Порог устаревания из `GET /sync/status` (`maxAgeWarningSec`, 08 §3.13). Схема v2.
  IntColumn get staleAfterSec => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {entity};
}

/// `schema_version`, `catalog_full_loaded_at`, `min_app_version_seen`,
/// `recommended_app_version_seen`, `user_id` (07 §11.2).
@DataClassName('AppMetaRow')
class AppMeta extends Table {
  @override
  String get tableName => 'app_meta';

  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}
