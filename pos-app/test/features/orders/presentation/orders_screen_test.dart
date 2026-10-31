// SCR-25 «Список заказов» (агент F-fe-orders; 02 SCR-25.13 AC-UI-25-001…012; 13 RM-F-006, RM-F-013 п. 5 — чипы
// `statusCounts`; RM-F-015 — «Мои заказы» клиента): фильтры и чипы со счётчиками, права «Мои / Все», «Оплачено»,
// курсорная подгрузка, пустые состояния, период в границах суток Бишкека.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/presentation/orders_format.dart';
import 'package:optomstroy/features/orders/presentation/screens/orders_screen.dart';
import 'package:optomstroy/features/orders/presentation/state/orders_filters.dart';

import '../../../support/f_fakes.dart';
import '../support/orders_harness.dart';

List<OrdersQuery> _queries(FakeOrdersRepository r) => <OrdersQuery>[
  for (final FakeCall c in r.calls)
    if (c.method == 'list') c.args.single! as OrdersQuery,
];

void main() {
  late FakeOrdersRepository repo;

  setUp(() {
    repo = FakeOrdersRepository()
      ..onList = (OrdersQuery q) async => Success<OrdersPage>(
        ordersPage(
          <OrderSummary>[
            summary(1, onecNumber: 'УТ-0001234'),
            summary(2, status: OrderStatus.awaitingPayment, paidSom: 8000),
            summary(3, status: OrderStatus.shipped, method: PaymentMethod.credit),
            summary(4, status: OrderStatus.closed, isPaid: true, paidSom: 16007),
          ],
          total: 4,
          counts: q.cursor == null ? kCounts : const <OrderStatus, int>{},
        ),
      );
  });

  testWidgets('AC-UI-25-012: первый запрос с include=statusCounts; чипы со счётчиками групп', (WidgetTester t) async {
    final OrdersHarness h = OrdersHarness(orders: repo);
    await h.pump(t, const OrdersScreen());
    final List<OrdersQuery> qs = _queries(repo);
    expect(qs, hasLength(1));
    expect(qs.single.withStatusCounts, isTrue);
    expect(qs.single.cursor, isNull);
    expect(qs.single.statuses, isEmpty);
    expect(find.text('Все · 31'), findsOneWidget);
    expect(find.text('В работе · 12'), findsOneWidget);
    expect(find.text('Ждут оплаты · 3'), findsOneWidget);
    expect(find.text('Отгружены · 6'), findsOneWidget);
    expect(find.text('Закрыты · 9'), findsOneWidget);
    expect(find.text('Отменены и отклонены · 1'), findsOneWidget);
    expect(find.text('Найдено: 4 за период'), findsOneWidget);
  });

  testWidgets('AC-UI-25-012: без statusCounts чипы без чисел, список загружается', (WidgetTester t) async {
    repo.onList = (OrdersQuery q) async => Success<OrdersPage>(ordersPage(<OrderSummary>[summary(1)]));
    await OrdersHarness(orders: repo).pump(t, const OrdersScreen());
    expect(find.text('В работе'), findsOneWidget);
    expect(find.textContaining('В работе ·'), findsNothing);
    expect(find.byKey(const ValueKey<String>('order-row-o1')), findsOneWidget);
  });

  testWidgets('AC-UI-25-003: «Ждут оплаты» — status=awaiting_payment; «В работе» — четыре статуса', (
    WidgetTester t,
  ) async {
    await OrdersHarness(orders: repo).pump(t, const OrdersScreen());
    await t.tap(find.text('Ждут оплаты · 3'));
    await t.pump();
    await t.pump();
    expect(_queries(repo).last.statuses, <OrderStatus>{OrderStatus.awaitingPayment});
    expect(_queries(repo).last.cursor, isNull, reason: 'смена фильтра — с первой страницы');
    await t.tap(find.text('В работе · 12'));
    await t.pump();
    await t.pump();
    expect(_queries(repo).last.statuses, OrdersStatusGroup.inProgress.statuses);
    expect(OrdersStatusGroup.inProgress.statuses, hasLength(4));
  });

  testWidgets('AC-UI-25-001: продавец — «Мои заказы», без «Мои / Все», без createdBy', (WidgetTester t) async {
    await OrdersHarness(orders: repo, role: RoleCode.seller).pump(t, const OrdersScreen(mine: '1'));
    expect(find.text('Мои заказы'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('orders-scope-mine')), findsNothing);
    expect(_queries(repo).single.createdBy, isNull);
  });

  testWidgets('AC-UI-25-002: кассир видит все и переключает «Мои / Все» (createdBy)', (WidgetTester t) async {
    await OrdersHarness(orders: repo, userId: 'cashier-7').pump(t, const OrdersScreen());
    expect(find.text('Заказы'), findsOneWidget);
    expect(_queries(repo).single.createdBy, isNull);
    await t.tap(find.byKey(const ValueKey<String>('orders-scope-mine')));
    await t.pump();
    await t.pump();
    expect(_queries(repo).last.createdBy, 'cashier-7');
    await t.tap(find.byKey(const ValueKey<String>('orders-scope-all')));
    await t.pump();
    await t.pump();
    expect(_queries(repo).last.createdBy, isNull);
  });

  testWidgets('mine=1 в маршруте у кассира — «Мои» выбрано, createdBy = пользователь', (WidgetTester t) async {
    await OrdersHarness(orders: repo, userId: 'u9').pump(t, const OrdersScreen(mine: '1', status: 'awaiting_payment'));
    final OrdersQuery q = _queries(repo).single;
    expect(q.createdBy, 'u9');
    expect(q.statuses, <OrderStatus>{OrderStatus.awaitingPayment});
  });

  testWidgets('режим клиента (RM-F-015): «Мои заказы», без «Мои / Все» и фильтра клиента', (WidgetTester t) async {
    final OrdersHarness h = OrdersHarness(orders: repo, role: RoleCode.customer);
    await h.pump(t, const OrdersScreen(), size: kWindows['compact']!);
    expect(find.text('Мои заказы'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('orders-scope-all')), findsNothing);
    expect(_queries(repo).single.createdBy, isNull);
    await t.tap(find.byKey(const ValueKey<String>('orders-filters')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('filter-customer-search')), findsNothing);
    expect(find.byKey(const ValueKey<String>('filter-method-cash')), findsOneWidget);
  });

  testWidgets('AC-UI-25-005: «Оплачено» — «X из Y», «Долг» для credit, «Оплачен»', (WidgetTester t) async {
    await OrdersHarness(orders: repo).pump(t, const OrdersScreen());
    expect(
      find.text('${OrdersFormat.amount(const Money(800000))} из ${OrdersFormat.amount(const Money(1600750))}'),
      findsOneWidget,
    );
    expect(find.text('Долг'), findsOneWidget);
    expect(find.text('Оплачен'), findsOneWidget);
    // Статус и оплата — раздельно: статус заказа не заменяется на «Оплачен».
    expect(find.text('Закрыт'), findsWidgets);
  });

  testWidgets('AC-UI-25-006: подгрузка по курсору; ошибка подгрузки не стирает строки, «Повторить» — тот же курсор', (
    WidgetTester t,
  ) async {
    int page2 = 0;
    repo.onList = (OrdersQuery q) async {
      if (q.cursor == null) {
        return Success<OrdersPage>(
          ordersPage(<OrderSummary>[for (int i = 1; i <= 30; i++) summary(i)], next: 'c2', counts: kCounts),
        );
      }
      page2++;
      if (page2 == 1) return const FailureResult<OrdersPage>(NetworkFailure(NetworkFailureKind.offline));
      return Success<OrdersPage>(ordersPage(<OrderSummary>[for (int i = 31; i <= 35; i++) summary(i)]));
    };
    await OrdersHarness(orders: repo).pump(t, const OrdersScreen());
    await t.drag(find.byKey(const ValueKey<String>('orders-list')), const Offset(0, -3000));
    await t.pump();
    await t.pump();
    await t.pump();
    expect(find.byKey(const ValueKey<String>('orders-load-more-error')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('order-row-o30')), findsOneWidget);
    expect(_queries(repo).where((OrdersQuery q) => q.cursor == 'c2'), hasLength(1));
    expect(_queries(repo).last.withStatusCounts, isFalse);
    await t.tap(find.text('Повторить'));
    await t.pump();
    await t.pump();
    await t.drag(find.byKey(const ValueKey<String>('orders-list')), const Offset(0, -3000));
    await t.pump();
    expect(_queries(repo).where((OrdersQuery q) => q.cursor == 'c2'), hasLength(2));
    expect(find.byKey(const ValueKey<String>('order-row-o35')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('orders-load-more-error')), findsNothing);
  });

  testWidgets('AC-UI-25-008: пусто без фильтров — «Заказов пока нет» + «Создать заказ»', (WidgetTester t) async {
    repo.onList = (OrdersQuery q) async => Success<OrdersPage>(ordersPage(const <OrderSummary>[]));
    await OrdersHarness(orders: repo, role: RoleCode.seller).pump(t, const OrdersScreen());
    expect(find.text('Заказов пока нет'), findsOneWidget);
    expect(find.text('Создать заказ'), findsOneWidget);
  });

  testWidgets('AC-UI-25-008: пусто с изменёнными фильтрами и с поиском', (WidgetTester t) async {
    repo.onList = (OrdersQuery q) async => Success<OrdersPage>(ordersPage(const <OrderSummary>[]));
    await OrdersHarness(orders: repo, role: RoleCode.owner).pump(t, const OrdersScreen(status: 'closed'));
    expect(find.text('Ничего не найдено по выбранным фильтрам'), findsOneWidget);
    expect(find.text('Сбросить фильтры'), findsOneWidget);
    expect(find.text('Создать заказ'), findsNothing);
    await t.enterText(find.byType(EditableText), 'POS-2026-9');
    await t.pump(const Duration(milliseconds: 350));
    await t.pump();
    await t.pump();
    expect(_queries(repo).last.q, 'POS-2026-9');
    expect(find.text('Ничего не найдено по „POS-2026-9“'), findsOneWidget);
    await t.tap(find.text('Сбросить фильтры'));
    await t.pump();
    await t.pump();
    expect(_queries(repo).last.q, isNull);
    expect(_queries(repo).last.statuses, isEmpty);
  });

  testWidgets(
    'AC-UI-25-004: номер целиком и единственный результат — сразу SCR-24 (без маршрутизатора — без падения)',
    (WidgetTester t) async {
      repo.onList = (OrdersQuery q) async => Success<OrdersPage>(
        ordersPage(q.q == null ? <OrderSummary>[summary(1), summary(2)] : <OrderSummary>[summary(123)]),
      );
      await OrdersHarness(orders: repo).pump(t, const OrdersScreen());
      await t.enterText(find.byType(EditableText), 'POS-2026-000123');
      await t.testTextInput.receiveAction(TextInputAction.search);
      await t.pump();
      await t.pump();
      await t.pump();
      expect(_queries(repo).last.q, 'POS-2026-000123');
      // После перехода (no-op без go_router) экран обновляет первую страницу — тихо.
      expect(find.byKey(const ValueKey<String>('order-row-o123')), findsOneWidget);
    },
  );

  testWidgets('ошибка первой загрузки — ErrorState и «Повторить»', (WidgetTester t) async {
    int n = 0;
    repo.onList = (OrdersQuery q) async => n++ == 0
        ? const FailureResult<OrdersPage>(NetworkFailure(NetworkFailureKind.timeout))
        : Success<OrdersPage>(ordersPage(<OrderSummary>[summary(1)]));
    await OrdersHarness(orders: repo).pump(t, const OrdersScreen());
    expect(find.byKey(const ValueKey<String>('orders-error')), findsOneWidget);
    await t.tap(find.text('Повторить'));
    await t.pump();
    await t.pump();
    expect(find.byKey(const ValueKey<String>('order-row-o1')), findsOneWidget);
  });

  test('AC-UI-25-011: пресеты периода — границы суток Бишкека (UTC+6) в UTC', () {
    final OrdersPeriod today = OrdersPeriod.preset(OrdersPeriodPreset.today, kNow);
    expect(today.from, DateTime.utc(2026, 10, 21, 18));
    expect(today.to, DateTime.utc(2026, 10, 22, 18));
    final OrdersPeriod yesterday = OrdersPeriod.preset(OrdersPeriodPreset.yesterday, kNow);
    expect(yesterday.from, DateTime.utc(2026, 10, 20, 18));
    expect(yesterday.to, DateTime.utc(2026, 10, 21, 18));
    final OrdersPeriod week = OrdersPeriod.preset(OrdersPeriodPreset.days7, kNow);
    expect(week.from, DateTime.utc(2026, 10, 15, 18));
    // 23:30 по Бишкеку 22.10 — это уже 22.10 (17:30 UTC), а 00:30 23.10 — 18:30 UTC 22.10.
    expect(
      OrdersPeriod.preset(OrdersPeriodPreset.today, DateTime.utc(2026, 10, 22, 18, 30)).from,
      DateTime.utc(2026, 10, 22, 18),
    );
  });

  testWidgets('период «Сегодня» уходит в запрос и в query маршрута', (WidgetTester t) async {
    await OrdersHarness(orders: repo).pump(t, const OrdersScreen());
    final OrdersQuery first = _queries(repo).single;
    expect(first.from, DateTime.utc(2026, 10, 19, 18), reason: 'по умолчанию — последние 3 дня');
    await t.tap(find.byKey(const ValueKey<String>('orders-period')));
    await t.pumpAndSettle();
    await t.tap(find.text('Сегодня').last);
    await t.pumpAndSettle();
    expect(_queries(repo).last.from, DateTime.utc(2026, 10, 21, 18));
    expect(_queries(repo).last.to, DateTime.utc(2026, 10, 22, 18));
    final OrdersFilters f = OrdersFilters.fromRoute(
      nowUtc: kNow,
      from: '2026-10-21T18:00:00.000Z',
      to: '2026-10-22T18:00:00.000Z',
    );
    expect(f.period.preset, OrdersPeriodPreset.today);
    expect(f.toRouteQuery()['from'], '2026-10-21T18:00:00.000Z');
  });

  testWidgets('фильтры: способ оплаты и «Оплачен» — новый запрос; бейдж числа фильтров', (WidgetTester t) async {
    await OrdersHarness(orders: repo).pump(t, const OrdersScreen(), size: kWindows['compact']!);
    await t.tap(find.byKey(const ValueKey<String>('orders-filters')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey<String>('filter-method-credit')));
    await t.pumpAndSettle();
    expect(_queries(repo).last.paymentMethod, PaymentMethod.credit);
    await t.ensureVisible(find.byKey(const ValueKey<String>('filter-paid-yes')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey<String>('filter-paid-yes')));
    await t.pumpAndSettle();
    expect(_queries(repo).last.isPaid, isTrue);
    expect(find.text('Фильтры · 2'), findsOneWidget);
  });

  testWidgets('сортировка «По сумме» — sort=total:desc', (WidgetTester t) async {
    await OrdersHarness(orders: repo).pump(t, const OrdersScreen());
    await t.tap(find.byKey(const ValueKey<String>('orders-sort')));
    await t.pumpAndSettle();
    await t.tap(find.text('По сумме').last);
    await t.pumpAndSettle();
    expect(_queries(repo).last.sort, OrdersSort.totalDesc);
  });

  testWidgets('expanded: печать из строки (UI-25-009) — недоступна для submitting, счёт печатается', (
    WidgetTester t,
  ) async {
    repo.onList = (OrdersQuery q) async => Success<OrdersPage>(
      ordersPage(<OrderSummary>[summary(1, onecNumber: 'УТ-1'), summary(2, status: OrderStatus.submitting)]),
    );
    repo.onDocument = (String id, OrderDocumentKind kind, PrintPaper paper, bool copy) async =>
        const Success<OrderDocumentFile>(OrderDocumentFile(bytes: <int>[1, 2, 3], fileName: 'invoice-POS.pdf'));
    final OrdersHarness h = OrdersHarness(orders: repo);
    await h.pump(t, const OrdersScreen());
    expect(t.widget<AppIconButton>(find.byKey(const ValueKey<String>('order-print-o2'))).onPressed, isNull);
    expect(t.widget<AppIconButton>(find.byKey(const ValueKey<String>('order-print-o1'))).onPressed, isNotNull);
    await t.tap(find.byKey(const ValueKey<String>('order-print-o1')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey<String>('row-print-invoice')));
    await t.pumpAndSettle();
    final FakeCall doc = repo.calls.lastWhere((FakeCall c) => c.method == 'document');
    expect(doc.args[1], OrderDocumentKind.invoice);
    expect(doc.args[2], PrintPaper.a4);
    expect(h.printer.calls, <String>['print:invoice-POS.pdf']);
  });

  testWidgets('F5 — перезагрузка первой страницы', (WidgetTester t) async {
    await OrdersHarness(orders: repo).pump(t, const OrdersScreen());
    await t.sendKeyEvent(LogicalKeyboardKey.f5);
    await t.pump();
    await t.pump();
    expect(_queries(repo), hasLength(2));
    expect(_queries(repo).last.cursor, isNull);
  });

  // 02 SCR-25.6: при возврате на экран — тихое обновление первой страницы. Экран живёт в ветке оболочки и под SCR-24 /
  // SCR-22 (дочерние маршруты `/orders/…`); «Заказы» из меню после оплаты показывали снимок до неё (uiA-03).
  testWidgets('возврат на экран из маршрута поверх — тихое обновление первой страницы', (WidgetTester t) async {
    await OrdersHarness(orders: repo).pump(t, const OrdersScreen());
    expect(_queries(repo), hasLength(1));
    final NavigatorState nav = t.state<NavigatorState>(find.byType(Navigator).first);
    unawaited(nav.push<void>(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('SCR-24')))));
    await t.pumpAndSettle();
    expect(_queries(repo), hasLength(1), reason: 'под другим маршрутом список не перечитывается');
    nav.pop();
    await t.pumpAndSettle();
    expect(_queries(repo), hasLength(2));
    expect(_queries(repo).last.cursor, isNull);
    expect(find.byKey(const ValueKey<String>('order-row-o1')), findsOneWidget);
  });

  // Ревью RP-01: меню печати строки, меню периода и лист фильтров — маршруты без страницы поверх SCR-25 в том же
  // навигаторе (`useRootNavigator: false`); их закрытие — не «возврат на экран» (02 SCR-25.6), лишнего GET /orders нет.
  testWidgets('expanded: меню печати строки (с печатью) и меню периода закрыты — список не перечитывается', (
    WidgetTester t,
  ) async {
    repo.onDocument = (String id, OrderDocumentKind kind, PrintPaper paper, bool copy) async =>
        const Success<OrderDocumentFile>(OrderDocumentFile(bytes: <int>[1, 2, 3], fileName: 'invoice-POS.pdf'));
    final OrdersHarness h = OrdersHarness(orders: repo);
    await h.pump(t, const OrdersScreen());
    expect(_queries(repo), hasLength(1));
    await t.tap(find.byKey(const ValueKey<String>('order-print-o1')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey<String>('row-print-invoice')));
    await t.pumpAndSettle();
    expect(h.printer.calls, <String>['print:invoice-POS.pdf']);
    expect(_queries(repo), hasLength(1), reason: 'закрытие меню печати — не возврат на экран');
    await t.tap(find.byKey(const ValueKey<String>('orders-period')));
    await t.pumpAndSettle();
    expect(find.text('Сегодня'), findsWidgets);
    await t.tapAt(const Offset(4, 4));
    await t.pumpAndSettle();
    expect(_queries(repo), hasLength(1), reason: 'закрытие меню периода без выбора — не возврат на экран');
  });

  testWidgets('compact: лист фильтров открыт и закрыт без изменений — список не перечитывается', (
    WidgetTester t,
  ) async {
    await OrdersHarness(orders: repo).pump(t, const OrdersScreen(), size: kWindows['compact']!);
    expect(_queries(repo), hasLength(1));
    await t.tap(find.byKey(const ValueKey<String>('orders-filters')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('filter-method-cash')), findsOneWidget);
    await t.tapAt(const Offset(4, 4));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('filter-method-cash')), findsNothing);
    expect(_queries(repo), hasLength(1));
  });

  // Как в приложении (go_router): SCR-25 — страница навигатора. Меню поверх — не уход; страница поверх (непрозрачная
  // SCR-24 и прозрачная, как модальный SCR-21 на medium+) — уход, её закрытие — возврат с обновлением.
  testWidgets('страница навигатора: меню поверх — не уход; страница поверх (и прозрачная) — возврат с обновлением', (
    WidgetTester t,
  ) async {
    final GlobalKey<_PagedHostState> host = GlobalKey<_PagedHostState>();
    await OrdersHarness(orders: repo).pump(t, _PagedHost(key: host, child: const OrdersScreen()));
    expect(_queries(repo), hasLength(1));
    await t.tap(find.byKey(const ValueKey<String>('orders-period')));
    await t.pumpAndSettle();
    await t.tapAt(const Offset(4, 4));
    await t.pumpAndSettle();
    expect(_queries(repo), hasLength(1), reason: 'меню без страницы — не уход с экрана');

    host.currentState!.push(
      const MaterialPage<void>(
        key: ValueKey<String>('scr-24'),
        child: Scaffold(body: Text('SCR-24')),
      ),
    );
    await t.pumpAndSettle();
    expect(_queries(repo), hasLength(1));
    host.currentState!.pop();
    await t.pumpAndSettle();
    expect(_queries(repo), hasLength(2));

    host.currentState!.push(
      CustomTransitionPage<void>(
        key: const ValueKey<String>('scr-21'),
        opaque: false,
        transitionsBuilder: (_, _, _, Widget child) => child,
        child: const Center(child: Text('SCR-21')),
      ),
    );
    await t.pumpAndSettle();
    expect(_queries(repo), hasLength(2), reason: 'под прозрачной страницей список не перечитывается');
    host.currentState!.pop();
    await t.pumpAndSettle();
    expect(_queries(repo), hasLength(3));
  });
}

/// Навигатор со страницами (как ветка оболочки go_router): SCR-25 — нижняя страница, сверху — [push]/[pop].
class _PagedHost extends StatefulWidget {
  const _PagedHost({required this.child, super.key});

  final Widget child;

  @override
  State<_PagedHost> createState() => _PagedHostState();
}

class _PagedHostState extends State<_PagedHost> {
  final List<Page<void>> _above = <Page<void>>[];

  void push(Page<void> page) => setState(() => _above.add(page));

  void pop() => setState(_above.removeLast);

  @override
  Widget build(BuildContext context) => Navigator(
    pages: <Page<void>>[
      MaterialPage<void>(key: const ValueKey<String>('scr-25'), child: widget.child),
      ..._above,
    ],
    onDidRemovePage: (Page<Object?> page) {},
  );
}
