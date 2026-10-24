// Транзакция журнала операций (08 §4.16 `Transaction`, read-model `transactions`, 07; 10 TXN-) — общая сущность
// этапа G для фич cashier (SCR-30 «Недавние операции»), transactions (SCR-36/37) и reports (SCR-48 «QR-сверка» →
// SCR-36). Лежит в core/models по правилу pos_common.dart: значение нужно фичам, у которых нет общего предка в DAG
// 06 §6.1 (dashboard cashier ↛ transactions). Чистый Dart (FL-01); деньги — `Money` (тыйыны, D-19).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';

/// Группа статуса транзакции для фильтра SCR-36 (`TransactionStatusGroup`, OpenAPI 1.2.0; значения — 08).
enum TransactionStatusGroup {
  received('received'),
  pending('pending'),
  voided('voided'),
  returned('returned'),
  onecError('onec_error');

  const TransactionStatusGroup(this.value);

  final String value;

  static TransactionStatusGroup? tryParse(String? value) {
    for (final TransactionStatusGroup g in values) {
      if (g.value == value) return g;
    }
    return null;
  }
}

/// Знак суммы (`Transaction.sign`): `+` — поступление, `-` — расход/аннулирование.
enum TransactionSign {
  plus('+'),
  minus('-');

  const TransactionSign(this.value);

  final String value;

  static TransactionSign? tryParse(String? value) {
    for (final TransactionSign s in values) {
      if (s.value == value) return s;
    }
    return null;
  }
}

/// Вид связанного документа (`TransactionRelated.type`).
enum TransactionRelatedType {
  order('order'),
  payment('payment'),
  returnRequest('return_request'),
  onecDocument('onec_document');

  const TransactionRelatedType(this.value);

  final String value;

  static TransactionRelatedType? tryParse(String? value) {
    for (final TransactionRelatedType t in values) {
      if (t.value == value) return t;
    }
    return null;
  }
}

/// Связанный документ (`TransactionRelated`).
final class TransactionRelated {
  const TransactionRelated({required this.type, this.id, this.number, this.url});

  /// `null` — значение вида, неизвестное клиенту (совместимость вперёд): строка показывается без перехода.
  final TransactionRelatedType? type;
  final String? id;
  final String? number;

  /// Внутренняя ссылка API (не URL для открытия в браузере).
  final String? url;
}

/// Клиент транзакции (`Transaction.customer` — только id и имя; финансов нет).
final class TransactionCustomerRef {
  const TransactionCustomerRef({this.id, this.displayName});

  final String? id;
  final String? displayName;
}

/// Транзакция (`Transaction`). Поля, не разрешённые роли, сервер не присылает.
final class Transaction {
  const Transaction({
    required this.id,
    required this.kind,
    required this.number,
    required this.occurredAt,
    required this.amount,
    required this.status,
    this.sign,
    this.statusGroup,
    this.customer,
    this.actor,
    this.source,
    this.related = const <TransactionRelated>[],
  });

  final String id;

  /// `null` — вид, неизвестный клиенту (совместимость вперёд).
  final TransactionKind? kind;
  final String number;
  final DateTime occurredAt;
  final Money amount;
  final TransactionSign? sign;

  /// Статус исходного документа строкой контракта (значения — 07/08, отображение — фича).
  final String status;
  final TransactionStatusGroup? statusGroup;
  final TransactionCustomerRef? customer;
  final UserRef? actor;
  final TransactionSource? source;
  final List<TransactionRelated> related;

  /// Сумма со знаком: `-` — отрицательная.
  Money get signedAmount => sign == TransactionSign.minus ? -amount : amount;

  @override
  String toString() => 'Transaction($id)';
}
