// Синхронизация корзины: локальная копия drift (`cart_draft`/`cart_items_draft`) ↔ серверная корзина (D-32; 07 §11.2,
// §11.4; 02 SCR-20.4.1, SCR-20.11; ядро §19.4, §22.6). Сервер — источник истины цен и итогов (D-23): локальная копия
// хранит только состав (вариант, упаковка, целевое количество, единица), снимки цены/остатка для показа «было → стало»
// офлайн и базу цепочки `rowVersion`.
//
// Поток изменения количества (один путь онлайн и офлайн):
//   1) UI → [CartSync.setQuantity] — строка черновика сразу получает целевое количество (`sync_state='pending'`;
//      0 — метка удаления до ответа сервера), переживает перезапуск;
//   2) после паузы ввода 500 мс (debounce — у контроллера экрана) → [CartSync.sync]: `pending`-строки ставятся в
//      outbox `cart.sync` (`set_item`/`delete_item`, только `mode=set`, сжатие по паре вариант+упаковка) и, если сеть
//      есть, очередь отправляется;
//   3) обработчик записи отправляет `PUT/DELETE /cart/items/{variantId}` с `rowVersion` = база черновика, ответ
//      (`Cart`) перезаписывает черновик и базу (следующая запись идёт со следующей версией) и публикуется событием
//      [CartServerUpdated]; `409 VERSION_CONFLICT` останавливает очередь корзины до решения пользователя
//      ([CartVersionConflict], диалог UI-20-027).
// Остальные изменения корзины (склад, клиент, скидка, очистка, «Отложить», «Продолжить») — только онлайн
// ([CartSync.direct]: сначала отправляется очередь, затем запрос с актуальным `rowVersion`).
// Чистый Dart (FL-01).
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';

/// Ключ строки корзины: пара (`variantId`, `packagingId`) уникальна (CART-002).
final class CartLineKey {
  const CartLineKey(this.variantId, [this.packagingId]);

  final String variantId;

  /// Упаковка строки; `null` — базовая единица варианта.
  final String? packagingId;

  @override
  bool operator ==(Object other) =>
      other is CartLineKey && other.variantId == variantId && other.packagingId == packagingId;

  @override
  int get hashCode => Object.hash(variantId, packagingId);

  @override
  String toString() => 'CartLineKey($variantId, $packagingId)';
}

/// Строка локальной копии корзины (+ подписи из кэша каталога для показа офлайн).
final class CartLocalLine {
  const CartLocalLine({
    required this.key,
    required this.quantity,
    required this.syncState,
    required this.lineNo,
    this.unitId,
    this.priceSnapshot,
    this.stockSnapshot,
    this.priceChanged = false,
    this.stockInsufficient = false,
    this.productId,
    this.productName,
    this.variantName,
    this.sku,
    this.unitLabel,
    this.packagingName,
    this.factor,
    this.step,
    this.minQuantity,
    this.qtyPrecision,
  });

  final CartLineKey key;

  /// Целевое количество в единицах строки (упаковки — целые, INV-006); 0 — удаление ждёт подтверждения сервера.
  final Qty quantity;
  final CartDraftSyncState syncState;
  final int lineNo;

  /// Серверный идентификатор единицы строки (`Quantity.unitId`).
  final String? unitId;

  /// Цена за единицу строки из последнего ответа сервера (или каталога при добавлении) — только показ.
  final Money? priceSnapshot;

  /// `available` строки из последнего ответа сервера (базовая единица).
  final Qty? stockSnapshot;
  final bool priceChanged;
  final bool stockInsufficient;

  // Подписи из кэша каталога (07 §11.3) — `null`, если кэш товара не загружен.
  final String? productId;
  final String? productName;
  final String? variantName;
  final String? sku;

  /// «шт», «кор».
  final String? unitLabel;
  final String? packagingName;

  /// Базовых единиц в упаковке строки.
  final Qty? factor;

  /// Шаг «+»/«−» в единицах строки (кратность варианта/товара; упаковка — 1).
  final Qty? step;

  /// Минимальная партия в единицах строки.
  final Qty? minQuantity;

