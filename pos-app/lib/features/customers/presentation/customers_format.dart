// Форматирование значений экранов клиентов SCR-31…SCR-35: время Бишкека (UTC+6 круглый год), деньги (`Money`, тыйыны —
// `PriceText.format`, в финансовых контекстах всегда 2 знака — Q-108), проценты, телефоны (`+996 XXX XXX XXX`,
// ядро §17.2). Подписи — только ARB (FL-08): [CustomersTexts]. Суммы долга на клиенте не вычисляются (DEBT-001).
import 'package:flutter/material.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/formats/ds_phone_format.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/entities/customer_history.dart';

/// Время, деньги, проценты, телефоны.
abstract final class CustomersFormat {
  /// Смещение Asia/Bishkek.
  static const Duration bishkekOffset = Duration(hours: 6);

  /// Момент [utc] на «стенных часах» Бишкека.
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

  /// Календарная дата (`format: date`) без сдвига пояса.
  static String plainDate(DateTime d) => '${_pad2(d.day)}.${_pad2(d.month)}.${d.year}';

  /// «09:41».
  static String time(DateTime utc) {
    final DateTime w = wall(utc);
    return '${_pad2(w.hour)}:${_pad2(w.minute)}';
  }

  /// Метка снимка: сегодня — «09:41», иначе — «22.10.2026 09:41».
  static String stamp(DateTime utc, DateTime nowUtc) =>
      startOfDayUtc(utc) == startOfDayUtc(nowUtc) ? time(utc) : '${date(utc)} ${time(utc)}';

  /// «16 007,50 сом».
  static String money(Money m) => PriceText.format(m, fixed2: true);

  /// «5 %» / «2,5 %».
  static String percent(Percent p) {
    final int whole = p.hundredths ~/ 100;
    final int frac = p.hundredths % 100;
    if (frac == 0) return '$whole %';
    final String f = frac.toString().padLeft(2, '0');
    return '$whole,${f.endsWith('0') ? f.substring(0, 1) : f} %';
  }

  /// `+996XXXXXXXXX` → `+996 XXX XXX XXX`.
  static String phone(String e164) => DsPhoneFormat.display(e164);

  /// Телефон клиента для строки: полный (первый) у ролей с правом, иначе маска с сервера (как пришла).
  static String? customerPhone(Customer c) => c.phones.isNotEmpty ? phone(c.phones.first.valueE164) : c.phoneMasked;

  /// Строка поиска — телефон: 9 национальных цифр → E.164, иначе `null`.
  static String? phoneQuery(String q) {
    final String t = q.trim();
    if (!RegExp(r'^[+\d\s()]+$').hasMatch(t)) return null;
    return DsPhoneFormat.normalize(t);
  }

  /// Устарел ли снимок: флаг сервера или возраст больше порога (P-STALE; по умолчанию 60 мин).
  static bool isStale({required DateTime? asOf, required bool flag, required DateTime nowUtc, int? maxAgeMinutes}) {
    if (flag) return true;
    if (asOf == null) return false;
    return nowUtc.difference(asOf) > Duration(minutes: maxAgeMinutes ?? 60);
  }
}

/// Подписи экранов клиентов (ключи 02 §7 частей D/E и общие `ds_*`/`role_*`/`status_*`).
abstract final class CustomersTexts {
  /// Вид клиента.
  static String type(AppLocalizations l10n, CustomerType t) => switch (t) {
    CustomerType.individual => l10n.customer_card_type_individual,
    CustomerType.entrepreneur => l10n.customer_card_type_entrepreneur,
    CustomerType.legal => l10n.customer_card_type_legal,
  };

  /// Код: 1С — «Код 1С: …», POS — «Код POS: …».
  static String? code(AppLocalizations l10n, Customer c) {
    final String? code = c.onecCode;
    if (code == null || code.isEmpty) return null;
    return c.source == CustomerSource.pos && c.onecStatus != CustomerOnecStatus.confirmed
        ? l10n.customer_card_code_pos(code)
        : l10n.customer_card_code(code);
  }

  /// Клиент POS, ещё не созданный в 1С (CUST-014).
  static bool pendingOnec(Customer c) => c.onecStatus == CustomerOnecStatus.pending;

  /// Роль.
  static String role(AppLocalizations l10n, RoleCode r) => switch (r) {
    RoleCode.seller => l10n.role_seller,
    RoleCode.cashier => l10n.role_cashier,
    RoleCode.seniorSeller => l10n.role_senior_seller,
    RoleCode.admin => l10n.role_admin,
    RoleCode.owner => l10n.role_owner,
    RoleCode.customer => l10n.role_customer,
    RoleCode.integration => l10n.role_integration,
  };

  /// Статус привязки пользователя.
  static String linkStatus(AppLocalizations l10n, CustomerLinkStatus s) => switch (s) {
    CustomerLinkStatus.proposed => l10n.status_link_proposed,
    CustomerLinkStatus.confirmed => l10n.status_link_confirmed,
    CustomerLinkStatus.rejected => l10n.status_link_rejected,
    CustomerLinkStatus.conflict => l10n.status_link_conflict,
  };

  /// Подпись типа совпадения поиска (UI-31-008). Ключи сгенерированы с разрывом текста 02 §7 (GQ-FECUST-01):
  /// `customers_search_match_name` — «Найдено по имени», остальные — продолжение фразы; временно выводятся как есть.
  static String match(AppLocalizations l10n, CustomerMatchType t, int count) => switch (t) {
    CustomerMatchType.name => '${l10n.customers_search_match_name}: $count',
    CustomerMatchType.phone => '${l10n.customers_search_match_phone}: $count',
    CustomerMatchType.code => '${l10n.customers_search_match_code}: $count',
    CustomerMatchType.inn => l10n.customers_search_match_inn(count),
  };

  /// Иконка вида записи истории (UI-33-003).
  static IconData historyIcon(CustomerHistoryKind? k) => switch (k) {
    CustomerHistoryKind.order => Icons.receipt_rounded,
    CustomerHistoryKind.shipment => Icons.local_shipping_outlined,
    CustomerHistoryKind.returnValue => Icons.undo_rounded,
    null => Icons.description_outlined,
  };

  /// Иконка вида документа взаиморасчётов (UI-34-005).
  static IconData documentIcon(ReceivableDocumentKind? k) => switch (k) {
    ReceivableDocumentKind.invoice => Icons.receipt_long_rounded,
    ReceivableDocumentKind.payment => Icons.payments_outlined,
    ReceivableDocumentKind.returnValue => Icons.undo_rounded,
    ReceivableDocumentKind.discount => Icons.percent_rounded,
    ReceivableDocumentKind.adjustment => Icons.tune_rounded,
    null => Icons.description_outlined,
  };

  /// Подпись вида документа: ключей единственного числа нет (GQ-FECUST-02) — временно подписи чипов фильтра.
  static String documentKind(AppLocalizations l10n, ReceivableDocumentKind? k) => switch (k) {
    ReceivableDocumentKind.invoice => l10n.receivables_filter_shipments,
    ReceivableDocumentKind.payment => l10n.receivables_filter_payments,
    ReceivableDocumentKind.returnValue => l10n.receivables_filter_returns,
    ReceivableDocumentKind.discount || ReceivableDocumentKind.adjustment => l10n.receivables_filter_discounts,
    null => l10n.receivables_col_document,
  };
}
