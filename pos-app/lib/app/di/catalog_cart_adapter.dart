// Адаптер корзины (фича cart, RM-F-005) → порт «+ Добавить» каталога `CatalogCartPort` (SCR-10/11/12, SCR-50).
//
// Каталог и корзина связаны только через корень (06 §6.1, FL-03: каталог не знает реализацию корзины): «+ Добавить»
// прибавляет шаг варианта по умолчанию в черновик корзины (`CartSync.addStep`: кратность и минимальная партия из кэша
// каталога, INV-004/005) и сразу ставит изменение в очередь `cart.sync` (`mode=set`, 07 §11.2). Цена клиента не
// передаётся (D-23): цена карточки уходит только как `priceSnapshot` новой строки (предупреждение `price_changed`).
// Отказ сервера (201-я строка — `400 VALIDATION_FAILED` rule `max_items`, 10 CART-024) — результат-отказ: каталог
// показывает «Слишком много позиций (максимум 200)…» вместо «Добавлено» на любом классе окна (12 T-CART-022).
// Тест — `test/features/cart/presentation/cart_wiring_test.dart`.
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/sync/cart_sync.dart';
import 'package:optomstroy/features/cart/presentation/providers/cart_controller.dart' show cartMaxItemsRule;
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';

/// `CatalogCartPort` поверх `CartSync`.
final class CartSyncCatalogCartPort implements CatalogCartPort {
  const CartSyncCatalogCartPort(this._sync);

  final CartSync _sync;

  @override
  Future<Result<void>> add(ProductSummary product) async {
    final String? variantId = product.defaultVariantId;
    if (variantId == null) return const FailureResult<void>(UnknownFailure(cause: 'no default variant'));
    final Result<Qty> r = await _sync.addStep(CartLineKey(variantId), priceSnapshot: product.price?.amount);
    return r.map((Qty _) {});
  }

  @override
  String? rejectionText(Failure failure, AppLocalizations l10n) => switch (failure) {
    ValidationFailure(:final List<FieldError> errors) when errors.any((FieldError e) => e.rule == cartMaxItemsRule) =>
      l10n.cart_max_items('${Cart.maxItems}'),
    _ => null,
  };
}