  /// Точность количества базовой единицы (0…3).
  final int? qtyPrecision;

  /// Строка удалена локально и ждёт подтверждения сервера.
  bool get isDeletion => quantity.isZero;

  /// Изменение строки ещё не подтверждено сервером (`pending`) или не отправлено (`dead`).
  bool get isUnsent => syncState != CartDraftSyncState.synced;
}

/// Локальная копия активной корзины пользователя.
final class CartLocalSnapshot {
  const CartLocalSnapshot({
    required this.localCartId,
    required this.lines,
    required this.dirty,
    this.serverId,
    this.baseRowVersion,
    this.serverSyncedAt,
    this.warehouseId,
    this.priceListId,
    this.customerId,
    this.discount = Percent.zero,
  });

  final String localCartId;

  /// `Cart.id` последнего ответа сервера.
  final String? serverId;

  /// База цепочки `rowVersion` (последний ответ сервера); `null` — сервер корзину ещё не видел.
  final int? baseRowVersion;

  /// Время последнего ответа сервера («Данные от {time}» после перезапуска без сети).
  final DateTime? serverSyncedAt;
  final bool dirty;
  final String? warehouseId;
  final String? priceListId;
  final String? customerId;
  final Percent discount;

  /// Все строки по `line_no`, включая метки удаления (количество 0).
  final List<CartLocalLine> lines;

  /// Строки для показа (без меток удаления).
  List<CartLocalLine> get visibleLines => <CartLocalLine>[
    for (final CartLocalLine l in lines)
      if (!l.isDeletion) l,
  ];

  /// Есть неподтверждённые сервером изменения строк.
  bool get hasUnsent => lines.any((CartLocalLine l) => l.isUnsent);

  CartLocalLine? line(CartLineKey key) {
    for (final CartLocalLine l in lines) {
      if (l.key == key) return l;
    }
    return null;
  }
}

/// Состояние очереди `cart.sync` (индикатор UI-20-023).
final class CartSyncStatus {
  const CartSyncStatus({this.queued = 0, this.dead = 0});

  static const CartSyncStatus idle = CartSyncStatus();

  /// Записи `pending|sending|failed`.
  final int queued;

  /// Записи `dead` — «Ошибка сохранения · Повторить».
  final int dead;

  @override
  bool operator ==(Object other) => other is CartSyncStatus && other.queued == queued && other.dead == dead;

  @override
  int get hashCode => Object.hash(queued, dead);
}

/// `409 VERSION_CONFLICT` при отправке очереди корзины (UI-20-027): серверная версия и неподтверждённые изменения.
final class CartVersionConflict {
  const CartVersionConflict({required this.localCartId, required this.unsent, this.current});

  final String localCartId;

  /// Корзина на сервере (`current` из problem+json или `GET /cart`); `null` — не удалось получить.
  final Cart? current;

  /// Локальные изменения, которые не применены на сервере.
  final List<CartLocalLine> unsent;
}

/// Событие синхронизации корзины.
sealed class CartSyncEvent {
  const CartSyncEvent();
}

/// Сервер ответил новой корзиной (запись очереди, `GET /cart`, прямая операция).
final class CartServerUpdated extends CartSyncEvent {
  const CartServerUpdated(this.cart);

  final Cart cart;
}

/// Конфликт версий — очередь корзины остановлена до [CartSync.resolveConflict].
final class CartConflictDetected extends CartSyncEvent {
  const CartConflictDetected(this.conflict);

  final CartVersionConflict conflict;
}

/// Сервер окончательно отклонил изменение (запись `dead`): строка помечена «не отправлено».
final class CartSyncRejected extends CartSyncEvent {
  const CartSyncRejected(this.failure, {this.key});

  final Failure failure;
  final CartLineKey? key;
}

/// Смена варианта строки (10 CART-005): строка [from] переносится в строку [to] с количеством [quantity] (при
/// объединении — сумма). Журнал замены переживает перезапуск ([CartSync.beginReplace]).
final class CartLineReplace {
  const CartLineReplace({required this.from, required this.to, required this.quantity});

  final CartLineKey from;
  final CartLineKey to;

