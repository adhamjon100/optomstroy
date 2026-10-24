import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Подпись и описание контрола выбора; строка 48 — тач-цель (`listTile`, 03 §9.65).
class DsSelectionRow extends StatelessWidget {
  /// Создаёт строку.
  const DsSelectionRow({
    super.key,
    required this.control,
    this.label,
    this.description,
    this.errorText,
    this.enabled = true,
    this.controlFirst = true,
  });

  /// Контрол (20 lp или трек переключателя).
  final Widget control;

  /// Подпись `body 14`.
  final String? label;

  /// Описание `caption textSecondary`.
  final String? description;

  /// Ошибка `caption error` («Нужно согласие»).
  final String? errorText;

  /// Доступна ли строка.
  final bool enabled;

  /// Контрол слева (чекбокс, радио) или справа (переключатель — подпись слева).
  final bool controlFirst;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    if (label == null && description == null && errorText == null) {
      return control;
    }
    final Widget text = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (label != null)
          Text(label!, style: context.text.body.copyWith(color: enabled ? c.textPrimary : c.textSecondary)),
        if (description != null) Text(description!, style: context.text.caption.copyWith(color: c.textSecondary)),
        if (errorText != null)
          Semantics(
            liveRegion: true,
            child: Text(errorText!, style: context.text.caption.copyWith(color: c.error)),
          ),
      ],
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
        children: controlFirst
            ? <Widget>[control, const SizedBox(width: 12), Expanded(child: text)]
            : <Widget>[Expanded(child: text), const SizedBox(width: 12), control],
      ),
    );
  }
}

/// Ореол hover/pressed 40 вокруг контрола (03 §9.65).
Color? dsSelectionHalo(DsColors c, DsInteractionState s) =>
    !s.enabled ? null : (s.pressed ? c.iconButtonPressed : (s.hovered ? c.surfaceVariant : null));

/// Чекбокс `AppCheckbox` (03 §9.65; ядро §17.5): квадрат 20 (радиус `xs`), обводка `borderStrong`
/// 2 px; выбран — заливка `primary` + контур `primaryText` 2 px + галочка `onPrimary` 14;
/// неопределённый — тире. Тап по контролу или подписи — toggle; тач-цель 48.
class AppCheckbox extends StatelessWidget {
  /// Создаёт чекбокс. [value] = `null` — неопределённый (только при [tristate]).
  const AppCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    this.label,
    this.description,
    this.errorText,
    this.tristate = false,
    this.semanticLabel,
  });

  /// Значение.
  final bool? value;

  /// Изменение; `null` — недоступен.
  final ValueChanged<bool?>? onChanged;

  /// Подпись справа.
  final String? label;

  /// Описание под подписью.
  final String? description;

  /// Ошибка (согласие не отмечено).
  final String? errorText;

  /// Три состояния («все» в списках).
  final bool tristate;

  /// Подпись для screen reader (если нет [label]).
  final String? semanticLabel;

  void _toggle() {
    if (onChanged == null) {
      return;
    }
    if (tristate) {
      onChanged!(value == null ? false : (value! ? null : true));
    } else {
      onChanged!(!(value ?? false));
    }
  }

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool enabled = onChanged != null;
    final bool hasError = errorText != null;
    return Semantics(
      checked: value ?? false,
      mixed: tristate && value == null,
      enabled: enabled,
      label: label ?? semanticLabel,
      excludeSemantics: true,
      child: DsInteractive(
        enabled: enabled,
        onTap: _toggle,
        builder: (BuildContext context, DsInteractionState s) {
          final bool selected = value != false;
          final Color fill = !enabled
              ? (selected ? c.disabledText : Colors.transparent)
              : (selected ? c.primary : c.surface);
          final Color border = !enabled
              ? c.disabledText
              : hasError
              ? c.error
              : selected
              ? c.primaryText
              : c.borderStrong;
          final Color mark = enabled ? c.onPrimary : c.surface;
          final Color? halo = dsSelectionHalo(c, s);
          final Widget box = Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.all(context.radii.xs),
              border: Border.all(color: border, width: 2),
            ),
            child: selected
                ? Icon(value == null ? Icons.remove_rounded : Icons.check_rounded, size: 14, color: mark)
                : null,
          );
          final Widget control = SizedBox.square(
            dimension: 48,
            child: Center(
              child: Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: halo, shape: BoxShape.circle),
                child: DsFocusRing(visible: s.focused, borderRadius: BorderRadius.all(context.radii.xs), child: box),
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
