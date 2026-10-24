// SCR-30 «Дашборд кассира» (02 SCR-30.13; 13 RM-G-007): состояния (загрузка, данные, ошибка, нет сети, устаревшие
// данные), блоки промта (AC-UI-30-001), роли (AC-UI-30-003, AC-UI-30-019), поиск (AC-UI-30-005), «Ожидают оплаты»
// (AC-UI-30-007, AC-UI-30-022), избранное (AC-UI-30-006), баннер синхронизации (AC-UI-30-012), незавершённая
// операция (AC-UI-30-017), один запрос одновременно (AC-UI-30-010), лист «Найти заказ».
import 'dart:async';

import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/features/cashier/domain/entities/pos_dashboard.dart';
import 'package:optomstroy/features/cashier/presentation/providers/cashier_ports.dart';
import 'package:optomstroy/features/cashier/presentation/screens/cashier_dashboard_screen.dart';
import 'package:optomstroy/features/cashier/presentation/state/unfinished_operations.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/entities/receivable.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';

import '../support/cashier_harness.dart';

CashierHarness _h({RoleCode role = RoleCode.cashier, bool online = true, PosDashboard? d, bool returns = true}) {
  final CashierHarness h = CashierHarness(role: role, online: online, returns: returns);
  final PosDashboard data = d ?? dashboard();
  h.cashier.onDashboard = () async => Success<PosDashboard>(data);
  return h;
}

Future<void> _pumpRouted(WidgetTester tester, CashierHarness h, {Size size = const Size(1366, 900)}) =>
    h.pumpRouter(tester, '/cashier', (_) => const CashierDashboardScreen(), size: size);

