// DTO-кодеки клиентов этапа G (contracts/openapi/pos-api.v1.yaml 1.2.0; ADR-085 — вручную): `CustomerContact`,
// `CustomerLink`, `CustomersLinkWithUser`, `CustomersLinkUser`, `DiscountRule`, `CustomersCreditTerms`,
// `CustomersDiscountsResponse`, `DiscountsRulesResponse`, `Receivable`, `ReceivableDocument`,
// `ReceivablesOverdueItem`, `CustomerHistory`, `CustomersHistoryEntry`, `CustomersHistorySummary`.
// Сверка ключей — test/features/customers/data/customer_g_dtos_contract_test.dart. Деньги — `Money` (тыйыны).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/network/dto_json.dart';
import 'package:optomstroy/core/network/models/pos_common_dtos.dart';
import 'package:optomstroy/features/customers/data/dto/customer_dtos.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/entities/customer_contact.dart';
import 'package:optomstroy/features/customers/domain/entities/customer_history.dart';
import 'package:optomstroy/features/customers/domain/entities/customer_terms.dart';
import 'package:optomstroy/features/customers/domain/entities/receivable.dart';

/// `CustomerContact`.
abstract final class CustomerContactDto {
  static const Set<String> jsonKeys = {'kind', 'value', 'name'};
  static const Set<String> requiredKeys = {'kind', 'value'};

  static CustomerContact fromJson(JsonMap j) => CustomerContact(
    kind: ContactKind.tryParse(jReq<String>(j, 'kind')),
    value: jReq<String>(j, 'value'),
    name: jOpt<String>(j, 'name'),
  );
}

/// `CustomersLinkUser`.
abstract final class CustomerLinkUserDto {
  static const Set<String> jsonKeys = {'id', 'displayName', 'phoneMasked'};
  static const Set<String> requiredKeys = {'id', 'displayName'};

  static CustomerLinkUser fromJson(JsonMap j) => CustomerLinkUser(
    id: jReq<String>(j, 'id'),
    displayName: jReq<String>(j, 'displayName'),
    phoneMasked: jOpt<String>(j, 'phoneMasked'),
  );
}

/// `CustomerLink` и `CustomersLinkWithUser` (= CustomerLink + `user`).
abstract final class CustomerLinkDto {
  static const Set<String> jsonKeys = {
    'id',
    'userId',
    'customerId',
    'status',
    'matchedBy',
    'createdAt',
    'resolvedBy',
    'resolvedAt',
  };
  static const Set<String> requiredKeys = {'id', 'customerId', 'status'};

  /// `CustomersLinkWithUser`.
  static const Set<String> withUserKeys = {...jsonKeys, 'user'};
  static const Set<String> withUserRequiredKeys = {...requiredKeys, 'user'};

  static CustomerLinkRef fromJson(JsonMap j) {
    final JsonMap? user = jObject(j, 'user');
    return CustomerLinkRef(
      id: jReq<String>(j, 'id'),
      customerId: jReq<String>(j, 'customerId'),
      status: CustomerLinkStatus.tryParse(jReq<String>(j, 'status')),
      userId: jOpt<String>(j, 'userId'),
      matchedBy: jEnum(j, 'matchedBy', LinkMatchMethod.tryParse),
      createdAt: jDate(j, 'createdAt'),
      resolvedBy: UserRefDto.optional(j, 'resolvedBy'),
      resolvedAt: jDate(j, 'resolvedAt'),
      user: user == null ? null : CustomerLinkUserDto.fromJson(user),
    );
  }
}

/// `DiscountRule`.
abstract final class DiscountRuleDto {
  static const Set<String> jsonKeys = {
    'id',
    'source',
    'name',
    'kind',
    'value',
    'requiresApproval',
    'isActive',
    'conditions',
  };
  static const Set<String> requiredKeys = {'id', 'source', 'kind'};
  static const Set<String> conditionKeys = {'minTotal', 'categoryIds', 'customerIds'};

  static DiscountRule fromJson(JsonMap j) {
    final JsonMap? c = jObject(j, 'conditions');
    return DiscountRule(
      id: jReq<String>(j, 'id'),
      source: DiscountSource.tryParse(jReq<String>(j, 'source')),
      kind: DiscountKind.tryParse(jReq<String>(j, 'kind')),
      name: jOpt<String>(j, 'name'),
      value: jOpt<String>(j, 'value'),
      requiresApproval: jBool(j, 'requiresApproval'),
      isActive: jBool(j, 'isActive'),
      conditions: c == null
          ? null
          : DiscountRuleConditions(
              minTotal: jMoney(c, 'minTotal'),
              categoryIds: jStrings(c, 'categoryIds'),
              customerIds: jStrings(c, 'customerIds'),
            ),
    );
  }
}

