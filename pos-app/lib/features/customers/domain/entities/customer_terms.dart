// Скидки и условия клиента (08 §4.11.6 `CustomersDiscountsResponse`, §4.12 `DiscountsRulesResponse`, `DiscountRule`,
// `CustomersCreditTerms`; 10 DISC-, D-23) для SCR-35 и вложенного `Customer.discounts`. Скидки 1С — только чтение,
// автоматические скидки 1С не воспроизводятся (итог 1С — истина). Чистый Dart (FL-01).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';

/// Условия правила (`DiscountRule.conditions`).
final class DiscountRuleConditions {
  const DiscountRuleConditions({
    this.minTotal,
    this.categoryIds = const <String>[],
    this.customerIds = const <String>[],
  });

  final Money? minTotal;
  final List<String> categoryIds;
  final List<String> customerIds;
}

/// Правило скидки (`DiscountRule`).
final class DiscountRule {
  const DiscountRule({
    required this.id,
    required this.source,
    required this.kind,
    this.name,
    this.value,
    this.requiresApproval,
    this.isActive,
    this.conditions,
  });

  final String id;

  /// `null` — значение, неизвестное клиенту.
  final DiscountSource? source;
  final DiscountKind? kind;
  final String? name;

  /// Значение строкой контракта: процент (`5.00`), сумма (`MoneyAmount`) или id вида цены — по [kind].
  final String? value;
  final bool? requiresApproval;
  final bool? isActive;
  final DiscountRuleConditions? conditions;
}

/// Условия оплаты (`CustomersCreditTerms`): `creditLimit` — только cashier+ и customer (свой).
final class CustomerCreditTerms {
  const CustomerCreditTerms({required this.creditAllowed, this.paymentTermDays, this.creditLimit});

  final bool creditAllowed;
  final int? paymentTermDays;
  final Money? creditLimit;
}

/// Скидки и условия клиента (`CustomersDiscountsResponse`, SCR-35).
final class CustomerDiscounts {
  const CustomerDiscounts({
    required this.rules,
    required this.asOf,
    this.priceList,
    this.customerDiscountPercent,
    this.creditTerms,
    this.manualDiscountLimitPercent,
  });

  final PriceListRef? priceList;
  final Percent? customerDiscountPercent;
  final List<DiscountRule> rules;
  final CustomerCreditTerms? creditTerms;

  /// Лимит ручной скидки текущей роли (Q-015 — значения не подтверждены).
  final Percent? manualDiscountLimitPercent;

  /// Метка данных 1С.
  final DateTime asOf;
}

/// Правила скидок и лимиты ручной скидки (`GET /discounts/rules`, `DiscountsRulesResponse`).
final class DiscountRulesInfo {
  const DiscountRulesInfo({
    required this.rules,
    required this.manualDiscountLimitPercent,
    this.overrideRoles = const <RoleCode>[],
    this.limitsByRole = const <String, String>{},
  });

  final List<DiscountRule> rules;
  final Percent manualDiscountLimitPercent;

  /// Роли, подтверждающие скидку сверх лимита (10 DISC-, по умолчанию senior_seller/admin).
  final List<RoleCode> overrideRoles;

  /// Лимиты по ролям как пришли (`role → Percent`-строка); в OpenAPI 1.2.0 объект без схемы значений.
  final Map<String, String> limitsByRole;
}
