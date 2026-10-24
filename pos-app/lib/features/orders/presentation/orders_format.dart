// Форматирование значений SCR-24/SCR-25: время Бишкека (UTC+6, без перехода на летнее время — 02 UI-25-004),
// количества (`Qty`, milli) и деньги (`Money`, тыйыны — `PriceText.format`, D-19). Подписи — только ARB:
// [OrdersTexts] собирает подписи SCR-24/25: ключи этапа F (03 §16.8, FQ-FEORD-01 закрыт) и общие тексты 02 §7.
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/order_status_chip.dart';
import 'package:optomstroy/design_system/components/price_text.dart';

/// Время Бишкека и деньги для заказов.
abstract final class OrdersFormat {
  /// Смещение Asia/Bishkek (UTC+6 круглый год).
  static const Duration bishkekOffset = Duration(hours: 6);

  /// Момент [utc] на «стенных часах» Бишкека (поля `year…minute` — местные; `isUtc` остаётся `true`).
  static DateTime wall(DateTime utc) => utc.toUtc().add(bishkekOffset);

  /// Полночь Бишкека дня [utc] (в UTC).
  static DateTime startOfDayUtc(DateTime utc) {
    final DateTime w = wall(utc);
    return DateTime.utc(w.year, w.month, w.day).subtract(bishkekOffset);
  }

  static String _pad2(int v) => v.toString().padLeft(2, '0');

  /// «22.10.2026».
  static String date(DateTime utc) {
    final DateTime w = wall(utc);
    return '${_pad2(w.day)}.${_pad2(w.month)}.${w.year}';
  }

  /// «09:41».
  static String time(DateTime utc) {
    final DateTime w = wall(utc);
    return '${_pad2(w.hour)}:${_pad2(w.minute)}';
  }

  /// «22.10.2026 09:41».
  static String dateTime(DateTime utc) => '${date(utc)} ${time(utc)}';

  /// Календарная дата без времени (`format: date`, напр. `desiredDate`, `paymentDueDate`) — без сдвига пояса.
  static String plainDate(DateTime d) => '${_pad2(d.day)}.${_pad2(d.month)}.${d.year}';

  /// «22.10» (короткая дата периода).
  static String shortDate(DateTime utc) {
    final DateTime w = wall(utc);
    return '${_pad2(w.day)}.${_pad2(w.month)}';
  }

  /// Метка времени данных: сегодня — «09:41», иначе — «22.10.2026 09:41».
  static String stamp(DateTime utc, DateTime nowUtc) =>
      startOfDayUtc(utc) == startOfDayUtc(nowUtc) ? time(utc) : dateTime(utc);

  /// Сумма «16 007,50 сом» (финансовый контекст — всегда 2 знака, Q-108).
  static String money(Money m) => PriceText.format(m, fixed2: true);

  /// Сумма без валюты «16 007,50».
  static String amount(Money m) => PriceText.formatAmount(m, fixed2: true);

  /// Количество «12», «2,5», «0,125» (без лишних нулей).
  static String qty(Qty q) {
    final int abs = q.milli.abs();
    final String whole = (abs ~/ 1000).toString();
    String frac = (abs % 1000).toString().padLeft(3, '0');
    while (frac.endsWith('0')) {
      frac = frac.substring(0, frac.length - 1);
    }
    return '${q.milli < 0 ? '−' : ''}$whole${frac.isEmpty ? '' : ',$frac'}';
  }

  /// Процент «5» / «2,5».
  static String percent(Percent p) {
    final int whole = p.hundredths ~/ 100;
    final int frac = p.hundredths % 100;
    if (frac == 0) return '$whole';
    final String f = frac.toString().padLeft(2, '0');
    return '$whole,${f.endsWith('0') ? f.substring(0, 1) : f}';
  }
}

/// Подписи, общие для SCR-24/25. Ключи этапа F (03 §16.8, FQ-FEORD-01) — `order_section_*`, `orders_col_*`,
/// `order_cancel_keep`, `order_doc_waybill`; остальные — общие тексты 02 §7 с тем же смыслом.
abstract final class OrdersTexts {
  /// Статус платежа для клиента-покупателя (10 CUST-024, 12 T-PAY-042 (5)): `manual_confirm` — «Оплата проверяется
  /// магазином» без причины разбора. Ключа с этим текстом в 02 §7 нет (GQ-FECM-01) — временно нейтральный
  /// `ds_idempotency_pending` («Статус операции уточняется»), без «подтверждён вручную» и причин разбора для персонала.
  static String customerPaymentStatus(AppLocalizations l10n, PaymentStatus s) => switch (s) {
    PaymentStatus.manualConfirm => l10n.ds_idempotency_pending,
    _ => PaymentStatusChip.labelOf(l10n, s),
  };

