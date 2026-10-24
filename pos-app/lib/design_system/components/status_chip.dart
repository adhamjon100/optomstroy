import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Варианты `StatusChip` (03 §9.39): контейнер / текст и иконка / глиф 16.
enum StatusChipVariant {
  /// `surfaceVariant` / `textSecondary` / `radio_button_unchecked`.
  neutral,

  /// `infoContainer` / `info` / `hourglass_top`.
  info,

  /// `successContainer` / `success` / `check_circle`.
  success,

  /// `warningContainer` / `warning` / `warning` (иконка обязательна).
  warning,

  /// `errorContainer` / `error` / `error`.
  error,

  /// `primaryContainer` / `primaryText` / `sell` — вид цены «Опт»/«Розница», не статус.
  priceList,
}

/// Статус `StatusChip` (03 §9.39): всегда иконка 16 + текст `label 13/500` (A11Y-004),
/// высота 24 (20 — [dense]), паддинг 2×8, текст не переносится (ellipsis при ширине > 160).
class StatusChip extends StatelessWidget {
  /// Создаёт чип.
  const StatusChip({
    super.key,
    required this.label,
    required this.variant,
    this.dense = false,
    this.rounded = true,
    this.icon,
    this.tooltip,
    this.semanticLabel,
  });

  /// Подпись из ARB (`status_order_<code>` и т. п.).
  final String label;

  /// Вариант.
  final StatusChipVariant variant;

  /// Высота 20 (строки на compact).
  final bool dense;

  /// Пилюля (`full`); `false` — прямоугольник (`xs`).
  final bool rounded;

  /// Иконка вместо иконки варианта (например, `schedule` для «данные устарели»).
  final IconData? icon;

  /// Полное описание (тултип на expanded).
  final String? tooltip;

  /// Подпись для screen reader («Статус: ожидает оплаты»).
  final String? semanticLabel;

  /// Иконка варианта (03 §9.39, п. 5.5).
  static IconData iconOf(StatusChipVariant v) => switch (v) {
    StatusChipVariant.neutral => Icons.radio_button_unchecked_rounded,
    StatusChipVariant.info => Icons.hourglass_top_rounded,
    StatusChipVariant.success => Icons.check_circle_rounded,
    StatusChipVariant.warning => Icons.warning_rounded,
    StatusChipVariant.error => Icons.error_rounded,
    StatusChipVariant.priceList => Icons.sell_rounded,
  };

  /// Пара (контейнер, текст/иконка) варианта.
  static (Color, Color) colorsOf(DsColors c, StatusChipVariant v) => switch (v) {
    StatusChipVariant.neutral => (c.surfaceVariant, c.textSecondary),
    StatusChipVariant.info => (c.infoContainer, c.info),
    StatusChipVariant.success => (c.successContainer, c.success),
    StatusChipVariant.warning => (c.warningContainer, c.warning),
    StatusChipVariant.error => (c.errorContainer, c.error),
    StatusChipVariant.priceList => (c.primaryContainer, c.primaryText),
  };

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg) = colorsOf(context.colors, variant);
    final Widget chip = Container(
      height: dense ? 20 : 24,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.all(rounded ? context.radii.full : context.radii.xs),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon ?? iconOf(variant), size: 16, color: fg),
          const SizedBox(width: 4),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: context.text.label.copyWith(color: fg, height: 1.2),
              ),
            ),
          ),
        ],
      ),
    );
    final Widget sem = Semantics(label: semanticLabel ?? label, excludeSemantics: true, child: chip);
    return tooltip == null ? sem : AppTooltip(message: tooltip!, child: sem);
  }
}

/// Сопоставление enum ядра → вариант `StatusChip` (03 §9.39, таблица). Ключ — `<домен>.<значение>`
/// (домены: `order`, `payment`, `payment_review`, `outbox`, `sync`, `return`, `link`, `cart`).
/// Значение без строки считается дефектом (`T-DS-080`). `cart.active` и `cart.converted`
/// не отображаются (нет варианта).
abstract final class StatusChipMapping {
  /// Таблица 03 §9.39.
  static const Map<String, StatusChipVariant> table = <String, StatusChipVariant>{
    // order_status (D-20)
    'order.draft': StatusChipVariant.neutral,
    'order.submitting': StatusChipVariant.info,
    'order.submit_failed': StatusChipVariant.error,
    'order.pending_approval': StatusChipVariant.info,
    'order.awaiting_payment': StatusChipVariant.warning,
    'order.approved': StatusChipVariant.success,
    'order.awaiting_shipment': StatusChipVariant.warning,
    'order.shipped': StatusChipVariant.success,
    'order.partially_returned': StatusChipVariant.warning,
    'order.closed': StatusChipVariant.success,
    'order.cancelled': StatusChipVariant.neutral,
    // payment_status (D-21)
    'payment.initiated': StatusChipVariant.neutral,
    'payment.cash_pending': StatusChipVariant.info,
    'payment.qr_pending': StatusChipVariant.info,
    'payment.qr_shown': StatusChipVariant.info,
    'payment.qr_expired': StatusChipVariant.warning,
    'payment.manual_confirm': StatusChipVariant.warning,
    'payment.credit': StatusChipVariant.warning,
    'payment.received': StatusChipVariant.success,
    'payment.voided': StatusChipVariant.error,
    'payment.refunded': StatusChipVariant.neutral,
    // payments.review_reason (атрибут)
    'payment_review.amount_mismatch': StatusChipVariant.warning,
    'payment_review.unknown_reference': StatusChipVariant.warning,
    'payment_review.no_webhook': StatusChipVariant.warning,
    'payment_review.late_payment': StatusChipVariant.warning,
    // outbox_status
    'outbox.pending': StatusChipVariant.info,
    'outbox.sending': StatusChipVariant.info,
    'outbox.sent': StatusChipVariant.info,
    'outbox.confirmed': StatusChipVariant.success,
    'outbox.failed': StatusChipVariant.error,
    'outbox.dead': StatusChipVariant.error,
    // [ДОПУЩЕНИЕ RM-C-003] `outbox_status.cancelled` есть в contracts/enums.json, но нет в таблице
    // 03 §9.39 и в ARB (`status_outbox_*` — 6 ключей): вариант — как у `order.cancelled`;
    // строка в 03 и ключ `status_outbox_cancelled` — запрос владельцу 03 (DS).
    'outbox.cancelled': StatusChipVariant.neutral,
    // sync_run_status
    'sync.queued': StatusChipVariant.info,
    'sync.running': StatusChipVariant.info,
    'sync.success': StatusChipVariant.success,
    'sync.partial': StatusChipVariant.warning,
    'sync.failed': StatusChipVariant.error,
    // return_request_status
    'return.draft': StatusChipVariant.neutral,
    'return.submitted': StatusChipVariant.info,
    'return.accepted': StatusChipVariant.success,
    'return.rejected': StatusChipVariant.error,
    'return.completed': StatusChipVariant.success,
    // customer_link_status
    'link.proposed': StatusChipVariant.warning,
    'link.confirmed': StatusChipVariant.success,
    'link.rejected': StatusChipVariant.error,
    'link.conflict': StatusChipVariant.error,
    // cart_status (active/converted не отображаются)
    'cart.parked': StatusChipVariant.neutral,
    'cart.cleared': StatusChipVariant.neutral,
  };

  /// Значения, которые чипом не отображаются.
  static const Set<String> hidden = <String>{'cart.active', 'cart.converted'};

  /// Вариант для `<домен>.<значение>` или `null` (скрыт / нет в таблице).
  static StatusChipVariant? variantOf(String domain, String value) => table['$domain.$value'];
}
