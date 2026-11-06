// Заявки с планшета магазина у сотрудника (P-002 §8.7 п. 3, п. 5, п. 7; ADR-115; 13 TAB-2-06; пакет WP-A10):
// T-KIOSK-026 (UI-часть: пометка «С планшета» SCR-24 и строк SCR-25, чип фильтра «С планшета»; SCR-30 — в
// test/features/cashier/awaiting_payment_kiosk_test.dart; уведомления и видимость ролей — pos-api
// test/kiosk/staff-view.spec.ts) и T-KIOSK-056 (подсказка кассиру при `single`, оплата не блокируется). Критерии 02:
// AC-UI-24-018, AC-UI-24-019, AC-UI-25-013; 03 AC-DS-104. Паритет: заказы `staff` и `customer` и режим покупателя —
// без пометок и подсказок. Данные синтетические (номера — тестовые +996 555 000 xxx).
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/category_chip.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/orders/data/repositories/dio_orders_repository.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/presentation/providers/orders_ports.dart';
import 'package:optomstroy/features/orders/presentation/screens/order_details_screen.dart';
import 'package:optomstroy/features/orders/presentation/screens/orders_screen.dart';
import 'package:optomstroy/features/orders/presentation/state/orders_filters.dart';

import '../../core/network/fake_adapter.dart';
import '../../support/f_fakes.dart';
import 'support/orders_harness.dart';

final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));

const ValueKey<String> _badge = ValueKey<String>('order-badge-kiosk');
const ValueKey<String> _chip = ValueKey<String>('orders-chip-kiosk');
const ValueKey<String> _pay = ValueKey<String>('action-pay');

/// Тестовый номер покупателя заявки (правило тестовых данных: +996 555 000 xxx).
const String _phone = '+996555000101';

/// Заказ SCR-24 с каналом [via] (заявка с планшета: получатель — покупатель с номером кода, без имени; 08 §4.25.2).
Order kioskOrder({
  OrderCreatedVia? via = OrderCreatedVia.kiosk,
  KioskCustomerMatch? match = KioskCustomerMatch.single,
  Receiver receiver = const Receiver(kind: ReceiverKind.customer, phoneE164: _phone),
  OrderStatus status = OrderStatus.awaitingPayment,
}) {
  final Order base = order(status: status);
  return Order(
    id: base.id,
    publicNumber: base.publicNumber,
    status: base.status,
    total: base.total,
    subtotal: base.subtotal,
    totalToPay: base.totalToPay,
    paymentMethod: PaymentMethod.cash,
    paidAmount: Money.zero,
    customer: base.customer,
    delivery: base.delivery,
    receiver: receiver,
    onecSyncState: base.onecSyncState,
    onec: base.onec,
    items: base.items,
    history: base.history,
    createdVia: via,
    kioskCustomerMatch: match,
  );
}

/// Строка списка с каналом [via].
OrderSummary kioskSummary(int n, {OrderCreatedVia? via = OrderCreatedVia.kiosk}) {
  final OrderSummary s = summary(n, status: OrderStatus.awaitingPayment);
  return OrderSummary(
    id: s.id,
    publicNumber: s.publicNumber,
    status: s.status,
    total: s.total,
    paymentMethod: s.paymentMethod,
    paidAmount: s.paidAmount,
    customer: s.customer,
    createdVia: via,
  );
}

Future<OrdersHarness> _openDetails(
  WidgetTester t,
  Order o, {
  RoleCode role = RoleCode.cashier,
  Size size = const Size(1366, 900),
}) async {
  final FakeOrdersRepository repo = FakeOrdersRepository()
    ..onGet = (String id, bool refresh) async =>
        Success<OrderDetails>(details(o, <OrderAction>{OrderAction.pay, OrderAction.cancel}));
  final OrdersHarness h = OrdersHarness(orders: repo, role: role);
  await h.pump(t, const OrderDetailsScreen(orderId: 'o1'), size: size);
  return h;
}

List<OrdersQuery> _queries(FakeOrdersRepository r) => <OrdersQuery>[
  for (final FakeCall c in r.calls)
    if (c.method == 'list') c.args.single! as OrdersQuery,
];

