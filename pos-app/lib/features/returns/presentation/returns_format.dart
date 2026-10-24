// Форматирование и адреса SCR-39: время Бишкека (UTC+6 круглый год), количества (`Qty`, milli), деньги
// (`Money`, тыйыны — `PriceText.format`, D-19). Подписи — только ARB. Фича не импортирует app/router (AP-01), поэтому
// адреса — строки тех же маршрутов (`ReturnRoute`, `OrderRoute`); сверка — test/features/returns/presentation.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/price_text.dart';

/// Форматирование значений SCR-39.
abstract final class ReturnsFormat {
  static const Duration _bishkek = Duration(hours: 6);

  static String _pad2(int v) => v.toString().padLeft(2, '0');

  /// «22.10.2026» по Бишкеку.
  static String date(DateTime utc) {
    final DateTime w = utc.toUtc().add(_bishkek);
    return '${_pad2(w.day)}.${_pad2(w.month)}.${w.year}';
  }

  /// «09:41» по Бишкеку.
  static String time(DateTime utc) {
    final DateTime w = utc.toUtc().add(_bishkek);
    return '${_pad2(w.hour)}:${_pad2(w.minute)}';
  }

  /// «22.10.2026 09:41».
  static String dateTime(DateTime utc) => '${date(utc)} ${time(utc)}';

  /// Сумма «4 700,00 сом» (финансовый контекст — 2 знака, Q-108).
  static String money(Money m) => PriceText.format(m, fixed2: true);

  /// Количество «2», «2,5», «0,125» (без лишних нулей, разделитель — запятая).
  static String qty(Qty q) {
    final int abs = q.milli.abs();
    final String sign = q.milli < 0 ? '−' : '';
    final int whole = abs ~/ 1000;
    final int frac = abs % 1000;
    if (frac == 0) return '$sign$whole';
    String f = frac.toString().padLeft(3, '0');
    while (f.endsWith('0')) {
      f = f.substring(0, f.length - 1);
    }
    return '$sign$whole,$f';
  }

  /// Ввод нампада («2,5» / «2.5») → `Qty`; `null` — неверный формат.
  static Qty? parseQty(String input) {
    try {
      return Qty.parseInput(input.replaceAll(',', '.').trim(), precision: Qty.maxPrecision);
    } on Object {
      return null;
    }
  }

  /// Подпись причины возврата (02 UI-39-004).
  static String reason(AppLocalizations l10n, ReturnReason r) => switch (r) {
    ReturnReason.defect => l10n.return_reason_defect,
    ReturnReason.wrongItem => l10n.return_reason_wrong_item,
    ReturnReason.notSuitable => l10n.return_reason_not_suitable,
    ReturnReason.surplus => l10n.return_reason_surplus,
    ReturnReason.sellerError => l10n.return_reason_seller_error,
    ReturnReason.other => l10n.return_reason_other,
  };

  /// Подпись пожелания способа возврата (02 UI-39-010).
  static String refundKind(AppLocalizations l10n, PaymentMethod m) => switch (m) {
    PaymentMethod.cash => l10n.return_refund_kind_cash,
    PaymentMethod.qrBakai => l10n.return_refund_kind_qr,
    PaymentMethod.credit => l10n.return_refund_kind_offset,
  };
}

/// Адреса переходов SCR-39 (02 SCR-39.6).
abstract final class ReturnsLocations {
  /// SCR-39 сохранённая заявка (`ReturnRoute`).
  static String returnRequest(String returnId) => '/returns/${Uri.encodeComponent(returnId)}';

  /// SCR-24 заказ (`OrderRoute`).
  static String order(String orderId) => '/orders/${Uri.encodeComponent(orderId)}';
}

/// Переходы через go_router; без маршрутизатора (widget-тесты экрана) — `Navigator`.
extension ReturnsNavigation on BuildContext {
  /// Заменить текущий маршрут (`/returns/new` → `/returns/{id}`, 02 SCR-39.4).
  void returnsReplace(String location) => GoRouter.maybeOf(this)?.replace<void>(location);

  /// `go` (переход в ветку заказов, SCR-39 → SCR-24).
  void returnsGo(String location) => GoRouter.maybeOf(this)?.go(location);

  /// Закрыть экран: назад по стеку, иначе — к заказу [orderId].
  void returnsClose({String? orderId}) {
    final GoRouter? router = GoRouter.maybeOf(this);
    if (router == null) {
      final NavigatorState? nav = Navigator.maybeOf(this);
      if (nav != null) unawaited(nav.maybePop());
      return;
    }
    if (router.canPop()) {
      router.pop();
    } else if (orderId != null) {
      router.go(ReturnsLocations.order(orderId));
    }
  }
}
