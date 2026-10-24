// Статус продажи в долг UI-34-007 (SCR-32 Z5 / SCR-34 Z4) — порядок PAY-031 (ревью G-flutter-data-1): известная
// блокировка шага 2 (просрочка, лимит не задан/исчерпан) — раньше устаревшего/неполного снимка шага 3; просрочка —
// только по `overdue_amount` (как на сервере), не по `overdueDays`.
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/customers/presentation/state/debt_snapshot.dart';

final DateTime _now = DateTime.utc(2026, 10, 22, 4, 30);
final DateTime _fresh = DateTime.utc(2026, 10, 22, 4, 25);
final DateTime _old = DateTime.utc(2026, 10, 22, 3); // 90 мин

DebtSnapshot _s({
  Money? balance = const Money(1250000),
  Money? overdue = Money.zero,
  int? overdueDays,
  Money? limit = const Money(5000000),
  Money? remaining = const Money(3750000),
  bool? creditAllowed = true,
  DateTime? asOf,
  bool staleFlag = false,
}) => DebtSnapshot(
  balance: balance,
  overdueAmount: overdue,
  overdueDays: overdueDays,
  creditLimit: limit,
  limitRemaining: remaining,
  creditAllowed: creditAllowed,
  asOf: asOf ?? _fresh,
  staleFlag: staleFlag,
);

void main() {
  test('свежий полный снимок без блокировок — продажа в долг возможна', () {
    expect(_s().creditStatus(_now), CreditStatus.allowed);
  });

  test('снимка нет — «нет данных»; соглашение без отсрочки — раньше снимка (шаг 1)', () {
    expect(_s(balance: null).creditStatus(_now), CreditStatus.blockedNoData);
    expect(
      _s(creditAllowed: false, overdue: const Money(500000), asOf: _old).creditStatus(_now),
      CreditStatus.notAllowed,
    );
  });

  test('устаревший снимок с просрочкой — «просрочка» (шаг 2 раньше шага 3)', () {
    expect(_s(overdue: const Money(500000), asOf: _old).creditStatus(_now), CreditStatus.blockedOverdue);
    expect(_s(overdue: const Money(500000), staleFlag: true).creditStatus(_now), CreditStatus.blockedOverdue);
  });

  test('устаревший снимок с исчерпанным лимитом — «лимит» (шаг 2 раньше шага 3)', () {
    expect(_s(remaining: Money.zero, asOf: _old).creditStatus(_now), CreditStatus.blockedLimit);
    expect(_s(remaining: const Money(-100), staleFlag: true).creditStatus(_now), CreditStatus.blockedLimit);
  });

  test('лимит в 1С не задан (credit_limit = null) — CREDIT_LIMIT_EXCEEDED шага 2, не «нет данных»', () {
    expect(_s(limit: null, remaining: null).creditStatus(_now), CreditStatus.blockedLimit);
    expect(_s(limit: null, remaining: null, asOf: _old).creditStatus(_now), CreditStatus.blockedLimit);
  });

  test('просрочка неизвестна (overdue_amount = null) — неполный снимок шага 3 → «устарели»', () {
    expect(_s(overdue: null).creditStatus(_now), CreditStatus.blockedStale);
    expect(_s(remaining: null).creditStatus(_now), CreditStatus.blockedStale);
  });

  test('устаревший снимок без блокировок — «данные устарели»', () {
    expect(_s(asOf: _old).creditStatus(_now), CreditStatus.blockedStale);
    expect(_s(staleFlag: true).creditStatus(_now), CreditStatus.blockedStale);
  });

  test('overdueDays > 0 при overdue_amount = 0 не блокирует (сервер смотрит только на сумму)', () {
    expect(_s(overdueDays: 3).creditStatus(_now), CreditStatus.allowed);
  });
}
