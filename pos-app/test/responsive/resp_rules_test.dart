// T-UI-117: правила, которые закрепил прогон адаптивности 2026-11-18 (указание владельца 2026-11-18 «i ekran nujno
// selat aaptivnim… prover kak vse selano», 15 §5.8 (3); 03 §8.8; 02 SCR-21.2, SCR-25.2, SCR-30.2, SCR-32.2):
// (1) «Касса»: «Принять оплату» и «Каталог» — в ряд, только если обе подписи помещаются без уменьшения, иначе друг под
//     другом (360 — столбик, 1440 — ряд); карточка избранного клиента растёт с масштабом текста (1,3 — без
//     переполнения);
// (2) оформление: окно 600 при масштабе 1,3 — футер столбиком (CTA, «Отмена»), подписи предстоящих узлов степпера
//     скрыты; окно 1280 — прежний футер в одну строку 72;
// (3) окно ≥ 1600: тело списка заказов, журнала операций и карточки клиента — не шире 1200 + боковая панель по центру;
//     окно 1366 — во всю ширину, как прежде;
// (4) тач-цели (03 §7.4): строка товара заказа ≥ 44, сортировка журнала — на высоту шапки 44, чипы-метрики карточки
//     клиента ≥ 44, строка «Клиент» корзины `/cart` — 48;
// (5) строки журнала (`TransactionRow`): сумма и «›» у правого края доли строки — «›» всех строк на одной вертикали;
// (6) суммы не уменьшаются как обычный вид (03 §8.8; 02 SCR-30.2, UI-30-014; 15 §5.8 (3), уточнение 2026-11-18 —
//     [ВЫВОД исполнителя]): «Сегодня» SCR-30 — три плитки в ряд, только если суммы помещаются, иначе столбиком; колонки
//     SCR-30 — по измеренной ширине; сумма `TransactionRow` шире своей доли — под заголовком; суммы SCR-30, SCR-36 и
//     SCR-33 рисуются не мельче 0,85 своей величины в окнах 600×960, 1024×768, 1280×800 (текст 1 и 1,3), 412×915 и
//     1920×1080;
// (7) SCR-40: окно ≥ 1600 — обе вкладки не шире 1200 по центру (и у роли без вкладки «Клиенты»).
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/transaction.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/checkout_stepper.dart';
import 'package:optomstroy/design_system/components/receivable_badge.dart';
import 'package:optomstroy/design_system/components/shift_summary_card.dart';
import 'package:optomstroy/design_system/components/transaction_row.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_panel_view.dart' show CartKeys;
import 'package:optomstroy/features/cashier/domain/entities/pos_dashboard.dart';
import 'package:optomstroy/features/cashier/presentation/screens/cashier_dashboard_screen.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout_draft.dart';
import 'package:optomstroy/features/customers/presentation/screens/customer_card_screen.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_card_view.dart' show CustomerCardKeys;
import 'package:optomstroy/features/favorites/presentation/screens/favorites_screen.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/presentation/screens/order_details_screen.dart';
import 'package:optomstroy/features/orders/presentation/screens/orders_screen.dart';
import 'package:optomstroy/features/transactions/domain/entities/transactions_query.dart';
import 'package:optomstroy/features/transactions/presentation/screens/transactions_screen.dart';

import '../features/cashier/support/cashier_harness.dart' as ch;
import '../features/customers/support/customers_harness.dart';
import '../features/orders/support/orders_harness.dart' as oh;
import '../support/f_fakes.dart';
import '../support/responsive_audit.dart';
import 'support/resp_cart_checkout_scenes.dart';

