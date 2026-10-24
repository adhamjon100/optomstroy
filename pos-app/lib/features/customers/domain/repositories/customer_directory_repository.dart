// Порт справочника клиентов этапа G (SCR-31 поиск/список, SCR-32 карточка, SCR-33 история, SCR-35 скидки;
// 08 §4.11, §4.12). Отдельно от `CustomersRepository` этапа F (SCR-21/SCR-26), чтобы не ломать его реализации.
// Только онлайн: кэша клиентов на устройстве нет (07 §11.1 п. 5); поля ответа — по роли (allowlist сервера,
// 11 §4.4). Чистый Dart (FL-01).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/cancel_signal.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/entities/customer_history.dart';
import 'package:optomstroy/features/customers/domain/entities/customer_terms.dart';

/// Вложенные блоки карточки (`GET /customers/{id}?include=`).
enum CustomerInclude {
  receivable('receivable'),
  discounts('discounts'),
  links('links'),
  contacts('contacts');

  const CustomerInclude(this.value);

  final String value;
}

/// Сортировка `GET /customers`.
enum CustomersSort {
  nameAsc('name:asc'),
  lastOrderAtDesc('lastOrderAt:desc');

  const CustomersSort(this.value);

  final String value;
}

/// Параметры `GET /customers` (SCR-31 `/customers?q=&favorites=1&withDebt=1`; SCR-45 «Привязки» — `linkStatus`).
final class CustomersListQuery {
  const CustomersListQuery({
    this.q,
    this.favoriteOnly = false,
    this.hasDebt,
    this.isOverdue,
    this.customerType,
    this.linkStatuses = const <CustomerLinkStatus>{},
    this.withReceivable = false,
    this.limit,
    this.cursor,
    this.sort,
  });

  /// Строка поиска; правила длины по роли — на сервере (cashier+ — от 4 цифр / 2 букв, seller — полный номер или
  /// код; ядро §19.4).
  final String? q;
  final bool favoriteOnly;
  final bool? hasDebt;
  final bool? isOverdue;
  final CustomerType? customerType;

  /// Только `proposed`, `conflict` (1…2 значения).
  final Set<CustomerLinkStatus> linkStatuses;

  /// `include=receivable` — суммы долга (только с `customer.receivables.read.summary`).
  final bool withReceivable;
  final int? limit;
  final String? cursor;
  final CustomersSort? sort;
}

/// Параметры `GET /customers/{id}/orders` (SCR-33 `?from=&to=&source=`).
final class CustomerHistoryQuery {
  const CustomerHistoryQuery({this.from, this.to, this.source, this.limit, this.cursor});

  final DateTime? from;
  final DateTime? to;
  final CustomerHistorySource? source;
  final int? limit;
  final String? cursor;
}

abstract interface class CustomerDirectoryRepository {
  /// Список / поиск клиентов (`GET /customers`).
  Future<Result<PageResult<Customer>>> list(CustomersListQuery query, {CancelSignal? cancel});

  /// Карточка клиента с вложенными блоками (`GET /customers/{id}?include=`); поля — по роли.
  Future<Result<Customer>> card(String customerId, {Set<CustomerInclude> include = const <CustomerInclude>{}});

  /// История покупок (`GET /customers/{id}/orders`).
  Future<Result<CustomerHistory>> history(String customerId, CustomerHistoryQuery query, {CancelSignal? cancel});

  /// Скидки и условия клиента (`GET /customers/{id}/discounts`).
  Future<Result<CustomerDiscounts>> discounts(String customerId);

  /// Правила скидок и лимиты ручной скидки (`GET /discounts/rules`).
  Future<Result<DiscountRulesInfo>> discountRules({String? customerId, String? cartId});
}
