import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_density.dart';

/// Строка списка `AppListTile` (03 §9.66): высота 56 (`standard`) / 48 (`compact`-плотность),
/// иконка 24/20, заголовок `bodyLg`/`body`, подзаголовок `caption textSecondary`, trailing.
/// Выбрана — `primaryContainer` + полоса 3 px `primaryText` слева (не только цвет, DS-036).
class AppListTile extends StatelessWidget {
  /// Создаёт строку.
  const AppListTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leadingIcon,
    this.leading,
    this.trailing,
    this.onTap,
    this.selected = false,
    this.enabled = true,
    this.density,
    this.showChevron = false,
  });

  /// Заголовок.
  final String title;

  /// Подзаголовок.
  final String? subtitle;

  /// Иконка слева.
  final IconData? leadingIcon;

  /// Произвольный элемент слева (аватар).
  final Widget? leading;

  /// Элемент справа (переключатель, значение, бейдж).
  final Widget? trailing;

  /// Действие по тапу.
  final VoidCallback? onTap;

  /// Выбрана.
  final bool selected;

  /// Доступна.
  final bool enabled;

  /// Плотность (по умолчанию — по классу окна).
  final DsDensity? density;

  /// Шеврон `chevron_right` справа (переход).
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final DsDensity d = density ?? context.density;
    final bool dense = d == DsDensity.compact;
    final double height = subtitle == null ? d.rowHeight : d.rowHeightWithThumb;
    final Color fg = enabled ? c.textPrimary : c.disabledText;
    return Semantics(
      button: onTap != null,
      selected: selected,
      enabled: enabled,
      child: DsInteractive(
        enabled: enabled && onTap != null,
        onTap: onTap,
        builder: (BuildContext context, DsInteractionState s) {
          final Color bg = selected
              ? (s.pressed ? c.primaryContainerPressed : c.primaryContainer)
              : (s.pressed ? c.surfacePressed : (s.hovered ? c.surfaceHover : Colors.transparent));
          final Widget row = AnimatedContainer(
            duration: context.motion.of(context.motion.fast),
            constraints: BoxConstraints(minHeight: height),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: bg,
              border: selected ? Border(left: BorderSide(color: c.primaryText, width: 3)) : null,
            ),
            child: Row(
              children: <Widget>[
                if (leading != null) ...<Widget>[leading!, const SizedBox(width: 12)],
                if (leading == null && leadingIcon != null) ...<Widget>[
                  Icon(
                    leadingIcon,
                    size: d.rowIconSize,
                    color: !enabled ? c.disabledText : (selected ? c.primaryText : c.textSecondary),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: (dense ? context.text.body : context.text.bodyLg).copyWith(
                            color: fg,
                            fontWeight: selected ? FontWeight.w600 : null,
                          ),
                        ),
                        if (subtitle != null)
                          Text(
                            subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.text.caption.copyWith(color: c.textSecondary),
                          ),
                      ],
                    ),
                  ),
                ),
                if (trailing != null) ...<Widget>[const SizedBox(width: 12), trailing!],
                if (showChevron) ...<Widget>[
                  const SizedBox(width: 8),
                  Icon(Icons.chevron_right_rounded, size: 20, color: c.textSecondary),
                ],
              ],
            ),
          );
          return DsFocusRing(visible: s.focused, child: row);
        },
      ),
    );
  }
}
