// Подписи, форматы и адреса переходов журнала SCR-36/SCR-37 (02 SCR-36.8, SCR-37.8; navigation.md §3). Фича не
// импортирует app/router/routes.dart (AP-01): адреса — строки маршрутов `TransactionsRoute`, `TransactionRoute`,
// `OrderRoute`, `PaymentNewRoute`, `ReturnNewRoute`, `ReturnRoute`, `CustomerRoute`, `AdminAuditRoute`.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/transaction.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/date_range_picker.dart' show DsBishkekTime;
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/components/transaction_row.dart';

/// Подписи журнала.
abstract final class TransactionsTexts {
  /// Вид операции (`transactions_kind_*`).
  static String kind(AppLocalizations l10n, TransactionKind? k) => switch (k) {
    TransactionKind.orderCreated => l10n.transactions_kind_order_created,
    TransactionKind.orderCancelled => l10n.transactions_kind_order_cancelled,
    TransactionKind.paymentReceived => l10n.transactions_kind_payment_received,
    TransactionKind.paymentVoided => l10n.transactions_kind_payment_voided,
    TransactionKind.refund => l10n.transactions_kind_refund,
    TransactionKind.discountOverride => l10n.transactions_kind_discount_override,
    TransactionKind.creditSaleApproved => l10n.transactions_kind_credit_sale_approved,
    TransactionKind.manualQrConfirm => l10n.transactions_kind_manual_qr_confirm,
    TransactionKind.returnRequested => l10n.transactions_kind_return_requested,
    null => '',
  };

  /// Группа статуса (`transactions_status_*`).
  static String status(AppLocalizations l10n, TransactionStatusGroup g) => switch (g) {
    TransactionStatusGroup.received => l10n.transactions_status_received,
    TransactionStatusGroup.pending => l10n.transactions_status_pending,
    TransactionStatusGroup.voided => l10n.transactions_status_voided,
    TransactionStatusGroup.returned => l10n.transactions_status_returned,
    TransactionStatusGroup.onecError => l10n.transactions_status_onec_error,
  };

  /// Вариант чипа группы статуса (иконка + текст, A11Y-004).
  static StatusChipVariant statusVariant(TransactionStatusGroup g) => switch (g) {
    TransactionStatusGroup.received => StatusChipVariant.success,
    TransactionStatusGroup.pending => StatusChipVariant.info,
    TransactionStatusGroup.voided => StatusChipVariant.neutral,
    TransactionStatusGroup.returned => StatusChipVariant.neutral,
    TransactionStatusGroup.onecError => StatusChipVariant.error,
  };

  /// Способ оплаты (`transactions_method_*`).
  static String method(AppLocalizations l10n, PaymentMethod m) => switch (m) {
    PaymentMethod.cash => l10n.transactions_method_cash,
    PaymentMethod.qrBakai => l10n.transactions_method_qr,
    PaymentMethod.credit => l10n.transactions_method_credit,
  };

  /// Чип статуса строки (`null` — группа неизвестна).
  static StatusChip? statusChip(AppLocalizations l10n, Transaction t, {bool dense = true}) {
    final TransactionStatusGroup? g = t.statusGroup;
    if (g == null) return null;
    return StatusChip(label: status(l10n, g), variant: statusVariant(g), dense: dense);
  }

  /// «Платёж получен № 1024».
  static String title(AppLocalizations l10n, Transaction t) {
    final String k = kind(l10n, t.kind);
    return k.isEmpty ? t.number : '$k № ${t.number}';
  }

  /// Знак суммы строки.
  static TransactionRowAmountTone tone(Transaction t) =>
      TransactionRow.toneOf(t.kind, plus: t.sign == null ? null : t.sign == TransactionSign.plus);

  /// «16 007,50 сом» (финансовый контекст — 2 знака).
  static String money(Money m) => PriceText.format(m, fixed2: true);

  /// Подзаголовок дня: «Сегодня» / «Вчера» / «18 октября».
  static String dayHeader(AppLocalizations l10n, DateTime utc, DateTime nowUtc, String locale) {
    final DateTime day = DsBishkekTime.startOfDayUtc(utc);
    final DateTime today = DsBishkekTime.startOfDayUtc(nowUtc);
    if (day == today) return l10n.transactions_period_today;
    if (day == today.subtract(const Duration(days: 1))) return l10n.transactions_period_yesterday;
    return DsBishkekTime.dayMonthLong(utc, locale);
  }

  /// Подпись для screen reader (03 §9.38).
  static String semantic(AppLocalizations l10n, Transaction t, String locale) => <String>[
    title(l10n, t),
    DsBishkekTime.dayMonthLong(t.occurredAt, locale),
    DsBishkekTime.time(t.occurredAt),
    TransactionRow.signed(money(t.amount), tone(t)),
    if (t.statusGroup != null) status(l10n, t.statusGroup!),
    ?t.customer?.displayName,
    ?t.actor?.displayName,
  ].join(', ');
}

/// Адреса переходов.
abstract final class TransactionsLocations {
  /// SCR-36 с фильтрами.
  static String list(Map<String, String> query) =>
      Uri(path: '/transactions', queryParameters: query.isEmpty ? null : query).toString();

  /// SCR-37.
  static String details(String id) => '/transactions/${Uri.encodeComponent(id)}';

  /// SCR-24.
  static String order(String id) => '/orders/${Uri.encodeComponent(id)}';

  /// SCR-38 по заказу.
  static String pay(String orderId) =>
      Uri(path: '/payments/new', queryParameters: <String, String>{'orderId': orderId}).toString();

  /// SCR-39 новая заявка.
  static String returnNew(String orderId) =>
      Uri(path: '/returns/new', queryParameters: <String, String>{'orderId': orderId}).toString();

  /// SCR-39 заявка.
  static String returnRequest(String id) => '/returns/${Uri.encodeComponent(id)}';

  /// SCR-32.
  static String customer(String id) => '/customers/${Uri.encodeComponent(id)}';

  /// SCR-47 с фильтром объекта.
  static String audit({required String entityType, required String entityId}) => Uri(
    path: '/admin/audit',
    queryParameters: <String, String>{'entityType': entityType, 'entityId': entityId},
  ).toString();
}

/// Переходы через go_router; без маршрутизатора (widget-тесты) — no-op.
extension TransactionsNavigation on BuildContext {
  /// `push`.
  Future<void> txPush(String location) async {
    final GoRouter? router = GoRouter.maybeOf(this);
    if (router != null) await router.push<void>(location);
  }

  /// `go`.
  void txGo(String location) => GoRouter.maybeOf(this)?.go(location);

  /// Назад к журналу (сохраняя фильтры — по стеку ветки).
  void txBack() {
    final GoRouter? router = GoRouter.maybeOf(this);
    if (router == null) {
      unawaited(Navigator.maybeOf(this)?.maybePop());
    } else if (router.canPop()) {
      router.pop();
    } else {
      router.go('/transactions');
    }
  }
}