FakeOrdersRepository _listRepo(List<OrderSummary> items) {
  final FakeOrdersRepository repo = FakeOrdersRepository();
  repo.onList = (OrdersQuery q) async => Success<OrdersPage>(ordersPage(items, total: items.length, counts: kCounts));
  repo.onGet = (String id, bool refresh) async => Success<OrderDetails>(details(kioskOrder()));
  return repo;
}

/// Приложение с маршрутами `/orders` (SCR-25; фильтры — из query, как `OrdersRoute`: `createdVia` типизированный
/// маршрут не передаёт) и `/orders/:id` (SCR-24).
Widget _routedApp(OrdersHarness h, String initial, Size size) {
  final GoRouter router = GoRouter(
    initialLocation: initial,
    routes: <RouteBase>[
      GoRoute(
        path: '/orders',
        builder: (BuildContext c, GoRouterState s) => OrdersScreen(
          status: s.uri.queryParameters['status'],
          from: s.uri.queryParameters['from'],
          to: s.uri.queryParameters['to'],
          customerId: s.uri.queryParameters['customerId'],
          mine: s.uri.queryParameters['mine'],
        ),
        routes: <RouteBase>[
          GoRoute(
            path: ':id',
            builder: (BuildContext c, GoRouterState s) => OrderDetailsScreen(orderId: s.pathParameters['id']!),
          ),
        ],
      ),
    ],
  );
  return ProviderScope(
    // Новый контейнер на каждую обвязку: повторный `pump` в одном тесте не наследует состояние провайдеров.
    key: ObjectKey(h),
    overrides: h.overrides,
    child: MaterialApp.router(
      routerConfig: router,
      theme: AppTheme.light(),
      locale: const Locale('ru'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      debugShowCheckedModeBanner: false,
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true, size: size, padding: EdgeInsets.zero),
        child: child!,
      ),
    ),
  );
}

Future<void> _pumpRouted(WidgetTester t, OrdersHarness h, String initial, {Size size = const Size(390, 844)}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  addTearDown(t.view.reset);
  await t.pumpWidget(_routedApp(h, initial, size));
  await t.pumpAndSettle();
}

Uri _location(WidgetTester t) =>
    GoRouter.of(t.element(find.byType(Navigator).first)).routerDelegate.currentConfiguration.uri;

bool _chipSelected(WidgetTester t) => t.widget<CategoryChip>(find.byKey(_chip)).selected;

Future<void> _tap(WidgetTester t, Finder f) async {
  await t.tap(f);
  await t.pump();
  await t.pump();
}

