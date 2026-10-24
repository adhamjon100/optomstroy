import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Варианты `AppIconButton` (03 §9.2).
enum AppIconButtonVariant { standard, tonal, filled, danger }

/// Кнопка-иконка `AppIconButton` (03 §9.2): визуально 40 (small — 32), тач-цель 48 (small — 44);
/// иконка `textSecondary`, активная/выбранная — `primaryText`; pressed — `iconButtonPressed`.
/// [semanticLabel] обязателен (A11Y-007), на десктопе он же — тултип.
class AppIconButton extends StatelessWidget {
  /// Создаёт кнопку-иконку.
  const AppIconButton({
    super.key,
    required this.icon,
    required this.semanticLabel,
    required this.onPressed,
    this.variant = AppIconButtonVariant.standard,
    this.small = false,
    this.selected = false,
    this.selectedIcon,
    this.loading = false,
    this.tooltip,
    this.iconSize,
    this.badge,
    this.focusNode,
  });

  /// Иконка (outlined).
  final IconData icon;

  /// Иконка выбранного состояния (filled); по умолчанию [icon].
  final IconData? selectedIcon;

  /// Подпись для screen reader (из ARB).
  final String semanticLabel;

  /// Действие; `null` — недоступна.
  final VoidCallback? onPressed;

  /// Вариант.
  final AppIconButtonVariant variant;

  /// Компактный размер 32/44 — только expanded с мышью.
  final bool small;

  /// Выбрана (toggle: звезда, вид каталога).
  final bool selected;

  /// Выполняется: иконка → `AppProgress.circular 20`.
  final bool loading;

  /// Тултип; по умолчанию — [semanticLabel]. Пустая строка отключает тултип.
  final String? tooltip;

  /// Размер иконки (24; 20 в плотных строках).
  final double? iconSize;

  /// Бейдж в правом верхнем углу (`AppBadge`).
  final Widget? badge;

  /// Узел фокуса.
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final double visual = small ? 32 : 40;
    final double target = small ? 44 : 48;
    final double glyph = iconSize ?? (small ? 20 : 24);
    final bool enabled = onPressed != null;
    final Duration fast = context.motion.of(context.motion.fast);

    final Widget button = Semantics(
      button: true,
      enabled: enabled,
      selected: selected,
      label: semanticLabel,
      excludeSemantics: true,
      child: DsInteractive(
        enabled: enabled,
        onTap: loading ? null : onPressed,
        focusNode: focusNode,
        builder: (BuildContext context, DsInteractionState s) {
          final (Color bg, Color fg) = _colors(c, s);
          final Widget glyphWidget = loading
              ? AppProgress.circular(size: 20, color: fg)
              : Icon(selected ? (selectedIcon ?? icon) : icon, size: glyph, color: fg);
          Widget circle = AnimatedContainer(
            duration: fast,
            width: visual,
            height: visual,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
            child: glyphWidget,
          );
          if (badge != null) {
            circle = Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                circle,
                Positioned(right: -2, top: -2, child: badge!),
              ],
            );
          }
          return DsTapTarget(
            minWidth: target,
            minHeight: target,
            child: DsFocusRing(visible: s.focused, circle: true, child: circle),
          );
        },
      ),
    );
    final String tip = tooltip ?? semanticLabel;
    return AppTooltip(message: tip, child: button);
  }

  (Color, Color) _colors(DsColors c, DsInteractionState s) {
    if (!s.enabled) {
      return (variant == AppIconButtonVariant.filled ? c.disabledBg : Colors.transparent, c.disabledText);
    }
    final Color fg = switch (variant) {
      AppIconButtonVariant.filled => c.onPrimary,
      AppIconButtonVariant.danger => c.error,
      _ => selected ? c.primaryText : c.textSecondary,
    };
    final Color bg = switch (variant) {
      AppIconButtonVariant.standard || AppIconButtonVariant.danger =>
        s.pressed ? c.iconButtonPressed : (s.hovered ? c.surfaceVariant : Colors.transparent),
      AppIconButtonVariant.tonal => s.pressed ? c.iconButtonPressed : (s.hovered ? c.surfaceHover : c.surfaceVariant),
      AppIconButtonVariant.filled => s.pressed ? c.primaryPressed : (s.hovered ? c.primaryHover : c.primary),
    };
    return (bg, fg);
  }
}
