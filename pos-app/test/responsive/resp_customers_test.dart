// T-UI-117: прогон адаптивности экранов клиентов и возвратов — SCR-31 «Поиск клиентов», SCR-32 «Карточка клиента»,
// SCR-33 «История покупок», SCR-34 «Долги и взаиморасчёты» (после step-up), SCR-35 «Скидки и условия», SCR-40
// «Избранное» (вкладка «Клиенты»), SCR-39 «Заявка на возврат» (черновик и отправленная) — по окнам 360…2560
// (портрет и ландшафт, окна масштаба страницы веб-демо) при масштабе текста 1 и 1,3: без переполнения и недоступных
// элементов (03 §8.8; указание владельца 2026-11-18, 15 §5.8 (3)). Данные — как у эталонов; деньги — целые тыйыны.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/repositories/customer_directory_repository.dart';
import 'package:optomstroy/features/customers/presentation/screens/customer_card_screen.dart';
import 'package:optomstroy/features/customers/presentation/screens/customer_discounts_screen.dart';
import 'package:optomstroy/features/customers/presentation/screens/customer_history_screen.dart';
import 'package:optomstroy/features/customers/presentation/screens/customer_receivables_screen.dart';
import 'package:optomstroy/features/customers/presentation/screens/customers_search_screen.dart';
import 'package:optomstroy/features/favorites/presentation/screens/favorites_screen.dart';
import 'package:optomstroy/features/returns/domain/entities/return_request.dart';
import 'package:optomstroy/features/returns/presentation/screens/return_request_screen.dart';

import '../features/customers/support/customers_harness.dart';
import '../features/returns/support/returns_harness.dart';
import '../support/responsive_audit.dart';

CustomersHarness _search() {
  final CustomersHarness h = CustomersHarness();
  h.directory.onList = (CustomersListQuery q) async => Success<PageResult<Customer>>(
    PageResult<Customer>(
      items: <Customer>[
        cashierCustomer(favorite: true),
        cashierCustomer(id: 'c2', name: 'ИП Бакытов Нурлан', favorite: true, overdue: false),
        cashierCustomer(id: 'c3', name: 'Сантехмонтаж ОсОО', favorite: true, hasDebt: false, overdue: false),
        cashierCustomer(
          id: 'c4',
          name: 'Асанова Айгуль',
          favorite: true,
          hasDebt: false,
          overdue: false,
          onecStatus: CustomerOnecStatus.pending,
        ),
      ],
    ),
  );
  return h;
}

ReturnsHarness _draft() => ReturnsHarness()
  ..returns.onGet = ((String id) async => Success<ReturnRequest>(
    returnRequest(
      items: const <ReturnRequestItem>[
        ReturnRequestItem(
          orderLineNo: 1,
          variantId: 'v1',
          quantity: LineQuantity(value: Qty(1000), unitId: 'pcs'),
          maxReturnable: Qty(2000),
          amount: Money(235000),
        ),
        ReturnRequestItem(
          orderLineNo: 3,
          variantId: 'v3',
          quantity: LineQuantity(value: Qty(5000), unitId: 'm'),
          amount: Money(55000),
        ),
      ],
    ),
  ));

ReturnsHarness _submitted() =>
    ReturnsHarness(role: RoleCode.seniorSeller, userId: 'u9')
      ..returns.onGet = ((String id) async =>
          Success<ReturnRequest>(returnRequest(status: ReturnRequestStatus.submitted)));

Future<void> _frames(WidgetTester tester, Size size) async {
  for (int i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  setUpAll(() => EditableText.debugDeterministicCursor = true);
  tearDownAll(() => EditableText.debugDeterministicCursor = false);

  final Map<String, RespBuild> scenes = <String, RespBuild>{
    'scr31_customers': (Size s, double _) => _search().app(const CustomersSearchScreen(), size: s),
    'scr32_customer': (Size s, double _) => CustomersHarness().app(const CustomerCardScreen(customerId: 'c1'), size: s),
    'scr33_history': (Size s, double _) =>
        CustomersHarness().app(const CustomerHistoryScreen(customerId: 'c1'), size: s),
    'scr34_receivables': (Size s, double _) =>
        (CustomersHarness()..grantDetail()).app(const CustomerReceivablesScreen(customerId: 'c1'), size: s),
    'scr35_discounts': (Size s, double _) =>
        CustomersHarness().app(const CustomerDiscountsScreen(customerId: 'c1'), size: s),
    'scr40_favorites': (Size s, double _) => CustomersHarness().app(const FavoritesScreen(tab: 'customers'), size: s),
    // Вкладка «Товары» SCR-40: окно ≥ 1600 — не шире 1200 по центру, как «Клиенты» (03 §8.8).
    'scr40_favorites_products': (Size s, double _) =>
        CustomersHarness().app(const FavoritesScreen(tab: 'products'), size: s),
    'scr39_return_draft': (Size s, double _) => _draft().app(const ReturnRequestScreen(returnId: 'r1'), size: s),
    'scr39_return_submitted': (Size s, double _) =>
        _submitted().app(const ReturnRequestScreen(returnId: 'r1'), size: s),
  };

  for (final MapEntry<String, RespBuild> scene in scenes.entries) {
    testWidgets('T-UI-117 ${scene.key}: окна 360…2560 × текст 1 / 1,3', (WidgetTester tester) async {
      final RespAudit audit = RespAudit(scene.key);
      await audit.run(tester, scene.value, settle: _frames);
      audit.expectNoBlocking();
    });
  }
}