Future<void> _show(WidgetTester tester, Widget app, Size size, {double scale = 1}) async {
  await loadRespFonts();
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = size;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(app);
  for (int i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(tester.takeException(), isNull);
}

ch.CashierHarness _dashboard() {
  final ch.CashierHarness h = ch.CashierHarness();
  h.cashier.onDashboard = () async => Success<PosDashboard>(ch.dashboard());
  return h;
}

oh.OrdersHarness _ordersList() => oh.OrdersHarness(
  orders: FakeOrdersRepository()
    ..onList = (OrdersQuery q) async => Success<OrdersPage>(
      oh.ordersPage(<OrderSummary>[oh.summary(123, onecNumber: 'УТ-0001234'), oh.summary(122)], total: 2),
    ),
);

oh.OrdersHarness _orderDetails() => oh.OrdersHarness(
  orders: FakeOrdersRepository()
    ..onGet = (String id, bool refresh) async => Success<OrderDetails>(oh.details(oh.order())),
);

ch.CashierHarness _transactions() {
  final ch.CashierHarness h = ch.CashierHarness();
  h.transactions.onList = (TransactionsQuery q) async => Success<TransactionsPage>(
    ch.txPage(<Transaction>[
      ch.tx('t1', at: DateTime.utc(2026, 10, 22, 4, 10)),
    ], summary: const TransactionsSummary(count: 1, sumIn: Money(1600750), sumOut: Money.zero)),
  );
  return h;
}

ch.CashierHarness _transactionsMany() {
  final ch.CashierHarness h = ch.CashierHarness();
  h.transactions.onList = (TransactionsQuery q) async => Success<TransactionsPage>(
    ch.txPage(<Transaction>[
      ch.tx('t1', at: DateTime.utc(2026, 10, 22, 4, 10)),
      ch.tx(
        't2',
        kind: TransactionKind.paymentVoided,
        sign: TransactionSign.minus,
        group: TransactionStatusGroup.voided,
        tyiyn: 235000,
        number: '1025',
        at: DateTime.utc(2026, 10, 22, 3),
      ),
    ], summary: const TransactionsSummary(count: 2, sumIn: Money(1600750), sumOut: Money(235000))),
  );
  return h;
}

double _width(WidgetTester tester, Finder f) => tester.getSize(f).width;

/// Наименьший масштаб `FittedBox` над денежным текстом («… сом») на экране: 1 — суммы в натуральную величину.
double _minMoneyFit(WidgetTester tester) {
  final RegExp money = RegExp(r'\d[\d\s]*,\d\d\s*сом');
  double min = 1;
  for (final RenderFittedBox box in tester.allRenderObjects.whereType<RenderFittedBox>()) {
    final RenderBox? child = box.child;
    if (child == null || !child.hasSize || child.size.width < 1 || child.size.height < 1) continue;
    RenderParagraph? p;
    void visit(RenderObject o) {
      if (p != null) return;
      if (o is RenderParagraph) {
        p = o;
        return;
      }
      o.visitChildren(visit);
    }

    visit(child);
    if (p == null || !money.hasMatch(p!.text.toPlainText())) continue;
    final double s = (box.size.width / child.size.width).clamp(0, 1).toDouble();
    final double h = (box.size.height / child.size.height).clamp(0, 1).toDouble();
    if (s < min) min = s;
    if (h < min) min = h;
  }
  return min;
}

void main() {
  setUpAll(() => EditableText.debugDeterministicCursor = true);
  tearDownAll(() => EditableText.debugDeterministicCursor = false);

  group('(1) «Касса» SCR-30', () {
    testWidgets('360: «Принять оплату» и «Каталог» — столбиком во всю ширину', (WidgetTester tester) async {
      await _show(
        tester,
        _dashboard().app(const CashierDashboardScreen(), size: const Size(360, 780)),
        const Size(360, 780),
      );
      expect(find.byKey(const ValueKey<String>('cashier-actions-stacked')), findsOneWidget);
      final Rect accept = tester.getRect(find.byKey(const ValueKey<String>('cashier-accept-payment')));
      final Rect catalog = tester.getRect(find.byKey(const ValueKey<String>('cashier-catalog')));
      expect(catalog.top, greaterThan(accept.bottom - 0.5), reason: '«Каталог» под «Принять оплату»');
      expect(accept.width, closeTo(catalog.width, 0.5));
    });

    testWidgets('1440: в ряд, подписи без уменьшения', (WidgetTester tester) async {
      await _show(
        tester,
        _dashboard().app(const CashierDashboardScreen(), size: const Size(1440, 900)),
        const Size(1440, 900),
      );
      expect(find.byKey(const ValueKey<String>('cashier-actions-stacked')), findsNothing);
      final Rect accept = tester.getRect(find.byKey(const ValueKey<String>('cashier-accept-payment')));
      final Rect catalog = tester.getRect(find.byKey(const ValueKey<String>('cashier-catalog')));
      expect(accept.top, closeTo(catalog.top, 0.5), reason: 'в одном ряду');
      final Finder label = find.descendant(
        of: find.byKey(const ValueKey<String>('cashier-accept-payment')),
        matching: find.byType(FittedBox),
      );
      final RenderBox fitted = tester.renderObject<RenderBox>(label);
      final RenderBox text = tester.renderObject<RenderBox>(
        find.descendant(of: label, matching: find.byType(RichText)),
      );
      expect(fitted.size.width, greaterThanOrEqualTo(text.size.width - 0.5), reason: 'подпись не уменьшена');
    });

    testWidgets('масштаб текста 1,3: карточки избранных клиентов без переполнения', (WidgetTester tester) async {
      await _show(
        tester,
        _dashboard().app(const CashierDashboardScreen(), size: const Size(412, 915)),
        const Size(412, 915),
        scale: 1.3,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('(2) оформление SCR-21', () {
    testWidgets('600 × 1,3: футер столбиком, у предстоящих узлов степпера — только номер', (WidgetTester tester) async {
      await _show(
        tester,
        respCheckoutWindow(const Size(600, 960), CheckoutStep.payment),
        const Size(600, 960),
        scale: 1.3,
      );
      expect(find.byKey(const ValueKey<String>('checkout-footer-stacked')), findsOneWidget);
      final Finder stepper = find.byType(CheckoutStepper);
      expect(stepper, findsOneWidget);
      expect(tester.getSize(stepper).width, lessThanOrEqualTo(600));
    });

    testWidgets('1280: футер в одну строку 72 (с границей), подписи всех узлов', (WidgetTester tester) async {
      await _show(tester, respCheckoutWindow(const Size(1280, 800), CheckoutStep.payment), const Size(1280, 800));
      expect(find.byKey(const ValueKey<String>('checkout-footer-stacked')), findsNothing);
      expect(find.byKey(const ValueKey<String>('checkout-footer-narrow')), findsNothing);
      expect(find.text('Клиент'), findsWidgets);
      expect(find.text('Оплата'), findsWidgets);
    });
  });

  group('(3) окно ≥ 1600: тело не шире 1200 + панель', () {
    testWidgets('SCR-25 «Заказы»: 1920 — 1200 по центру; 1366 — во всю ширину', (WidgetTester tester) async {
      await _show(
        tester,
        _ordersList().app(const OrdersScreen(), size: const Size(1920, 1080)),
        const Size(1920, 1080),
      );
      final Finder box = find.byKey(const ValueKey<String>('ds-large-content'));
      expect(box, findsOneWidget);
      final Rect body = tester.getRect(find.descendant(of: box, matching: find.byType(Column)).first);
      expect(body.width, closeTo(1200, 0.5));
      expect(body.center.dx, closeTo(960, 0.5));
      await _show(tester, _ordersList().app(const OrdersScreen(), size: const Size(1366, 900)), const Size(1366, 900));
      expect(find.byKey(const ValueKey<String>('ds-large-content')), findsNothing);
    });

    testWidgets('SCR-36 «Журнал операций»: 2560 — 1200 + 320', (WidgetTester tester) async {
      await _show(
        tester,
        _transactions().app(const TransactionsScreen(), size: const Size(2560, 1440)),
        const Size(2560, 1440),
      );
      expect(_width(tester, find.byKey(const ValueKey<String>('ds-large-content'))), 2560);
      final Finder panel = find.byKey(const ValueKey<String>('tx-filter-panel'));
      expect(tester.getRect(panel).right, closeTo((2560 + 1520) / 2, 0.5));
    });

    testWidgets('SCR-32 «Карточка клиента»: 1920 — 1200 + 320 по центру', (WidgetTester tester) async {
      await _show(
        tester,
        CustomersHarness().app(const CustomerCardScreen(customerId: 'c1'), size: const Size(1920, 1080)),
        const Size(1920, 1080),
      );
      expect(find.byKey(const ValueKey<String>('ds-large-content')), findsOneWidget);
      expect(tester.getRect(find.byKey(CustomerCardKeys.metrics)).left, greaterThanOrEqualTo((1920 - 1520) / 2));
    });
  });

  group('(4) тач-цели 03 §7.4', () {
    testWidgets('строка товара заказа SCR-24 — не ниже 44 (expanded)', (WidgetTester tester) async {
      await _show(
        tester,
        _orderDetails().app(const OrderDetailsScreen(orderId: 'o1'), size: const Size(1366, 900)),
        const Size(1366, 900),
      );
      for (final int n in <int>[1, 2, 3]) {
        expect(tester.getSize(find.byKey(ValueKey<String>('order-line-$n'))).height, greaterThanOrEqualTo(44));
      }
    });

    testWidgets('сортировка журнала SCR-36 — на высоту шапки 44', (WidgetTester tester) async {
      await _show(
        tester,
        _transactions().app(const TransactionsScreen(), size: const Size(1366, 900)),
        const Size(1366, 900),
      );
      expect(tester.getSize(find.byKey(const ValueKey<String>('tx-sort-occurredAtDesc'))).height, 44);
      expect(tester.getSize(find.byKey(const ValueKey<String>('tx-sort-amountDesc'))).height, 44);
    });

    for (final ({Size size, double min}) c in <({Size size, double min})>[
      (size: const Size(390, 844), min: 48),
      (size: const Size(1366, 900), min: 44),
    ]) {
      testWidgets('чипы-метрики карточки клиента SCR-32 — цель ${c.min.toInt()} (${c.size.width.toInt()}), подпись и '
          'действие — один узел диктора', (WidgetTester tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        await _show(tester, CustomersHarness().app(const CustomerCardScreen(customerId: 'c1'), size: c.size), c.size);
        final Finder targets = find.descendant(
          of: find.byKey(CustomerCardKeys.metrics),
          matching: find.byWidgetPredicate((Widget w) => w is GestureDetector && w.onTap != null),
        );
        expect(targets, findsWidgets);
        for (final Element e in targets.evaluate()) {
          expect((e.renderObject! as RenderBox).size.height, greaterThanOrEqualTo(c.min));
          final SemanticsData node = tester
              .getSemantics(find.byElementPredicate((Element x) => x == e))
              .getSemanticsData();
          expect(node.hasAction(SemanticsAction.tap), isTrue);
          expect(node.label.trim(), isNotEmpty, reason: 'узел нажатия чипа с подписью');
          expect(node.flagsCollection.isButton, isTrue);
        }
        final Finder debt = find.descendant(
          of: find.byKey(CustomerCardKeys.metrics),
          matching: find.byType(ReceivableBadge),
        );
        expect(debt, findsOneWidget);
        final SemanticsData debtNode = tester.getSemantics(debt).getSemanticsData();
        expect(debtNode.label, contains('Долг'));
        expect(debtNode.hasAction(SemanticsAction.tap), isTrue, reason: 'чип долга — нажимаемый узел с подписью');
        handle.dispose();
      });
    }

    testWidgets('строка «Клиент» корзины `/cart` (compact) — 48', (WidgetTester tester) async {
      await _show(tester, respCart(const Size(360, 780)), const Size(360, 780));
      expect(tester.getSize(find.byKey(CartKeys.customer)).height, 48);
    });
  });

  testWidgets('(5) строки журнала SCR-36 (medium 960 × 540): «›» всех строк — на одной вертикали у правого края', (
    WidgetTester tester,
  ) async {
    await _show(
      tester,
      _transactionsMany().app(const TransactionsScreen(), size: const Size(960, 540)),
      const Size(960, 540),
    );
    final List<double> rights = <double>[
      for (final Element e in find.byIcon(Icons.chevron_right_rounded).evaluate())
        (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dx,
    ];
    expect(rights.length, greaterThanOrEqualTo(2));
    for (final double x in rights) {
      expect(x, closeTo(rights.first, 0.5));
    }
  });

  group('(6) суммы не уменьшаются как обычный вид', () {
    for (final ({Size size, double scale}) w in <({Size size, double scale})>[
      (size: const Size(600, 960), scale: 1),
      (size: const Size(600, 960), scale: 1.3),
      (size: const Size(1024, 768), scale: 1),
      (size: const Size(1024, 768), scale: 1.3),
      (size: const Size(1280, 800), scale: 1),
      (size: const Size(1280, 800), scale: 1.3),
      (size: const Size(412, 915), scale: 1),
      (size: const Size(1920, 1080), scale: 1),
    ]) {
      final String name = '${w.size.width.toInt()}×${w.size.height.toInt()} × ${w.scale}';
      testWidgets('SCR-30 «Касса» $name: суммы «Сегодня» и строк операций ≥ 0,85', (WidgetTester tester) async {
        await _show(tester, _dashboard().app(const CashierDashboardScreen(), size: w.size), w.size, scale: w.scale);
        expect(find.byType(ShiftSummaryCard), findsOneWidget);
        expect(_minMoneyFit(tester), greaterThanOrEqualTo(0.85));
      });
      testWidgets('SCR-36 «Журнал операций» $name: суммы ≥ 0,85, без обрезки', (WidgetTester tester) async {
        await _show(tester, _transactionsMany().app(const TransactionsScreen(), size: w.size), w.size, scale: w.scale);
        expect(_minMoneyFit(tester), greaterThanOrEqualTo(0.85));
        for (final RenderParagraph p in tester.allRenderObjects.whereType<RenderParagraph>()) {
          if (p.text.toPlainText().contains('сом')) {
            expect(p.didExceedMaxLines, isFalse, reason: '«${p.text.toPlainText()}» не обрезана');
          }
        }
      });
      testWidgets('SCR-33 «История клиента» $name: суммы ≥ 0,85', (WidgetTester tester) async {
        await _show(
          tester,
          CustomersHarness().app(
            const CustomerCardScreen(customerId: 'c1', tab: 'history'),
            size: w.size,
          ),
          w.size,
          scale: w.scale,
        );
        expect(_minMoneyFit(tester), greaterThanOrEqualTo(0.85));
      });
    }

    testWidgets('SCR-30 колонки по измеренной ширине: 600 — одна, 1024 × 1,3 — две, 1920 — три', (
      WidgetTester tester,
    ) async {
      Future<int> columns(Size size, double scale) async {
        await _show(tester, _dashboard().app(const CashierDashboardScreen(), size: size), size, scale: scale);
        for (final int n in <int>[1, 2, 3]) {
          if (find.byKey(ValueKey<String>('cashier-columns-$n')).evaluate().isNotEmpty) return n;
        }
        return 0;
      }

      expect(await columns(const Size(600, 960), 1), 1);
      expect(await columns(const Size(1024, 768), 1.3), 2);
      expect(await columns(const Size(1920, 1080), 1), 3);
    });

    testWidgets('«Сегодня»: тесно — плитки столбиком, суммы целиком', (WidgetTester tester) async {
      await _show(
        tester,
        _dashboard().app(const CashierDashboardScreen(), size: const Size(360, 780)),
        const Size(360, 780),
        scale: 1.3,
      );
      expect(find.byKey(ShiftSummaryCard.stackedKey), findsOneWidget);
      expect(_minMoneyFit(tester), greaterThanOrEqualTo(0.85));
    });

    testWidgets('TransactionRow: сумма шире доли строки — под заголовком, «›» у правого края', (
      WidgetTester tester,
    ) async {
      await _show(
        tester,
        _transactionsMany().app(const TransactionsScreen(), size: const Size(600, 960)),
        const Size(600, 960),
        scale: 1.3,
      );
      expect(find.byType(TransactionRow), findsWidgets);
      expect(_minMoneyFit(tester), greaterThanOrEqualTo(0.85));
    });
  });

  group('(7) SCR-40 «Избранное»: окно ≥ 1600 — обе вкладки не шире 1200 по центру', () {
    for (final ({RoleCode role, String name}) r in <({RoleCode role, String name})>[
      (role: RoleCode.cashier, name: 'с вкладкой «Клиенты»'),
      (role: RoleCode.seller, name: 'без вкладки «Клиенты»'),
    ]) {
      testWidgets('«Товары» ${r.name}: 1920 — 1200 по центру; 1366 — во всю ширину', (WidgetTester tester) async {
        final Finder row = find.byKey(const ValueKey<String>('favorites-product-p1'));
        await _show(
          tester,
          CustomersHarness(role: r.role).app(const FavoritesScreen(tab: 'products'), size: const Size(1920, 1080)),
          const Size(1920, 1080),
        );
        expect(find.byKey(const ValueKey<String>('ds-large-content')), findsWidgets);
        expect(row, findsOneWidget);
        expect(tester.getSize(row).width, closeTo(1200, 1));
        expect(tester.getCenter(row).dx, closeTo(960, 1));
        await _show(
          tester,
          CustomersHarness(role: r.role).app(const FavoritesScreen(tab: 'products'), size: const Size(1366, 900)),
          const Size(1366, 900),
        );
        expect(find.byKey(const ValueKey<String>('ds-large-content')), findsNothing);
        expect(tester.getSize(row).width, greaterThan(1200));
      });
    }
  });

  test('окна прогона: ширины 360…2560, окна масштаба страницы 67 %, 150 %, 200 %; текст 1 / 1,3 / 1,5', () {
    final Set<double> widths = <double>{for (final RespWindow w in kRespWindows) w.size.width};
    expect(widths, containsAll(<double>[360, 412, 600, 768, 1024, 1280, 1440, 1920, 2560, 960, 2866]));
    expect(kRespScales, <double>[1, 1.3, 1.5]);
    expect(kRespWideScaleLimit, inInclusiveRange(1.31, 1.5), reason: '1,5 — только в окнах уже 1024 (maxTextScaleFor)');
    expect(kRespWindows.where((RespWindow w) => w.size.width > w.size.height), isNotEmpty, reason: 'ландшафт');
    expect(kRespWindows.where((RespWindow w) => w.size.width < w.size.height), isNotEmpty, reason: 'портрет');
  });
}
