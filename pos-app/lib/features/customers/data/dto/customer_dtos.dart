// DTO-кодеки клиентов (contracts/openapi/pos-api.v1.yaml 1.2.0; ADR-085 — вручную): `Customer`,
// `SearchCustomerItem`, `CustomerPhone`, `PriceListRef`, `ReceivableSummary`, `CustomersCreateRequest`.
// Сверка ключей — test/features/customers/data/customer_dtos_contract_test.dart.
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/network/dto_json.dart';
import 'package:optomstroy/features/customers/data/dto/customer_g_dtos.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/entities/new_customer.dart';

/// `CustomerPhone`.
abstract final class CustomerPhoneDto {
  static const Set<String> jsonKeys = {'value', 'verified'};
  static const Set<String> requiredKeys = {'value', 'verified'};

  static CustomerPhone fromJson(JsonMap j) =>
      CustomerPhone(valueE164: jReq<String>(j, 'value'), verified: jBool(j, 'verified') ?? false);
}

/// `PriceListRef`.
abstract final class PriceListRefDto {
  static const Set<String> jsonKeys = {'id', 'name'};
  static const Set<String> requiredKeys = {'id', 'name'};

  static PriceListRef fromJson(JsonMap j) => PriceListRef(id: jReq<String>(j, 'id'), name: jReq<String>(j, 'name'));
}

/// `ReceivableSummary`.
abstract final class ReceivableSummaryDto {
  static const Set<String> jsonKeys = {'balance', 'overdueAmount', 'creditLimit', 'limitRemaining', 'asOf'};
  static const Set<String> requiredKeys = {'balance', 'asOf'};

  static ReceivableSummary fromJson(JsonMap j) => ReceivableSummary(
    balance: jReqMoney(j, 'balance'),
    overdueAmount: jMoney(j, 'overdueAmount'),
    creditLimit: jMoney(j, 'creditLimit'),
    limitRemaining: jMoney(j, 'limitRemaining'),
    asOf: jReqDate(j, 'asOf'),
  );
}

/// `Customer` (и `SearchCustomerItem` = Customer + `matchType`; `CustomersListItem` = Customer с `links[]` вида
/// `CustomersLinkWithUser`).
abstract final class CustomerDto {
  static const Set<String> jsonKeys = {
    'id',
    'name',
    'displayName',
    'customerType',
    'onecCode',
    'isRetailDefault',
    'phoneMasked',
    'phones',
    'inn',
    'priceList',
    'discountPercent',
    'creditAllowed',
    'hasDebt',
    'isOverdue',
    'receivable',
    'ordersCount',
    'lastOrderAt',
    'addresses',
    'contacts',
    'discounts',
    'links',
    'isFavorite',
    'source',
    'onecStatus',
    'onecRef',
    'syncedAt',
  };

  /// Поля контракта, не переносимые в сущность (этап G: все поля `Customer` переносятся).
  static const Set<String> ignoredKeys = <String>{};
  static const Set<String> requiredKeys = {'id', 'name'};

  /// `SearchCustomerItem`.
  static const Set<String> searchItemKeys = {...jsonKeys, 'matchType'};

