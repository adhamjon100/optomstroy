// Тексты отказа изменения корзины планшета магазина (02 ч. F SCR-51 UI-51-010, UI-51-012, таблица анимаций ANIM-006
// «подпись без количества»; 08 §2.4 «Коды и отказы планшета магазина» п. 3; 10 KIOSK-016; 11 SEC-141 (3); ADR-115).
//
// В `conflicts[]` любого `422` планшету приходят только `variantId`, `kind` и `stockLevel` — без `factor`, `available`,
// `requested`. Поэтому общий разбор ошибок (`UiErrorMapper`: число из `conflicts[0]`) дал бы «Минимальная партия — »
// с пустым числом. Здесь: минимум и кратность — из данных строки на устройстве (кэш каталога, карточка товара), если
// они известны, иначе — подпись без числа «Корзина не сохранена»; нехватка остатка и недоступность — подписи без
// количества. Без связи и при метке сброса без сети — «Корзина не сохранена». Тексты сотрудника и покупателя SCR-50
// не меняются: функция вызывается только для роли `kiosk` (витрина, слой карточки, drawer планшета).
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/presentation/cart_formats.dart';

/// Текст отказа [failure] изменения корзины планшета; [minQuantity] и [multiple] — минимальная партия и кратность строки
/// по данным устройства (базовая единица [unit]). `null` — отказ не из правил планшета (текст — общий).
String? kioskCartRejectionText(
  AppLocalizations l10n,
  Failure failure, {
  Qty? minQuantity,
  Qty? multiple,
  String unit = '',
}) {
  switch (failure) {
    case NetworkFailure():
      return l10n.cart_header_save_failed;
    case UnknownFailure(:final Object? cause) when cause is KioskCartResetPending:
      return l10n.cart_header_save_failed;
    case ConflictFailure(:final ConflictKind kind):
      switch (kind) {
        case ConflictKind.qtyBelowMin:
          return minQuantity != null && minQuantity.milli > 0
              ? l10n.error_qty_below_min(CartFormats.qty(minQuantity), unit).trim()
              : l10n.cart_header_save_failed;
        case ConflictKind.qtyNotMultiple:
          return multiple != null && multiple.milli > 0
              ? l10n.error_qty_not_multiple(CartFormats.qty(multiple), unit).trim()
              : l10n.cart_header_save_failed;
        case ConflictKind.stockInsufficient:
          return l10n.cart_line_stock_short_customer;
        case ConflictKind.variantUnavailable:
          return l10n.error_variant_unavailable;
        default:
          return null;
      }
    default:
      return null;
  }
}
