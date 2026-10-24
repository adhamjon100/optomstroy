// Снимок долга для показа (SCR-32 Z5, SCR-34 Z1–Z4): поля ответа сервера без вычислений (DEBT-001, D-24). Источник —
// `Customer.receivable` (`include=receivable`) или `Receivable` (`GET|POST …/receivables`). Статус продажи в долг
// (UI-34-007) выводится только сравнением присланных полей (fail-closed: нет данных/устарело — недоступна, PAY-031).
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/entities/receivable.dart';
import 'package:optomstroy/features/customers/presentation/customers_format.dart';

/// Статус продажи в долг по снимку (UI-34-007).
enum CreditStatus { allowed, blockedOverdue, blockedLimit, blockedNoData, blockedStale, notAllowed }

/// Снимок долга.
final class DebtSnapshot {
  const DebtSnapshot({
    this.balance,
    this.overdueAmount,
    this.overdueDays,
    this.creditLimit,
    this.limitRemaining,
    this.openOrdersAmount,
    this.creditAllowed,
    this.paymentTermDays,
    this.asOf,
    this.staleFlag = false,
    this.staleAfterMinutes,
    this.notInOnec = false,
  });

  /// Из сводки карточки (`Customer.receivable`) + флага отсрочки клиента.
  factory DebtSnapshot.fromSummary(ReceivableSummary s, {bool? creditAllowed}) => DebtSnapshot(
    balance: s.balance,
    overdueAmount: s.overdueAmount,
    creditLimit: s.creditLimit,
    limitRemaining: s.limitRemaining,
    creditAllowed: creditAllowed,
    asOf: s.asOf,
  );

  /// Из `Receivable`.
  factory DebtSnapshot.fromReceivable(Receivable r) => DebtSnapshot(
    balance: r.balance,
    overdueAmount: r.overdueAmount,
    overdueDays: r.overdueDays,
    creditLimit: r.creditLimit,
    limitRemaining: r.limitRemaining,
    openOrdersAmount: r.openOrdersAmount,
    creditAllowed: r.creditAllowed,
    paymentTermDays: r.paymentTermDays,
    asOf: r.asOf,
    staleFlag: r.isStale,
    staleAfterMinutes: r.staleAfterMinutes,
    notInOnec: r.reason == ReceivableAbsenceReason.notInOnec,
  );

  final Money? balance;
  final Money? overdueAmount;
  final int? overdueDays;
  final Money? creditLimit;
  final Money? limitRemaining;
  final Money? openOrdersAmount;
  final bool? creditAllowed;
  final int? paymentTermDays;
  final DateTime? asOf;
  final bool staleFlag;
  final int? staleAfterMinutes;

  /// Клиент ещё не создан в 1С (`reason: not_in_onec`).
  final bool notInOnec;

  /// Снимка нет — «Нет данных из 1С», не «0 сом» (DEBT-009).
  bool get noData => balance == null;

  /// Просрочка по снимку.
  bool get overdue => (overdueAmount != null && overdueAmount! > Money.zero) || (overdueDays ?? 0) > 0;

  /// Аванс (отрицательное сальдо).
  bool get advance => balance != null && balance!.isNegative;

  /// Устарел (флаг сервера или возраст больше порога; P-STALE).
  bool staleAt(DateTime nowUtc) =>
      CustomersFormat.isStale(asOf: asOf, flag: staleFlag, nowUtc: nowUtc, maxAgeMinutes: staleAfterMinutes);

  /// Статус продажи в долг — в порядке проверок PAY-031 (только отображение; решает сервер):
  /// шаг 1 — соглашение без отсрочки; шаг 2 — известная блокировка в имеющемся снимке **независимо от его возраста**
  /// (`overdue_amount > 0`; лимит в 1С не задан или исчерпан) — её снимает разрешение старшего (DEBT-010);
  /// шаг 3 — снимка нет, он неполон (`overdue_amount` неизвестна) или устарел — `RECEIVABLES_STALE`, разрешение
  /// старшего не снимает. Просрочка — только по `overdue_amount` (как на сервере), не по `overdueDays`.
  CreditStatus creditStatus(DateTime nowUtc) {
    if (noData) return CreditStatus.blockedNoData;
    if (creditAllowed == false) return CreditStatus.notAllowed;
    final Money? overdueSum = overdueAmount;
    if (overdueSum != null && overdueSum > Money.zero) return CreditStatus.blockedOverdue;
    // Лимит в 1С не задан (`credit_limit IS NULL`) — `CREDIT_LIMIT_EXCEEDED` шага 2 (DEBT-012, до ответа Q-017).
    if (creditLimit == null) return CreditStatus.blockedLimit;
    final Money? remaining = limitRemaining;
    if (remaining != null && remaining <= Money.zero) return CreditStatus.blockedLimit;
    if (overdueSum == null || remaining == null || staleAt(nowUtc)) return CreditStatus.blockedStale;
    return CreditStatus.allowed;
  }
}
