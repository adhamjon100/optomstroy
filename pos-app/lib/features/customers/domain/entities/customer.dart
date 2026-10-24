// Клиент (08 §3.7 `Customer`) — надмножество полей; сервер отдаёт поля по allowlist роли (поля, не разрешённые
// роли, отсутствуют → `null`/пусто). Суммы долга ([receivable]) — только из сетевого ответа, в памяти процесса,
// на диск не пишутся (07 §11.1 п.5, DATA-258, DATA-264). Чистый Dart (FL-01).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/customers/domain/entities/customer_contact.dart';
import 'package:optomstroy/features/customers/domain/entities/customer_terms.dart';

/// Телефон клиента (`CustomerPhone`).
final class CustomerPhone {
  const CustomerPhone({required this.valueE164, required this.verified});

  final String valueE164;
  final bool verified;
}

/// Вид цены клиента (`PriceListRef`).
final class PriceListRef {
  const PriceListRef({required this.id, required this.name});

  final String id;
  final String name;
}

/// Сводка долга (`ReceivableSummary`) — только cashier, senior_seller, admin, owner, customer (свой).
final class ReceivableSummary {
  const ReceivableSummary({
    required this.balance,
    required this.asOf,
    this.overdueAmount,
    this.creditLimit,
    this.limitRemaining,
  });

  final Money balance;
  final Money? overdueAmount;
  final Money? creditLimit;
  final Money? limitRemaining;

  /// Метка снимка 1С (`onec_snapshot_at`); старше `RECEIVABLES_MAX_AGE_MIN` — «устарело».
  final DateTime asOf;
}

/// Как найден клиент (`SearchCustomerItem.matchType`).
enum CustomerMatchType {
  name('name'),
  phone('phone'),
  code('code'),
  inn('inn');

  const CustomerMatchType(this.value);

  final String value;

  static CustomerMatchType? tryParse(String? value) {
    for (final CustomerMatchType t in values) {
      if (t.value == value) return t;
    }
    return null;
  }
}

/// Клиент (`Customer`, `SearchCustomerItem`, `CustomersListItem`, `Cart.customer`, `Order.customer`).
///
/// Этап G (основа): `discounts` (SCR-35, `include=discounts`), `contacts` (SCR-32, `include=contacts`), `links`
/// (`customer.link.read`; `include=links`) — только при запросе карточки с `include`, иначе пусто/`null`.
final class Customer {
  const Customer({
    required this.id,
    required this.name,
    this.displayName,
    this.customerType,
    this.onecCode,
    this.isRetailDefault = false,
    this.phoneMasked,
    this.phones = const <CustomerPhone>[],
    this.inn,
    this.priceList,
    this.discountPercent,
    this.creditAllowed,
    this.hasDebt,
    this.isOverdue,
    this.receivable,
    this.ordersCount,
    this.lastOrderAt,
    this.addresses = const <String>[],
    this.contacts = const <CustomerContact>[],
    this.discounts,
    this.links = const <CustomerLinkRef>[],
    this.isFavorite,
    this.source,
    this.onecStatus,
    this.onecRef,
    this.syncedAt,
    this.matchType,
  });

  final String id;
  final String name;
  final String? displayName;
  final CustomerType? customerType;
  final String? onecCode;

  /// Системный клиент «Розничный покупатель» (Q-026).
  final bool isRetailDefault;

  /// Маскированный телефон (`seller`).
  final String? phoneMasked;

  /// Полные телефоны (`cashier`+, `customer` — свой).
  final List<CustomerPhone> phones;
  final String? inn;
  final PriceListRef? priceList;

  /// Скидка клиента 1С (сотые доли процента).
  final Percent? discountPercent;
  final bool? creditAllowed;
  final bool? hasDebt;
  final bool? isOverdue;
  final ReceivableSummary? receivable;
  final int? ordersCount;
  final DateTime? lastOrderAt;
  final List<String> addresses;

  /// Контакты (cashier+, customer — свой); только чтение.
  final List<CustomerContact> contacts;

  /// Скидки и условия (`include=discounts`).
  final CustomerDiscounts? discounts;

  /// Привязки пользователей-клиентов (admin, owner; customer — своя).
  final List<CustomerLinkRef> links;
  final bool? isFavorite;
  final CustomerSource? source;

  /// Статус создания клиента POS в 1С (`pending` — продажа в долг недоступна до подтверждения).
  final CustomerOnecStatus? onecStatus;
  final String? onecRef;
  final DateTime? syncedAt;
  final CustomerMatchType? matchType;

  /// Имя для показа: `displayName`, иначе `name`.
  String get title => (displayName == null || displayName!.isEmpty) ? name : displayName!;

  @override
  String toString() => 'Customer($id)';
}