  /// Количество строки [to] после замены (единицы строки).
  final Qty quantity;
}

/// Склад для меню UI-20-005 (кэш каталога `warehouses`).
final class CartWarehouseOption {
  const CartWarehouseOption({required this.id, required this.name, this.isDefault = false});

  final String id;
  final String name;
  final bool isDefault;
}

/// Подписи склада и вида цены корзины (UI-20-005).
typedef CartPlaceLabels = ({String? warehouse, String? priceList});

/// Порт синхронизации активной корзины текущего пользователя.
abstract interface class CartSync {
  /// Изменения локальной копии (`null` — копии нет или БД пользователя не открыта).
  Stream<CartLocalSnapshot?> watchLocal();

  /// Локальная копия сейчас.
  Future<Result<CartLocalSnapshot?>> loadLocal();

  /// События синхронизации (широковещательный поток).
  Stream<CartSyncEvent> get events;

  /// Состояние очереди `cart.sync` текущего пользователя.
  Stream<CartSyncStatus> watchStatus();

  /// Неразрешённый конфликт версий.
  CartVersionConflict? get conflict;

  /// Отправить очередь (если есть сеть) и получить корзину `GET /cart?revalidate=true` → копия.
  Future<Result<Cart>> refresh();

  /// Целевое количество строки (`mode=set`, 0 — удаление). Пишется в копию сразу; в очередь — при [sync].
  Future<Result<void>> setQuantity(CartLineKey key, Qty quantity);

  /// «+ Добавить» (каталог, SCR-50): +1 шаг строки (кратность варианта; первое добавление — не меньше минимальной
  /// партии, INV-004/005) — в копию и сразу в очередь. Результат — новое количество строки; если сервер отклонил
  /// изменение при этой отправке (например, 201-я строка — `400 VALIDATION_FAILED` rule `max_items`, 10 CART-024), —
  /// отказ сервера, а копия возвращена к серверной корзине.
  Future<Result<Qty>> addStep(CartLineKey key, {Money? priceSnapshot});

  /// Поставить неотправленные строки в очередь `cart.sync` и отправить её, если сеть есть.
  Future<Result<void>> sync();

  /// Прямая (онлайн) операция над серверной корзиной: очередь отправляется, затем [op] вызывается с базой
  /// `rowVersion`; корзина из ответа ([cartOf]) записывается в копию ([keepPending] — сохранить неотправленные
  /// строки; `false` — копия = ответ сервера: очистка, «Отложить», «Продолжить»). Строки [settle] при успехе
  /// принимают значение ответа сервера: их неотправленное (`pending`/`dead`) изменение и записи очереди
  /// `cart.sync` снимаются (операция уже записала их новое состояние — смена варианта, 10 CART-005).
  Future<Result<T>> direct<T>(
    Future<Result<T>> Function(int rowVersion) op, {
    required Cart? Function(T value) cartOf,
    bool keepPending = true,
    Set<CartLineKey> settle = const <CartLineKey>{},
  });

  /// Записать намерение смены варианта до первого запроса: если приложение завершится после записанного сервером
  /// `PUT` строки [CartLineReplace.to] и до удаления [CartLineReplace.from], сверка [refresh] после перезапуска
  /// завершит замену (удаление старой строки — через очередь `cart.sync`), а не оставит обе строки.
  Future<Result<void>> beginReplace(CartLineReplace replace);

  /// Замена завершена (успешно или отказом) — журнал [beginReplace] снимается.
  Future<void> endReplace();

  /// Решение по конфликту: [applyMine] — повторить свои изменения поверх серверной версии, иначе — принять
  /// серверную корзину и отбросить неотправленные изменения.
  Future<Result<void>> resolveConflict({required bool applyMine});

  /// «Повторить» для отклонённых (`dead`) изменений.
  Future<Result<void>> retryFailed();

  /// Склады для смены склада корзины (кэш каталога; активные).
  Future<Result<List<CartWarehouseOption>>> warehouses();

  /// Названия склада и вида цены (кэш каталога).
  Future<CartPlaceLabels> placeLabels({String? warehouseId, String? priceListId});
}
