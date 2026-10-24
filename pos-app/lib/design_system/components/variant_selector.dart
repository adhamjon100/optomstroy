import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_dropdown.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Значение оси варианта («Хром», «Ø20»).
@immutable
class VariantAxisValue {
  /// Создаёт значение.
  const VariantAxisValue({
    required this.value,
    this.label,
    this.swatch,
    this.available = true,
    this.combinationExists = true,
  });

  /// Значение характеристики (ключ выбора).
  final String value;

  /// Подпись; по умолчанию [value].
  final String? label;

  /// Цвет свотча (ось «цвет», если известен); `null` — чип.
  final Color? swatch;

  /// Есть остаток на складе корзины; иначе — пунктир/зачёркивание, но выбираемый (INV-012).
  final bool available;

  /// Сочетание с выбранными значениями других осей существует; иначе — disabled-вид с
  /// тултипом «Нет такого сочетания» (выбор переключает другие оси).
  final bool combinationExists;
}

/// Ось выбора («Цвет», «Размер»).
@immutable
class VariantAxis {
  /// Создаёт ось.
  const VariantAxis({required this.key, required this.label, required this.values, this.selected});

  /// Ключ характеристики.
  final String key;

  /// Название оси для заголовка «{axis}: {value}».
  final String label;

  /// Значения в порядке 1С.
  final List<VariantAxisValue> values;

  /// Выбранное значение; `null` — не выбрано.
  final String? selected;
}

/// Выбор варианта `VariantSelector` (03 §9.22, SCR-14 UI-14-008; INV-012): по оси — свотчи
/// (цвет), чипы (размер/модель), выпадающий список при > 12 значений. Выбранное — обводка
/// `primaryText` 2 + `check`; без остатка на складе корзины — пунктир/зачёркивание `disabledText`,
/// но выбираемо. Заголовок оси («Цвет: Чёрный матовый») и тексты передаёт вызывающий.
/// Товару с одним вариантом селектор не показывается (решает экран).
class VariantSelector extends StatelessWidget {
  /// Создаёт селектор.
  const VariantSelector({
    super.key,
    required this.axes,
    required this.onSelected,
    required this.titleFor,
    this.combinationMissingHint,
    this.errorText,
  });

  /// Оси.
  final List<VariantAxis> axes;

  /// Выбор значения оси.
  final void Function(String axisKey, String value) onSelected;

  /// Заголовок оси («Цвет: Хром» / «Цвет»).
  final String Function(VariantAxis axis) titleFor;

  /// Тултип недоступного сочетания (`product_variant_combination_missing`).
  final String? combinationMissingHint;

  /// Ошибка «Выберите {ось}».
  final String? errorText;

  /// Порог переключения на выпадающий список.
  static const int dropdownThreshold = 12;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Column(
      key: const ValueKey<String>('variant-selector'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final VariantAxis axis in axes) ...<Widget>[
          Text(titleFor(axis), style: context.text.label.copyWith(color: c.textPrimary)),
          const SizedBox(height: 8),
          if (axis.values.length > dropdownThreshold)
            AppDropdown<String>(
              semanticLabel: axis.label,
              value: axis.selected,
              onChanged: (String v) => onSelected(axis.key, v),
              items: <AppDropdownItem<String>>[
                for (final VariantAxisValue v in axis.values)
                  AppDropdownItem<String>(value: v.value, label: v.label ?? v.value),
              ],
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[for (final VariantAxisValue v in axis.values) _option(context, axis, v)],
            ),
          if (axis != axes.last) const SizedBox(height: 16),
        ],
        if (errorText != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(errorText!, style: context.text.caption.copyWith(color: c.error)),
        ],
      ],
    );
  }

  Widget _option(BuildContext context, VariantAxis axis, VariantAxisValue v) {
    final DsColors c = context.colors;
    final bool selected = axis.selected == v.value;
    final bool dim = !v.available || !v.combinationExists;
    final String label = v.label ?? v.value;
    final bool swatch = v.swatch != null;
    final Widget option = Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: '${axis.label}: $label',
      excludeSemantics: true,
      child: DsInteractive(
        key: ValueKey<String>('variant-option-${axis.key}-${v.value}'),
        onTap: selected ? () {} : () => onSelected(axis.key, v.value),
        builder: (BuildContext context, DsInteractionState s) {
          final Color border = selected ? c.primaryText : (s.hovered ? c.borderStrong : c.border);
          final Widget content = swatch
              ? Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: v.swatch,
                    border: Border.all(color: border, width: selected ? 2 : 1),
                  ),
                  child: selected ? Icon(Icons.check_rounded, size: 20, color: c.onInverseSurface) : null,
                )
              : AnimatedContainer(
                  duration: context.motion.of(const Duration(milliseconds: 200)),
                  height: 40,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: selected ? c.primaryContainer : (s.hovered ? c.surfaceHover : c.surface),
                    borderRadius: BorderRadius.all(context.radii.sm),
                    border: Border.all(color: border, width: selected ? 2 : 1),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (selected) ...<Widget>[
                        Icon(Icons.check_rounded, size: 16, color: c.primaryText),
                        const SizedBox(width: 4),
                      ],
                      Text(
                        label,
                        style: context.text.label.copyWith(
                          color: dim ? c.disabledText : (selected ? c.primaryText : c.textPrimary),
                          decoration: v.available ? null : TextDecoration.lineThrough,
                          decorationColor: c.disabledText,
                        ),
                      ),
                    ],
                  ),
                );
          return DsFocusRing(
            visible: s.focused,
            borderRadius: swatch ? null : BorderRadius.all(context.radii.sm),
            circle: swatch,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Center(widthFactor: 1, child: content),
            ),
          );
        },
      ),
    );
    if (!v.combinationExists && combinationMissingHint != null) {
      return AppTooltip(message: combinationMissingHint!, child: option);
    }
    return option;
  }
}
