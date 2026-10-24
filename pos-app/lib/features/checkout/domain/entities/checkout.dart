// Оформление заказа SCR-21 (08 §4.7.7 `checkout-preview`, §4.8.1 `POST /orders`; 10 ORD-, PAY-). Клиент не передаёт
// цены и итоги (D-23): итоги, конфликты и допустимые способы оплаты приходят из `CheckoutPreview`. Чистый Dart (FL-01).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';

/// Проверки способа оплаты (`CheckoutPreview.paymentChecks`; долг — fail-closed, ядро §22.4).
final class PaymentChecks {
  const PaymentChecks({
    this.creditAllowed,
    this.creditReason,
    this.limitRemaining,
    this.receivablesAsOf,
    this.receivablesStale,
  });

  final bool? creditAllowed;

  /// Только при `paymentMethod=credit`; `null` при `creditAllowed=true`.
  final CreditReason? creditReason;
  final Money? limitRemaining;
  final DateTime? receivablesAsOf;
  final bool? receivablesStale;
}

/// Права на оформление (`CheckoutPreview.permissions`; режим клиента — 08 API-179, 10 CUST-024).
final class CheckoutPermissions {
  const CheckoutPermissions({
    this.canCreateOrder,
    this.canApplyDiscount,
    this.discountLimitPercent,
    this.canSellOnCredit,
    this.needsOverride = const <String>[],
    this.allowedPaymentMethods = const <PaymentMethod>[],
  });

  final bool? canCreateOrder;
  final bool? canApplyDiscount;
  final Percent? discountLimitPercent;
  final bool? canSellOnCredit;

  /// `discount` / `credit` — нужен override старшего со step-up.
  final List<String> needsOverride;

  /// Допустимые способы оплаты (у `customer` — `cash` и `qr_bakai` только при `QR_PROVIDER≠none`).
  final List<PaymentMethod> allowedPaymentMethods;
}

/// Итог синхронной проверки 1С (`CheckoutPreview.onecCheck`).
enum OnecCheckResult {
  ok('ok'),
  unavailable('unavailable'),
  rejected('rejected');

  const OnecCheckResult(this.value);

  final String value;

  static OnecCheckResult? tryParse(String? value) {
    for (final OnecCheckResult r in values) {
      if (r.value == value) return r;
    }
    return null;
  }
}

/// Синхронная проверка 1С (таймаут 6 с) — «Проверено в 1С · HH:MM».
final class OnecCheck {
  const OnecCheck({this.performed, this.at, this.result});

  final bool? performed;
  final DateTime? at;
  final OnecCheckResult? result;
}

/// Результат `POST /cart/checkout-preview` (`CheckoutPreview`); `ok=false` с [conflicts] — не ошибка.
final class CheckoutPreview {
  const CheckoutPreview({
    required this.cartId,
    required this.cartRowVersion,
    required this.ok,
    this.conflicts = const <CartConflict>[],
    this.items = const <OrderLine>[],
    this.subtotal,
    this.discountPercent,
    this.discountTotal,
    this.customerDiscountTotal,
    this.total,
    this.cashRounding = Money.zero,
    this.totalToPay,
    this.paymentMethod,
    this.paymentChecks,
    this.permissions,
    this.onecCheck,
    this.validUntil,
    this.previewToken,
    this.warnings = const <ApiWarning>[],
  });

  final String cartId;
  final int cartRowVersion;
  final bool ok;
  final List<CartConflict> conflicts;
  final List<OrderLine> items;
  final Money? subtotal;
  final Percent? discountPercent;
  final Money? discountTotal;
  final Money? customerDiscountTotal;
  final Money? total;
  final Money cashRounding;
  final Money? totalToPay;
  final PaymentMethod? paymentMethod;
  final PaymentChecks? paymentChecks;
  final CheckoutPermissions? permissions;
  final OnecCheck? onecCheck;

  /// Срок действия [previewToken] (5 мин).
  final DateTime? validUntil;

  /// Непрозрачный токен (HMAC) — передаётся в `POST /orders`; клиент его не разбирает.
  final String? previewToken;
  final List<ApiWarning> warnings;
}

/// Тело `POST /cart/checkout-preview` (`CartCheckoutPreviewRequest`).
final class CheckoutPreviewRequest {
  const CheckoutPreviewRequest({
    required this.cartId,
    required this.cartRowVersion,
    required this.paymentMethod,
    required this.delivery,
    required this.receiver,
    this.manualDiscountPercent,
    this.creditOverrideReason,
    this.syncCheckWithOnec = true,
    this.strict = false,
  });

  final String cartId;
  final int cartRowVersion;
  final PaymentMethod paymentMethod;
  final Delivery delivery;
  final Receiver receiver;
  final Percent? manualDiscountPercent;
  final String? creditOverrideReason;
  final bool syncCheckWithOnec;

  /// `true` — блокировки долга строгими кодами (403/422), а не в `paymentChecks.creditReason`.
  final bool strict;
}

/// Строка `POST /orders` (`OrdersCreateItem`): обязана совпадать с корзиной `cartRowVersion`.
final class OrderCreateItem {
  const OrderCreateItem({required this.variantId, required this.quantity});

  final String variantId;
  final LineQuantity quantity;
}

/// Тело `POST /orders` (`OrdersCreateRequest`): цены, итоги, `clientTotalSnapshot` запрещены (ORD-020).
final class OrderCreateRequest {
  const OrderCreateRequest({
    required this.cartId,
    required this.cartRowVersion,
    required this.paymentMethod,
    required this.delivery,
    required this.receiver,
    required this.items,
    this.previewToken,
    this.customerId,
    this.manualDiscountPercent,
    this.discountOverrideReason,
    this.creditOverrideReason,
    this.printOptions,
    this.comment,
    this.confirmDuplicate = false,
  });

  final String cartId;
  final int cartRowVersion;
  final String? previewToken;
  final String? customerId;
  final Receiver receiver;
  final Delivery delivery;
  final PaymentMethod paymentMethod;
  final Percent? manualDiscountPercent;

  /// `discount.approve.over_limit` + step-up.
  final String? discountOverrideReason;

  /// `credit.sale.approve` + step-up (снимает только шаг (2) ядра §22.4).
  final String? creditOverrideReason;
  final PrintOptions? printOptions;

  /// ≤ 500.
  final String? comment;

  /// Обход мягкой защиты от дубля (`409 possible_duplicate`).
  final bool confirmDuplicate;
  final List<OrderCreateItem> items;

  static const int commentMax = 500;
}

/// Ответ `POST /orders`: `201` — `/check` выполнен; `202` — 1С недоступна, заказ `submitting` с `STALE_DATA`
/// (ядро §22.3). В обоих случаях заказ создан и статус — `submitting`.
final class OrderCreateResult {
  const OrderCreateResult({required this.order, required this.accepted, this.replayed = false});

  final Order order;

  /// `202 Accepted` (проверка 1С не выполнена — опрашивать `GET /orders/{id}` каждые 3 с до 60 с).
  final bool accepted;

  /// `Idempotent-Replayed: true` — ответ повтора тем же ключом.
  final bool replayed;
}
