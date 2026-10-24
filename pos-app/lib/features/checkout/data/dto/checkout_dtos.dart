// DTO-кодеки оформления (contracts/openapi/pos-api.v1.yaml 1.1.0; ADR-085 — вручную): `CheckoutPreview`,
// `CartCheckoutPreviewRequest`, `OrdersCreateRequest`, `OrdersCreateItem`, `CartOverride`. Вложенные `CartConflict`,
// `OrderItem` разбирают кодеки фич cart/orders (порты `CartJsonDecoder`/`OrderJsonDecoder`; FL-06).
// Сверка — test/features/checkout/data/checkout_dtos_contract_test.dart.
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/network/dto_json.dart';
import 'package:optomstroy/core/network/models/pos_common_dtos.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_json_decoder.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout.dart';
import 'package:optomstroy/features/orders/domain/repositories/order_json_decoder.dart';

/// `CheckoutPreview`.
abstract final class CheckoutPreviewDto {
  static const Set<String> jsonKeys = {
    'cartId',
    'cartRowVersion',
    'ok',
    'conflicts',
    'items',
    'subtotal',
    'discountPercent',
    'discountTotal',
    'customerDiscountTotal',
    'total',
    'cashRounding',
    'totalToPay',
    'paymentMethod',
    'paymentChecks',
    'permissions',
    'onecCheck',
    'validUntil',
    'previewToken',
    'warnings',
  };
  static const Set<String> requiredKeys = {'cartId', 'cartRowVersion', 'ok'};

  /// `paymentChecks`.
  static const Set<String> paymentChecksKeys = {
    'creditAllowed',
    'creditReason',
    'limitRemaining',
    'receivablesAsOf',
    'receivablesStale',
  };

  /// `permissions`.
  static const Set<String> permissionsKeys = {
    'canCreateOrder',
    'canApplyDiscount',
    'discountLimitPercent',
    'canSellOnCredit',
    'needsOverride',
    'allowedPaymentMethods',
  };

  /// `onecCheck`.
  static const Set<String> onecCheckKeys = {'performed', 'at', 'result'};

  static CheckoutPreview fromJson(JsonMap j, {required CartJsonDecoder cart, required OrderJsonDecoder order}) {
    final JsonMap? checks = jObject(j, 'paymentChecks');
    final JsonMap? perms = jObject(j, 'permissions');
    final JsonMap? onec = jObject(j, 'onecCheck');
    return CheckoutPreview(
      cartId: jReq<String>(j, 'cartId'),
      cartRowVersion: jReqInt(j, 'cartRowVersion'),
      ok: jReq<bool>(j, 'ok'),
      conflicts: cart.conflicts(j['conflicts']),
      items: jObjects(j, 'items', order.line),
      subtotal: jMoney(j, 'subtotal'),
      discountPercent: jPercent(j, 'discountPercent'),
      discountTotal: jMoney(j, 'discountTotal'),
      customerDiscountTotal: jMoney(j, 'customerDiscountTotal'),
      total: jMoney(j, 'total'),
      cashRounding: jMoneyAmount(j, 'cashRounding') ?? Money.zero,
      totalToPay: jMoney(j, 'totalToPay'),
      paymentMethod: jEnum(j, 'paymentMethod', PaymentMethod.tryParse),
      paymentChecks: checks == null
          ? null
          : PaymentChecks(
              creditAllowed: jBool(checks, 'creditAllowed'),
              creditReason: jEnum(checks, 'creditReason', CreditReason.tryParse),
              limitRemaining: jMoney(checks, 'limitRemaining'),
              receivablesAsOf: jDate(checks, 'receivablesAsOf'),
              receivablesStale: jBool(checks, 'receivablesStale'),
            ),
      permissions: perms == null
          ? null
          : CheckoutPermissions(
              canCreateOrder: jBool(perms, 'canCreateOrder'),
              canApplyDiscount: jBool(perms, 'canApplyDiscount'),
              discountLimitPercent: jPercent(perms, 'discountLimitPercent'),
              canSellOnCredit: jBool(perms, 'canSellOnCredit'),
              needsOverride: jStrings(perms, 'needsOverride'),
              allowedPaymentMethods: <PaymentMethod>[
                for (final String m in jStrings(perms, 'allowedPaymentMethods'))
                  if (PaymentMethod.tryParse(m) case final PaymentMethod known) known,
              ],
            ),
      onecCheck: onec == null
          ? null
          : OnecCheck(
              performed: jBool(onec, 'performed'),
              at: jDate(onec, 'at'),
              result: jEnum(onec, 'result', OnecCheckResult.tryParse),
            ),
      validUntil: jDate(j, 'validUntil'),
      previewToken: jOpt<String>(j, 'previewToken'), // check-secrets: allow — имя поля DTO
      warnings: WarningDto.listOf(j),
    );
  }
}

