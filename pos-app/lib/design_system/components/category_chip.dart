import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Вариант `CategoryChip` (03 §9.9).
enum CategoryChipVariant {
  /// Одна активная: «Все», подкатегории, подборки.
  choice,

  /// Множественный выбор (фильтры, типы совпадений).
  filter,

  /// Активный фильтр с крестиком удаления (UI-10-017).
  input,
}

/// Чип категории/подборки `CategoryChip` (03 §9.9): высота 36 (цель 48 за счёт полосы), радиус
/// `full`; выбранный — `primaryContainer` + обводка `primaryText` 1,5 + `check` 16 (не только цвет).
class CategoryChip extends StatelessWidget {
  /// Создаёт чип.
  const CategoryChip({
    super.key,
    required this.label,
    this.onTap,
    this.selected = false,
    this.variant = CategoryChipVariant.choice,
    this.icon,
    this.count,
    this.onRemove,
    this.removeLabel,
    this.trailingChevron = false,
    this.enabled = true,
  });

  /// Подпись.
  final String label;

  /// Тап.
  final VoidCallback? onTap;

  /// Выбран.
  final bool selected;

  /// Вариант.
  final CategoryChipVariant variant;

  /// Иконка 18 слева (подборки `history` / `star`, «Все категории» — `category`).
  final IconData? icon;

  /// Счётчик `caption tnum` справа.
  final int? count;

  /// Крестик (`input`).
  final VoidCallback? onRemove;

  /// Подпись крестика.
  final String? removeLabel;

  /// Шеврон «›» («Все категории ›»).
  final bool trailingChevron;

  /// Доступен (0 совпадений — `disabled`).
  final bool enabled;

  /// Полоса скелетон-чипов (loading: 5 × 80×36).
  static Widget skeletonStrip(BuildContext context) => Row(
    children: <Widget>[
      for (int i = 0; i < 5; i++) ...<Widget>[
        const SkeletonBox(width: 80, height: 36, radius: Radius.circular(18)),
        SizedBox(width: context.space.s2),
      ],
    ],
  );

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool on = selected && variant != CategoryChipVariant.input;
    final Color fg = !enabled ? c.disabledText : (on ? c.primaryText : c.textPrimary);
    return Semantics(
      button: true,
      selected: on,
      enabled: enabled,
      label: count == null ? label : '$label $count',
      excludeSemantics: true,
      child: DsInteractive(
        onTap: enabled ? onTap : null,
        enabled: enabled,
        builder: (BuildContext context, DsInteractionState s) {
          final Color bg = !enabled
              ? c.disabledBg
              : on
              ? c.primaryContainer
              : (s.pressed ? c.surfacePressed : (s.hovered ? c.surfaceVariant : c.surface));
          final double scale = s.pressed && !context.motion.reduceMotion ? 0.97 : 1;
          return SizedBox(
            height: 48,
            child: Center(
              child: AnimatedScale(
                scale: scale,
                duration: context.motion.of(context.motion.fast),
                child: DsFocusRing(
                  visible: s.focused,
                  borderRadius: BorderRadius.all(context.radii.full),
                  child: AnimatedContainer(
                    duration: context.motion.of(context.motion.fast),
                    height: 36,
                    constraints: const BoxConstraints(maxWidth: 220),
                    padding: EdgeInsetsDirectional.only(
                      start: on || icon != null ? context.space.s2 : context.space.s3,
                      end: onRemove != null ? context.space.s1 : context.space.s3,
                    ),
                    decoration: BoxDecoration(
                      color: bg,
                      borderRadius: BorderRadius.all(context.radii.full),
                      border: Border.all(color: on ? c.primaryText : c.border, width: on ? 1.5 : 1),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (on) ...<Widget>[
                          Icon(Icons.check_rounded, size: 16, color: c.primaryText),
                          SizedBox(width: context.space.s1),
                        ] else if (icon != null) ...<Widget>[
                          Icon(icon, size: 18, color: fg),
                          SizedBox(width: context.space.s1),
                        ],
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.text.label.copyWith(fontWeight: FontWeight.w500, color: fg),
                          ),
                        ),
                        if (count != null) ...<Widget>[
                          SizedBox(width: context.space.s1),
                          Text(
                            '$count',
                            style: context.text.caption.copyWith(
                              color: on ? c.primaryText : c.textSecondary,
                              fontFeatures: DsTypography.numeric,
                            ),
                          ),
                        ],
                        if (trailingChevron) Icon(Icons.chevron_right_rounded, size: 18, color: fg),
                        if (onRemove != null)
                          Semantics(
                            button: true,
                            label: removeLabel,
                            child: InkResponse(
                              onTap: onRemove,
                              radius: 16,
                              child: SizedBox.square(
                                dimension: 28,
                                child: Icon(Icons.close_rounded, size: 16, color: c.textSecondary),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
