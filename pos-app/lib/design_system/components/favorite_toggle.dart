import 'dart:async';

import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Вид `FavoriteToggle` (03 §9.23).
enum FavoriteToggleVariant {
  /// На фото в сетке: круг 32 `surface` 80 % + иконка 20; цель 48.
  onImage,

  /// В строке списка: иконка 24, цель 48 (40 визуально).
  inline,
}

/// Избранное `FavoriteToggle` (03 §9.23; ядро §8.1, v1.9 §24.1): только звезда (DS-094).
/// Выкл. — `star` outlined `warning`; вкл. — заливка `favorite` + контур `warning`.
/// Optimistic-переключение и снекбары — у вызывающего кода; здесь — визуал и ANIM-009
/// (scale 1 → 1,3 → 1 за 200 мс; reduce-motion — мгновенно).
class FavoriteToggle extends StatefulWidget {
  /// Создаёт переключатель.
  const FavoriteToggle({
    super.key,
    required this.selected,
    required this.onChanged,
    required this.semanticLabel,
    this.variant = FavoriteToggleVariant.inline,
  });

  /// В избранном.
  final bool selected;

  /// Новое значение; `null` — скрытое право (не рисуется активным).
  final ValueChanged<bool>? onChanged;

  /// «Добавить в избранное» / «В избранном».
  final String semanticLabel;

  /// Вид.
  final FavoriteToggleVariant variant;

  @override
  State<FavoriteToggle> createState() => _FavoriteToggleState();
}

class _FavoriteToggleState extends State<FavoriteToggle> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));

  @override
  void didUpdateWidget(FavoriteToggle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected && widget.selected && !context.motion.reduceMotion) {
      unawaited(_pulse.forward(from: 0));
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool onImage = widget.variant == FavoriteToggleVariant.onImage;
    final double iconSize = onImage ? 20 : 24;
    final Widget star = widget.selected
        ? Stack(
            alignment: Alignment.center,
            children: <Widget>[
              Icon(Icons.star_rounded, size: iconSize, color: c.favorite),
              Icon(Icons.star_border_rounded, size: iconSize, color: c.warning),
            ],
          )
        : Icon(Icons.star_border_rounded, size: iconSize, color: c.warning);
    final Widget animated = AnimatedBuilder(
      animation: _pulse,
      builder: (BuildContext context, Widget? child) {
        final double t = _pulse.value;
        final double scale = t == 0 ? 1 : 1 + 0.3 * (t < 0.5 ? t * 2 : (1 - t) * 2);
        return Transform.scale(scale: scale, child: child);
      },
      child: star,
    );
    return Semantics(
      button: true,
      toggled: widget.selected,
      label: widget.semanticLabel,
      excludeSemantics: true,
      child: DsInteractive(
        onTap: widget.onChanged == null ? null : () => widget.onChanged!(!widget.selected),
        enabled: widget.onChanged != null,
        builder: (BuildContext context, DsInteractionState s) {
          final Color? hover = s.pressed ? c.iconButtonPressed : (s.hovered ? c.surfaceVariant : null);
          return SizedBox.square(
            dimension: 48,
            child: Center(
              child: DsFocusRing(
                visible: s.focused,
                circle: true,
                child: Container(
                  width: onImage ? 32 : 40,
                  height: onImage ? 32 : 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: hover ?? (onImage ? c.surface.withValues(alpha: 0.8) : Colors.transparent),
                  ),
                  child: animated,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
