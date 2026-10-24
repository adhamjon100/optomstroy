// SCR-37 «Транзакция: детали» (02 SCR-37.13): поля и связанные документы (AC-UI-37-001, -009), аннулирование только
// cashier/senior_seller и только до получения денег, с причиной (AC-UI-37-002, -003), ручное подтверждение со
// step-up до запроса (AC-UI-37-004, -011), повтор тем же ключом после сбоя сети (AC-UI-37-005), аудит только
// admin/owner (AC-UI-37-006), чужая/несуществующая → «Операция не найдена» (AC-UI-37-007), возврат при выключенном
// модуле — «Возврат оформляется в 1С» (AC-UI-37-010), без сети действия недоступны (AC-UI-37-013).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/audit_record.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/models/transaction.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';
import 'package:optomstroy/features/transactions/domain/entities/transactions_query.dart';
import 'package:optomstroy/features/transactions/presentation/screens/transaction_details_screen.dart';

import '../../cashier/support/cashier_harness.dart';

const List<TransactionRelated> _related = <TransactionRelated>[
  TransactionRelated(type: TransactionRelatedType.order, id: 'o1', number: 'POS-2026-000123'),
  TransactionRelated(type: TransactionRelatedType.payment, id: 'pay-1', number: 'PAY-77'),
  TransactionRelated(type: TransactionRelatedType.onecDocument, number: 'ПКО-0001'),
];

CashierHarness _h({
  RoleCode role = RoleCode.cashier,
  PaymentStatus status = PaymentStatus.qrShown,
  Set<PaymentAction> actions = const <PaymentAction>{PaymentAction.voidPayment, PaymentAction.confirmManual},
  OrderStatus orderStatus = OrderStatus.awaitingPayment,
  bool online = true,
  bool returns = true,
  List<AuditRecord> audit = const <AuditRecord>[],
}) {
  final CashierHarness h = CashierHarness(role: role, online: online, returns: returns);
  h.transactions.onGet = (String id) async =>
      Success<TransactionDetail>(txDetail(tx(id, related: _related), audit: audit));
  h.payments.onGet = (String id, bool refresh) async => Success<PaymentDetails>(
    PaymentDetails(
      payment: Payment(
        id: 'pay-1',
        orderId: 'o1',
        method: status == PaymentStatus.received ? PaymentMethod.cash : PaymentMethod.qrBakai,
        status: status,
        amount: const Money(1600750),
        receivedAmount: status == PaymentStatus.received ? const Money(1610000) : null,
        changeAmount: status == PaymentStatus.received ? const Money(9250) : null,
      ),
      allowedActions: actions,
    ),
  );
  h.orders.onGet = (String id, bool refresh) async => Success<OrderDetails>(
    OrderDetails(
      order: payOrder(status: orderStatus),
      allowedActions: <OrderAction>{OrderAction.pay, OrderAction.returnRequest},
    ),
  );
  return h;
}

Future<void> _tapKey(WidgetTester t, String key) async {
  final Finder f = find.byKey(ValueKey<String>(key));
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await CashierHarness.settle(t);
}

