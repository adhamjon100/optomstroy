// SCR-38 «Приём оплаты» (02 SCR-38.13; 13 RM-G-007 п. 3, RM-G-012 п. 2, RM-G-013 п. 3): сумма только с сервера,
// наличные с подтверждением и сдачей, P-IDEMP (один запрос, тот же ключ при «Проверить», автоповтор
// `IDEMPOTENCY_IN_PROGRESS`), состояния «Заказ оплачен» / «Оплата недоступна» / «Заказ в долг», долг fail-closed по
// каждой причине (`creditReason`, `RECEIVABLES_STALE`, `CUSTOMER_NOT_IDENTIFIED`) с «Обновить долг» и подтверждением
// старшего по CASH-007 (без `StepUpDialog.supervisor`), QR (таймер, автоподтверждение, запасной путь, ручное
// подтверждение со step-up до запроса, разбор), роли (без admin/owner — D-15), режим «по долгу» выключен (RM-G-013).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/features/cashier/presentation/screens/payment_screen.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';

import '../support/cashier_harness.dart';

const Size _compact = Size(390, 844);

CashierHarness _h({RoleCode role = RoleCode.cashier, Order? order, bool online = true, bool printer = true}) {
  final CashierHarness h = CashierHarness(role: role, online: online, withPrinter: printer);
  final Order o = order ?? payOrder();
  h.orders.onGet = (String id, bool refresh) async =>
      Success<OrderDetails>(OrderDetails(order: o, allowedActions: <OrderAction>{OrderAction.pay}));
  h.orders.onDocument = (String id, OrderDocumentKind kind, PrintPaper format, bool copy) async =>
      const Success<OrderDocumentFile>(OrderDocumentFile(bytes: <int>[1, 2, 3], fileName: 'receipt.pdf'));
  return h;
}

Iterable<FakeCallView> _creates(CashierHarness h) =>
    h.payments.calls.where((c) => c.method == 'createForOrder').map(FakeCallView.new);

/// Разбор вызова `createForOrder`.
final class FakeCallView {
  FakeCallView(({String method, List<Object?> args}) c)
    : request = c.args[1]! as OrderPaymentRequest,
      key = c.args[2]! as String;

  final OrderPaymentRequest request;
  final String key;
}

Future<void> _enterCash(WidgetTester t, String text) async {
  await t.enterText(find.byKey(const ValueKey<String>('payment-received')).first, text);
  await CashierHarness.settle(t, 2);
}

Future<void> _acceptAndConfirm(WidgetTester t) async {
  await tapKey(t, 'payment-cta');
  await CashierHarness.settle(t);
  expect(find.text('Подтвердите приём оплаты'), findsOneWidget);
  await t.tap(find.text('Подтвердить приём'));
  await CashierHarness.settle(t);
}

Future<void> _cashFailure(WidgetTester t, CashierHarness h, Failure f) async {
  h.payments.onCreateForOrder = (String id, OrderPaymentRequest r, String key) async =>
      FailureResult<OrderPaymentResult>(f);
  await h.pump(t, const PaymentScreen(orderId: 'o1', method: 'cash'));
  await _enterCash(t, '16100');
  await _acceptAndConfirm(t);
}

