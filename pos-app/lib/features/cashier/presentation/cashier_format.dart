// Форматирование, роли и адреса переходов экранов кассира SCR-30, SCR-38 (02 §0.1, §4.1; navigation.md §3).
// Фича не импортирует app/router/routes.dart (AP-01), поэтому адреса — строки тех же маршрутов (`CashierRoute`,
// `PaymentNewRoute`, `TransactionsRoute`, `TransactionRoute`, `CustomersRoute`, `CustomerRoute`,
// `CustomerReceivablesRoute`, `CustomerDiscountsRoute`, `CustomerNewRoute`, `ParkedRoute`, `FavoritesRoute`,
// `ReturnNewRoute`, `OrderRoute`, `SyncRoute`, `NotificationsRoute`). Деньги — `PriceText.format` (тыйыны, D-19).
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/date_range_picker.dart';
import 'package:optomstroy/design_system/components/price_text.dart';

/// Деньги и время кассы.
abstract final class CashierFormat {
  /// «16 007,50 сом» (финансовый контекст — всегда 2 знака).
  static String money(Money m) => PriceText.format(m, fixed2: true);

  /// «09:41» (Бишкек).
  static String time(DateTime utc) => DsBishkekTime.time(utc);

  /// Метка данных: сегодня — время, иначе дата и время.
  static String stamp(DateTime utc, DateTime nowUtc) => DsBishkekTime.stamp(utc, nowUtc);

  /// Календарная дата (`paymentDueDate`) без сдвига пояса: «22.10.2026».
  static String plainDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

  /// Процент «5 %» / «2,5 %».
  static String percent(Percent p) {
    final int whole = p.hundredths ~/ 100;
    final int frac = p.hundredths % 100;
    if (frac == 0) return '$whole %';
    final String f = frac.toString().padLeft(2, '0');
    return '$whole,${f.endsWith('0') ? f.substring(0, 1) : f} %';
  }

