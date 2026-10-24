// Переходы экранов клиентов (02 SCR-31.6, SCR-32.6, SCR-33.6, SCR-34.6; navigation.md): пути — строками маршрутов
// `app/router/routes.dart` (компонент фичи не импортирует app/). Без GoRouter (виджет-тест без роутера) переходы
// игнорируются. ПДн в URL не попадают: номер для SCR-26 — только [customerNewPrefillProvider].
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// Пути и переходы.
abstract final class CustomersNav {
  static String _id(String id) => Uri.encodeComponent(id);

  /// `/customers/{id}`.
  static String cardPath(String id, {String? tab}) =>
      '/customers/${_id(id)}${tab == null ? '' : '?tab=${Uri.encodeQueryComponent(tab)}'}';

  /// Карточка: compact — `push` в ветке, иначе `go`.
  static void openCard(BuildContext context, String id, {bool push = true}) {
    final GoRouter? r = GoRouter.maybeOf(context);
    if (r == null) return;
    if (push) {
      unawaited(r.push<void>(cardPath(id)));
    } else {
      r.go(cardPath(id));
    }
  }

  /// Вкладка карточки на expanded — `go` с заменой `?tab=` (без новой записи истории).
  static void selectTab(BuildContext context, String id, String tab) =>
      GoRouter.maybeOf(context)?.go(cardPath(id, tab: tab));

  /// SCR-33 / SCR-34 / SCR-35 (compact — `push`).
  static void openSection(BuildContext context, String id, String section) =>
      unawaited(GoRouter.maybeOf(context)?.push<void>('/customers/${_id(id)}/$section'));

  /// SCR-26 (`push` на корне); результат — ID созданного или выбранного клиента.
  static Future<String?> newCustomer(BuildContext context) async {
    final GoRouter? r = GoRouter.maybeOf(context);
    if (r == null) return null;
    return r.push<String>('/customers/new');
  }

  /// SCR-24 заказа (`go` в ветку Заказы).
  static void openOrder(BuildContext context, String orderId) =>
      GoRouter.maybeOf(context)?.go('/orders/${_id(orderId)}');

  /// SCR-37 операции (`go` в ветку Транзакции).
  static void openTransaction(BuildContext context, String transactionId) =>
      GoRouter.maybeOf(context)?.go('/transactions/${_id(transactionId)}');

  /// SCR-38 «Принять оплату по долгу» (`push` на корне).
  static void acceptDebtPayment(BuildContext context, String customerId) => unawaited(
    GoRouter.maybeOf(context)?.push<void>('/payments/new?customerId=${Uri.encodeQueryComponent(customerId)}'),
  );

  /// SCR-45 «Привязки» (admin).
  static void resolveLinks(BuildContext context) => GoRouter.maybeOf(context)?.go('/admin/users?tab=links');

  /// SCR-31 (корень ветки Клиенты).
  static void toList(BuildContext context) => GoRouter.maybeOf(context)?.go('/customers');

  /// Назад: `pop`, иначе — корень ветки.
  static void back(BuildContext context) {
    final GoRouter? r = GoRouter.maybeOf(context);
    if (r != null && r.canPop()) {
      r.pop();
    } else if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      toList(context);
    }
  }
}
