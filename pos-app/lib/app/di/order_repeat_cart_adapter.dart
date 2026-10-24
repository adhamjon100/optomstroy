// Адаптер корзины (фича cart, RM-F-005) → порт «Повторить заказ» SCR-24 `OrderRepeatPort` (02 UI-24-011, UI-24-020).
//
// orders ↛ cart (06 §6.1): связь только через корень. Строки заказа добавляются в активную серверную корзину по
// ТЕКУЩИМ ценам — `PUT /cart/items/{variantId}` `mode=increment` с `Idempotency-Key` на строку (08 §4.7; цена не
// передаётся, D-23). Через `CartSync.direct`: сначала уходит очередь `cart.sync`, затем запрос с актуальным
// `rowVersion`; ответ становится новой копией корзины (черновик drift не расходится с сервером).
// Недоступный вариант (`VARIANT_UNAVAILABLE`) — `Success(false)`: строка пропускается с отчётом.
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/cart/domain/sync/cart_sync.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/presentation/providers/orders_ports.dart';

/// `OrderRepeatPort` поверх `CartSync` + `CartRepository`.
final class CartSyncOrderRepeatPort implements OrderRepeatPort {
  const CartSyncOrderRepeatPort(this._sync, this._repository);

  final CartSync _sync;
  final CartRepository _repository;

  @override
  Future<Result<int>> activeCartItemsCount() async {
    final Result<Cart> r = await _sync.refresh();
    return r.map((Cart c) => c.itemsCount ?? c.items.length);
  }

  @override
  Future<Result<void>> parkActiveCart({required String idempotencyKey}) async {
    final Result<CartParkResult> r = await _sync.direct<CartParkResult>(
      (int rowVersion) => _repository.park(rowVersion: rowVersion, idempotencyKey: idempotencyKey),
      cartOf: (CartParkResult v) => v.active,
      keepPending: false,
    );
    return r.map((CartParkResult _) {});
  }

  @override
  Future<Result<bool>> addLine(OrderLine line, {required String idempotencyKey}) async {
    final Result<Cart> r = await _sync.direct<Cart>(
      (int rowVersion) => _repository.putItem(
        line.variantId,
        CartItemPut(
          quantity: LineQuantity(
            value: line.quantity.value,
            unitId: line.quantity.unitId,
            packagingId: line.quantity.packagingId,
          ),
          rowVersion: rowVersion,
          mode: CartPutMode.increment,
        ),
        idempotencyKey: idempotencyKey,
      ),
      cartOf: (Cart c) => c,
    );
    return switch (r) {
      Success<Cart>() => const Success<bool>(true),
      FailureResult<Cart>(:final Failure failure) when isVariantUnavailable(failure) => const Success<bool>(false),
      FailureResult<Cart>(:final Failure failure) => FailureResult<bool>(failure),
    };
  }

  /// Вариант снят с продажи / недоступен (`VARIANT_UNAVAILABLE`, 422).
  static bool isVariantUnavailable(Failure f) =>
      (f is ConflictFailure && f.kind == ConflictKind.variantUnavailable) ||
      (f is ServerFailure && f.code == 'VARIANT_UNAVAILABLE');
}

/// «Открыть восстановленную корзину» SCR-22/SCR-24 (02 UI-22-014, UI-24-015; 10 ORD-027): сервер восстанавливает состав
/// заказа `submit_failed` в новую корзину — активную, если текущая пуста, иначе отложенную «Восстановлена из заказа № …».
/// Активная корзина с `restoredFromOrderId` этого заказа → SCR-20, иначе → SCR-23 (ошибка сети — SCR-20).
Future<String> restoredCartLocation(CartRepository repository, String orderId) async {
  final Result<Cart> r = await repository.fetch();
  final Cart? active = r.valueOrNull;
  if (active == null || active.restoredFromOrderId == orderId) return '/cart';
  return '/cart/parked';
}