/// `CustomersCreditTerms`.
abstract final class CustomerCreditTermsDto {
  static const Set<String> jsonKeys = {'creditAllowed', 'paymentTermDays', 'creditLimit'};
  static const Set<String> requiredKeys = {'creditAllowed'};

  static CustomerCreditTerms fromJson(JsonMap j) => CustomerCreditTerms(
    creditAllowed: jReq<bool>(j, 'creditAllowed'),
    paymentTermDays: jInt(j, 'paymentTermDays'),
    creditLimit: jMoney(j, 'creditLimit'),
  );
}

/// `CustomersDiscountsResponse` (`GET /customers/{id}/discounts`, `Customer.discounts`).
abstract final class CustomerDiscountsDto {
  static const Set<String> jsonKeys = {
    'priceList',
    'customerDiscountPercent',
    'rules',
    'creditTerms',
    'manualDiscountLimitPercent',
    'asOf',
  };
  static const Set<String> requiredKeys = {'rules', 'asOf'};

  static CustomerDiscounts fromJson(JsonMap j) {
    final JsonMap? priceList = jObject(j, 'priceList');
    final JsonMap? terms = jObject(j, 'creditTerms');
    return CustomerDiscounts(
      priceList: priceList == null ? null : PriceListRefDto.fromJson(priceList),
      customerDiscountPercent: jPercent(j, 'customerDiscountPercent'),
      rules: jObjects(j, 'rules', DiscountRuleDto.fromJson, required: true),
      creditTerms: terms == null ? null : CustomerCreditTermsDto.fromJson(terms),
      manualDiscountLimitPercent: jPercent(j, 'manualDiscountLimitPercent'),
      asOf: jReqDate(j, 'asOf'),
    );
  }
}

/// `DiscountsRulesResponse` (`GET /discounts/rules`).
abstract final class DiscountRulesDto {
  static const Set<String> jsonKeys = {'rules', 'manualDiscountLimitPercent', 'overrideRoles', 'limitsByRole'};
  static const Set<String> requiredKeys = {'rules', 'manualDiscountLimitPercent'};

  static DiscountRulesInfo fromJson(JsonMap j) {
    final JsonMap limits = jObject(j, 'limitsByRole') ?? const <String, dynamic>{};
    return DiscountRulesInfo(
      rules: jObjects(j, 'rules', DiscountRuleDto.fromJson, required: true),
      manualDiscountLimitPercent:
          jPercent(j, 'manualDiscountLimitPercent') ?? (throw const DtoFormatException('manualDiscountLimitPercent')),
      overrideRoles: <RoleCode>[for (final String r in jStrings(j, 'overrideRoles')) ?RoleCode.tryParse(r)],
      limitsByRole: <String, String>{
        for (final MapEntry<String, dynamic> e in limits.entries)
          if (e.value is String) e.key: e.value as String,
      },
    );
  }
}

/// `ReceivableDocument`.
abstract final class ReceivableDocumentDto {
  static const Set<String> jsonKeys = {
    'kind',
    'status',
    'number',
    'date',
    'amount',
    'paid',
    'remaining',
    'dueDate',
    'overdueDays',
    'onecRef',
  };
  static const Set<String> requiredKeys = {'kind', 'status', 'amount'};

  static ReceivableDocument fromJson(JsonMap j) => ReceivableDocument(
    kind: ReceivableDocumentKind.tryParse(jReq<String>(j, 'kind')),
    status: ReceivableDocumentStatus.tryParse(jReq<String>(j, 'status')),
    number: jOpt<String>(j, 'number'),
    date: jDate(j, 'date'),
    amount: jReqMoney(j, 'amount'),
    paid: jMoney(j, 'paid'),
    remaining: jMoney(j, 'remaining'),
    dueDate: jDate(j, 'dueDate'),
    overdueDays: jInt(j, 'overdueDays'),
    onecRef: jOpt<String>(j, 'onecRef'),
  );
}

/// `Receivable`.
abstract final class ReceivableDto {
  static const Set<String> jsonKeys = {
    'customerId',
    'balance',
    'reason',
    'overdueAmount',
    'overdueDays',
    'creditLimit',
    'openOrdersAmount',
    'limitRemaining',
    'creditAllowed',
    'paymentTermDays',
    'asOf',
    'isStale',
    'staleAfterMinutes',
    'refreshed',
    'documents',
  };

  /// `balance` и `asOf` обязательны, но nullable (`null` — снимка нет).
  static const Set<String> requiredKeys = {'customerId', 'balance', 'asOf'};