  /// Способ оплаты.
  static String paymentMethod(AppLocalizations l10n, PaymentMethod m) => switch (m) {
    PaymentMethod.cash => l10n.payment_method_cash,
    PaymentMethod.qrBakai => l10n.payment_method_qr,
    PaymentMethod.credit => l10n.payment_method_credit,
  };

  /// «История статусов» (UI-24-003).
  static String sectionHistory(AppLocalizations l10n) => l10n.order_section_history;

  /// «Клиент».
  static String sectionCustomer(AppLocalizations l10n) => l10n.checkout_section_customer;

  /// «Получение товара».
  static String sectionDelivery(AppLocalizations l10n) => l10n.checkout_section_delivery;

  /// «Состав заказа».
  static String sectionItems(AppLocalizations l10n) => l10n.checkout_section_items;

  /// «Платежи» (UI-24-008).
  static String sectionPayments(AppLocalizations l10n) => l10n.order_section_payments;

  /// «Документы» (UI-24-009).
  static String sectionDocuments(AppLocalizations l10n) => l10n.order_section_documents;

  /// «Самовывоз» / «Доставка».
  static String pickup(AppLocalizations l10n) => l10n.checkout_pickup_title;

  /// «Доставка».
  static String delivery(AppLocalizations l10n) => l10n.checkout_delivery_title;

  /// «Сумма без скидки».
  static String subtotal(AppLocalizations l10n) => l10n.checkout_summary_subtotal;

  /// «Скидка клиента (из 1С)».
  static String customerDiscount(AppLocalizations l10n) => l10n.checkout_summary_customer_discount;

  /// «Скидка ({percent} %)».
  static String discount(AppLocalizations l10n, Percent? p) =>
      l10n.checkout_summary_discount(p == null ? '0' : OrdersFormat.percent(p));

  /// «Итого».
  static String total(AppLocalizations l10n) => l10n.cart_summary_total;

  /// «Счёт на оплату».
  static String invoice(AppLocalizations l10n) => l10n.checkout_print_invoice;

  /// «PDF, A4; печать после получения номера 1С».
  static String invoiceHint(AppLocalizations l10n) => l10n.checkout_print_invoice_hint;

  /// «Товарный чек».
  static String receipt(AppLocalizations l10n) => l10n.checkout_print_receipt;

  /// «Не является фискальным документом, 80 мм».
  static String receiptHint(AppLocalizations l10n) => l10n.checkout_print_receipt_hint;

  /// «Накладная» (UI-24-009).
  static String waybill(AppLocalizations l10n) => l10n.order_doc_waybill;

  /// Поле причины в диалоге отмены — «Причина».
  static String reason(AppLocalizations l10n) => l10n.audit_reason;

  /// «Не отменять» — безопасная кнопка диалога отмены (UI-24-017).
  static String keepOrder(AppLocalizations l10n) => l10n.order_cancel_keep;

  /// Колонки таблицы SCR-25 (expanded): «№».
  static String colNumber(AppLocalizations l10n) => l10n.orders_col_number;

  /// «Дата».
  static String colDate(AppLocalizations l10n) => l10n.orders_col_date;

  /// «Клиент».
  static String colCustomer(AppLocalizations l10n) => l10n.orders_col_customer;

  /// «Сумма».
  static String colAmount(AppLocalizations l10n) => l10n.orders_col_total;

  /// «Оплачено».
  static String colPaid(AppLocalizations l10n) => l10n.orders_col_paid;

  /// «Статус».
  static String colStatus(AppLocalizations l10n) => l10n.orders_col_status;

  /// Фильтр «Клиент».
  static String filterCustomer(AppLocalizations l10n) => l10n.transactions_filter_customer;

  /// Фильтр «Способ оплаты».
  static String filterPaymentMethod(AppLocalizations l10n) => l10n.payment_method_title;
}
