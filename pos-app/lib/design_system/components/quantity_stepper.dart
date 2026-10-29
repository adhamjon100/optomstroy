import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Размер `QuantityStepper` (03 §9.20).
enum QuantityStepperSize {
  /// Кнопки 44, поле 56×44, тач-цель 48 (compact, medium, карточка товара).
  md(button: 44, field: 56, height: 44),

  /// Кнопки 36, поле 48×36 (только expanded с мышью).
  sm(button: 36, field: 48, height: 36),

  /// Группа drawer корзины (прототип 2026-10-29; expanded/large): общая обводка `border` 1, радиус `sm`; визуально
  /// кнопки 34×32 без фона (hover — `surfaceHover`), число `body 600 tnum` без своей рамки (это кнопка нампада, а не
  /// поле ввода), поле 44×32 — всего 112×32. Цели касания — 44×44 (03 §7.4: POS-мониторы бывают сенсорными, тип
  /// указателя не проверяется): невидимое поле 6 сверху и снизу, у «−» и «+» — 10 с внешней стороны; занимаемое место
  /// 132×44 ([groupTarget]).
  group(button: 34, field: 44, height: 32);

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

  @override
  State<QuantityStepper> createState() => _QuantityStepperState();
}

/// Невидимое поле цели касания «−»/«+» группы с внешней стороны: 34 + 10 = 44.
const double _groupOuterPad = QuantityStepperSize.groupTarget - 34;

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
    final TextStyle valueStyle = (group ? context.text.body : context.text.bodyLg).copyWith(
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
            // Группа: число без своей рамки, поле не уже 44 (цель касания 44×44, визуально — 32 по высоте; кольцо
            // фокуса — вокруг видимой части).
            ? SizedBox(
                height: QuantityStepperSize.groupTarget,
                child: Center(
                  child: DsFocusRing(
                    visible: st.focused,
                    borderRadius: BorderRadius.all(context.radii.sm),
                    child: Container(
                      constraints: BoxConstraints(minWidth: s.field),
                      height: s.height,
                      padding: EdgeInsets.symmetric(horizontal: context.space.s1),
                      alignment: Alignment.center,
                      color: st.hovered && widget.onValueTap != null ? c.surfaceHover : null,
                      child: Text(widget.value, maxLines: 1, style: valueStyle),
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
          // Группа: обводка рисуется под строкой целей касания (визуально 32 по высоте, внутри внешних полей «−»/«+»),
          // сами цели — 44×44.
          ? Stack(
              children: <Widget>[
                Positioned.fill(
                  left: _groupOuterPad,
                  right: _groupOuterPad,
                  top: (QuantityStepperSize.groupTarget - s.height) / 2,
                  bottom: (QuantityStepperSize.groupTarget - s.height) / 2,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.all(context.radii.sm),
                        border: Border.all(color: widget.error ? c.error : c.border, width: widget.error ? 2 : 1),
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
              // невидимое поле 6 сверху и снизу и [_groupOuterPad] с внешней стороны группы; кольцо — вокруг кнопки.
              ? SizedBox(
                  width: side + _groupOuterPad,
                  height: QuantityStepperSize.groupTarget,
                  child: Align(
                    alignment: outerEnd ? AlignmentDirectional.centerStart : AlignmentDirectional.centerEnd,
                    child: DsFocusRing(
                      visible: s.focused,
                      borderRadius: BorderRadius.all(context.radii.sm),
                      child: AnimatedContainer(
                        duration: context.motion.of(const Duration(milliseconds: 150)),
                        width: side,
                        height: size.height,
                        decoration: BoxDecoration(
                          color: !enabled ? null : (s.pressed ? c.surfacePressed : (s.hovered ? c.surfaceHover : null)),
                          borderRadius: outerEnd
                              ? BorderRadiusDirectional.horizontal(end: context.radii.sm)
                              : BorderRadiusDirectional.horizontal(start: context.radii.sm),
                        ),
                        child: Icon(icon, size: 18, color: enabled ? c.textPrimary : c.disabledText),
                      ),
                    ),
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
