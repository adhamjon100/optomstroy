import 'package:flutter/material.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_checkbox.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Строка заявки на возврат `ReturnItemRow` (02 SCR-39 UI-39-003 — вариант возврата `CartLine`): чекбокс 48 слева,
/// название и «Продано N, возвращено M», справа степпер 44/48 и сумма строки `body 700 tnum`; подсказка «Можно
/// вернуть: N» / «Нет данных о прежних возвратах…» `caption textSecondary`, ошибка превышения — `caption error`.
/// Строка, возвращённая полностью, — `disabled` с чипом `neutral` ([fullyReturnedLabel]) вместо степпера.
///
/// [compact] (02 SCR-39.2 compact, строка 72): степпер и сумма — вторым рядом под названием; иначе — один ряд (64).
/// Компонент не знает о домене: тексты, степпер и сумму передаёт экран; деньги — `Money` (тыйыны, D-19).
class ReturnItemRow extends StatelessWidget {
  /// Создаёт строку.
  const ReturnItemRow({
    super.key,
    required this.title,
    required this.checked,
    this.onCheckedChanged,
    this.subtitle,
    this.hint,
    this.errorText,
    this.quantity,
    this.amount,
    this.fullyReturnedLabel,
    this.compact = false,
    this.semanticLabel,
  });

  /// Название товара (вариант — через « · »).
  final String title;

  /// «Продано 2, возвращено 0».
  final String? subtitle;

  /// «Можно вернуть: 2» или предупреждение о неизвестных прежних возвратах.
  final String? hint;

  /// «Больше, чем можно вернуть (2)» — степпер и подпись в `error`.
  final String? errorText;

  /// Строка включена в заявку.
  final bool checked;

  /// Переключение чекбокса; `null` — строка недоступна (просмотр, возвращено полностью).
  final ValueChanged<bool>? onCheckedChanged;

  /// Степпер количества (`QuantityStepper`) — только у отмеченной строки.
  final Widget? quantity;

  /// Предварительная сумма строки.
  final Money? amount;

  /// «возвращено полностью» — строка `disabled`, чип `neutral`.
  final String? fullyReturnedLabel;

  /// Раскладка compact (два ряда).
  final bool compact;

  /// Подпись чекбокса для screen reader (по умолчанию — [title]).
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final DsTypography t = context.text;
    final bool disabled = fullyReturnedLabel != null;
    final Widget texts = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: t.bodyMedium.copyWith(color: disabled ? c.textSecondary : c.textPrimary),
        ),
        if (subtitle != null)
          Text(
            subtitle!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t.caption.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
          ),
        if (errorText != null)
          Text(
            errorText!,
            style: t.caption.copyWith(color: c.error, fontFeatures: DsTypography.numeric),
          )
        else if (hint != null)
          Text(
            hint!,
            style: t.caption.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
          ),
      ],
    );
    final Widget amountText = Text(
      checked && amount != null ? PriceText.format(amount!, fixed2: true) : '',
      textAlign: TextAlign.end,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: t.priceOf(t.body).copyWith(color: errorText != null ? c.error : c.textPrimary),
    );
    final Widget chip = StatusChip(label: fullyReturnedLabel ?? '', variant: StatusChipVariant.neutral, dense: true);
    // compact: второй ряд на всю ширину строки — степпер слева, сумма справа.
    final Widget trailing = disabled
        ? chip
        : compact
        ? Row(
            children: <Widget>[
              ?quantity,
              if (quantity != null) SizedBox(width: context.space.s3),
              Expanded(child: amountText),
            ],
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ?quantity,
              if (quantity != null) SizedBox(width: context.space.s3),
              ConstrainedBox(constraints: const BoxConstraints(minWidth: 96), child: amountText),
            ],
          );
    final Widget checkbox = SizedBox.square(
      dimension: 48,
      child: AppCheckbox(
        value: checked,
        onChanged: onCheckedChanged == null || disabled ? null : (bool? v) => onCheckedChanged!(v ?? false),
        semanticLabel: semanticLabel ?? title,
      ),
    );
    final Widget body = compact
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  checkbox,
                  Expanded(child: texts),
                ],
              ),
              if (disabled || checked)
                Padding(
                  padding: EdgeInsetsDirectional.only(top: context.space.s1),
                  child: disabled ? Align(alignment: AlignmentDirectional.centerEnd, child: trailing) : trailing,
                ),
            ],
          )
        : Row(
            children: <Widget>[
              checkbox,
              Expanded(child: texts),
              SizedBox(width: context.space.s3),
              trailing,
            ],
          );
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: compact ? 72 : 64),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: context.space.s1),
        child: body,
      ),
    );
  }
}