/// Тела запросов оформления (`additionalProperties: false`; цены и итоги — никогда, D-23).
abstract final class CheckoutRequestDto {
  /// `CartOverride`.
  static const Set<String> overrideKeys = {'reason'};

  static JsonMap _override(String reason) => <String, dynamic>{'reason': reason};

  /// `CartCheckoutPreviewRequest`.
  static const Set<String> previewKeys = {
    'cartId',
    'cartRowVersion',
    'paymentMethod',
    'delivery',
    'receiver',
    'manualDiscountPercent',
    'creditOverride',
    'syncCheckWithOnec',
    'strict',
  };
  static const Set<String> previewRequired = {'cartId', 'cartRowVersion', 'paymentMethod', 'delivery', 'receiver'};

  static JsonMap preview(CheckoutPreviewRequest r) => <String, dynamic>{
    'cartId': r.cartId,
    'cartRowVersion': r.cartRowVersion,
    'paymentMethod': r.paymentMethod.value,
    'delivery': DeliveryDto.toJson(r.delivery),
    'receiver': ReceiverDto.toJson(r.receiver),
    if (r.manualDiscountPercent != null) 'manualDiscountPercent': r.manualDiscountPercent!.toApiString(),
    if (r.creditOverrideReason != null) 'creditOverride': _override(r.creditOverrideReason!),
    'syncCheckWithOnec': r.syncCheckWithOnec,
    'strict': r.strict,
  };

  /// `OrdersCreateItem`.
  static const Set<String> createItemKeys = {'variantId', 'quantity'};

  /// `OrdersCreateRequest`.
  static const Set<String> createKeys = {
    'cartId',
    'cartRowVersion',
    'previewToken',
    'customerId',
    'receiver',
    'delivery',
    'paymentMethod',
    'manualDiscountPercent',
    'discountOverride',
    'creditOverride',
    'printOptions',
    'comment',
    'confirmDuplicate',
    'items',
  };
  static const Set<String> createRequired = {
    'cartId',
    'cartRowVersion',
    'paymentMethod',
    'delivery',
    'receiver',
    'items',
  };

  static JsonMap create(OrderCreateRequest r) => <String, dynamic>{
    'cartId': r.cartId,
    'cartRowVersion': r.cartRowVersion,
    'previewToken': ?r.previewToken, // check-secrets: allow — имя поля DTO
    'customerId': ?r.customerId,
    'receiver': ReceiverDto.toJson(r.receiver),
    'delivery': DeliveryDto.toJson(r.delivery),
    'paymentMethod': r.paymentMethod.value,
    if (r.manualDiscountPercent != null) 'manualDiscountPercent': r.manualDiscountPercent!.toApiString(),
    if (r.discountOverrideReason != null) 'discountOverride': _override(r.discountOverrideReason!),
    if (r.creditOverrideReason != null) 'creditOverride': _override(r.creditOverrideReason!),
    if (r.printOptions != null) 'printOptions': PrintOptionsDto.toJson(r.printOptions!),
    if (r.comment != null && r.comment!.isNotEmpty) 'comment': r.comment,
    if (r.confirmDuplicate) 'confirmDuplicate': true,
    'items': <JsonMap>[
      for (final OrderCreateItem i in r.items)
        <String, dynamic>{'variantId': i.variantId, 'quantity': QuantityDto.toJson(i.quantity)},
    ],
  };
}
