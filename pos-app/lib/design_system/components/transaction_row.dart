// `TransactionRow` (03 §9.38): строка журнала операций SCR-36, «Недавние операции» и «Ожидают оплаты» SCR-30,
// история клиента SCR-33. Анатомия: иконка типа 24 в круге 40 `surfaceVariant` → колонка (заголовок «Платёж № 1024 ·
// Азамат Б.» `body 500`, подзаголовок «18 окт 2026, 09:42 · Абдулла» `caption textSecondary tnum`) → справа сумма
// `bodyLg 700 tnum` со знаком в тексте (поступление «+» — `success`, расход «−» и заказ без знака — `textPrimary`) +
// `StatusChip` → шеврон. Высота 64; на compact — не ниже 72, статус переносится под дату, заголовок — до 2 строк. Статус не передаётся только цветом (A11Y-004):
// знак суммы — в тексте, статус — чип с иконкой. Заголовки дней — [TransactionDayHeader].
import 'package:flutter/material.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Знак суммы строки (семантика цвета — 03 §9.38).
enum TransactionRowAmountTone {
  /// Поступление денег: «+», `success`.
  incoming,

  /// Расход, возврат, аннулирование: «−», `textPrimary`.
  outgoing,

  /// Документ без движения денег (заказ создан): без знака, `textPrimary`.
  neutral,
}

/// Строка операции.
class TransactionRow extends StatelessWidget {
  /// Создаёт строку.
  const TransactionRow({
    super.key,
    required this.kind,
    required this.title,
    required this.amountText,
    this.subtitle,
    this.tone = TransactionRowAmountTone.neutral,
    this.status,
    this.note,
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.enabled = true,
    this.compactWindow = false,
    this.highlighted = false,
    this.showChevron = true,
    this.semanticLabel,
    this.leadingIcon,
  });

  /// Вид операции (`transaction_kind`) — иконка; `null` — неизвестный вид (иконка `receipt`).
  final TransactionKind? kind;

  /// «Платёж № 1024 · Азамат Б.».
  final String title;

  /// «18 окт 2026, 09:42 · Абдулла».
  final String? subtitle;

  /// Сумма с валютой («16 007,50 сом»); знак добавляет строка по [tone].
  final String amountText;

  /// Знак и цвет суммы.
  final TransactionRowAmountTone tone;

  /// `StatusChip` статуса (иконка + текст).
  final Widget? status;

  /// Дополнительная подпись справа под суммой (таймер QR, «Оплачено X из Y», «Оплачен»).
  final String? note;

  /// Тап — деталь.
  final VoidCallback? onTap;

  /// Долгое нажатие / правый клик — «Скопировать номер».
  final VoidCallback? onLongPress;

  /// Открыта в панели (полоса `primaryText` слева, 03 §5.5 п. 5).
  final bool selected;

  /// Доступна (строка оплаченного заказа в листе поиска — `disabled`).
  final bool enabled;

  /// Окно compact: высота 72, статус под датой.
  final bool compactWindow;

  /// Подсветка новой строки (`primaryContainer`, SCR-30.5).
  final bool highlighted;

  /// Шеврон справа.
  final bool showChevron;

  /// Полная подпись для screen reader (03 §9.38 «Доступность»).
  final String? semanticLabel;

  /// Иконка вместо иконки вида (заказ в очереди оплаты).
  final IconData? leadingIcon;

  /// Иконка вида операции (03 §9.38).
  static IconData iconOf(TransactionKind? kind) => switch (kind) {
    TransactionKind.orderCreated || null => Icons.receipt_outlined,
    TransactionKind.orderCancelled => Icons.cancel_outlined,
    TransactionKind.paymentReceived => Icons.payments_outlined,
    TransactionKind.paymentVoided => Icons.money_off_outlined,
    TransactionKind.refund => Icons.undo_rounded,
    TransactionKind.discountOverride => Icons.percent_rounded,
    TransactionKind.creditSaleApproved => Icons.receipt_long_outlined,
    TransactionKind.manualQrConfirm => Icons.qr_code_2_rounded,
    TransactionKind.returnRequested => Icons.assignment_return_outlined,
  };

  /// Знак суммы по виду операции (03 §9.38: платёж — `success` «+…»; возврат, аннулирование, отмена —
  /// `textPrimary` «−…»; заказ и прочие документы без движения денег — `textPrimary` без знака). Знак
  /// `Transaction.sign` ([plus], `true` — «+») решает только для вида, неизвестного клиенту (`null`).
  static TransactionRowAmountTone toneOf(TransactionKind? kind, {bool? plus}) => switch (kind) {
    TransactionKind.paymentReceived || TransactionKind.manualQrConfirm => TransactionRowAmountTone.incoming,
    TransactionKind.paymentVoided ||
    TransactionKind.refund ||
    TransactionKind.orderCancelled => TransactionRowAmountTone.outgoing,
    TransactionKind.orderCreated ||
    TransactionKind.creditSaleApproved ||
    TransactionKind.discountOverride ||
    TransactionKind.returnRequested => TransactionRowAmountTone.neutral,
    null =>
      plus == null
          ? TransactionRowAmountTone.neutral
          : (plus ? TransactionRowAmountTone.incoming : TransactionRowAmountTone.outgoing),
  };