  static Receivable fromJson(JsonMap j) {
    if (!j.containsKey('balance') || !j.containsKey('asOf')) throw const DtoFormatException('balance/asOf');
    return Receivable(
      customerId: jReq<String>(j, 'customerId'),
      balance: jMoney(j, 'balance'),
      reason: jEnum(j, 'reason', ReceivableAbsenceReason.tryParse),
      overdueAmount: jMoney(j, 'overdueAmount'),
      overdueDays: jInt(j, 'overdueDays'),
      creditLimit: jMoney(j, 'creditLimit'),
      openOrdersAmount: jMoney(j, 'openOrdersAmount'),
      limitRemaining: jMoney(j, 'limitRemaining'),
      creditAllowed: jBool(j, 'creditAllowed'),
      paymentTermDays: jInt(j, 'paymentTermDays'),
      asOf: jDate(j, 'asOf'),
      isStale: jBool(j, 'isStale') ?? false,
      staleAfterMinutes: jInt(j, 'staleAfterMinutes'),
      refreshed: jBool(j, 'refreshed') ?? false,
      documents: j['documents'] == null ? null : jObjects(j, 'documents', ReceivableDocumentDto.fromJson),
    );
  }
}

/// `ReceivablesOverdueItem`.
abstract final class OverdueReceivableDto {
  static const Set<String> jsonKeys = {'customer', 'balance', 'overdueAmount', 'overdueDays', 'oldestDueDate', 'asOf'};
  static const Set<String> requiredKeys = {'customer', 'balance', 'overdueAmount', 'overdueDays', 'asOf'};

  static OverdueReceivable fromJson(JsonMap j) => OverdueReceivable(
    customer: CustomerDto.fromJson(jReqObject(j, 'customer')),
    balance: jReqMoney(j, 'balance'),
    overdueAmount: jReqMoney(j, 'overdueAmount'),
    overdueDays: jReqInt(j, 'overdueDays'),
    oldestDueDate: jDate(j, 'oldestDueDate'),
    asOf: jReqDate(j, 'asOf'),
  );

  /// Ответ `GET /receivables/overdue` (Page + `isStale`).
  static const Set<String> pageKeys = {...PageDto.jsonKeys, 'isStale'};

  static OverdueReceivablesPage pageFromJson(JsonMap j) =>
      OverdueReceivablesPage(page: PageDto.fromJson(j, fromJson), isStale: jBool(j, 'isStale') ?? false);
}

/// `CustomersHistoryEntry`.
abstract final class CustomerHistoryEntryDto {
  static const Set<String> jsonKeys = {'kind', 'id', 'number', 'date', 'total', 'status', 'source', 'url'};
  static const Set<String> requiredKeys = {'kind', 'number', 'date', 'total', 'status', 'source'};

  static CustomerHistoryEntry fromJson(JsonMap j) => CustomerHistoryEntry(
    kind: CustomerHistoryKind.tryParse(jReq<String>(j, 'kind')),
    id: jOpt<String>(j, 'id'),
    number: jReq<String>(j, 'number'),
    date: jReqDate(j, 'date'),
    total: jReqMoney(j, 'total'),
    status: jReq<String>(j, 'status'),
    source: CustomerHistorySource.tryParse(jReq<String>(j, 'source')),
    url: jOpt<String>(j, 'url'),
  );
}

/// `CustomersHistorySummary`.
abstract final class CustomerHistorySummaryDto {
  static const Set<String> jsonKeys = {'count', 'total', 'lastOrderAt'};
  static const Set<String> requiredKeys = {'count', 'total'};

  static CustomerHistorySummary fromJson(JsonMap j) => CustomerHistorySummary(
    count: jReqInt(j, 'count'),
    total: jReqMoney(j, 'total'),
    lastOrderAt: jDate(j, 'lastOrderAt'),
  );
}

/// `CustomerHistory` (Page + `summary` + `historyFrom`).
abstract final class CustomerHistoryDto {
  static const Set<String> jsonKeys = {...PageDto.jsonKeys, 'summary', 'historyFrom'};
  static const Set<String> requiredKeys = {'items', 'nextCursor', 'hasMore', 'summary'};

  static CustomerHistory fromJson(JsonMap j) => CustomerHistory(
    page: PageDto.fromJson(j, CustomerHistoryEntryDto.fromJson),
    summary: CustomerHistorySummaryDto.fromJson(jReqObject(j, 'summary')),
    historyFrom: jDate(j, 'historyFrom'),
  );
}

/// `GET /favorites/customers` (Page + `count`).
abstract final class FavoriteCustomersPageDto {
  static const Set<String> jsonKeys = {...PageDto.jsonKeys, 'count'};

  static (PageResult<Customer>, int) fromJson(JsonMap j) =>
      (PageDto.fromJson(j, CustomerDto.fromJson), jReqInt(j, 'count'));
}
