// Контакты и привязки клиента (08 §3.7 `Customer.contacts[]`, `Customer.links[]`, `CustomersListItem.links[]`;
// `CustomerContact`, `CustomerLink`, `CustomersLinkWithUser`). Контакты — только чтение (редактирование — R2),
// привязки — `customer.link.read` (admin, owner; customer — своя). ПДн — только в памяти. Чистый Dart (FL-01).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/models/pos_common.dart';

/// Контакт клиента (`CustomerContact`).
final class CustomerContact {
  const CustomerContact({required this.kind, required this.value, this.name});

  /// `null` — вид, неизвестный клиенту.
  final ContactKind? kind;
  final String value;
  final String? name;

  @override
  String toString() => 'CustomerContact(${kind?.value})';
}

/// Пользователь приложения в привязке (`CustomersLinkUser`; только `GET /customers`, admin).
final class CustomerLinkUser {
  const CustomerLinkUser({required this.id, required this.displayName, this.phoneMasked});

  final String id;
  final String displayName;
  final String? phoneMasked;
}

/// Привязка пользователя-клиента к карточке (`CustomerLink` / `CustomersLinkWithUser`).
final class CustomerLinkRef {
  const CustomerLinkRef({
    required this.id,
    required this.customerId,
    required this.status,
    this.userId,
    this.matchedBy,
    this.createdAt,
    this.resolvedBy,
    this.resolvedAt,
    this.user,
  });

  final String id;
  final String customerId;

  /// `null` — статус, неизвестный клиенту.
  final CustomerLinkStatus? status;
  final String? userId;
  final LinkMatchMethod? matchedBy;
  final DateTime? createdAt;
  final UserRef? resolvedBy;
  final DateTime? resolvedAt;
  final CustomerLinkUser? user;
}
