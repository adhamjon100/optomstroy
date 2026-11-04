import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:optomstroy/design_system/components/ds_hairline.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Размер `QuantityStepper` (03 §9.20).
enum QuantityStepperSize {
  /// Кнопки 44, поле 56×44, тач-цель 48 (compact, medium, карточка товара).
  md(button: 44, field: 56, height: 44),

  /// Кнопки 36, поле 48×36 (только expanded с мышью).
  sm(button: 36, field: 48, height: 36),

  /// Группа drawer корзины по прототипу без округления (ADR-114 п. 6; expanded/large): общая обводка 1 `border` с
  /// радиусом `badge` 9 вокруг кнопок 34×32 без фона (hover — `surfaceHover`) со знаками «−» (U+2212) и «+» 18/400
  /// `textPrimary` и числа 14/600 без своей рамки (это кнопка нампада, а не поле ввода), поле не уже 32 — видимая
  /// часть 102×34. Цели касания — 44×44 у «−», числа и «+» (03 §7.4, A11Y-003: POS-мониторы бывают сенсорными, тип
  /// указателя не проверяется) без изменения вида: невидимое поле 5 над и под обводкой и
  /// [QuantityStepper.groupOuterInset] 15 с внешней стороны; число забирает у каждой кнопки по 6 у внутреннего края
  /// (видимые границы ячеек не нарисованы, знаки остаются в целях своих кнопок); занимаемое место 132×44.
  group(button: 34, field: 32, height: 32);

  const QuantityStepperSize({required this.button, required this.field, required this.height});

  /// Сторона кнопки.
  final double button;

  /// Ширина поля числа.
  final double field;

  /// Высота.
  final double height;

  /// Сторона цели касания кнопок и числа размера [group].
  static const double groupTarget = 44;
}

/// Степпер количества `QuantityStepper` (03 §9.20; INV-040…INV-042, ANIM-007).
///
/// `[−] [число] [+]`: кнопки `tonal` (`surfaceVariant`/`textPrimary`), поле — обводка `borderStrong`,
/// число `bodyLg 16/600 tnum` (`error` при нарушении правил). Логику шага, кратности и пределов
/// задаёт вызывающий: недоступные действия передаются как `null` (кнопка `disabledText`, тач-цель
/// остаётся). Удержание «−» > 500 мс — автоповтор каждые 150 мс (ANIM-007); удержание «+» > 500 мс
/// и тап по числу — [onValueTap] / [onIncrementLongPress] (нампад SCR-16, INV-041). Клавиши `+`/`−`
/// при фокусе — шаг.
class QuantityStepper extends StatefulWidget {
  /// Создаёт степпер.
  const QuantityStepper({
    super.key,
    required this.value,
    required this.increaseLabel,
    required this.decreaseLabel,
    this.unit,
    this.onIncrement,
    this.onDecrement,
    this.onValueTap,
    this.onIncrementLongPress,
    this.error = false,
    this.size = QuantityStepperSize.md,
    this.valueSemantics,
  });

  /// Отформатированное значение («2», «1,5»).
  final String value;

  /// Единица («шт», «кор») — под числом `caption`.
  final String? unit;

  /// «+»; `null` — недоступна (максимум, неизвестный остаток).
  final VoidCallback? onIncrement;

  /// «−»; `null` — недоступна (минимум вне корзины).
  final VoidCallback? onDecrement;

  /// Тап по числу — нампад.
  final VoidCallback? onValueTap;

  /// Удержание «+» > 500 мс — нампад (автоповтора «+» нет, 02 SCR-14 ANIM).
  final VoidCallback? onIncrementLongPress;

  /// Нарушение правил: число `error`.
  final bool error;

  /// Размер.
  final QuantityStepperSize size;

  /// Подпись кнопки «+» для screen reader.
  final String increaseLabel;

  /// Подпись кнопки «−» для screen reader.
  final String decreaseLabel;

  /// «2 штуки» (по умолчанию — значение и единица).
  final String? valueSemantics;

  /// Задержка автоповтора.
  static const Duration repeatDelay = Duration(milliseconds: 500);

  /// Интервал автоповтора.
  static const Duration repeatInterval = Duration(milliseconds: 150);

  /// Размер [QuantityStepperSize.group]: невидимое поле целей касания от края виджета до видимой обводки (слева и
  /// справа). Строка drawer корзины выносит его в зазор перед степпером, чтобы обводка стояла на месте прототипа.
  static const double groupOuterInset = _groupOuterPad;

  @override
  State<QuantityStepper> createState() => _QuantityStepperState();
}