void main() {
  testWidgets('поля, сумма со знаком, источник POS, связанные документы (AC-UI-37-001)', (WidgetTester t) async {
    final CashierHarness h = _h();
    await h.pump(t, const TransactionDetailsScreen(transactionId: 't1'));
    expect(find.byKey(TransactionDetailsScreen.rootKey), findsOneWidget);
    expect(find.text('Платёж получен'), findsOneWidget);
    expect(find.text('№ 1024 · 22.10.2026 09:42:00'), findsOneWidget);
    expect(find.text('+${fmt(1600750)}'), findsOneWidget);
    expect(find.text('POS'), findsOneWidget);
    expect(find.text('Азамат Б.'), findsOneWidget);
    expect(find.text('Абдулла'), findsOneWidget);
    expect(find.text('Открыть заказ № POS-2026-000123'), findsOneWidget);
    expect(find.text('Номер в 1С № ПКО-0001'), findsOneWidget);
    expect(find.text('Связанные документы'), findsOneWidget);
  });

  testWidgets('связанный заказ → SCR-24 (AC-UI-37-009)', (WidgetTester t) async {
    final CashierHarness h = _h();
    await h.pumpRouter(t, '/transactions/:id', (s) => TransactionDetailsScreen(transactionId: s.pathParameters['id']!));
    await t.pump();
    await _tapKey(t, 'tx-related-order-o1');
    expect(h.visited.last, '/orders/o1');
  });

  testWidgets('cashier: аннулирование до получения денег — причина и запрос `void` (AC-UI-37-002)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h();
    h.payments.onVoid = (String id, VoidPaymentRequest r, String key, String? stepUp) async => Success<Payment>(
      Payment(id: id, method: PaymentMethod.qrBakai, status: PaymentStatus.voided, amount: const Money(1600750)),
    );
    await h.pump(t, const TransactionDetailsScreen(transactionId: 't1'));
    await _tapKey(t, 'tx-action-void');
    expect(find.text('Аннулировать платёж?'), findsOneWidget);
    // Без причины — недоступно; «Иное» — комментарий не короче 5 символов.
    await _tapKey(t, 'void-reason-other');
    await t.enterText(find.byKey(const ValueKey<String>('void-comment')), 'abc');
    await CashierHarness.settle(t, 2);
    await _tapKey(t, 'void-submit');
    expect(h.payments.calls.where((c) => c.method == 'voidPayment'), isEmpty);
    await _tapKey(t, 'void-reason-duplicate');
    await _tapKey(t, 'void-submit');
    final List<({String method, List<Object?> args})> calls = h.payments.calls
        .where((({String method, List<Object?> args}) c) => c.method == 'voidPayment')
        .toList();
    expect(calls, hasLength(1));
    expect((calls.single.args[1]! as VoidPaymentRequest).reasonCode, PaymentVoidReasonCode.duplicate);
    expect(find.text('Платёж аннулирован'), findsOneWidget);
  });

  testWidgets('полученный платёж — аннулирования нет, подсказка «оформите возврат в 1С» (AC-UI-37-003)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h(
      status: PaymentStatus.received,
      actions: const <PaymentAction>{PaymentAction.voidPayment},
    );
    await h.pump(t, const TransactionDetailsScreen(transactionId: 't1'));
    expect(find.byKey(const ValueKey<String>('tx-action-void')), findsNothing);
    expect(find.text('Деньги получены — оформите возврат в 1С'), findsOneWidget);
    expect(find.text('Получено'), findsWidgets);
    expect(find.text('Сдача'), findsOneWidget);
  });

  testWidgets('admin и owner: без кассовых действий; аудит виден (AC-UI-37-006); cashier — без аудита', (
    WidgetTester t,
  ) async {
    final List<AuditRecord> audit = <AuditRecord>[
      AuditRecord(
        id: 'a1',
        occurredAt: DateTime.utc(2026, 10, 22, 3, 43),
        action: 'payment.received',
        result: AuditResult.ok,
        chainOk: true,
        actor: const UserRef(id: 'u1', displayName: 'Абдулла'),
      ),
    ];
    for (final RoleCode r in <RoleCode>[RoleCode.admin, RoleCode.owner]) {
      final CashierHarness h = _h(role: r, audit: audit);
      await h.pump(t, const TransactionDetailsScreen(transactionId: 't1'));
      expect(find.byKey(const ValueKey<String>('tx-action-void')), findsNothing);
      expect(find.byKey(const ValueKey<String>('tx-action-confirm')), findsNothing);
      expect(find.byKey(const ValueKey<String>('tx-action-accept')), findsNothing);
      expect(find.byKey(const ValueKey<String>('tx-audit-a1')), findsOneWidget);
    }
    final CashierHarness cashier = _h(audit: audit);
    await cashier.pump(t, const TransactionDetailsScreen(transactionId: 't1'));
    expect(find.byKey(const ValueKey<String>('tx-audit-a1')), findsNothing);
    expect(find.byKey(const ValueKey<String>('tx-action-accept')), findsOneWidget);
  });

  testWidgets('ручное подтверждение: step-up до запроса, `X-Step-Up-Token` (AC-UI-37-004, -011)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h();
    h.payments.onConfirmManual = (String id, ConfirmManualRequest r, String key, String? token) async =>
        Success<Payment>(
          Payment(id: id, method: PaymentMethod.qrBakai, status: PaymentStatus.received, amount: r.receivedAmount),
        );
    await h.pump(t, const TransactionDetailsScreen(transactionId: 't1'));
    await _tapKey(t, 'tx-action-confirm');
    await t.enterText(find.byKey(const ValueKey<String>('payment-manual-ref')), 'BK');
    await CashierHarness.settle(t, 2);
    expect(find.text('Введите референс от 4 до 64 символов'), findsNothing);
    await t.enterText(find.byKey(const ValueKey<String>('payment-manual-ref')), 'BK-77123');
    await CashierHarness.settle(t, 2);
    await _tapKey(t, 'payment-manual-submit');
    expect(h.stepUps, <String>['payment.qr.confirm_manual']);
    final ({String method, List<Object?> args}) call = h.payments.calls.firstWhere(
      (({String method, List<Object?> args}) c) => c.method == 'confirmManual',
    );
    expect(call.args[3], 'step-up-token');
    expect(find.text('Оплата подтверждена'), findsOneWidget);
  });

  testWidgets('сбой сети при аннулировании — «Результат неизвестен · Проверить» тем же ключом (AC-UI-37-005)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h();
    int n = 0;
    h.payments.onVoid = (String id, VoidPaymentRequest r, String key, String? stepUp) async => ++n == 1
        ? const FailureResult<Payment>(NetworkFailure(NetworkFailureKind.timeout, outcomeUnknown: true))
        : Success<Payment>(
            Payment(id: id, method: PaymentMethod.qrBakai, status: PaymentStatus.voided, amount: const Money(1600750)),
          );
    await h.pump(t, const TransactionDetailsScreen(transactionId: 't1'));
    await _tapKey(t, 'tx-action-void');
    await _tapKey(t, 'void-reason-customer_refused');
    await _tapKey(t, 'void-submit');
    expect(find.byKey(const ValueKey<String>('tx-details-unknown')), findsOneWidget);
    await t.tap(
      find.descendant(of: find.byKey(const ValueKey<String>('tx-details-unknown')), matching: find.text('Повторить')),
    );
    await CashierHarness.settle(t);
    final List<String> keys = <String>[
      for (final ({String method, List<Object?> args}) c in h.payments.calls)
        if (c.method == 'voidPayment') c.args[2]! as String,
    ];
    expect(keys, hasLength(2));
    expect(keys[0], keys[1]);
  });

  testWidgets('404 — «Операция не найдена» и «К журналу операций» (AC-UI-37-007)', (WidgetTester t) async {
    final CashierHarness h = CashierHarness(role: RoleCode.seller);
    h.transactions.onGet = (String id) async =>
        const FailureResult<TransactionDetail>(ServerFailure(code: 'NOT_FOUND', status: 404));
    await h.pump(t, const TransactionDetailsScreen(transactionId: 'alien'));
    expect(find.byKey(const ValueKey<String>('tx-details-not-found')), findsOneWidget);
    expect(find.text('Операция не найдена'), findsOneWidget);
    expect(find.text('К журналу операций'), findsOneWidget);
  });

  testWidgets('модуль возвратов выключен — «Возврат оформляется в 1С» (AC-UI-37-010); включён — «Заявка на возврат»', (
    WidgetTester t,
  ) async {
    final CashierHarness off = _h(orderStatus: OrderStatus.shipped, returns: false);
    await off.pump(t, const TransactionDetailsScreen(transactionId: 't1'));
    expect(find.byKey(const ValueKey<String>('tx-details-return-onec')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('tx-action-return')), findsNothing);

    final CashierHarness on = _h(orderStatus: OrderStatus.shipped);
    await on.pump(t, const TransactionDetailsScreen(transactionId: 't1'));
    expect(find.byKey(const ValueKey<String>('tx-action-return')), findsOneWidget);
  });

  testWidgets('без сети — действия недоступны с подсказкой (AC-UI-37-013)', (WidgetTester t) async {
    final CashierHarness h = _h(online: false);
    await h.pump(t, const TransactionDetailsScreen(transactionId: 't1'));
    expect(find.byKey(const ValueKey<String>('tx-actions-offline')), findsOneWidget);
    await _tapKey(t, 'tx-action-void');
    expect(find.text('Аннулировать платёж?'), findsNothing);
  });

  testWidgets('операция из 1С — источник «1С», автор не показывается', (WidgetTester t) async {
    final CashierHarness h = CashierHarness();
    h.transactions.onGet = (String id) async =>
        Success<TransactionDetail>(txDetail(tx(id, source: TransactionSource.onec)));
    await h.pump(t, const TransactionDetailsScreen(transactionId: 't9'));
    expect(find.text('1С'), findsOneWidget);
    expect(find.text('Абдулла'), findsNothing);
    expect(find.text('Связанных документов нет'), findsOneWidget);
  });
}
