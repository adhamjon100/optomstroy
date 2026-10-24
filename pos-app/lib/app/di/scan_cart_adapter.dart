// Адаптер корзины-черновика (фича cart, RM-E-008) → порт `ScanCartPort` фичи scan (композиционный корень).
//
// Фичи scan и cart друг друга не импортируют (DAG 06 §6.1), поэтому адаптер живёт в `app/di/`. Режим «сразу в
// корзину» (ядро §19.4; 13 RM-E-014 п. 5): скан под `cashier` (или при `Settings.scanAddsToCart = true`) пишет
// строку в локальный черновик `cart_items_draft` (+1 шаг или `suggestedQuantity` упаковки); «Отменить» возвращает
// прежнее количество строки. Этап F (RM-F-005): после изменения черновика вызывается [CartDraftScanCartPort.onChanged]
// — корень ставит изменение в очередь `cart.sync` (`CartSync.sync`, `mode=set`).
// Тест — `test/app/scan_cart_adapter_test.dart`.
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';
import 'package:optomstroy/features/scan/domain/scan_lookup.dart';

/// Данные отмены: строка и её количество до скана (`null` — строки не было).
final class CartDraftScanUndo {
  const CartDraftScanUndo({required this.variantId, required this.packagingId, required this.previous});

  final String variantId;
  final String? packagingId;
  final Qty? previous;
}

/// `ScanCartPort` поверх `CartDraftRepository`.
final class CartDraftScanCartPort implements ScanCartPort {
  CartDraftScanCartPort(this._draft, {this.onChanged});

  final CartDraftRepository _draft;

  /// Черновик изменён (скан или «Отменить») — отправить корзину на сервер (этап F).
  final void Function()? onChanged;

  @override
  Future<Result<ScanAddReceipt>> addStep(ScanLookupResult result, {required String idempotencyKey}) async {
    // Ключ идемпотентности понадобится отправке строки на сервер (этап F); локальная запись — без него.
    final Result<CartDraftLine?> before = await _draft.line(result.variantId, packagingId: result.packagingId);
    if (before case FailureResult<CartDraftLine?>(:final failure)) return FailureResult<ScanAddReceipt>(failure);
    final Qty step = result.suggestedQuantity ?? Qty.units(1);
    final Result<CartDraftLine> added = await _draft.add(
      CartDraftAdd(variantId: result.variantId, packagingId: result.packagingId, quantity: step),
    );
    if (added.isSuccess) onChanged?.call();
    return added.map(
      (CartDraftLine _) => ScanAddReceipt(
        quantityLabel: formatQty(step),
        unitLabel: result.unitLabel,
        token: CartDraftScanUndo(
          variantId: result.variantId,
          packagingId: result.packagingId,
          previous: before.valueOrNull?.quantity,
        ),
      ),
    );
  }

  @override
  Future<Result<void>> undo(ScanAddReceipt receipt) async {
    final Object? token = receipt.token;
    if (token is! CartDraftScanUndo) return const Success<void>(null);
    final Result<CartDraftLine?> r = await _draft.setQuantity(
      token.variantId,
      packagingId: token.packagingId,
      quantity: token.previous ?? Qty.zero,
    );
    if (r.isSuccess) onChanged?.call();
    return r.map((CartDraftLine? _) {});
  }

  /// «1», «2,5» — без хвостовых нулей (для «+{qty} {unit}»).
  static String formatQty(Qty q) {
    final int whole = q.milli ~/ 1000;
    final int frac = q.milli % 1000;
    if (frac == 0) return '$whole';
    return '$whole,${frac.toString().padLeft(3, '0').replaceFirst(RegExp(r'0+$'), '')}';
  }
}