  /// Остаток времени «14:32» (мм:сс; ≥ 1 ч — «1:04:10»).
  static String countdown(Duration d) {
    final Duration v = d.isNegative ? Duration.zero : d;
    final int h = v.inHours;
    final String mm = (v.inMinutes % 60).toString().padLeft(2, '0');
    final String ss = (v.inSeconds % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  /// Подпись роли (`role_*`).
  static String role(AppLocalizations l10n, RoleCode r) => switch (r) {
    RoleCode.seller => l10n.role_seller,
    RoleCode.cashier => l10n.role_cashier,
    RoleCode.seniorSeller => l10n.role_senior_seller,
    RoleCode.admin => l10n.role_admin,
    RoleCode.owner => l10n.role_owner,
    RoleCode.customer => l10n.role_customer,
    RoleCode.integration => l10n.role_integration,
  };
}

/// Права экранов кассира по роли (11 §4.4; 02 SCR-30.10, SCR-38.10). Сервер проверяет независимо (CASH-001).
abstract final class CashierRoles {
  /// Подпись роли для шапки «Имя · Кассир» (`role_<code>`, 03 §16.2).
  static String label(AppLocalizations l10n, RoleCode? r) => switch (r) {
    RoleCode.seller => l10n.role_seller,
    RoleCode.cashier => l10n.role_cashier,
    RoleCode.seniorSeller => l10n.role_senior_seller,
    RoleCode.admin => l10n.role_admin,
    RoleCode.owner => l10n.role_owner,
    RoleCode.customer => l10n.role_customer,
    RoleCode.integration || null => '',
  };

  /// Кассовые действия: «Принять оплату», лист поиска заказа, скан HID, строки «Ожидают оплаты» (D-15).
  static bool canAcceptPayment(RoleCode? r) => r == RoleCode.cashier || r == RoleCode.seniorSeller;

  /// Режим просмотра дашборда (`admin`, `owner`).
  static bool viewOnly(RoleCode? r) => r == RoleCode.admin || r == RoleCode.owner;

  /// Блок «Избранные клиенты» и его изменение (`favorites.customers.manage`; у `owner` блока нет — FAV-006).
  static bool canManageFavorites(RoleCode? r) =>
      r == RoleCode.cashier || r == RoleCode.seniorSeller || r == RoleCode.admin;

  /// Чип «Новый клиент» (`customer.create`; `owner` — нет).
  static bool canCreateCustomer(RoleCode? r) =>
      r == RoleCode.cashier || r == RoleCode.seniorSeller || r == RoleCode.admin;

  /// Чип «Заявка на возврат» на дашборде (cashier, senior_seller; admin — через SCR-24/37).
  static bool canStartReturn(RoleCode? r) => canAcceptPayment(r);

  /// Чип «Отложенные» (корзина; `owner` — нет).
  static bool canOpenParked(RoleCode? r) => canAcceptPayment(r);

  /// Ручное подтверждение QR и аннулирование неполученного платежа (S!; 11 §4.4).
  static bool canConfirmManual(RoleCode? r) => canAcceptPayment(r);
}

/// Адреса переходов SCR-30/SCR-38.
abstract final class CashierLocations {
  /// SCR-30.
  static const String dashboard = '/cashier';

  /// SCR-10.
  static const String catalog = '/catalog';

  /// SCR-41 «Профиль».
  static const String profile = '/profile';

  /// SCR-42 «Настройки».
  static const String settings = '/settings';

  /// SCR-38 по заказу.
  static String payOrder(String orderId, {PaymentMethod? method}) => Uri(
    path: '/payments/new',
    queryParameters: <String, String>{'orderId': orderId, 'method': ?method?.value},
  ).toString();

  /// SCR-38 по долгу (RM-G-013; в R1 закрыто флагом).
  static String payDebt(String customerId) =>
      Uri(path: '/payments/new', queryParameters: <String, String>{'customerId': customerId}).toString();

  /// SCR-31.
  static String customers(String q) => Uri(path: '/customers', queryParameters: <String, String>{'q': q}).toString();

  /// SCR-32.
  static String customer(String id) => '/customers/${Uri.encodeComponent(id)}';

  /// SCR-34.
  static String receivables(String id) => '/customers/${Uri.encodeComponent(id)}/receivables';

  /// SCR-35.
  static String discounts(String id) => '/customers/${Uri.encodeComponent(id)}/discounts';

  /// SCR-26 (без query — navigation.md §3).
  static const String newCustomer = '/customers/new';

  /// SCR-23.
  static const String parked = '/cart/parked';

  /// SCR-40 «Клиенты».
  static const String favoriteCustomers = '/favorites?tab=customers';

  /// SCR-39.
  static String returnNew(String orderId) =>
      Uri(path: '/returns/new', queryParameters: <String, String>{'orderId': orderId}).toString();

  /// SCR-24.
  static String order(String orderId) => '/orders/${Uri.encodeComponent(orderId)}';

  /// SCR-36 с фильтрами (`from`, `to` — ISO-8601).
  static String transactions({DateTime? from, DateTime? to, String? kind, String? paymentMethod}) => Uri(
    path: '/transactions',
    queryParameters: <String, String>{
      'from': ?from?.toUtc().toIso8601String(),
      'to': ?to?.toUtc().toIso8601String(),
      'kind': ?kind,
      'paymentMethod': ?paymentMethod,
    },
  ).toString();

  /// SCR-37.
  static String transaction(String id) => '/transactions/${Uri.encodeComponent(id)}';

  /// SCR-43.
  static String sync({String? entity}) =>
      Uri(path: '/sync', queryParameters: <String, String>{'entity': ?entity}).toString();

  /// SCR-44.
  static const String notifications = '/notifications';
}

/// Переходы через go_router; без маршрутизатора (widget-тесты экрана) — no-op.
extension CashierNavigation on BuildContext {
  /// `push` (root-маршруты SCR-38, SCR-39, SCR-26).
  Future<void> cashierPush(String location) async {
    final GoRouter? router = GoRouter.maybeOf(this);
    if (router != null) await router.push<void>(location);
  }

  /// `go` в ветку.
  void cashierGo(String location) => GoRouter.maybeOf(this)?.go(location);

  /// Закрыть root-экран (SCR-38 «Готово»): `pop`, иначе — на дашборд.
  void cashierClose() {
    final GoRouter? router = GoRouter.maybeOf(this);
    if (router == null) {
      unawaited(Navigator.maybeOf(this)?.maybePop());
      return;
    }
    if (router.canPop()) {
      router.pop();
    } else {
      router.go(CashierLocations.dashboard);
    }
  }
}