  /// Текст суммы со знаком: «+16 007,50 сом», «−2 350,00 сом».
  static String signed(String amountText, TransactionRowAmountTone tone) => switch (tone) {
    TransactionRowAmountTone.incoming => '+$amountText',
    TransactionRowAmountTone.outgoing => '−$amountText',
    TransactionRowAmountTone.neutral => amountText,
  };

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) =>
          _row(context, stacked: compactWindow || box.maxWidth < TransactionRow.stackBelow),
    );
  }

  /// Ширина, ниже которой статус переносится под дату (как на compact).
  static const double stackBelow = 480;

  Widget _row(BuildContext context, {required bool stacked}) {
    final DsColors c = context.colors;
    final Color amountColor = !enabled
        ? c.disabledText
        : (tone == TransactionRowAmountTone.incoming ? c.success : c.textPrimary);
    final TextStyle amountStyle = context.text.bodyLg.copyWith(
      color: amountColor,
      fontWeight: FontWeight.w700,
      fontFeatures: DsTypography.numeric,
    );
    final Widget amount = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerEnd,
          child: Text(signed(amountText, tone), maxLines: 1, style: amountStyle),
        ),
        if (note != null)
          Text(
            note!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.text.caption.copyWith(
              color: enabled ? c.textSecondary : c.disabledText,
              fontFeatures: DsTypography.numeric,
            ),
          ),
        if (!stacked && status != null) ...<Widget>[SizedBox(height: context.space.s1), status!],
      ],
    );
    return Semantics(
      button: onTap != null,
      enabled: enabled,
      selected: selected,
      label: semanticLabel,
      excludeSemantics: semanticLabel != null,
      child: GestureDetector(
        onSecondaryTap: onLongPress,
        child: DsInteractive(
          onTap: enabled ? onTap : null,
          onLongPress: onLongPress,
          enabled: enabled && onTap != null,
          builder: (BuildContext context, DsInteractionState s) {
            final Color bg = highlighted
                ? c.primaryContainer
                : (s.pressed ? c.surfacePressed : (s.hovered || s.focused ? c.surfaceHover : c.surface));
            return AnimatedContainer(
              duration: context.motion.of(context.motion.fast),
              constraints: BoxConstraints(minHeight: stacked ? 72 : 64),
              padding: EdgeInsetsDirectional.only(
                start: context.space.s4,
                end: context.space.s3,
                top: context.space.s2,
                bottom: context.space.s2,
              ),
              decoration: BoxDecoration(
                color: bg,
                border: BorderDirectional(
                  start: BorderSide(color: selected ? c.primaryText : Colors.transparent, width: 3),
                  bottom: BorderSide(color: c.border),
                ),
              ),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(color: c.surfaceVariant, shape: BoxShape.circle),
                    child: Icon(
                      leadingIcon ?? iconOf(kind),
                      size: 24,
                      color: enabled ? c.textSecondary : c.disabledText,
                    ),
                  ),
                  SizedBox(width: context.space.s3),
                  Expanded(
                    flex: 3,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        // Номер операции — главный идентификатор: в узкой строке заголовок переносится на 2 строки,
                        // а не обрезается после «№ 1…» (03 §9.38, compact — 72).
                        Text(
                          title,
                          maxLines: stacked ? 2 : 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.bodyMedium.copyWith(
                            color: enabled ? c.textPrimary : c.disabledText,
                            fontFeatures: DsTypography.numeric,
                          ),
                        ),
                        if (subtitle != null && subtitle!.isNotEmpty)
                          Text(
                            subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.text.caption.copyWith(
                              color: enabled ? c.textSecondary : c.disabledText,
                              fontFeatures: DsTypography.numeric,
                            ),
                          ),
                        if (stacked && status != null) ...<Widget>[SizedBox(height: context.space.s1), status!],
                      ],
                    ),
                  ),
                  SizedBox(width: context.space.s3),
                  // Сумма и статус — не шире 2/5 строки: длинный чип переносится, строка не переполняется.
                  Flexible(flex: 2, child: amount),
                  if (showChevron && onTap != null) ...<Widget>[
                    SizedBox(width: context.space.s1),
                    Icon(Icons.chevron_right_rounded, size: 20, color: c.textTertiary),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Заголовок дня журнала «Сегодня» / «Вчера» / «18 октября» (`label`, `surfaceVariant`, 32; 03 §9.38).
class TransactionDayHeader extends StatelessWidget {
  /// Создаёт заголовок.
  const TransactionDayHeader({super.key, required this.label});

  /// Текст.
  final String label;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Semantics(
      header: true,
      child: Container(
        height: 32,
        alignment: AlignmentDirectional.centerStart,
        padding: EdgeInsets.symmetric(horizontal: context.space.s4),
        color: c.surfaceVariant,
        child: Text(
          label,
          style: context.text.label.copyWith(color: c.textSecondary, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
