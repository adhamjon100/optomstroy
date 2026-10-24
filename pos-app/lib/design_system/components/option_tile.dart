import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Индикатор выбора `OptionTile` (03 §9.33): `radio` — одиночный выбор, `check` — множественный.
enum OptionTileIndicator { radio, check }

/// Плитка выбора `OptionTile` (03 §9.33; ядро §17.5): карточка радиус `md`, обводка `border` 1 px,
/// `surface`, паддинг 16, мин. высота 72 → иконка 24 → заголовок `body 14/600` → подпись
/// `caption textSecondary` → индикатор справа. Выбрана — три признака: обводка `primaryText` 2 px,
/// фон `primaryContainer`, радио/галочка `primaryText`. [body] раскрывается при выборе (ANIM-020).
class OptionTile extends StatelessWidget {
  /// Создаёт плитку.
  const OptionTile({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.icon,
    this.indicator = OptionTileIndicator.radio,
    this.errorText,
    this.disabledReason,
    this.body,
  });

  /// Заголовок («Самовывоз»).
  final String title;

  /// Подпись (1–2 строки).
  final String? subtitle;

  /// Иконка 24.
  final IconData? icon;

  /// Выбрана.
  final bool selected;

  /// Выбор; `null` — недоступна.
  final VoidCallback? onTap;

  /// Индикатор.
  final OptionTileIndicator indicator;

  /// Ошибка «Выберите способ получения» (обводка `error`).
  final String? errorText;

  /// Причина недоступности («Доставка недоступна для этого клиента»).
  final String? disabledReason;

  /// Дополнительные поля под плиткой при выборе (`withBody`).
  final Widget? body;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool enabled = onTap != null;
    final BorderRadius radius = BorderRadius.all(context.radii.md);
    final Duration d = context.motion.of(context.motion.base);
    return Semantics(
      inMutuallyExclusiveGroup: indicator == OptionTileIndicator.radio,
      selected: selected,
      checked: selected,
      enabled: enabled,
      button: true,
      label: subtitle == null ? title : '$title. $subtitle',
      // Раскрытое тело (поля адреса и т. п.) остаётся доступным screen reader.
      excludeSemantics: !(selected && body != null),
      child: DsInteractive(
        enabled: enabled,
        onTap: onTap,
        builder: (BuildContext context, DsInteractionState s) {
          final Color bg = !enabled
              ? c.disabledBg
              : selected
              ? (s.pressed ? c.primaryContainerPressed : c.primaryContainer)
              : (s.pressed ? c.surfacePressed : (s.hovered ? c.surfaceHover : c.surface));
          final (Color border, double width) = !enabled
              ? (c.border, 1.0)
              : errorText != null
              ? (c.error, 2.0)
              : selected
              ? (c.primaryText, 2.0)
              : (s.hovered ? c.borderStrong : c.border, 1.0);
          final Color fg = enabled ? c.textPrimary : c.disabledText;
          final String? caption = enabled ? subtitle : (disabledReason ?? subtitle);
          final Widget card = AnimatedContainer(
            duration: context.motion.of(context.motion.fast),
            constraints: const BoxConstraints(minHeight: 72),
            // Толщина обводки 1→2 компенсируется паддингом — без сдвига содержимого.
            padding: EdgeInsets.all(16 - (width - 1)),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: radius,
              border: Border.all(color: border, width: width),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    if (icon != null) ...<Widget>[
                      Icon(
                        icon,
                        size: 24,
                        color: !enabled ? c.disabledText : (selected ? c.primaryText : c.textSecondary),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            title,
                            style: context.text.body.copyWith(fontWeight: FontWeight.w600, color: fg),
                          ),
                          if (caption != null)
                            Text(
                              caption,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: context.text.caption.copyWith(color: c.textSecondary),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    _indicator(c, enabled),
                  ],
                ),
                AnimatedSize(
                  duration: d,
                  curve: context.motion.standard,
                  alignment: Alignment.topCenter,
                  child: selected && body != null
                      ? Padding(padding: const EdgeInsets.only(top: 16), child: body)
                      : const SizedBox(width: double.infinity),
                ),
              ],
            ),
          );
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              DsFocusRing(visible: s.focused, borderRadius: radius, child: card),
              if (errorText != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(errorText!, style: context.text.caption.copyWith(color: c.error)),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _indicator(DsColors c, bool enabled) {
    final Color on = enabled ? c.primaryText : c.disabledText;
    if (indicator == OptionTileIndicator.check) {
      return Icon(
        selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
        size: 20,
        color: selected ? on : (enabled ? c.borderStrong : c.disabledText),
      );
    }
    return Container(
      width: 20,
      height: 20,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: c.surface,
        border: Border.all(color: selected ? on : (enabled ? c.borderStrong : c.disabledText), width: 2),
      ),
      child: selected
          ? Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(shape: BoxShape.circle, color: on),
            )
          : null,
    );
  }
}
