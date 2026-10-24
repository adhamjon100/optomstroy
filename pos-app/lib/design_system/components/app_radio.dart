import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_checkbox.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Радио `AppRadio` (03 §9.65; ядро §17.5): круг 20, обводка `borderStrong` 2; выбран — кольцо
/// `primaryText` 2 + точка `primaryText` 10. Группа — у вызывающего кода (значение + колбэк).
class AppRadio<T> extends StatelessWidget {
  /// Создаёт радио.
  const AppRadio({
    super.key,
    required this.value,
    required this.groupValue,
    required this.onChanged,
    this.label,
    this.description,
    this.errorText,
    this.semanticLabel,
  });

  /// Значение этого пункта.
  final T value;

  /// Выбранное значение группы.
  final T? groupValue;

  /// Выбор; `null` — недоступно.
  final ValueChanged<T>? onChanged;

  /// Подпись.
  final String? label;

  /// Описание.
  final String? description;

  /// Ошибка.
  final String? errorText;

  /// Подпись для screen reader (если нет [label]).
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool enabled = onChanged != null;
    final bool selected = value == groupValue;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      enabled: enabled,
      label: label ?? semanticLabel,
      excludeSemantics: true,
      child: DsInteractive(
        enabled: enabled,
        onTap: () => onChanged?.call(value),
        builder: (BuildContext context, DsInteractionState s) {
          final Color ring = !enabled
              ? c.disabledText
              : errorText != null
              ? c.error
              : selected
              ? c.primaryText
              : c.borderStrong;
          final Widget circle = Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c.surface,
              border: Border.all(color: ring, width: 2),
            ),
            child: selected
                ? Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: enabled ? c.primaryText : c.disabledText),
                  )
                : null,
          );
          final Widget control = SizedBox.square(
            dimension: 48,
            child: Center(
              child: Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: dsSelectionHalo(c, s), shape: BoxShape.circle),
                child: DsFocusRing(visible: s.focused, circle: true, child: circle),
              ),
            ),
          );
          return DsSelectionRow(
            control: control,
            label: label,
            description: description,
            errorText: errorText,
            enabled: enabled,
          );
        },
      ),
    );
  }
}