void main() {
  testWidgets('наличные: сумма с сервера, сдача, ConfirmDialog, один запрос без суммы платежа, успех и печать чека', (
    WidgetTester t,
  ) async {
    // AC-UI-38-004: ConfirmDialog с суммой к оплате, полученным, сдачей и клиентом.
    final CashierHarness h = _h();
    h.payments.onCreateForOrder = (String id, OrderPaymentRequest r, String key) async =>
        Success<OrderPaymentResult>(cashResult());
    await h.pump(
      t,
      const PaymentScreen(orderId: 'o1', method: 'cash'),
      size: _compact,
    );
    expect(find.byKey(PaymentScreen.rootKey), findsOneWidget);
    expect(find.text(fmt(1600750)), findsWidgets); // AC-UI-38-001: 16 007,50, а не 16 030
    expect(find.byKey(const ValueKey<String>('payment-tile-cash')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('payment-tile-qr')), findsOneWidget);
    expect(find.text('Без оплаты / долг'), findsNothing); // AC-UI-38-011
    // AC-UI-38-003: CTA неактивна, пока «Получено» < к оплате.
    await _enterCash(t, '16000');
    expect(find.text('Получено меньше суммы к оплате'), findsOneWidget);
    expect(ctaEnabled(t), isFalse);
    await _enterCash(t, '16100');
    expect(find.text('Сдача: ${fmt(9250)}'), findsOneWidget);
    expect(ctaEnabled(t), isTrue);
    await _acceptAndConfirm(t);
    final List<FakeCallView> calls = _creates(h).toList();
    expect(calls, hasLength(1));
    expect(calls.single.request.method, PaymentMethod.cash);
    expect(calls.single.request.receivedAmount, const Money(1610000)); // AC-UI-38-002
    expect(find.byKey(const ValueKey<String>('payment-success')), findsOneWidget);
    expect(find.text('Принято ${fmt(1600750)}'), findsOneWidget);
    expect(find.text('Сдача ${fmt(9250)}'), findsOneWidget);
    expect(find.text('Ожидает отражения в 1С'), findsOneWidget);
    expect(h.printed, <String>['receipt.pdf']);
  });

  testWidgets('быстрая сумма «Без сдачи» подставляет сумму к оплате', (WidgetTester t) async {
    final CashierHarness h = _h();
    await h.pump(t, const PaymentScreen(orderId: 'o1', method: 'cash'));
    await tapKey(t, 'payment-quick-1600750');
    await CashierHarness.settle(t, 2);
    expect(find.text('Сдача: ${fmt(0)}'), findsOneWidget);
  });

  testWidgets('сеть пропала — «Результат неизвестен», «Проверить» повторяет тем же ключом (AC-UI-38-005)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h();
    int n = 0;
    h.payments.onCreateForOrder = (String id, OrderPaymentRequest r, String key) async => ++n == 1
        ? const FailureResult<OrderPaymentResult>(NetworkFailure(NetworkFailureKind.timeout, outcomeUnknown: true))
        : Success<OrderPaymentResult>(cashResult());
    await h.pump(t, const PaymentScreen(orderId: 'o1', method: 'cash'));
    await _enterCash(t, '16100');
    await _acceptAndConfirm(t);
    expect(find.byKey(const ValueKey<String>('payment-unknown')), findsOneWidget);
    expect(find.text('Связь прервалась. Проверьте результат — деньги не принимайте повторно'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('payment-cta')), findsNothing);
    await tapKey(t, 'payment-check');
    await CashierHarness.settle(t);
    final List<FakeCallView> calls = _creates(h).toList();
    expect(calls, hasLength(2));
    expect(calls[1].key, calls[0].key);
    expect(find.byKey(const ValueKey<String>('payment-success')), findsOneWidget);
  });

  testWidgets('IDEMPOTENCY_IN_PROGRESS — 3 автоповтора тем же ключом, затем «Статус операции уточняется»', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h();
    await _cashFailure(
      t,
      h,
      const ConflictFailure(ConflictKind.idempotencyInProgress, retryAfter: Duration(milliseconds: 10)),
    );
    await CashierHarness.settle(t, 10);
    final List<FakeCallView> calls = _creates(h).toList();
    expect(calls, hasLength(4));
    expect(calls.map((FakeCallView c) => c.key).toSet(), hasLength(1));
    expect(find.text('Статус операции уточняется'), findsOneWidget);
  });

  testWidgets('двойное нажатие «Подтвердить приём» — один запрос', (WidgetTester t) async {
    final CashierHarness h = _h();
    final Completer<Result<OrderPaymentResult>> wait = Completer<Result<OrderPaymentResult>>();
    h.payments.onCreateForOrder = (String id, OrderPaymentRequest r, String key) => wait.future;
    await h.pump(t, const PaymentScreen(orderId: 'o1', method: 'cash'));
    await _enterCash(t, '16100');
    await _acceptAndConfirm(t);
    await t.tap(find.byKey(const ValueKey<String>('payment-cta')), warnIfMissed: false);
    await CashierHarness.settle(t);
    expect(_creates(h), hasLength(1));
    wait.complete(Success<OrderPaymentResult>(cashResult()));
    await CashierHarness.settle(t);
  });

  testWidgets('оплаченный заказ — «Заказ уже оплачен» без приёма (AC-UI-38-018)', (WidgetTester t) async {
    final CashierHarness h = _h(order: payOrder(isPaid: true, paidTyiyn: 1600750));
    await h.pump(t, const PaymentScreen(orderId: 'o1'));
    expect(find.text('Заказ уже оплачен: ${fmt(1600750)} из ${fmt(1600750)}'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('payment-tile-cash')), findsNothing);
  });

  testWidgets('статус не допускает оплату — «Оплата недоступна для заказа в статусе «Отгружен»» (AC-UI-38-023)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h(order: payOrder(status: OrderStatus.shipped));
    await h.pump(t, const PaymentScreen(orderId: 'o1'));
    expect(find.text('Оплата недоступна для заказа в статусе «Отгружен»'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('payment-cta')), findsNothing);
  });

  for (final OrderStatus st in <OrderStatus>[
    OrderStatus.submitting,
    OrderStatus.pendingApproval,
    OrderStatus.approved,
    OrderStatus.awaitingPayment,
  ]) {
    testWidgets('приём наличных доступен в статусе ${st.value} (ядро §22.5)', (WidgetTester t) async {
      final CashierHarness h = _h(order: payOrder(status: st));
      await h.pump(t, const PaymentScreen(orderId: 'o1', method: 'cash'));
      expect(find.byKey(const ValueKey<String>('payment-received')), findsOneWidget);
    });
  }

  testWidgets('заказ в долг — только просмотр (UI-38-013), плиток способов и «Оплаты долга» нет (RM-G-013)', (
    WidgetTester t,
  ) async {
    // AC-UI-38-012: разрешение продажи в долг на SCR-38 не предлагается (только просмотр заказа в долг).
    final CashierHarness h = _h(
      order: payOrder(method: PaymentMethod.credit, dueDate: DateTime.utc(2026, 11, 21)),
    );
    await h.pump(t, const PaymentScreen(orderId: 'o1'));
    expect(find.byKey(const ValueKey<String>('payment-credit-order')), findsOneWidget);
    expect(
      find.text(
        'Заказ оформлен в долг. Срок оплаты: 21.11.2026. Деньги по заказу принимаются как оплата долга клиента',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey<String>('payment-tile-cash')), findsNothing);
    expect(h.payments.calls.where((c) => c.method == 'createForOrder'), isEmpty);
  });

  group('долг — fail-closed по причинам (PAY-031; RM-G-007 п. 3, RM-G-012 п. 2)', () {
    testWidgets('CREDIT_BLOCKED overdue — причина с суммой и подтверждение старшего по CASH-007', (
      WidgetTester t,
    ) async {
      final CashierHarness h = _h();
      await _cashFailure(
        t,
        h,
        const ServerFailure(
          code: 'CREDIT_BLOCKED',
          status: 422,
          details: <String, Object?>{'creditReason': 'overdue', 'overdueAmount': '4200.00'},
        ),
      );
      expect(find.byKey(const ValueKey<String>('payment-credit-block')), findsOneWidget);
      expect(find.text('Есть просроченная задолженность ${fmt(420000)}'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('payment-refresh-debt')), findsNothing);
      await tapKey(t, 'payment-senior-help');
      await CashierHarness.settle(t);
      expect(find.byKey(const ValueKey<String>('senior-help-title')), findsOneWidget);
      expect(find.textContaining('в своей учётной записи'), findsOneWidget);
      // Подтверждения старшего в чужой сессии (StepUpDialog.supervisor — R2) нет: ни поля PIN, ни step-up.
      expect(find.byType(TextField), findsNWidgets(1)); // только «Получено» под диалогом
      expect(h.stepUps, isEmpty);
    });

    testWidgets('CREDIT_LIMIT_EXCEEDED limit_exceeded — «Превышен лимит: доступно …» и подтверждение старшего', (
      WidgetTester t,
    ) async {
      final CashierHarness h = _h();
      await _cashFailure(
        t,
        h,
        const ServerFailure(
          code: 'CREDIT_LIMIT_EXCEEDED',
          status: 422,
          details: <String, Object?>{'creditReason': 'limit_exceeded', 'limitRemaining': '1000.00'},
        ),
      );
      expect(find.text('Превышен лимит: доступно ${fmt(100000)}'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('payment-senior-help')), findsOneWidget);
    });

    testWidgets('CREDIT_BLOCKED credit_not_allowed — без подтверждения старшего (шаг 1 не снимается)', (
      WidgetTester t,
    ) async {
      final CashierHarness h = _h();
      await _cashFailure(
        t,
        h,
        const ServerFailure(
          code: 'CREDIT_BLOCKED',
          status: 422,
          details: <String, Object?>{'creditReason': 'credit_not_allowed'},
        ),
      );
      expect(find.text('Отсрочка не разрешена соглашением'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('payment-senior-help')), findsNothing);
      expect(find.byKey(const ValueKey<String>('payment-refresh-debt')), findsNothing);
    });

    testWidgets('RECEIVABLES_STALE stale_snapshot — «Обновить долг» вызывает refresh и показывает время снимка', (
      WidgetTester t,
    ) async {
      final CashierHarness h = _h();
      await _cashFailure(
        t,
        h,
        const ServerFailure(
          code: 'RECEIVABLES_STALE',
          status: 422,
          details: <String, Object?>{'creditReason': 'stale_snapshot'},
        ),
      );
      expect(
        find.text('Данные о долге устарели, 1С недоступна: продажа в долг невозможна, выберите наличные или QR'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey<String>('payment-senior-help')), findsNothing);
      await tapKey(t, 'payment-refresh-debt');
      await CashierHarness.settle(t);
      expect(h.receivables.refreshed, <String>['cu-1']);
      expect(find.byKey(const ValueKey<String>('payment-debt-refreshed')), findsOneWidget);
      expect(find.text('данные от 10:29'), findsOneWidget);
    });

    testWidgets('CUSTOMER_NOT_IDENTIFIED — «Выберите клиента из 1С»', (WidgetTester t) async {
      final CashierHarness h = _h();
      await _cashFailure(t, h, const ServerFailure(code: 'CUSTOMER_NOT_IDENTIFIED', status: 422));
      expect(find.text('Выберите клиента из 1С'), findsOneWidget);
    });

    testWidgets('«Другой способ оплаты» снимает блок', (WidgetTester t) async {
      final CashierHarness h = _h();
      await _cashFailure(
        t,
        h,
        const ServerFailure(code: 'CREDIT_BLOCKED', status: 422, details: <String, Object?>{'creditReason': 'overdue'}),
      );
      await tapKey(t, 'payment-credit-other');
      await CashierHarness.settle(t);
      expect(find.byKey(const ValueKey<String>('payment-credit-block')), findsNothing);
    });
  });

  testWidgets('409 open_payment_exists — «По заказу открыт QR-платёж…» и переход к открытому платежу (AC-UI-38-026)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h();
    h.payments.onGet = (String id, bool refresh) async => Success<PaymentDetails>(
      PaymentDetails(
        payment: qrPayment(id: 'pay-open', status: PaymentStatus.qrExpired),
        allowedActions: <PaymentAction>{PaymentAction.voidPayment, PaymentAction.reissueQr},
      ),
    );
    await _cashFailure(
      t,
      h,
      const ConflictFailure(
        ConflictKind.paymentStateInvalid,
        reason: 'open_payment_exists',
        details: <String, Object?>{'openPaymentId': 'pay-open'},
      ),
    );
    expect(find.byKey(const ValueKey<String>('payment-open-qr-exists')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('payment-qr-expired')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('payment-qr-reissue')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('payment-confirm-manual')), findsNothing); // AC-UI-38-027
    expect(find.byKey(const ValueKey<String>('payment-void')), findsOneWidget);
  });

  testWidgets('QR открыт: таймер, текст автоподтверждения 1С; оплата от 1С → успех (AC-UI-38-006, -009, -028)', (
    WidgetTester t,
  ) async {
    // AC-UI-38-028: QR от 1С (qr_shown), текст автоподтверждения; подтверждение от 1С — успех без ручных действий.
    final CashierHarness h = _h(
      order: payOrder(method: PaymentMethod.qrBakai, payments: <Payment>[qrPayment()]),
    );
    await h.pump(t, const PaymentScreen(orderId: 'o1'));
    expect(find.byKey(const ValueKey<String>('payment-qr-shown')), findsOneWidget);
    expect(find.text('Заказ № POS-2026-000123 · действует до 10:44 · 14:32'), findsOneWidget);
    expect(find.text('После оплаты заказ будет автоматически отмечен как оплаченный'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('payment-confirm-manual')), findsNothing);
    expect(h.payments.calls.where((c) => c.method == 'watch'), hasLength(1));
    h.payments.watchController.add(
      const Success<PaymentDetails>(
        PaymentDetails(
          payment: Payment(
            id: 'pay-qr',
            orderId: 'o1',
            method: PaymentMethod.qrBakai,
            status: PaymentStatus.received,
            amount: Money(1600750),
            confirmationKind: PaymentConfirmationKind.webhook,
          ),
        ),
      ),
    );
    await CashierHarness.settle(t);
    expect(find.byKey(const ValueKey<String>('payment-success')), findsOneWidget);
    await h.payments.dispose();
  });

  testWidgets('AC-UI-38-007: по истечении TTL QR гаснет; «Обновить QR» перевыпускает QR на том же payment_id', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h(
      order: payOrder(
        method: PaymentMethod.qrBakai,
        payments: <Payment>[qrPayment(expiresAt: kNow.add(const Duration(seconds: 20)))],
      ),
    );
    h.payments.onCreateForOrder = (String id, OrderPaymentRequest r, String key) async => Success<OrderPaymentResult>(
      OrderPaymentResult(
        payment: qrPayment(expiresAt: h.clock.nowUtc().add(const Duration(minutes: 10))),
        orderPaidAmount: Money.zero,
        orderIsPaid: false,
        created: false,
      ),
    );
    await h.pump(t, const PaymentScreen(orderId: 'o1'));
    expect(find.byKey(const ValueKey<String>('payment-qr-shown')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('payment-qr-reissue')), findsNothing);

    h.clock.advance(const Duration(seconds: 30));
    await t.pump(const Duration(seconds: 1));
    await CashierHarness.settle(t);
    expect(find.byKey(const ValueKey<String>('payment-qr-expired')), findsOneWidget, reason: 'QR гаснет по TTL');
    expect(find.byKey(const ValueKey<String>('payment-qr-shown')), findsNothing);

    await tapKey(t, 'payment-qr-reissue');
    await CashierHarness.settle(t);
    final FakeCallView reissue = _creates(h).last;
    expect(reissue.request.reissueQr, isTrue, reason: 'перевыпуск, не новый платёж');
    expect(find.byKey(const ValueKey<String>('payment-qr-shown')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('payment-qr-expired')), findsNothing);
    await h.payments.dispose();
  });

  testWidgets('выбор QR создаёт QR-платёж; 1С не сформировала QR — «Повторить без банка» (manualOnly)', (
    WidgetTester t,
  ) async {
    // AC-UI-38-029 (QR_PROVIDER=onec, warnings[QR_UNAVAILABLE] → «1С не сформировала QR…»), AC-UI-38-010 (статический QR / manualOnly), AC-UI-38-009 (autoConfirm=false — «кассир подтвердит по выписке»).
    final CashierHarness h = _h();
    h.payments.onCreateForOrder = (String id, OrderPaymentRequest r, String key) async => Success<OrderPaymentResult>(
      OrderPaymentResult(
        payment: r.manualOnly
            ? qrPayment(autoConfirm: false)
            : const Payment(
                id: 'pay-qr',
                orderId: 'o1',
                method: PaymentMethod.qrBakai,
                status: PaymentStatus.qrPending,
                amount: Money(1600750),
                warnings: <ApiWarning>[ApiWarning(rawCode: 'QR_UNAVAILABLE')],
              ),
        orderPaidAmount: Money.zero,
        orderIsPaid: false,
        created: true,
      ),
    );
    await h.pump(t, const PaymentScreen(orderId: 'o1', method: 'cash'));
    await tapKey(t, 'payment-tile-qr');
    await CashierHarness.settle(t);
    expect(find.byKey(const ValueKey<String>('payment-qr-unavailable')), findsOneWidget);
    expect(
      find.text(
        '1С не сформировала QR. Покажите статический QR и подтвердите оплату вручную или выберите другой способ',
      ),
      findsOneWidget,
    );
    await tapKey(t, 'payment-qr-manual-only');
    await CashierHarness.settle(t);
    final List<FakeCallView> calls = _creates(h).toList();
    expect(calls.first.request.method, PaymentMethod.qrBakai);
    expect(calls.last.request.manualOnly, isTrue);
    expect(find.text('После оплаты кассир подтвердит поступление по выписке'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('payment-confirm-manual')), findsOneWidget);
    await h.payments.dispose();
  });

  testWidgets('ручное подтверждение: step-up до запроса, запрос с X-Step-Up-Token (AC-UI-38-021)', (
    WidgetTester t,
  ) async {
    // AC-UI-38-008 (клиентская часть): «Подтвердить вручную» — step-up и референс банка до запроса.
    final CashierHarness h = _h(
      order: payOrder(method: PaymentMethod.qrBakai, payments: <Payment>[qrPayment(autoConfirm: false)]),
    );
    h.payments.onConfirmManual = (String id, ConfirmManualRequest r, String key, String? token) async =>
        Success<Payment>(
          Payment(
            id: id,
            orderId: 'o1',
            method: PaymentMethod.qrBakai,
            status: PaymentStatus.received,
            amount: r.receivedAmount,
          ),
        );
    await h.pump(t, const PaymentScreen(orderId: 'o1'));
    await tapKey(t, 'payment-confirm-manual');
    await CashierHarness.settle(t);
    await t.enterText(find.byKey(const ValueKey<String>('payment-manual-ref')), 'BK-77123');
    await CashierHarness.settle(t, 2);
    await tapKey(t, 'payment-manual-submit');
    await CashierHarness.settle(t);
    expect(h.stepUps, <String>['payment.qr.confirm_manual']);
    final ({String method, List<Object?> args}) call = h.payments.calls.firstWhere(
      (({String method, List<Object?> args}) c) => c.method == 'confirmManual',
    );
    expect((call.args[1]! as ConfirmManualRequest).bankReference, 'BK-77123');
    expect(call.args[3], 'step-up-token');
    expect(find.byKey(const ValueKey<String>('payment-success')), findsOneWidget);
    await h.payments.dispose();
  });

  testWidgets('step-up отменён — подтверждение не отправляется', (WidgetTester t) async {
    final CashierHarness base = _h(
      order: payOrder(method: PaymentMethod.qrBakai, payments: <Payment>[qrPayment(autoConfirm: false)]),
    );
    final CashierHarness cancel = CashierHarness(stepUpCancelled: true);
    cancel.orders.onGet = base.orders.onGet;
    await cancel.pump(t, const PaymentScreen(orderId: 'o1'));
    await tapKey(t, 'payment-confirm-manual');
    await CashierHarness.settle(t);
    await t.enterText(find.byKey(const ValueKey<String>('payment-manual-ref')), 'BK-77123');
    await CashierHarness.settle(t, 2);
    await tapKey(t, 'payment-manual-submit');
    await CashierHarness.settle(t);
    expect(cancel.payments.calls.where((c) => c.method == 'confirmManual'), isEmpty);
    expect(cancel.stepUps, <String>['payment.qr.confirm_manual']);
    await cancel.payments.dispose();
  });

  testWidgets('«Требует проверки»: таймер остановлен, «Подтвердить вручную» и «Аннулировать» (AC-UI-38-024)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h(
      order: payOrder(
        method: PaymentMethod.qrBakai,
        payments: <Payment>[qrPayment(status: PaymentStatus.manualConfirm, review: ReviewReason.amountMismatch)],
      ),
    );
    h.payments.onVoid = (String id, VoidPaymentRequest r, String key, String? token) async => Success<Payment>(
      Payment(
        id: id,
        orderId: 'o1',
        method: PaymentMethod.qrBakai,
        status: PaymentStatus.voided,
        amount: const Money(1600750),
      ),
    );
    await h.pump(t, const PaymentScreen(orderId: 'o1'));
    expect(find.byKey(const ValueKey<String>('payment-qr-review')), findsOneWidget);
    expect(find.text('Требует проверки: сумма не совпадает'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('payment-confirm-manual')), findsOneWidget);
    await tapKey(t, 'payment-void');
    await CashierHarness.settle(t);
    await tapKey(t, 'void-reason-customer_refused');
    await CashierHarness.settle(t, 2);
    await tapKey(t, 'void-submit');
    await CashierHarness.settle(t);
    final ({String method, List<Object?> args}) call = h.payments.calls.firstWhere(
      (({String method, List<Object?> args}) c) => c.method == 'voidPayment',
    );
    expect((call.args[1]! as VoidPaymentRequest).reasonCode, PaymentVoidReasonCode.customerRefused);
    await CashierHarness.settle(t, 12);
    // После аннулирования заказ перечитывается (`GET /orders/{id}`).
    expect(h.orders.calls.where((c) => c.method == 'get'), hasLength(2));
    await h.payments.dispose();
  });

  testWidgets('смена способа QR → наличные: только ConfirmDialog, без аннулирования (AC-UI-38-020)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h(
      order: payOrder(method: PaymentMethod.qrBakai, payments: <Payment>[qrPayment()]),
    );
    await h.pump(t, const PaymentScreen(orderId: 'o1'));
    await tapKey(t, 'payment-tile-cash');
    await CashierHarness.settle(t);
    expect(find.text('Отменить QR-оплату и принять наличными?'), findsOneWidget);
    await t.tap(find.text('Применить'));
    await CashierHarness.settle(t);
    expect(find.byKey(const ValueKey<String>('payment-received')), findsOneWidget);
    expect(h.payments.calls.where((c) => c.method == 'voidPayment'), isEmpty);
    expect(h.stepUps, isEmpty);
    await h.payments.dispose();
  });

  testWidgets('без сети — способы и CTA недоступны, «Нет сети: оплата невозможна» (AC-UI-38-016)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h(online: false);
    await h.pump(t, const PaymentScreen(orderId: 'o1', method: 'cash'));
    expect(find.text('Нет сети: оплата невозможна'), findsWidgets);
    await _enterCash(t, '16100');
    expect(ctaEnabled(t), isFalse);
  });

  testWidgets('admin и owner — «Недостаточно прав» (D-15, AC-UI-38-015); senior_seller — доступно', (
    WidgetTester t,
  ) async {
    for (final RoleCode r in <RoleCode>[RoleCode.admin, RoleCode.owner]) {
      final CashierHarness h = _h(role: r);
      await h.pump(t, const PaymentScreen(orderId: 'o1', method: 'cash'));
      expect(find.text('Недостаточно прав'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('payment-received')), findsNothing);
    }
    final CashierHarness senior = _h(role: RoleCode.seniorSeller);
    await senior.pump(t, const PaymentScreen(orderId: 'o1', method: 'cash'));
    expect(find.byKey(const ValueKey<String>('payment-received')), findsOneWidget);
  });

  testWidgets('роль неизвестна (null) — fail-closed: «Недостаточно прав», без кассовых действий (D-15, SCR-38.10)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = CashierHarness(role: null);
    final CashierHarness base = _h(
      order: payOrder(method: PaymentMethod.qrBakai, payments: <Payment>[qrPayment(autoConfirm: false)]),
    );
    h.orders.onGet = base.orders.onGet;
    await h.pump(t, const PaymentScreen(orderId: 'o1'));
    expect(find.text('Недостаточно прав'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('payment-tile-cash')), findsNothing);
    expect(find.byKey(const ValueKey<String>('payment-confirm-manual')), findsNothing);
    expect(find.byKey(const ValueKey<String>('payment-cta')), findsNothing);
    await h.payments.dispose();
  });

  testWidgets('режим «по долгу» (?customerId=) при debtPaymentsFromPos=false — «Недоступно» (RM-G-013 п. 3)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h();
    await h.pump(t, const PaymentScreen(customerId: 'cu-1'));
    expect(find.byKey(const ValueKey<String>('payment-debt-unavailable')), findsOneWidget);
    expect(h.payments.calls, isEmpty);
    expect(h.orders.calls, isEmpty);
  });

  testWidgets('ошибка печати не отменяет платёж и предлагает «Повторить» (AC-UI-38-017)', (WidgetTester t) async {
    final CashierHarness h = CashierHarness(printerOk: false);
    final CashierHarness base = _h();
    h.orders.onGet = base.orders.onGet;
    h.orders.onDocument = base.orders.onDocument;
    h.payments.onCreateForOrder = (String id, OrderPaymentRequest r, String key) async =>
        Success<OrderPaymentResult>(cashResult());
    await h.pump(t, const PaymentScreen(orderId: 'o1', method: 'cash'));
    await _enterCash(t, '16100');
    await _acceptAndConfirm(t);
    expect(find.byKey(const ValueKey<String>('payment-success')), findsOneWidget);
    expect(find.text('Не удалось напечатать чек'), findsOneWidget);
  });
}

/// Прокрутить к виджету с ключом [key] и нажать.
Future<void> tapKey(WidgetTester t, String key) async {
  final Finder f = find.byKey(ValueKey<String>(key));
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
}

/// CTA «Принять …» доступна.
bool ctaEnabled(WidgetTester t) =>
    t.widget<AppButton>(find.byKey(const ValueKey<String>('payment-cta'))).onPressed != null;