void main() {
  testWidgets('cashier: все блоки дашборда (AC-UI-30-001) и сводка смены в формате «45 200,50 сом» (AC-UI-30-013)', (
    WidgetTester t,
  ) async {
    // AC-UI-30-015: блок «Скидки и условия продаж» — лимит ручной скидки роли из GET /discounts/rules.
    final CashierHarness h = _h();
    await h.pump(t, const CashierDashboardScreen());
    expect(find.byKey(CashierDashboardScreen.rootKey), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('cashier-search')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('cashier-accept-payment')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('cashier-catalog')), findsOneWidget);
    expect(find.text('Избранные клиенты'), findsOneWidget);
    expect(find.text('Недавние операции'), findsOneWidget);
    expect(find.text('Долги и просрочки'), findsOneWidget);
    expect(find.text('Скидки и условия продаж'), findsOneWidget);
    expect(find.text('Синхронизация с 1С'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('cashier-recent-all')), findsOneWidget);
    expect(find.text(fmt(4520050)), findsOneWidget);
    expect(find.text('Заказов: 12 · Платежей: 9'), findsOneWidget);
    expect(find.text('Ваш лимит ручной скидки: 5 %'), findsOneWidget);
    expect(find.text('Правил скидок 1С: 2'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('cashier-debts-as-of')), findsOneWidget);
    expect(h.cashier.calls, 1);
  });

  testWidgets('AC-UI-30-016: expanded — 3 колонки (Z2 | Z5 | Z6 на одном уровне), панели корзины нет; compact — '
      '1 колонка', (WidgetTester t) async {
    Finder byType(String name) => find.byWidgetPredicate((Widget w) => w.runtimeType.toString() == name);
    final Finder z2 = byType('DashboardQuickActions');
    final Finder z5 = find
        .ancestor(of: find.byKey(const ValueKey<String>('cashier-totals')), matching: byType('DashboardCard'))
        .first;
    final Finder z6 = byType('DashboardDebts');

    await _h().pump(t, const CashierDashboardScreen(), size: const Size(1366, 900));
    final Offset a = t.getTopLeft(z2), b = t.getTopLeft(z5), c = t.getTopLeft(z6);
    expect(a.dx < b.dx && b.dx < c.dx, isTrue, reason: 'три колонки слева направо: $a $b $c');
    expect(b.dx - a.dx, greaterThan(300));
    expect(c.dx - b.dx, greaterThan(300));
    expect((a.dy - c.dy).abs(), lessThan(1), reason: 'колонки начинаются на одном уровне');
    expect(byType('CartPanelView'), findsNothing, reason: 'панель корзины на дашборде кассира скрыта');

    await t.pumpWidget(const SizedBox.shrink());
    await _h().pump(t, const CashierDashboardScreen(), size: const Size(390, 844));
    final double left = t.getTopLeft(z2).dx;
    expect(t.getTopLeft(z5).dx, left, reason: 'compact: одна колонка');
    expect(t.getTopLeft(z6).dx, left);
    expect(t.getTopLeft(z5).dy, greaterThan(t.getTopLeft(z2).dy));
    expect(t.getTopLeft(z6).dy, greaterThan(t.getTopLeft(z5).dy));
  });

  testWidgets('AC-UI-30-018: суммы и статусы читаются диктором текстом (StatusChip — с подписью, не только цветом)', (
    WidgetTester t,
  ) async {
    final SemanticsHandle semantics = t.ensureSemantics();
    await _h().pump(t, const CashierDashboardScreen());
    // Суммы — полным текстом для диктора («45 200 сом 50 тыйын»), не только цифрами.
    expect(find.bySemanticsLabel(RegExp(r'Наличные: 45\s200 сом 50 тыйын')), findsOneWidget, reason: 'сумма смены');
    expect(find.bySemanticsLabel(RegExp(r'Просрочено: 1 клиент на 4\s200,00\sсом')), findsOneWidget);
    // Статусы строк «Ожидают оплаты» — текстом (иконка + текст, A11Y-004), а не только цветом.
    for (final String status in <String>['Ожидает оплаты', 'Ожидает отправки в 1С']) {
      expect(find.bySemanticsLabel(RegExp(RegExp.escape(status))), findsWidgets, reason: 'статус «$status»');
    }
    for (final StatusChip c in t.widgetList<StatusChip>(find.byType(StatusChip))) {
      expect(find.bySemanticsLabel(RegExp(RegExp.escape(c.label))), findsWidgets, reason: 'чип «${c.label}»');
    }
    semantics.dispose();
  });

  testWidgets('admin: режим просмотра — без «Принять оплату», с избранным; owner — без избранного', (
    WidgetTester t,
  ) async {
    final CashierHarness admin = _h(role: RoleCode.admin);
    await admin.pump(t, const CashierDashboardScreen());
    expect(find.byKey(const ValueKey<String>('cashier-accept-payment')), findsNothing);
    expect(find.byKey(const ValueKey<String>('cashier-chip-return')), findsNothing);
    expect(find.byKey(const ValueKey<String>('cashier-chip-new-customer')), findsOneWidget);
    expect(find.text('Избранные клиенты'), findsOneWidget);

    final CashierHarness owner = _h(role: RoleCode.owner);
    await owner.pump(t, const CashierDashboardScreen());
    expect(find.byKey(const ValueKey<String>('cashier-accept-payment')), findsNothing);
    expect(find.text('Избранные клиенты'), findsNothing);
    expect(find.byKey(const ValueKey<String>('cashier-chip-new-customer')), findsNothing);
    expect(find.byKey(const ValueKey<String>('cashier-chip-parked')), findsNothing);
  });

  testWidgets('«Заявка на возврат» скрыта при features.returnsFromPos=false (P-FLAGS)', (WidgetTester t) async {
    final CashierHarness h = _h(returns: false);
    await h.pump(t, const CashierDashboardScreen());
    expect(find.byKey(const ValueKey<String>('cashier-chip-return')), findsNothing);
    expect(find.byKey(const ValueKey<String>('cashier-chip-parked')), findsOneWidget);
  });

  testWidgets('поиск: «А» — подсказка без перехода, «Аза» — SCR-31 ?q= (AC-UI-30-005)', (WidgetTester t) async {
    final CashierHarness h = _h();
    await _pumpRouted(t, h);
    await t.enterText(find.byKey(const ValueKey<String>('cashier-search')).first, 'А');
    await t.testTextInput.receiveAction(TextInputAction.search);
    await CashierHarness.settle(t);
    expect(find.byKey(const ValueKey<String>('cashier-search-too-short')), findsOneWidget);
    expect(h.visited, isEmpty);
    await t.enterText(find.byKey(const ValueKey<String>('cashier-search')).first, 'Аза');
    await t.testTextInput.receiveAction(TextInputAction.search);
    await CashierHarness.settle(t);
    expect(h.visited.single, Uri(path: '/customers', queryParameters: <String, String>{'q': 'Аза'}).toString());
  });

  testWidgets('«Ожидают оплаты»: строки со статусом заказа, тап → SCR-38 ?orderId= (AC-UI-30-007, AC-UI-30-022)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h();
    await _pumpRouted(t, h);
    expect(find.text('Ожидают оплаты · 2'), findsOneWidget);
    expect(find.text('Ожидает оплаты'), findsWidgets);
    expect(find.text('Ожидает отправки в 1С'), findsWidgets);
    await t.tap(find.byKey(const ValueKey<String>('awaiting-o1')));
    await CashierHarness.settle(t);
    expect(h.visited.single, '/payments/new?orderId=o1');
  });

  testWidgets('«Ожидают оплаты» пуст — блок скрыт; у admin строки без перехода', (WidgetTester t) async {
    final CashierHarness empty = _h(d: dashboard(awaitingPayment: const <OrderSummary>[]));
    await empty.pump(t, const CashierDashboardScreen());
    expect(find.byKey(const ValueKey<String>('cashier-awaiting')), findsNothing);

    final CashierHarness admin = _h(role: RoleCode.admin);
    await admin.pumpRouter(t, '/cashier', (_) => const CashierDashboardScreen());
    await t.tap(find.byKey(const ValueKey<String>('awaiting-o1')));
    await CashierHarness.settle(t);
    expect(admin.visited, isEmpty);
  });

  testWidgets('QR в очереди: таймер TTL у строки; «Требуют разбора» → SCR-37 платежа', (WidgetTester t) async {
    // AC-UI-30-008: «Требуют разбора» — платежи с reviewReason и чипом, тап → SCR-37.
    final Payment qr = Payment(
      id: 'p-qr',
      orderId: 'o2',
      method: PaymentMethod.qrBakai,
      status: PaymentStatus.qrShown,
      amount: const Money(235000),
      qr: QrInfo(
        rawProvider: 'onec',
        issuedAt: DateTime.utc(2026, 10, 22, 4, 20),
        expiresAt: DateTime.utc(2026, 10, 22, 4, 44, 32),
        autoConfirm: true,
      ),
    );
    const Payment review = Payment(
      id: 'p-rev',
      orderId: 'o9',
      method: PaymentMethod.qrBakai,
      status: PaymentStatus.manualConfirm,
      amount: Money(800000),
      reviewReason: ReviewReason.amountMismatch,
      transactionId: 'tx-rev',
    );
    final CashierHarness h = _h(
      d: dashboard(qrPending: <Payment>[qr], manualConfirm: <Payment>[review]),
    );
    await _pumpRouted(t, h);
    expect(find.text('14:32'), findsOneWidget);
    expect(find.text('Требуют разбора · 1'), findsOneWidget);
    await t.ensureVisible(find.byKey(const ValueKey<String>('awaiting-p-rev')));
    await t.tap(find.byKey(const ValueKey<String>('awaiting-p-rev')));
    await CashierHarness.settle(t);
    expect(h.visited.single, '/transactions/tx-rev');
  });

  testWidgets('ошибка загрузки — «Не удалось загрузить данные кассы» + Повторить', (WidgetTester t) async {
    final CashierHarness h = CashierHarness();
    h.cashier.onDashboard = () async =>
        const FailureResult<PosDashboard>(ServerFailure(code: 'INTERNAL', status: 500, requestId: 'req-1'));
    await h.pump(t, const CashierDashboardScreen());
    expect(find.byKey(const ValueKey<String>('cashier-error')), findsOneWidget);
    expect(find.text('Не удалось загрузить данные кассы'), findsOneWidget);
    h.cashier.onDashboard = () async => Success<PosDashboard>(dashboard());
    await t.tap(find.text('Повторить'));
    await CashierHarness.settle(t);
    expect(find.byKey(const ValueKey<String>('cashier-error')), findsNothing);
    expect(h.cashier.calls, 2);
  });

  testWidgets('нет сети и нет данных — OfflineNoData; финансовые данные не берутся из кэша (AC-UI-30-011)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = CashierHarness(online: false);
    h.cashier.onDashboard = () async => const FailureResult<PosDashboard>(NetworkFailure(NetworkFailureKind.offline));
    await h.pump(t, const CashierDashboardScreen());
    expect(find.byKey(const ValueKey<String>('cashier-offline')), findsOneWidget);
    expect(find.text('Нет сети. Данные кассы недоступны без подключения'), findsOneWidget);
    expect(find.text(fmt(4520050)), findsNothing);
  });

  testWidgets('без сети при загруженных данных — данные из памяти, «Принять оплату» disabled (P-OFFLINE)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h(online: false);
    await h.pump(t, const CashierDashboardScreen());
    expect(find.text(fmt(4520050)), findsOneWidget);
    final Finder accept = find.byKey(const ValueKey<String>('cashier-accept-payment'));
    expect(accept, findsOneWidget);
    await t.tap(accept);
    await CashierHarness.settle(t);
    expect(find.text('Найти заказ или клиента'), findsNothing);
  });

  testWidgets('ошибка обновления — данные остаются и баннер «Не удалось обновить, данные от …» (ReadyStale)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h();
    await h.pump(t, const CashierDashboardScreen());
    h.cashier.onDashboard = () async => const FailureResult<PosDashboard>(ServerFailure(code: 'INTERNAL', status: 500));
    await t.tap(find.byKey(const ValueKey<String>('cashier-refresh')));
    await CashierHarness.settle(t);
    expect(find.byKey(const ValueKey<String>('cashier-refresh-failed')), findsOneWidget);
    expect(find.text('Не удалось обновить, данные от 10:30'), findsOneWidget);
    expect(find.text(fmt(4520050)), findsOneWidget);
  });

  testWidgets('одновременно не более одного запроса дашборда (AC-UI-30-010)', (WidgetTester t) async {
    final CashierHarness h = CashierHarness();
    final Completer<Result<PosDashboard>> first = Completer<Result<PosDashboard>>();
    h.cashier.onDashboard = () => first.future;
    await h.pump(t, const CashierDashboardScreen());
    expect(h.cashier.calls, 1);
    // F5 во время запроса — присоединяется к нему.
    await t.sendKeyEvent(LogicalKeyboardKey.f5);
    await CashierHarness.settle(t);
    expect(h.cashier.calls, 1);
    first.complete(Success<PosDashboard>(dashboard()));
    await CashierHarness.settle(t);
    expect(find.text(fmt(4520050)), findsOneWidget);
  });

  testWidgets('sync.overall=failed — баннер с сущностью, временем и числом ошибок (AC-UI-30-012)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h(d: dashboard(overall: DashboardSyncOverall.failed));
    h.extraOverrides.add(
      syncStatusOverride(
        entities: <({String entity, DateTime? last, int errors, bool stale})>[
          (entity: 'receivables', last: DateTime.utc(2026, 10, 22, 3), errors: 4, stale: true),
          (entity: 'stock', last: DateTime.utc(2026, 10, 22, 4, 25), errors: 0, stale: false),
        ],
      ),
    );
    await _pumpRouted(t, h);
    expect(find.byKey(const ValueKey<String>('cashier-sync-banner')), findsOneWidget);
    expect(
      find.text('Ошибка обмена с 1С: Долги. Последний успешный обмен — 22.10.2026 09:00. Ошибок: 4'),
      findsOneWidget,
    );
    await t.tap(find.byKey(const ValueKey<String>('cashier-sync-banner-open')));
    await CashierHarness.settle(t);
    expect(h.visited.single, '/sync?entity=receivables');
  });

  testWidgets('незавершённая операция в памяти сессии — баннер «Проверить» → SCR-38 того же заказа (AC-UI-30-017)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h();
    await _pumpRouted(t, h);
    final ProviderContainer container = ProviderScope.containerOf(t.element(find.byType(CashierDashboardScreen)));
    container
        .read(cashierUnfinishedOperationsProvider.notifier)
        .put(
          const UnfinishedOperation(
            kind: UnfinishedKind.orderPayment,
            idempotencyKey: 'k-1',
            orderId: 'o1',
            orderNumber: 'POS-2026-000123',
            amount: Money(1600750),
          ),
        );
    await CashierHarness.settle(t);
    expect(find.text('Незавершённая операция: приём ${fmt(1600750)} по заказу № POS-2026-000123'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey<String>('cashier-unfinished-check')));
    await CashierHarness.settle(t);
    expect(h.visited.single, '/payments/new?orderId=o1');
  });

  testWidgets(
    'избранное: удаление скрывает карточку и показывает «Отменить»; ошибка возвращает карточку (AC-UI-30-006)',
    (WidgetTester t) async {
      final CashierHarness h = _h();
      await h.pump(t, const CashierDashboardScreen());
      expect(find.byKey(const ValueKey<String>('cashier-favorite-cu-3')), findsOneWidget);
      await t.longPress(find.byKey(const ValueKey<String>('cashier-favorite-cu-3')));
      await CashierHarness.settle(t);
      await t.tap(find.byKey(const ValueKey<String>('cashier-favorite-remove')));
      await CashierHarness.settle(t);
      expect(find.byKey(const ValueKey<String>('cashier-favorite-cu-3')), findsNothing);
      expect(find.text('Клиент убран из избранного'), findsOneWidget);
      expect(h.favorites.calls, <String>['remove:cu-3']);

      h.favorites.removeResult = const FailureResult<void>(ServerFailure(code: 'INTERNAL', status: 500));
      await t.longPress(find.byKey(const ValueKey<String>('cashier-favorite-cu-1')));
      await CashierHarness.settle(t);
      await t.tap(find.byKey(const ValueKey<String>('cashier-favorite-remove')));
      await CashierHarness.settle(t);
      expect(find.byKey(const ValueKey<String>('cashier-favorite-cu-1')), findsOneWidget);
    },
  );

  testWidgets('долги: нет снимка — «Нет данных из 1С о долгах»; нет просрочек — «Просроченных долгов нет»', (
    WidgetTester t,
  ) async {
    final CashierHarness none = _h(
      d: PosDashboard(
        date: DateTime.utc(2026, 10, 22),
        totals: const PosDashboardTotals(
          cash: Money.zero,
          qr: Money.zero,
          credit: Money.zero,
          ordersCount: 0,
          paymentsCount: 0,
        ),
        awaitingPayment: const <OrderSummary>[],
        qrPendingCount: 0,
        manualConfirmCount: 0,
        recentTransactions: const [],
        sync: const PosDashboardSync(overall: DashboardSyncOverall.ok),
        notificationsUnread: 0,
      ),
    );
    await none.pump(t, const CashierDashboardScreen());
    expect(find.byKey(const ValueKey<String>('cashier-debts-no-data')), findsOneWidget);
    expect(find.text('Операций за сегодня нет'), findsOneWidget);
    expect(find.text('Отмечайте клиентов звездой, чтобы они появились здесь'), findsOneWidget);

    final CashierHarness zero = _h(d: dashboard(overdue: const <PosDashboardOverdueItem>[]));
    await zero.pump(t, const CashierDashboardScreen());
    expect(find.text('Просроченных долгов нет'), findsOneWidget);
  });

  testWidgets('долги: просрочка → SCR-34 клиента; «Все просрочки» — лист с `GET /receivables/overdue`', (
    WidgetTester t,
  ) async {
    // AC-UI-30-014 (клиентская часть): лист «Все просрочки» загружает GET /receivables/overdue.
    final CashierHarness h = _h();
    await _pumpRouted(t, h);
    expect(find.text('Просрочено: 1 клиент на ${fmt(420000)}'), findsOneWidget);
    h.receivables.overduePage = Success<OverdueReceivablesPage>(
      overduePageOf(<({String id, String name, int tyiyn, int days})>[
        (id: 'cu-7', name: 'ИП Асанов', tyiyn: 420000, days: 12),
        (id: 'cu-8', name: 'ОсОО «Мир»', tyiyn: 120000, days: 3),
      ]),
    );
    await t.tap(find.byKey(const ValueKey<String>('cashier-debts-all')));
    await CashierHarness.settle(t);
    expect(h.receivables.overdueQueries, hasLength(1));
    expect(find.byKey(const ValueKey<String>('overdue-cu-8')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey<String>('overdue-cu-8')));
    await CashierHarness.settle(t);
    expect(h.visited.last, '/customers/cu-8/receivables');
  });

  testWidgets('«Принять оплату» → лист поиска заказа: оплаченный — disabled, выбор → SCR-38', (WidgetTester t) async {
    final CashierHarness h = _h();
    h.orders.onList = (OrdersQuery q) async => Success<OrdersPage>(
      OrdersPage(
        page: PageResult<OrderSummary>(
          items: <OrderSummary>[
            awaiting('o5', 1024),
            const OrderSummary(
              id: 'o6',
              publicNumber: 'POS-2026-001025',
              status: OrderStatus.approved,
              total: Money(100000),
              paymentMethod: PaymentMethod.cash,
              isPaid: true,
              paidAmount: Money(100000),
            ),
          ],
        ),
      ),
    );
    await _pumpRouted(t, h);
    await t.tap(find.byKey(const ValueKey<String>('cashier-accept-payment')));
    await CashierHarness.settle(t);
    expect(find.text('Найти заказ или клиента'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey<String>('cashier-lookup-field')), '1024');
    await t.pump(const Duration(milliseconds: 350));
    await CashierHarness.settle(t);
    expect(find.text('Оплачен'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey<String>('cashier-lookup-order-o6')));
    await CashierHarness.settle(t);
    expect(h.visited, isEmpty);
    await t.tap(find.byKey(const ValueKey<String>('cashier-lookup-order-o5')));
    await CashierHarness.settle(t);
    expect(h.visited.single, '/payments/new?orderId=o5');
  });

  testWidgets('лист поиска без вкладки «Клиент (долг)» при debtPaymentsFromPos=false (RM-G-013)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h();
    await h.pump(t, const CashierDashboardScreen());
    await t.tap(find.byKey(const ValueKey<String>('cashier-accept-payment')));
    await CashierHarness.settle(t);
    expect(find.text('Клиент (долг)'), findsNothing);
  });

  testWidgets('избранное: «Принять оплату по долгу» в меню отсутствует при debtPaymentsFromPos=false', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h(
      d: dashboard(favorites: <Customer>[customer('cu-1', 'Азамат Б.', onecRef: 'r')]),
    );
    await h.pump(t, const CashierDashboardScreen());
    await t.longPress(find.byKey(const ValueKey<String>('cashier-favorite-cu-1')));
    await CashierHarness.settle(t);
    expect(find.text('Принять оплату'), findsOneWidget); // только кнопка Z2
  });

  testWidgets('показанный QR — таймер TTL строки обновляется раз в секунду (UI-30-004, AC-UI-30-020)', (
    WidgetTester t,
  ) async {
    final Payment qr = Payment(
      id: 'p-qr',
      orderId: 'o2',
      method: PaymentMethod.qrBakai,
      status: PaymentStatus.qrShown,
      amount: const Money(235000),
      qr: QrInfo(
        rawProvider: 'onec',
        issuedAt: DateTime.utc(2026, 10, 22, 4, 20),
        expiresAt: DateTime.utc(2026, 10, 22, 4, 44, 32),
        autoConfirm: true,
      ),
    );
    final CashierHarness h = _h(d: dashboard(qrPending: <Payment>[qr]));
    await h.pump(t, const CashierDashboardScreen());
    expect(find.text('14:32'), findsOneWidget);
    h.clock.advance(const Duration(seconds: 1));
    await t.pump(const Duration(seconds: 1));
    expect(find.text('14:31'), findsOneWidget);
    h.clock.advance(const Duration(seconds: 1));
    await t.pump(const Duration(seconds: 1));
    expect(find.text('14:30'), findsOneWidget);
  });

  testWidgets('без QR — часы шапки HH:mm меняются по границе минуты (UI-30-013)', (WidgetTester t) async {
    final CashierHarness h = _h();
    h.clock.set(DateTime.utc(2026, 10, 22, 4, 30, 50)); // 10:30:50 по Бишкеку
    await h.pump(t, const CashierDashboardScreen());
    expect(find.text('10:30'), findsOneWidget);
    h.clock.advance(const Duration(seconds: 10));
    await t.pump(const Duration(seconds: 10));
    expect(find.text('10:31'), findsOneWidget);
    expect(find.text('10:30'), findsNothing);
  });

  testWidgets('долги: подпись «Данные 1С на HH:MM»; свежий снимок — без предупреждения (AC-UI-30-002)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h();
    await h.pump(t, const CashierDashboardScreen());
    expect(find.text('Данные 1С на 10:00'), findsOneWidget);
    expect(find.text('данные от 10:00'), findsNothing);
    expect(find.byKey(const ValueKey<String>('cashier-debts-stale')), findsNothing);
    expect(find.byKey(const ValueKey<String>('cashier-debts-refresh')), findsNothing);
  });

  testWidgets('долги: снимок старше порога — предупреждение и «Обновить» перечитывает дашборд (AC-UI-30-002)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h(d: dashboard(receivablesAsOf: DateTime.utc(2026, 10, 22, 3, 10)));
    await h.pump(t, const CashierDashboardScreen());
    expect(find.text('Данные могут быть неактуальны (от 09:10)'), findsOneWidget);
    expect(h.cashier.calls, 1);
    await t.ensureVisible(find.byKey(const ValueKey<String>('cashier-debts-refresh')));
    await t.tap(find.byKey(const ValueKey<String>('cashier-debts-refresh')));
    await CashierHarness.settle(t);
    expect(h.cashier.calls, 2);
  });

  testWidgets('долги: порог устаревания — с сервера (`GET /sync/status` receivables.isStale), не константа 60 мин', (
    WidgetTester t,
  ) async {
    // Снимку 20 мин, но сервер (receivables.max_age_minutes = 15) считает его устаревшим.
    final CashierHarness strict = _h(d: dashboard(receivablesAsOf: DateTime.utc(2026, 10, 22, 4, 10)));
    strict.extraOverrides.add(
      syncStatusOverride(
        entities: <({String entity, DateTime? last, int errors, bool stale})>[
          (entity: 'receivables', last: DateTime.utc(2026, 10, 22, 4, 10), errors: 0, stale: true),
        ],
      ),
    );
    await strict.pump(t, const CashierDashboardScreen());
    expect(find.byKey(const ValueKey<String>('cashier-debts-stale')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('cashier-debts-refresh')), findsOneWidget);

    // Снимку 2 ч, но порог сервера больше (receivables.max_age_minutes = 240) — предупреждения нет.
    final CashierHarness lax = _h(d: dashboard(receivablesAsOf: DateTime.utc(2026, 10, 22, 2, 30)));
    lax.extraOverrides.add(
      syncStatusOverride(
        entities: <({String entity, DateTime? last, int errors, bool stale})>[
          (entity: 'receivables', last: DateTime.utc(2026, 10, 22, 2, 30), errors: 0, stale: false),
        ],
      ),
    );
    await lax.pump(t, const CashierDashboardScreen());
    expect(find.byKey(const ValueKey<String>('cashier-debts-stale')), findsNothing);
  });

  testWidgets('долги: overdue[] на пределе ответа (10) — итог не вычисляется, вместо него «Все просрочки» (DEBT-001)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h(
      d: dashboard(
        overdue: <PosDashboardOverdueItem>[
          for (int i = 0; i < 10; i++)
            PosDashboardOverdueItem(
              customer: customer('cu-o$i', 'Клиент $i'),
              overdueAmount: Money(100000 + i),
              overdueDays: 5,
              asOf: DateTime.utc(2026, 10, 22, 4),
            ),
        ],
      ),
    );
    await _pumpRouted(t, h);
    expect(find.byKey(const ValueKey<String>('cashier-debts-summary')), findsNothing);
    expect(find.textContaining('Просрочено: 10'), findsNothing);
    expect(find.byKey(const ValueKey<String>('cashier-debts-summary-all')), findsOneWidget);
    h.receivables.overduePage = Success<OverdueReceivablesPage>(
      overduePageOf(<({String id, String name, int tyiyn, int days})>[
        (id: 'cu-o0', name: 'Клиент 0', tyiyn: 100000, days: 5),
      ]),
    );
    await t.ensureVisible(find.byKey(const ValueKey<String>('cashier-debts-summary-all')));
    await t.tap(find.byKey(const ValueKey<String>('cashier-debts-summary-all')));
    await CashierHarness.settle(t);
    expect(h.receivables.overdueQueries, hasLength(1));
  });

  testWidgets('шапка: логотип, «Имя · Кассир», меню аватара Профиль/Настройки/Заблокировать/Выйти (UI-30-013)', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _h();
    int locks = 0;
    int logouts = 0;
    h.extraOverrides.addAll(<Override>[
      cashierViewerNameProvider.overrideWithValue('Абдулла'),
      cashierLogoProvider.overrideWithValue((BuildContext c) => const SizedBox(key: ValueKey<String>('logo'))),
      cashierLockProvider.overrideWithValue(() => locks++),
      cashierLogoutProvider.overrideWithValue((BuildContext c, WidgetRef r) async => logouts++),
    ]);
    await _pumpRouted(t, h);
    expect(find.byKey(const ValueKey<String>('logo')), findsOneWidget);
    expect(find.text('Абдулла'), findsOneWidget);
    expect(find.text('Кассир'), findsOneWidget);

    Future<void> pick(String item) async {
      await t.tap(find.byKey(const ValueKey<String>('cashier-header-user')));
      await t.pumpAndSettle();
      expect(find.text('Профиль'), findsOneWidget);
      expect(find.text('Настройки'), findsOneWidget);
      expect(find.text('Заблокировать'), findsOneWidget);
      expect(find.text('Выйти'), findsOneWidget);
      await t.tap(find.byKey(ValueKey<String>(item)));
      await t.pumpAndSettle();
    }

    await pick('cashier-menu-lock');
    expect(locks, 1);
    await pick('cashier-menu-logout');
    expect(logouts, 1);
    await pick('cashier-menu-profile');
    expect(h.visited.last, '/profile');
  });

  testWidgets('шапка: SyncIndicator из корня вместо иконки (UI-30-013)', (WidgetTester t) async {
    final CashierHarness h = _h();
    h.extraOverrides.add(
      cashierSyncIndicatorProvider.overrideWithValue((BuildContext c) => const Text('sync-indicator')),
    );
    await h.pump(t, const CashierDashboardScreen());
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('cashier-header-sync')),
        matching: find.text('sync-indicator'),
      ),
      findsOneWidget,
    );
    expect(
      find
          .byType(AppIconButton)
          .evaluate()
          .where((Element e) => e.widget.key == const ValueKey<String>('cashier-header-sync')),
      isEmpty,
    );
  });
}
