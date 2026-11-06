// SCR-30 «Ожидают оплаты» и заявки с планшета магазина (P-002 §8.7 п. 5; ADR-115 п. 24; 13 TAB-2-06; пакет WP-A10):
// T-KIOSK-026 (UI-часть SCR-30: пометка «С планшета» UI-30-020, тап → SCR-38), AC-UI-30-023 (фильтр блока по складу
// кассы — на сервере: pos-api test/kiosk/staff-view.spec.ts, T-KIOSK-027), 03 AC-DS-104. Паритет: строки заказов
// `staff`, `customer` и без канала — прежние (только чип статуса), роли просмотра — без перехода.
import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/awaiting_payment_list.dart';
import 'package:optomstroy/design_system/components/order_status_chip.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/features/cashier/domain/entities/pos_dashboard.dart';
import 'package:optomstroy/features/cashier/presentation/screens/cashier_dashboard_screen.dart';
import 'package:optomstroy/features/cashier/presentation/widgets/dashboard_sections.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';

import 'support/cashier_harness.dart';

final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));

/// Строка «Ожидают оплаты» с каналом [via] (заявка с планшета — обычный заказ дня с открытым платежом `cash`).
OrderSummary _row(String id, int n, OrderCreatedVia? via) {
  final OrderSummary base = awaiting(id, n);
  return OrderSummary(
    id: base.id,
    publicNumber: base.publicNumber,
    status: base.status,
    total: base.total,
    totalToPay: base.totalToPay,
    paidAmount: base.paidAmount,
    paymentMethod: base.paymentMethod,
    customer: base.customer,
    createdAt: base.createdAt,
    createdVia: via,
  );
}

final List<OrderSummary> _rows = <OrderSummary>[
  _row('o1', 123, OrderCreatedVia.kiosk),
  _row('o2', 124, OrderCreatedVia.staff),
  _row('o3', 125, OrderCreatedVia.customer),
  _row('o4', 126, null),
];

CashierHarness _h({RoleCode role = RoleCode.cashier}) {
  final CashierHarness h = CashierHarness(role: role);
  h.cashier.onDashboard = () async => Success<PosDashboard>(dashboard(awaitingPayment: _rows));
  return h;
}

void main() {
  testWidgets('T-KIOSK-026 · AC-UI-30-023: заявка с планшета в «Ожидают оплаты» — «С планшета» (иконка и текст) '
      'рядом со статусом; тап → SCR-38 ?orderId=', (WidgetTester t) async {
    final CashierHarness h = _h();
    await h.pumpRouter(t, '/cashier', (_) => const CashierDashboardScreen());
    expect(find.text('Ожидают оплаты · 4'), findsOneWidget);
    final Finder badge = find.byKey(const ValueKey<String>('awaiting-kiosk-o1'));
    expect(badge, findsOneWidget);
    final StatusChip chip = t.widget<StatusChip>(badge);
    expect(
      (chip.label, chip.variant, chip.icon),
      ('С планшета', StatusChipVariant.neutral, Icons.tablet_android_rounded),
    );
    final Finder row = find.byKey(const ValueKey<String>('awaiting-o1'));
    expect(find.descendant(of: row, matching: badge), findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.byType(OrderStatusChip)),
      findsOneWidget,
      reason: 'статус остаётся',
    );
    for (final String id in <String>['o2', 'o3', 'o4']) {
      expect(find.byKey(ValueKey<String>('awaiting-kiosk-$id')), findsNothing, reason: id);
    }
    await t.ensureVisible(row);
    await t.tap(row);
    await CashierHarness.settle(t);
    expect(h.visited.single, '/payments/new?orderId=o1', reason: 'строка, как прочие, ведёт на SCR-38');
  });

  testWidgets('T-KIOSK-026: пометка видна на compact и диктору (не только цветом); admin — просмотр без перехода', (
    WidgetTester t,
  ) async {
    final SemanticsHandle semantics = t.ensureSemantics();
    await _h().pump(t, const CashierDashboardScreen(), size: kWindows['compact']!);
    final Finder badge = find.byKey(const ValueKey<String>('awaiting-kiosk-o1'));
    await t.ensureVisible(badge);
    expect(badge, findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('С планшета')), findsOneWidget);
    expect(t.takeException(), isNull, reason: 'строка compact без переполнения');
    semantics.dispose();

    final CashierHarness admin = _h(role: RoleCode.admin);
    await admin.pumpRouter(t, '/cashier', (_) => const CashierDashboardScreen());
    expect(find.byKey(const ValueKey<String>('awaiting-kiosk-o1')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey<String>('awaiting-o1')));
    await CashierHarness.settle(t);
    expect(admin.visited, isEmpty);
  });

  test(
    'паритет UI-30-004: у заказов staff, customer и без канала — прежний чип статуса; у заявки — статус и пометка',
    () {
      final List<AwaitingPaymentEntry> entries = awaitingEntries(
        l10n,
        dashboard(awaitingPayment: _rows),
        kNow,
        onTap: (OrderSummary o) {},
      );
      expect(entries.map((AwaitingPaymentEntry e) => e.id), <String>['o1', 'o2', 'o3', 'o4']);
      expect(entries.first.status, isA<Wrap>());
      final Wrap wrap = entries.first.status! as Wrap;
      expect(wrap.children.first, isA<OrderStatusChip>());
      expect((wrap.children.last as StatusChip).label, l10n.order_badge_kiosk);
      for (final AwaitingPaymentEntry e in entries.skip(1)) {
        expect(e.status, isA<OrderStatusChip>(), reason: e.id);
        expect(e.note, isNull, reason: e.id);
        expect(e.amountText, fmt(1600750), reason: e.id);
      }
      expect(entries.first.amountText, fmt(1600750));
      expect(entries.first.title, 'POS-2026-000123 · ОсОО «СтройМир»');
    },
  );
}
