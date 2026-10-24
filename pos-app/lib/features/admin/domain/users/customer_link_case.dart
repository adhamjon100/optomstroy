// Вкладка «Привязки клиентов» (UI-45-017/018; D-08; 09 §7.9; 08 §4.11.1, §4.11.7).
// Список — `GET /customers?linkStatus=proposed,conflict` (право `customer.link.conflicts.read`, только `admin`).
// Чистый Dart (FL-01).
import 'package:optomstroy/core/enums.dart';

/// Карточка клиента 1С/POS со связями, ожидающими решения администратора.
final class CustomerLinkCase {
  const CustomerLinkCase({
    required this.customerId,
    required this.name,
    required this.links,
    this.displayName,
    this.inn,
    this.phones = const [],
    this.onecCode,
  });

  final String customerId;
  final String name;
  final String? displayName;
  final String? inn;
  final List<String> phones;
  final String? onecCode;

  /// Связи в статусах `proposed`/`conflict`.
  final List<CustomerLinkCandidate> links;

  String get title => displayName?.isNotEmpty ?? false ? displayName! : name;

  /// Есть конфликт (≥ 2 кандидатов или статус `conflict`).
  bool get hasConflict => links.any((l) => l.linkStatus == CustomerLinkStatus.conflict);

  /// Ещё есть нерешённые связи.
  bool get hasOpenLinks => links.any((l) => l.isOpen);

  CustomerLinkCase withLink(CustomerLinkCandidate updated) => CustomerLinkCase(
    customerId: customerId,
    name: name,
    displayName: displayName,
    inn: inn,
    phones: phones,
    onecCode: onecCode,
    links: [for (final l in links) l.id == updated.id ? l.merge(updated) : l],
  );

  @override
  String toString() => 'CustomerLinkCase($customerId, ${links.length} links)';
}

/// Связь аккаунта `customer` с карточкой (`CustomerLink` + `user`).
final class CustomerLinkCandidate {
  const CustomerLinkCandidate({
    required this.id,
    required this.customerId,
    required this.status,
    this.userId,
    this.userDisplayName,
    this.userPhoneMasked,
    this.matchedBy,
    this.createdAt,
  });

  final String id;
  final String customerId;
  final String status;
  final String? userId;
  final String? userDisplayName;
  final String? userPhoneMasked;
  final String? matchedBy;
  final DateTime? createdAt;

  CustomerLinkStatus? get linkStatus => CustomerLinkStatus.tryParse(status);

  /// Решение ещё не принято.
  bool get isOpen => linkStatus == CustomerLinkStatus.proposed || linkStatus == CustomerLinkStatus.conflict;

  /// Ответ `confirm`/`reject` (`CustomerLink`) не содержит `user` — сохраняем его из списка.
  CustomerLinkCandidate merge(CustomerLinkCandidate fresh) => CustomerLinkCandidate(
    id: id,
    customerId: customerId,
    status: fresh.status,
    userId: fresh.userId ?? userId,
    userDisplayName: fresh.userDisplayName ?? userDisplayName,
    userPhoneMasked: fresh.userPhoneMasked ?? userPhoneMasked,
    matchedBy: fresh.matchedBy ?? matchedBy,
    createdAt: fresh.createdAt ?? createdAt,
  );

  @override
  String toString() => 'CustomerLinkCandidate($id, $status)';
}