void main() {
  group('SCR-24', () {
    testWidgets('T-KIOSK-026 · AC-UI-24-018 / AC-DS-104: у заявки с планшета в шапке — «С планшета» (StatusChip '
        'neutral, иконка tablet_android и текст); у заказов staff и customer пометки нет', (WidgetTester t) async {
      await _openDetails(t, kioskOrder());
      final Finder badge = find.byKey(_badge);
      expect(badge, findsOneWidget);
      final StatusChip chip = t.widget<StatusChip>(find.descendant(of: badge, matching: find.byType(StatusChip)));
      expect(chip.variant, StatusChipVariant.neutral);
      expect(chip.label, l10n.order_badge_kiosk);
      expect(chip.label, 'С планшета');
      expect(find.descendant(of: badge, matching: find.byIcon(Icons.tablet_android_rounded)), findsOneWidget);
      expect(
        find.descendant(of: badge, matching: find.text('С планшета')),
        findsOneWidget,
        reason: 'не только цвет',
      );
      expect(
        t.getTopLeft(badge).dy,
        closeTo(t.getTopLeft(find.byKey(const ValueKey<String>('order-status'))).dy, 1),
        reason: 'рядом со статусом UI-24-002',
      );

      for (final OrderCreatedVia? via in <OrderCreatedVia?>[OrderCreatedVia.staff, OrderCreatedVia.customer, null]) {
        await _openDetails(t, kioskOrder(via: via, match: null));
        expect(find.byKey(_badge), findsNothing, reason: 'createdVia=$via');
        expect(find.text('С планшета'), findsNothing, reason: 'createdVia=$via');
      }
    });

    testWidgets('T-KIOSK-056 · AC-UI-24-019: single — «Клиент найден по номеру: {name}. Спросите имя покупателя и '
        'сверьте с карточкой до оплаты» (info), «Принять оплату» доступна', (WidgetTester t) async {
      await _openDetails(t, kioskOrder());
      final Finder hint = find.byKey(const ValueKey<String>('order-kiosk-match-single'));
      expect(hint, findsOneWidget);
      final String text = l10n.order_kiosk_match_single_check(kCustomer.displayName!);
      expect(text, 'Клиент найден по номеру: ОсОО «СтройМир». Спросите имя покупателя и сверьте с карточкой до оплаты');
      expect(find.descendant(of: hint, matching: find.text(text)), findsOneWidget);
      final ErrorState banner = t.widget<ErrorState>(find.descendant(of: hint, matching: find.byType(ErrorState)));
      expect((banner.kind, banner.tone, banner.onClose), (ErrorStateKind.banner, ErrorStateTone.info, null));
      expect(find.textContaining(l10n.order_kiosk_match_repeat_hint), findsNothing);
      // Зона D: подсказка над клиентом UI-24-004.
      expect(t.getTopLeft(hint).dy, lessThan(t.getTopLeft(find.text(kCustomer.displayName!).last).dy));
      // Оплату система не запрещает (P-002 §8.7 п. 5: это инструкция, а не блокировка).
      expect(find.byKey(_pay), findsOneWidget);
      expect(t.widget<AppButton>(find.byKey(_pay)).onPressed, isNotNull);
    });

    testWidgets('AC-UI-24-019: ambiguous / none — текст итога и «Повторить заказ на карточку клиента» (warning); '
        '«Принять оплату» доступна; у customer подсказки и пометки нет', (WidgetTester t) async {
      final Map<KioskCustomerMatch, String> titles = <KioskCustomerMatch, String>{
        KioskCustomerMatch.ambiguous: 'Клиент не определён — выберите карточку',
        KioskCustomerMatch.none: 'Новый покупатель',
      };
      for (final MapEntry<KioskCustomerMatch, String> e in titles.entries) {
        await _openDetails(t, kioskOrder(match: e.key), size: kWindows['compact']!);
        final Finder hint = find.byKey(ValueKey<String>('order-kiosk-match-${e.key.value}'));
        await t.ensureVisible(hint);
        expect(hint, findsOneWidget, reason: '${e.key}');
        expect(find.descendant(of: hint, matching: find.textContaining(e.value)), findsOneWidget);
        expect(
          find.descendant(of: hint, matching: find.textContaining('Повторить заказ на карточку клиента')),
          findsOneWidget,
          reason: 'order_kiosk_match_repeat_hint',
        );
        final ErrorState banner = t.widget<ErrorState>(find.descendant(of: hint, matching: find.byType(ErrorState)));
        expect((banner.tone, banner.onClose), (ErrorStateTone.warning, null));
        expect(t.widget<AppButton>(find.byKey(_pay)).onPressed, isNotNull, reason: 'оплата не блокируется: ${e.key}');
      }

      // Покупатель видит свою заявку на подтверждённой карточке без служебных пометок (сервер ключа не шлёт; UI —
      // тоже не показывает).
      await _openDetails(t, kioskOrder(), role: RoleCode.customer);
      expect(find.byKey(_badge), findsNothing);
      expect(find.byKey(const ValueKey<String>('order-kiosk-match-single')), findsNothing);
      expect(find.textContaining('Спросите имя покупателя'), findsNothing);
      expect(find.textContaining('+996 555 000 101'), findsNothing);
    });

    testWidgets('UI-24-005: номер покупателя заявки — телефон получателя в «Получении»; после маскирования — '
        'receiver.phoneMasked; у заказа сотрудника строка получения прежняя', (WidgetTester t) async {
      await _openDetails(t, kioskOrder());
      expect(find.textContaining('+996 555 000 101'), findsOneWidget);

      await _openDetails(
        t,
        kioskOrder(
          receiver: const Receiver(kind: ReceiverKind.customer, phoneMasked: '+996 5** *** *01'),
        ),
      );
      expect(find.textContaining('+996 5** *** *01'), findsOneWidget);
      expect(find.textContaining('+996 555 000 101'), findsNothing);

      await _openDetails(t, kioskOrder(via: OrderCreatedVia.staff, match: null));
      expect(find.textContaining('+996 555 000 101'), findsNothing, reason: 'паритет: kind=customer без строки');
    });
  });

  group('SCR-25', () {
    testWidgets('T-KIOSK-026 · AC-UI-25-013: кассир — чип «С планшета» добавляет createdVia=kiosk, переводит «Мои» '
        'на «Все» и сочетается со статусом; повторный тап снимает фильтр', (WidgetTester t) async {
      final FakeOrdersRepository repo = _listRepo(<OrderSummary>[kioskSummary(1)]);
      await OrdersHarness(orders: repo, userId: 'cashier-7').pump(t, const OrdersScreen(mine: '1'));
      expect(find.byKey(_chip), findsOneWidget);
      expect(find.descendant(of: find.byKey(_chip), matching: find.text('С планшета')), findsOneWidget);
      expect(t.widget<CategoryChip>(find.byKey(_chip)).variant, CategoryChipVariant.filter);
      expect(_chipSelected(t), isFalse);
      expect((_queries(repo).single.createdVia, _queries(repo).single.createdBy), (null, 'cashier-7'));

      await _tap(t, find.byKey(_chip));
      expect(_chipSelected(t), isTrue);
      expect(_queries(repo).last.createdVia, OrderCreatedVia.kiosk);
      expect(_queries(repo).last.createdBy, isNull, reason: '«Мои / Все» → «Все»: автор заявок — планшет');
      expect(_queries(repo).last.cursor, isNull, reason: 'с первой страницы');

      await _tap(t, find.text('Ждут оплаты · 3'));
      expect(_queries(repo).last.statuses, <OrderStatus>{OrderStatus.awaitingPayment});
      expect(_queries(repo).last.createdVia, OrderCreatedVia.kiosk, reason: 'сочетается с чипами статусов');

      await _tap(t, find.byKey(_chip));
      expect(_chipSelected(t), isFalse);
      expect(_queries(repo).last.createdVia, isNull);

      // «Мои» при включённом чипе — чип снимается (заявки с планшета не бывают своими).
      await _tap(t, find.byKey(_chip));
      await _tap(t, find.byKey(const ValueKey<String>('orders-scope-mine')));
      expect(_chipSelected(t), isFalse);
      expect((_queries(repo).last.createdVia, _queries(repo).last.createdBy), (null, 'cashier-7'));
    });

    testWidgets('T-KIOSK-026 · AC-UI-25-013: чип сохраняется в адресе при возврате из SCR-24; ссылка '
        '/orders?createdVia=kiosk открывает список с фильтром', (WidgetTester t) async {
      final FakeOrdersRepository repo = _listRepo(<OrderSummary>[kioskSummary(1), kioskSummary(2)]);
      final OrdersHarness h = OrdersHarness(orders: repo);
      await _pumpRouted(t, h, '/orders');
      expect(_queries(repo).single.createdVia, isNull);
      await t.tap(find.byKey(_chip));
      await t.pumpAndSettle();
      expect(_location(t).queryParameters['createdVia'], 'kiosk');
      expect(_queries(repo).last.createdVia, OrderCreatedVia.kiosk);

      await t.tap(find.byKey(const ValueKey<String>('order-row-o2')));
      await t.pumpAndSettle();
      expect(find.byType(OrderDetailsScreen), findsOneWidget);
      GoRouter.of(t.element(find.byType(OrderDetailsScreen))).pop();
      await t.pumpAndSettle();
      expect(_location(t).queryParameters['createdVia'], 'kiosk', reason: 'адрес при возврате из SCR-24');
      expect(_chipSelected(t), isTrue);
      expect(_queries(repo).last.createdVia, OrderCreatedVia.kiosk, reason: 'обновление после возврата — с фильтром');

      final FakeOrdersRepository deep = _listRepo(<OrderSummary>[kioskSummary(1)]);
      await _pumpRouted(t, OrdersHarness(orders: deep), '/orders?createdVia=kiosk');
      expect(_queries(deep).first.createdVia, OrderCreatedVia.kiosk, reason: 'первый запрос — уже с фильтром');
      expect(_chipSelected(t), isTrue);
      await t.tap(find.byKey(_chip));
      await t.pumpAndSettle();
      expect(_location(t).queryParameters.containsKey('createdVia'), isFalse);
      expect(_queries(deep).last.createdVia, isNull);
    });

    testWidgets('AC-UI-25-013: у продавца (order.read.own) и покупателя чипа нет, createdVia из адреса не уходит', (
      WidgetTester t,
    ) async {
      for (final RoleCode role in <RoleCode>[RoleCode.seller, RoleCode.customer]) {
        final FakeOrdersRepository repo = _listRepo(<OrderSummary>[kioskSummary(1, via: OrderCreatedVia.staff)]);
        await _pumpRouted(t, OrdersHarness(orders: repo, role: role), '/orders?createdVia=kiosk');
        expect(find.byKey(_chip), findsNothing, reason: '$role');
        expect(_queries(repo).single.createdVia, isNull, reason: '$role');
      }
    });

    testWidgets('T-KIOSK-026 · UI-25-015: строки заявок — пометка «С планшета» рядом со статусом (compact, medium, '
        'expanded); у заказов staff/customer и у покупателя — нет', (WidgetTester t) async {
      final List<OrderSummary> items = <OrderSummary>[
        kioskSummary(1),
        kioskSummary(2, via: OrderCreatedVia.staff),
        kioskSummary(3, via: OrderCreatedVia.customer),
      ];
      for (final MapEntry<String, Size> w in kWindows.entries) {
        await OrdersHarness(orders: _listRepo(items)).pump(t, const OrdersScreen(), size: w.value);
        final Finder badge = find.byKey(const ValueKey<String>('order-row-kiosk-o1'));
        expect(badge, findsOneWidget, reason: w.key);
        expect(find.descendant(of: badge, matching: find.byIcon(Icons.tablet_android_rounded)), findsOneWidget);
        expect(
          find.descendant(of: badge, matching: find.text('С планшета')),
          findsOneWidget,
          reason: w.key,
        );
        expect(find.byKey(const ValueKey<String>('order-row-kiosk-o2')), findsNothing, reason: w.key);
        expect(find.byKey(const ValueKey<String>('order-row-kiosk-o3')), findsNothing, reason: w.key);
        expect(t.takeException(), isNull, reason: '${w.key}: строка без переполнения');
      }
      await OrdersHarness(orders: _listRepo(items), role: RoleCode.customer).pump(t, const OrdersScreen());
      expect(find.byKey(const ValueKey<String>('order-row-kiosk-o1')), findsNothing, reason: 'покупателю — нет');
    });

    test('фильтры: createdVia=kiosk — в query маршрута и обратно; иное значение — без фильтра; в запрос — только при '
        'order.read.all', () {
      final OrdersFilters f = OrdersFilters.fromRoute(nowUtc: kNow, createdVia: 'kiosk');
      expect(f.kioskOnly, isTrue);
      expect(f.toRouteQuery()['createdVia'], 'kiosk');
      expect(f.differsFromDefaults(kNow), isTrue, reason: 'пусто — «Ничего не найдено по выбранным фильтрам»');
      expect(OrdersFilters.fromRoute(nowUtc: kNow, createdVia: 'staff').kioskOnly, isFalse);
      expect(OrdersFilters.fromRoute(nowUtc: kNow).toRouteQuery().containsKey('createdVia'), isFalse);
      expect(f, isNot(OrdersFilters.fromRoute(nowUtc: kNow)));
      expect(f.toQuery(const OrdersViewer(role: RoleCode.cashier)).createdVia, OrderCreatedVia.kiosk);
      expect(f.toQuery(const OrdersViewer(role: RoleCode.seller)).createdVia, isNull);
    });

    test('DioOrdersRepository.list: createdVia=kiosk в GET /orders; без фильтра параметра нет', () async {
      final List<Map<String, String>> sent = <Map<String, String>>[];
      final FakeAdapter adapter = FakeAdapter((RequestOptions o) async {
        sent.add(o.uri.queryParameters);
        return json(200, <String, Object?>{'items': <Object?>[], 'nextCursor': null, 'hasMore': false});
      });
      final DioOrdersRepository repo = DioOrdersRepository(
        Dio(BaseOptions(baseUrl: 'http://pos.test/api/v1'))..httpClientAdapter = adapter,
      );
      await repo.list(const OrdersQuery(createdVia: OrderCreatedVia.kiosk));
      await repo.list(const OrdersQuery());
      expect(sent.first['createdVia'], 'kiosk');
      expect(sent.last.containsKey('createdVia'), isFalse);
    });
  });
}
