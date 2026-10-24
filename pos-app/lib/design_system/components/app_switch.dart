import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_checkbox.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Переключатель `AppSwitch` (03 §9.65; ядро §17.5): трек 52×32 (`borderStrong` выкл. /
/// `primaryText` вкл. — 5.34:1 к `surface`), ползунок 24 `surface` с иконкой `check` 16
/// `primaryText` во вкл. (не только цвет); подпись слева. [loading] — ползунок → спиннер 16,
/// повторные тапы игнорируются (ожидание сервера, откат — у вызывающего кода).
class AppSwitch extends StatelessWidget {
  /// Создаёт переключатель.
  const AppSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.label,
    this.description,
    this.loading = false,
    this.semanticLabel,
  });

  /// Значение.
  final bool value;

  /// Изменение; `null` — недоступен.
  final ValueChanged<bool>? onChanged;

  /// Подпись (слева).
  final String? label;

  /// Описание.
  final String? description;

  /// Ожидание сервера.
  final bool loading;

  /// Подпись для screen reader (если нет [label]).
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool enabled = onChanged != null;
    final Duration d = context.motion.of(context.motion.base);
    return Semantics(
      toggled: value,
      enabled: enabled,
      label: label ?? semanticLabel,
      excludeSemantics: true,
      child: DsInteractive(
        enabled: enabled,
        onTap: loading ? null : () => onChanged?.call(!value),
        builder: (BuildContext context, DsInteractionState s) {
          final Color track = !enabled ? c.disabledBg : (value ? c.primaryText : c.borderStrong);
          final Widget thumb = Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: enabled ? c.surface : c.disabledText, shape: BoxShape.circle),
            child: loading
                ? AppProgress.circular(size: 16, color: value ? c.primaryText : c.textSecondary)
                : (value ? Icon(Icons.check_rounded, size: 16, color: enabled ? c.primaryText : c.disabledBg) : null),
          );
          final Widget sw = AnimatedContainer(
            duration: d,
            width: 52,
            height: 32,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: track, borderRadius: BorderRadius.all(context.radii.full)),
            child: AnimatedAlign(
              duration: d,
              curve: context.motion.standard,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: thumb,
            ),
          );
          final Widget control = SizedBox(
            width: 60,
            height: 48,
            child: Center(
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: dsSelectionHalo(c, s),
                  borderRadius: BorderRadius.all(context.radii.full),
                ),
                child: DsFocusRing(visible: s.focused, borderRadius: BorderRadius.all(context.radii.full), child: sw),
              ),
            ),
          );
          return DsSelectionRow(
            control: control,
            label: label,
            description: description,
            enabled: enabled,
            controlFirst: false,
          );
        },
      ),
    );
  }
}