  static Customer fromJson(JsonMap j) {
    final JsonMap? priceList = jObject(j, 'priceList');
    final JsonMap? receivable = jObject(j, 'receivable');
    final JsonMap? discounts = jObject(j, 'discounts');
    return Customer(
      id: jReq<String>(j, 'id'),
      name: jReq<String>(j, 'name'),
      displayName: jOpt<String>(j, 'displayName'),
      customerType: jEnum(j, 'customerType', CustomerType.tryParse),
      onecCode: jOpt<String>(j, 'onecCode'),
      isRetailDefault: jBool(j, 'isRetailDefault') ?? false,
      phoneMasked: jOpt<String>(j, 'phoneMasked'),
      phones: jObjects(j, 'phones', CustomerPhoneDto.fromJson),
      inn: jOpt<String>(j, 'inn'),
      priceList: priceList == null ? null : PriceListRefDto.fromJson(priceList),
      discountPercent: jPercent(j, 'discountPercent'),
      creditAllowed: jBool(j, 'creditAllowed'),
      hasDebt: jBool(j, 'hasDebt'),
      isOverdue: jBool(j, 'isOverdue'),
      receivable: receivable == null ? null : ReceivableSummaryDto.fromJson(receivable),
      ordersCount: jInt(j, 'ordersCount'),
      lastOrderAt: jDate(j, 'lastOrderAt'),
      addresses: jStrings(j, 'addresses'),
      contacts: jObjects(j, 'contacts', CustomerContactDto.fromJson),
      discounts: discounts == null ? null : CustomerDiscountsDto.fromJson(discounts),
      // `Customer.links[]` — `CustomerLink`; `CustomersListItem.links[]` — `CustomersLinkWithUser` (+ `user`).
      links: jObjects(j, 'links', CustomerLinkDto.fromJson),
      isFavorite: jBool(j, 'isFavorite'),
      source: jEnum(j, 'source', CustomerSource.tryParse),
      onecStatus: jEnum(j, 'onecStatus', CustomerOnecStatus.tryParse),
      onecRef: jOpt<String>(j, 'onecRef'),
      syncedAt: jDate(j, 'syncedAt'),
      matchType: jEnum(j, 'matchType', CustomerMatchType.tryParse),
    );
  }

  /// Вложенный клиент (`Cart.customer`, `Order.customer`), `null` — нет.
  static Customer? optional(JsonMap j, String key) {
    final JsonMap? v = jObject(j, key);
    return v == null ? null : fromJson(v);
  }
}

/// `CustomersCreateRequest`.
abstract final class NewCustomerRequestDto {
  static const Set<String> jsonKeys = {
    'name',
    'customerType',
    'phones',
    'inn',
    'address',
    'comment',
    'priceListId',
    'forceCreate',
    'forceReason',
  };
  static const Set<String> requiredKeys = {'name', 'customerType', 'phones'};

  /// `additionalProperties: false`; `forceReason` — только при `forceCreate=true` (rule `force_reason_required`).
  static JsonMap toJson(NewCustomerRequest r) => <String, dynamic>{
    'name': r.name,
    'customerType': r.customerType.value,
    'phones': r.phonesE164,
    if (r.inn != null && r.inn!.isNotEmpty) 'inn': r.inn,
    if (r.address != null && r.address!.isNotEmpty) 'address': r.address,
    if (r.comment != null && r.comment!.isNotEmpty) 'comment': r.comment,
    'priceListId': ?r.priceListId,
    'forceCreate': r.forceCreate,
    if (r.forceCreate) 'forceReason': r.forceReason,
  };
}

/// Элемент `candidates[]` ответа `409 CUSTOMER_DUPLICATE_SUSPECTED` (08 §4.11.2: id, displayName, phoneMasked, source).
abstract final class DuplicateCandidateDto {
  static DuplicateCandidate fromJson(JsonMap j) => DuplicateCandidate(
    id: jReq<String>(j, 'id'),
    displayName: jOpt<String>(j, 'displayName') ?? jOpt<String>(j, 'name') ?? '',
    phoneMasked: jOpt<String>(j, 'phoneMasked'),
    source: jEnum(j, 'source', CustomerSource.tryParse),
  );

  /// Кандидаты из сырых полей problem+json (`ConflictFailure.details`).
  static List<DuplicateCandidate> fromProblem(Map<String, Object?> details) {
    final Object? raw = details['candidates'];
    if (raw is! List) return const <DuplicateCandidate>[];
    final List<DuplicateCandidate> out = <DuplicateCandidate>[];
    for (final Object? item in raw) {
      if (item is! Map) continue;
      try {
        out.add(fromJson(item.cast<String, dynamic>()));
      } on DtoFormatException {
        continue;
      }
    }
    return out;
  }
}
