import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Состояние `DiscountInput` (03 §9.31; 02 UI-20-013).
enum DiscountInputState {
  /// Ввод доступен.
  normal,

  /// `POST /cart/discount` выполняется: «…» + спиннер 16.
  loading,

  /// `422 DISCOUNT_LIMIT_EXCEEDED` / локальная ошибка: обводка `error`, текст под полем.
  error,
}

/// Ручная скидка в процентах `DiscountInput` (вариант `percent`; 03 §9.31): строка 44 — «Скидка» `body` → поле
/// 72×36 с суффиксом «%» (`tnum`, цифры и «,»/«.») → сумма скидки «−842,50 сом» `body tnum textSecondary` →
/// иконка `info` с тултипом «Ваш лимит: 5 %»; под полем — [message] и [actions] («Применить 5 %», «Как получить
/// подтверждение»). Вариант `readonly` ([readonlyText]) — без поля («Скидка клиента 5 % (из 1С)»).
///
/// Компонент не вычисляет суммы (D-23): [amount] — `discountTotal` ответа сервера. Разбор и проверку значения,
/// debounce и отправку выполняет вызывающий ([onChanged], [onSubmitted]).
class DiscountInput extends StatelessWidget {
  /// Создаёт поле скидки.
  const DiscountInput({
    super.key,
    required this.label,
    this.controller,
    this.focusNode,
    this.amount,
    this.limitTooltip,
    this.state = DiscountInputState.normal,
    this.message,
    this.actions = const <Widget>[],
    this.enabled = true,
    this.onChanged,
    this.onSubmitted,
    this.readonlyText,
    this.semanticLabel,
  });

  /// «Скидка».
  final String label;
  final TextEditingController? controller;
  final FocusNode? focusNode;

  /// Сумма скидки сервера (положительная; показывается с «−»).
  final Money? amount;

  /// «Ваш лимит: 5 %».
  final String? limitTooltip;
  final DiscountInputState state;

  /// Ошибка/подсказка под полем.
  final String? message;

  /// Кнопки под полем.
  final List<Widget> actions;
  final bool enabled;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// Вариант `readonly` — текст вместо поля.
  final String? readonlyText;

  /// «Скидка в процентах, лимит 5».
  final String? semanticLabel;

  /// Ключ поля (тесты).
  static const Key fieldKey = ValueKey<String>('discount-input-field');

  /// Допустимые символы: цифры и один разделитель.
  static final TextInputFormatter formatter = FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'));

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final TextStyle num = context.text.body.copyWith(
      color: c.textPrimary,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    final Money? a = amount;
    if (readonlyText != null) {
      return SizedBox(
        height: 44,
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(readonlyText!, style: context.text.body.copyWith(color: c.textSecondary)),
            ),
            if (a != null) Text(PriceText.format(-a, fixed2: true), style: num.copyWith(color: c.textSecondary)),
          ],
        ),
      );
    }
    final bool error = state == DiscountInputState.error;
    final OutlineInputBorder border = OutlineInputBorder(
      borderRadius: BorderRadius.all(context.radii.sm),
      borderSide: BorderSide(color: error ? c.error : c.borderStrong, width: error ? 2 : 1),
    );
    final Widget field = SizedBox(
      width: 72,
      height: 36,
      child: Semantics(
        label: semanticLabel ?? label,
        textField: true,
        child: TextField(
          key: fieldKey,
          controller: controller,
          focusNode: focusNode,
          enabled: enabled,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          textAlign: TextAlign.end,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: <TextInputFormatter>[formatter, LengthLimitingTextInputFormatter(6)],
          style: num,
          decoration: InputDecoration(
            isDense: true,
            hintText: '0',
            hintStyle: num.copyWith(color: c.textSecondary),
            suffixText: '%',
            suffixStyle: num.copyWith(color: c.textSecondary),
            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            filled: true,
            fillColor: enabled ? c.surface : c.disabledBg,
            border: border,
            enabledBorder: border,
            disabledBorder: border.copyWith(borderSide: BorderSide(color: c.border)),
            focusedBorder: border.copyWith(borderSide: BorderSide(color: error ? c.error : c.primaryText, width: 2)),
          ),
        ),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          height: 44,
          child: Row(
            children: <Widget>[
              Text(label, style: context.text.body.copyWith(color: c.textPrimary)),
              if (limitTooltip != null) ...<Widget>[
                SizedBox(width: context.space.s1),
                Tooltip(
                  message: limitTooltip,
                  child: Icon(Icons.info_outline_rounded, size: 16, color: c.textSecondary),
                ),
              ],
              SizedBox(width: context.space.s3),
              field,
              if (state == DiscountInputState.loading) ...<Widget>[
                const Spacer(),
                const AppProgress.circular(size: 16),
                SizedBox(width: context.space.s1),
                Text('…', style: num.copyWith(color: c.textSecondary)),
              ] else
                // Узкая панель (overlay 320 на medium): сумма уменьшается, а не выходит за край строки.
                Expanded(
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        a == null || a.tyiyn == 0 ? '' : PriceText.format(-a, fixed2: true),
                        style: num.copyWith(color: c.textSecondary),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (message != null)
          Semantics(
            liveRegion: true,
            child: Padding(
              padding: EdgeInsets.only(bottom: context.space.s1),
              child: Text(message!, style: context.text.caption.copyWith(color: error ? c.error : c.textSecondary)),
            ),
          ),
        if (actions.isNotEmpty) Wrap(spacing: context.space.s2, runSpacing: context.space.s1, children: actions),
      ],
    );
  }
}