/// Невидимое поле цели касания «−»/«+» группы с внешней стороны (до обводки).
const double _groupOuterPad = 15;

/// Обводка группы (CSS-px прототипа).
const double _groupBorder = 1;

/// Часть видимой ячейки «−»/«+» у внутреннего края, которая относится к цели числа: цель «−» и «+» —
/// 15 + 1 + 34 − 6 = 44, цель числа — 6 + 32 + 6 = 44.
const double _groupInnerShare = 6;

class _QuantityStepperState extends State<QuantityStepper> {
  Timer? _repeat;

  @override
  void dispose() {
    _repeat?.cancel();
    super.dispose();
  }

  void _startRepeat() {
    _repeat?.cancel();
    _repeat = Timer.periodic(QuantityStepper.repeatInterval, (_) {
      final VoidCallback? dec = widget.onDecrement;
      if (dec == null || !mounted) {
        _stopRepeat();
        return;
      }
      dec();
    });
  }

  void _stopRepeat() {
    _repeat?.cancel();
    _repeat = null;
  }

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final QuantityStepperSize s = widget.size;
    final bool group = s == QuantityStepperSize.group;
    // Группа (прототип): 14/600 без `tnum`; иначе — `bodyLg 600 tnum`.
    final TextStyle valueStyle = group
        ? context.text.chip.copyWith(color: widget.error ? c.error : c.textPrimary)
        : context.text.bodyLg.copyWith(
            fontWeight: FontWeight.w600,
            color: widget.error ? c.error : c.textPrimary,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            height: 1.1,
          );
    final Widget field = Semantics(
      label: widget.valueSemantics ?? (widget.unit == null ? widget.value : '${widget.value} ${widget.unit}'),
      button: widget.onValueTap != null,
      excludeSemantics: true,
      child: DsInteractive(
        key: const ValueKey<String>('quantity-stepper-value'),
        onTap: widget.onValueTap,
        builder: (BuildContext context, DsInteractionState st) => group
            // Группа: число без своей рамки, поле не уже 32; цель касания — поле и по 6 у соседних кнопок (44×44;
            // кольцо фокуса — вокруг видимой части).
            ? SizedBox(
                height: QuantityStepperSize.groupTarget,
                child: Center(
                  widthFactor: 1,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: _groupInnerShare),
                    child: DsFocusRing(
                      visible: st.focused,
                      borderRadius: BorderRadius.all(context.radii.sm),
                      child: Container(
                        constraints: BoxConstraints(minWidth: s.field),
                        height: s.height,
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        alignment: Alignment.center,
                        color: st.hovered && widget.onValueTap != null ? c.surfaceHover : null,
                        child: Text(widget.value, maxLines: 1, style: valueStyle),
                      ),
                    ),
                  ),
                ),
              )
            : DsFocusRing(
                visible: st.focused,
                borderRadius: BorderRadius.all(context.radii.sm),
                child: Container(
                  width: s.field,
                  height: s.height,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.all(context.radii.sm),
                    border: Border.all(color: widget.error ? c.error : c.borderStrong, width: widget.error ? 2 : 1),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(widget.value, maxLines: 1, style: valueStyle),
                      ),
                      if (widget.unit != null && s == QuantityStepperSize.md)
                        Text(
                          widget.unit!,
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          style: context.text.micro.copyWith(color: c.textSecondary, height: 1.1),
                        ),
                    ],
                  ),
                ),
              ),
      ),
    );
    final Widget decrement = _button(
      context,
      key: const ValueKey<String>('quantity-stepper-decrement'),
      icon: Icons.remove_rounded,
      sign: '\u2212',
      label: widget.decreaseLabel,
      onTap: widget.onDecrement,
      onLongPressStart: widget.onDecrement == null ? null : _startRepeat,
      onLongPressEnd: _stopRepeat,
      outerEnd: false,
    );
    final Widget increment = _button(
      context,
      key: const ValueKey<String>('quantity-stepper-increment'),
      icon: Icons.add_rounded,
      sign: '+',
      label: widget.increaseLabel,
      onTap: widget.onIncrement,
      onLongPressStart: widget.onIncrementLongPress,
      outerEnd: true,
    );
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (FocusNode node, KeyEvent e) {
        if (e is! KeyDownEvent) return KeyEventResult.ignored;
        final LogicalKeyboardKey k = e.logicalKey;
        if ((k == LogicalKeyboardKey.add || k == LogicalKeyboardKey.numpadAdd || k == LogicalKeyboardKey.equal) &&
            widget.onIncrement != null) {
          widget.onIncrement!();
          return KeyEventResult.handled;
        }
        if ((k == LogicalKeyboardKey.minus || k == LogicalKeyboardKey.numpadSubtract) && widget.onDecrement != null) {
          widget.onDecrement!();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: group
          // Группа: обводка рисуется под строкой целей касания (видимая часть 34 по высоте, внутри внешних полей
          // «−»/«+»), сами цели — 44 по высоте.
          ? Stack(
              children: <Widget>[
                Positioned.fill(
                  left: _groupOuterPad,
                  right: _groupOuterPad,
                  top: (QuantityStepperSize.groupTarget - s.height) / 2 - _groupBorder,
                  bottom: (QuantityStepperSize.groupTarget - s.height) / 2 - _groupBorder,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.all(context.radii.badge),
                        border: widget.error ? Border.all(color: c.error, width: 2) : DsHairline.all(context, c.border),
                      ),
                    ),
                  ),
                ),
                Row(mainAxisSize: MainAxisSize.min, children: <Widget>[decrement, field, increment]),
              ],
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[decrement, const SizedBox(width: 4), field, const SizedBox(width: 4), increment],
            ),
    );
  }

  Widget _button(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String sign,
    required String label,
    required VoidCallback? onTap,
    VoidCallback? onLongPressStart,
    VoidCallback? onLongPressEnd,
    required bool outerEnd,
  }) {
    final DsColors c = context.colors;
    final QuantityStepperSize size = widget.size;
    final double side = size.button;
    final bool enabled = onTap != null;
    final bool group = size == QuantityStepperSize.group;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        onLongPressStart: onLongPressStart == null ? null : (_) => onLongPressStart(),
        onLongPressEnd: onLongPressEnd == null ? null : (_) => onLongPressEnd(),
        onLongPressCancel: onLongPressEnd,
        child: DsInteractive(
          key: key,
          enabled: enabled,
          onTap: onTap,
          builder: (BuildContext context, DsInteractionState s) => group
              // Группа: кнопка 34×32 без фона, hover — `surfaceHover`, pressed — `surfacePressed`; цель 44×44 —
              // невидимое поле 6 сверху и снизу и [_groupOuterPad] + обводка с внешней стороны группы, а внутренние 6
              // ячейки — у цели числа (ячейка рисуется поверх края цели); кольцо — вокруг кнопки. Знак — текстом, как в
              // прототипе («−» U+2212 и «+», 18/400).
              ? SizedBox(
                  width: QuantityStepperSize.groupTarget,
                  height: QuantityStepperSize.groupTarget,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: <Widget>[
                      PositionedDirectional(
                        start: outerEnd ? -_groupInnerShare : _groupOuterPad + _groupBorder,
                        top: (QuantityStepperSize.groupTarget - size.height) / 2,
                        width: side,
                        height: size.height,
                        child: DsFocusRing(
                          visible: s.focused,
                          borderRadius: BorderRadius.all(context.radii.sm),
                          child: AnimatedContainer(
                            duration: context.motion.of(const Duration(milliseconds: 150)),
                            width: side,
                            height: size.height,
                            decoration: BoxDecoration(
                              color: !enabled
                                  ? null
                                  : (s.pressed ? c.surfacePressed : (s.hovered ? c.surfaceHover : null)),
                              borderRadius: outerEnd
                                  ? BorderRadiusDirectional.horizontal(end: context.radii.badge)
                                  : BorderRadiusDirectional.horizontal(start: context.radii.badge),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              sign,
                              maxLines: 1,
                              textScaler: TextScaler.noScaling,
                              style: context.text.title.copyWith(
                                fontWeight: FontWeight.w400,
                                height: 1,
                                color: enabled ? c.textPrimary : c.disabledText,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              : DsFocusRing(
                  visible: s.focused,
                  borderRadius: BorderRadius.all(context.radii.sm),
                  child: SizedBox(
                    width: size == QuantityStepperSize.md ? 48 : side,
                    height: size == QuantityStepperSize.md ? 48 : side,
                    child: Center(
                      child: AnimatedContainer(
                        duration: context.motion.of(const Duration(milliseconds: 150)),
                        width: side,
                        height: side,
                        decoration: BoxDecoration(
                          color: !enabled
                              ? c.disabledBg
                              : (s.pressed ? c.surfacePressed : (s.hovered ? c.surfaceHover : c.surfaceVariant)),
                          borderRadius: BorderRadius.all(context.radii.sm),
                        ),
                        child: Icon(icon, size: 20, color: enabled ? c.textPrimary : c.disabledText),
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}
