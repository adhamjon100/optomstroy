// Локальная корзина-черновик (07 §11.2 `cart_draft`/`cart_items_draft`, DATA-253; ядро §18.2 п.1).
// Этап E (RM-E-008): только «добавить / изменить / прочитать» строки поверх таблиц drift основы —
// отправка на сервер (`cart.sync`, цепочка `rowVersion`), `GET /cart` и CartPanel — этап F.
// Чистый Dart (FL-01): деньги — `Money` (тыйыны), количества — `Qty` (milli-units), D-19.
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';

/// Состояние отправки строки (`cart_items_draft.sync_state`).
enum CartDraftSyncState {
  synced('synced'),
  pending('pending'),
  dead('dead');

  const CartDraftSyncState(this.value);

  final String value;

  static CartDraftSyncState parse(String? value) {
    for (final s in values) {
      if (s.value == value) return s;
    }
    return pending;
  }
}

/// Строка черновика: пара (`variantId`, `packagingId`) уникальна в корзине (CART-002).
///
/// [quantity] — в единицах строки, как в `PUT /cart/items/{variantId}`: в упаковках при
/// `packagingId != null` (целое, INV-006), иначе в базовой единице (INV-002).
final class CartDraftLine {
  const CartDraftLine({
    required this.localItemId,
    required this.cartId,
    required this.variantId,
    required this.quantity,
    required this.lineNo,
    this.packagingId,
    this.priceSnapshot,
    this.stockSnapshot,
    this.syncState = CartDraftSyncState.pending,
  });

  final String localItemId;
  final String cartId;
  final String variantId;
  final String? packagingId;
  final Qty quantity;

  /// Цена за единицу строки на момент добавления (только показ; цену считает сервер, D-23).
  final Money? priceSnapshot;

  /// `available` склада корзины на момент добавления (базовая единица).
  final Qty? stockSnapshot;
  final int lineNo;
  final CartDraftSyncState syncState;
}

/// Добавление в черновик: создаёт строку или увеличивает существующую (`mode=increment`).
final class CartDraftAdd {
  const CartDraftAdd({
    required this.variantId,
    required this.quantity,
    this.packagingId,
    this.priceSnapshot,
    this.stockSnapshot,
  });

  final String variantId;
  final String? packagingId;

  /// Приращение в единицах строки (> 0).
  final Qty quantity;
  final Money? priceSnapshot;
  final Qty? stockSnapshot;
}

/// Черновик недоступен: БД пользователя не открыта или пользователь сессии неизвестен.
final class CartDraftUnavailable implements Exception {
  const CartDraftUnavailable();

  @override
  String toString() => 'CartDraftUnavailable';
}

/// Порт черновика корзины текущего пользователя (одна `active`, 07 §11.2).
abstract interface class CartDraftRepository {
  /// Строки активной корзины по `line_no`.
  Future<Result<List<CartDraftLine>>> lines();

  /// Изменения строк активной корзины (пустой поток без БД).
  Stream<List<CartDraftLine>> watchLines();

  /// Строка пары (`variantId`, `packagingId`) или `null`.
  Future<Result<CartDraftLine?>> line(String variantId, {String? packagingId});

  /// Создать строку или увеличить количество; корзина `active` создаётся при первом добавлении.
  Future<Result<CartDraftLine>> add(CartDraftAdd add);

  /// Установить количество строки (`mode=set`); 0 — удалить строку (после подтверждения в UI,
  /// CART-012). Результат — строка или `null` после удаления / если строки не было.
  Future<Result<CartDraftLine?>> setQuantity(String variantId, {String? packagingId, required Qty quantity});

  /// Склад активной корзины (`cart_draft.warehouse_id`); `null` — не выбран (склад по умолчанию).
  Future<Result<String?>> warehouseId();
}
