import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_badge.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/layout/text_measure.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Кнопка-переключатель строки управления каталога `ToolbarToggleButton` (03 §9.72; прототип 2026-10-29, ADR-112):
/// «Новые», «Избранные», «Недавние», «Фильтры» SCR-10/11/12 на medium и шире.
///
/// 40 визуально (цель 48), радиус `md`, поля 12 (прототип 14), иконка 18 + подпись `body 600`:
/// - невыбранная — `surface`, обводка `border`, текст и иконка `textPrimary`;
/// - выбранная — `primaryContainer`, обводка `primaryContainerBorder` (декоративная), текст и иконка
///   `onPrimaryContainer` 700; иконка залитая ([selectedIcon]) и вес подписи — выбранное состояние передаётся не только
///   цветом (A11Y-004);
/// - недоступная — `disabledBg` / `disabledText`;
/// - hover — `surfaceHover` (выбранная — `primaryContainerPressed`), фокус — кольцо.
///
/// Необязательный бейдж [badgeCount] (число активных фильтров). `CategoryChip` (пилюля 36) остаётся для полос чипов.
class ToolbarToggleButton extends StatelessWidget {
  /// Создаёт кнопку.
  const ToolbarToggleButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.selectedIcon,
    this.selected = false,
    this.enabled = true,
    this.badgeCount,
    this.showLabel = true,
    this.semanticLabel,
  });

  /// Визуальная высота.
  static const double height = 40;

  /// Высота тач-цели.
  static const double target = 48;

  /// Размер иконки.
  static const double iconSize = 18;

  /// Подпись.
  final String label;

  /// Нажатие; `null` — кнопка без действия (например, выбранная, повтор которой ничего не меняет).
  final VoidCallback? onTap;

  /// Иконка слева (контурная).
  final IconData? icon;

  /// Иконка выбранной (залитая); по умолчанию — [icon].
  final IconData? selectedIcon;

  /// Выбрана (включена).
  final bool selected;

  /// Доступна.
  final bool enabled;

  /// Бейдж-счётчик справа (активные фильтры); `null` или 0 — без бейджа.
  final int? badgeCount;

  /// Подпись видна; иначе — только иконка с тултипом (узкая строка управления).
  final bool showLabel;

  /// Подпись для screen reader (по умолчанию — [label] и число бейджа).
  final String? semanticLabel;

  /// Оценка ширины кнопки (до раскладки): поля 12 + 12, иконка 18 с зазором 8, подпись `body 700` (ширина выбранной),
  /// бейдж, обводка.
  static double estimateWidth(
    BuildContext context,
    String label, {
    bool withIcon = true,
    bool withBadge = false,
    bool showLabel = true,
  }) {
    final double text = showLabel
        ? dsTextWidth(context, label, context.text.body.copyWith(fontWeight: FontWeight.w700))
        : 0;
    final double iconPart = withIcon ? iconSize + (showLabel ? context.space.s2 : 0) : 0;
    final double badge = withBadge ? context.space.s2 + 22 : 0;
    final double width = context.space.s3 * 2 + iconPart + text + badge + 2;
    return width < target ? target : width;
  }

  int get _badge => badgeCount ?? 0;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool active = enabled && onTap != null;
    final String a11y = semanticLabel ?? (_badge > 0 ? '$label, $_badge' : label);
    final Widget button = Semantics(
      button: true,
      toggled: selected,
      enabled: enabled,
      label: a11y,
      excludeSemantics: true,
      // Действие «нажать» для TalkBack/Narrator: жест DsInteractive из семантики исключён.
      onTap: active ? onTap : null,
      child: DsInteractive(
        onTap: active ? onTap : null,
        enabled: enabled,
        builder: (BuildContext context, DsInteractionState s) {
          final Color fg = !enabled ? c.disabledText : (selected ? c.onPrimaryContainer : c.textPrimary);
          final Color bg = !enabled
              ? c.disabledBg
              : selected
              ? (s.pressed || s.hovered ? c.primaryContainerPressed : c.primaryContainer)
              : (s.pressed ? c.surfacePressed : (s.hovered ? c.surfaceHover : c.surface));
          final Color border = !enabled ? c.disabledBg : (selected ? c.primaryContainerBorder : c.border);
          final BorderRadius radius = BorderRadius.all(context.radii.md);
          final IconData? glyph = selected ? (selectedIcon ?? icon) : icon;
          return SizedBox(
            height: target,
            child: Center(
              widthFactor: 1,
              child: DsFocusRing(
                visible: s.focused,
                borderRadius: radius,
                child: AnimatedContainer(
                  duration: context.motion.of(context.motion.fast),
                  height: height,
                  constraints: const BoxConstraints(minWidth: target),
                  padding: EdgeInsets.symmetric(horizontal: context.space.s3),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: radius,
                    border: Border.all(color: border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      if (glyph != null) Icon(glyph, size: iconSize, color: fg),
                      if (glyph != null && showLabel) SizedBox(width: context.space.s2),
                      if (showLabel)
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.text.body.copyWith(
                              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                              color: fg,
                            ),
                          ),
                        ),
                      if (_badge > 0) ...<Widget>[
                        SizedBox(width: context.space.s2),
                        AppBadge(count: _badge, tone: AppBadgeTone.cart),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
    return showLabel ? button : AppTooltip(message: label, child: button);
  }
}
