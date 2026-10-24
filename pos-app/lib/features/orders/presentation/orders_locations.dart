// Адреса переходов SCR-24/SCR-25 (02 SCR-24.6, SCR-25.6; navigation.md §3). Фича не импортирует
// app/router/routes.dart (AP-01: app — композиционный корень), поэтому адреса — строки тех же маршрутов
// (`OrderRoute`, `OrdersRoute`, `PaymentNewRoute`, `OrderCreatedRoute`, `ReturnNewRoute`, `CustomerRoute`, `CartRoute`,
// `ProductRoute`, `TransactionRoute`); сверка — test/features/orders/presentation/orders_locations_test.dart.
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// Маршруты переходов заказов.
abstract final class OrdersLocations {
  /// SCR-25 с фильтрами.
  static String orders(Map<String, String> query) =>
      Uri(path: '/orders', queryParameters: query.isEmpty ? null : query).toString();

  /// SCR-24.
  static String order(String orderId) => '/orders/${Uri.encodeComponent(orderId)}';

  /// SCR-38 приём оплаты по заказу.
  static String acceptPayment(String orderId) =>
      Uri(path: '/payments/new', queryParameters: <String, String>{'orderId': orderId}).toString();

  /// SCR-22 «Показать QR».
  static String showQr(String orderId, String paymentId) => Uri(
    path: '/orders/${Uri.encodeComponent(orderId)}/created',
    queryParameters: <String, String>{'paymentId': paymentId},
  ).toString();

  /// SCR-39 заявка на возврат.
  static String returnRequest(String orderId) =>
      Uri(path: '/returns/new', queryParameters: <String, String>{'orderId': orderId}).toString();

  /// SCR-37 транзакция платежа (UI-24-008; `Payment.transactionId`, OpenAPI 1.2.0) — `TransactionRoute`.
  static String transaction(String transactionId) => '/transactions/${Uri.encodeComponent(transactionId)}';

  /// SCR-32 карточка клиента.
  static String customer(String customerId) => '/customers/${Uri.encodeComponent(customerId)}';

  /// SCR-20 корзина.
  static const String cart = '/cart';

  /// Каталог (SCR-10) — «Создать заказ» в `EmptyState.orders` (expanded — с постоянной `CartPanel`).
  static const String catalog = '/catalog';

  /// SCR-14 карточка товара (тап по строке состава).
  static String product(String productId) => '/catalog/p/${Uri.encodeComponent(productId)}';
}

/// Переходы через go_router; без маршрутизатора (widget-тесты экрана) — no-op.
extension OrdersNavigation on BuildContext {
  /// `push` в текущей ветке; завершается при возврате на экран.
  Future<void> ordersPush(String location) async {
    final GoRouter? router = GoRouter.maybeOf(this);
    if (router != null) await router.push<void>(location);
  }

  /// `go` в ветку.
  void ordersGo(String location) => GoRouter.maybeOf(this)?.go(location);
}
