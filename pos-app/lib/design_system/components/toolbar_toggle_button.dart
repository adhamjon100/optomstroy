import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_badge.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/ds_glyph.dart';
import 'package:optomstroy/design_system/components/ds_hairline.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/layout/text_measure.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Кнопка-переключатель строки управления каталога `ToolbarToggleButton` (03 §9.72; прототип, ADR-112, ADR-114):
/// «Новые», «Избранные», «Недавние», «Фильтры» SCR-10/11/12 на medium и шире.
///
/// Значения прототипа: 40 визуально (цель 48), поля 0 14, радиус `control` 10, обводка 1, контурный глиф 17 (линия 2;
/// [glyph] — часы, звезда, воронка прототипа, иначе [icon]) + зазор 8 + подпись `chip 14/600`:
/// - невыбранная — `surface`, обводка `border`, текст и глиф `textPrimary`;
/// - выбранная — `primaryContainer`, обводка `primaryContainerBorder` (декоративная), текст и глиф
///   `onPrimaryContainer`; вес подписи и контур глифа не меняются (как в прототипе; [selectedIcon] не используется) —
///   выбранное состояние дают заливка, цвет и `Semantics.toggled` (ADR-114). Признак не только цветом (A11Y-004,
///   DS-036) — при системном «высоком контрасте» (`MediaQuery.highContrastOf`): подпись 700 и обводка 2
///   `onPrimaryContainer` (без него вид прототипа не меняется; ревью RC-05, RP-06);
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
    this.glyph,
    this.selected = false,
    this.enabled = true,
    this.badgeCount,
    this.showLabel = true,
    this.semanticLabel,
    this.tooltip,
  });

  /// Визуальная высота.
  static const double height = 40;

  /// Высота тач-цели.
  static const double target = 48;

  /// Размер иконки (прототип: SVG 17 × 17).
  static const double iconSize = 17;

  /// Поля по горизонтали (прототип: `padding: 0 14px`).
  static const double horizontalPadding = 14;

  /// Зазор иконка — подпись (прототип: `gap: 8px`).
  static const double iconGap = 8;

  /// Подпись.
  final String label;

  /// Нажатие; `null` — кнопка без действия (например, выбранная, повтор которой ничего не меняет).
  final VoidCallback? onTap;

  /// Иконка слева (контурная), если нет [glyph].
  final IconData? icon;

  /// Не используется (ADR-114: иконка контурная в обоих состояниях, как в прототипе); оставлен для совместимости.
  final IconData? selectedIcon;

  /// Глиф прототипа слева (`DsGlyphKind.clock`, `star`, `filter`); важнее [icon].
  final DsGlyphKind? glyph;

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

  /// Подсказка при наведении («Избранные, 12 товаров» — число, которое прежде показывала плитка колонки; паритет
  /// функций ADR-114); `null` — только у кнопки без подписи ([showLabel] `false`) — [label].
  final String? tooltip;

  /// Обводка выбранной при высоком контрасте (DS-036: «обводка 2 px» — признак формы).
  static const double highContrastBorder = 2;

  /// Выбранное показывается не только цветом: системный высокий контраст (A11Y-004; ревью RC-05, RP-06).
  static bool strongSelectionCue(BuildContext context) => MediaQuery.maybeHighContrastOf(context) ?? false;

  /// Оценка ширины кнопки (до раскладки): поля 14 + 14, иконка 17 с зазором 8, подпись `chip 14/600` (вес одинаков в
  /// обоих состояниях; при высоком контрасте — по весу 700), бейдж, обводка — «Новые» 101,2, «Избранные» 134,5,
  /// «Фильтры» 118,1 (прототип).
  static double estimateWidth(
    BuildContext context,
    String label, {
    bool withIcon = true,
    bool withBadge = false,
    bool showLabel = true,
  }) {
    final TextStyle style = strongSelectionCue(context)
        ? context.text.chip.copyWith(fontWeight: FontWeight.w700)
        : context.text.chip;
    final double text = showLabel ? dsTextWidth(context, label, style) : 0;
    final double iconPart = withIcon ? iconSize + (showLabel ? iconGap : 0) : 0;
    final double badge = withBadge ? context.space.s2 + 22 : 0;
    final double width = horizontalPadding * 2 + iconPart + text + badge + 2 * DsHairline.of(context);
    return width < target ? target : width;
  }

  int get _badge => badgeCount ?? 0;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool active = enabled && onTap != null;
    final String a11y = semanticLabel ?? (_badge > 0 ? '$label, $_badge' : label);
    final bool strong = selected && enabled && strongSelectionCue(context);
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
          final Color border = !enabled
              ? c.disabledBg
              : (strong ? c.onPrimaryContainer : (selected ? c.primaryContainerBorder : c.border));
          final BorderRadius radius = BorderRadius.all(context.radii.control);
          final DsGlyphKind? kind = glyph;
          final Widget? art = kind != null
              ? DsGlyph(kind: kind, size: iconSize, color: fg, strokeWidth: 2)
              : (icon == null ? null : Icon(icon, size: iconSize, color: fg));
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
                  // Обводка 2 при высоком контрасте — за счёт поля, ширина кнопки та же.
                  padding: EdgeInsets.symmetric(
                    horizontal: strong
                        ? horizontalPadding - (highContrastBorder - DsHairline.of(context))
                        : horizontalPadding,
                  ),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: radius,
                    border: strong
                        ? Border.all(color: border, width: highContrastBorder)
                        : DsHairline.all(context, border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      ?art,
                      if (art != null && showLabel) const SizedBox(width: iconGap),
                      if (showLabel)
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.text.chip.copyWith(color: fg, fontWeight: strong ? FontWeight.w700 : null),
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
    final String? hint = tooltip ?? (showLabel ? null : label);
    return hint == null ? button : AppTooltip(message: hint, child: button);
  }
}
