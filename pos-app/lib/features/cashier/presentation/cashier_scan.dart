// HID-скан на экранах кассы (02 п. 2.2.11; SCR-30 UI-30-019, AC-UI-30-009; SCR-38.12). Обработчик сканера —
// оболочка (`app/router/shells/app_shell.dart`, HidScanScope.onEvent): по текущему адресу она передаёт скан сюда,
// а не в поиск товара по штрихкоду каталога.
//
// * SCR-30 (вне полей ввода): код заказа (номер POS/1С) → `GET /orders?q=&status=…` (статусы к оплате, ядро §22.5) →
//   ровно один заказ → SCR-38 `?orderId=`; ноль, несколько или ошибка → лист «Найти заказ» UI-30-016 с введённым
//   значением. Только `cashier`, `senior_seller` (D-15); прочим ролям касса скан не перехватывает.
// * SCR-38: скан игнорируется, подсказка «Сканирование недоступно во время оплаты» (`payment_scan_disabled`).
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/features/cashier/cashier_providers.dart';
import 'package:optomstroy/features/cashier/presentation/cashier_format.dart';
import 'package:optomstroy/features/cashier/presentation/providers/cashier_ports.dart';
import 'package:optomstroy/features/cashier/presentation/widgets/cashier_sheets.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/orders_providers.dart';

/// Адрес относится к SCR-38 (финансовая форма: скан игнорируется).
bool isPaymentLocation(String path) => path == '/payments' || path.startsWith('/payments/');

/// SCR-38: подсказка `payment_scan_disabled` вместо действия скана.
void showPaymentScanDisabled(BuildContext context) =>
    AppSnackbar.show(context, message: AppLocalizations.of(context).payment_scan_disabled);

/// SCR-30: скан кода заказа [value] (UI-30-019). `false` — роль без приёма оплаты: скан не для кассы.
Future<bool> openOrderByScan(BuildContext context, WidgetRef ref, String value) async {
  if (!CashierRoles.canAcceptPayment(ref.read(cashierViewerRoleProvider))) return false;
  final String q = value.trim();
  final Result<OrdersPage> r = await ref
      .read(ordersRepositoryProvider)
      .list(OrdersQuery(q: q, statuses: kLookupPayableStatuses, limit: 2));
  if (!context.mounted) return true;
  final List<OrderSummary>? found = r.valueOrNull?.page.items;
  if (found != null && found.length == 1) {
    await context.cashierPush(CashierLocations.payOrder(found.single.id));
    return true;
  }
  final CashierLookupResult? picked = await showCashierLookup(
    context,
    initialQuery: q,
    debtTab: ref.read(debtPaymentsFromPosProvider),
  );
  if (!context.mounted || picked == null) return true;
  switch (picked) {
    case LookupOrder(:final String orderId):
      await context.cashierPush(CashierLocations.payOrder(orderId));
    case LookupCustomer(:final String customerId):
      await context.cashierPush(CashierLocations.payDebt(customerId));
  }
  return true;
}
