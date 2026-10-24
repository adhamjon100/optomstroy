// `SuccessCheck` (03 §9.67, §13.6; ANIM-005): круг `success` scale 0→1 (250 мс `emphasized`)
// + галочка `onSuccess`. Только после ответа сервера 2xx; при reduce-motion — crossfade ≤ 80 мс
// без scale. Компонент DS (п. 9.67) — до переноса в design_system живёт в фиче auth (RM-D-007).
import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

class SuccessCheck extends StatelessWidget {
  const SuccessCheck({super.key, this.size = 48});

  static const Key rootKey = Key('auth-success-check');

  /// 48 (персонаж) / 72 / 96.
  final double size; // money-double: allow — геометрия UI (lp)

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool reduce = context.motion.reduceMotion;
    final Widget badge = Container(
      key: rootKey,
      width: size,
      height: size,
      decoration: BoxDecoration(color: c.success, shape: BoxShape.circle),
      child: Icon(Icons.check_rounded, size: size * 0.66, color: c.onSuccess),
    );
    if (reduce) {
      return TweenAnimationBuilder<double /* money-double: allow — анимация UI */>(
        tween: Tween<double>(begin: 0, end: 1), // money-double: allow — анимация UI
        duration: context.motion.reducedCrossfade,
        builder:
            (BuildContext context, double t, Widget? child) => // money-double: allow — геометрия UI (lp)
                Opacity(opacity: t, child: child),
        child: badge,
      );
    }
    return TweenAnimationBuilder<double /* money-double: allow — анимация UI */>(
      tween: Tween<double>(begin: 0, end: 1), // money-double: allow — анимация UI
      duration: const Duration(milliseconds: 250),
      curve: context.motion.emphasized,
      builder:
          (BuildContext context, double t, Widget? child) => // money-double: allow — геометрия UI (lp)
              Transform.scale(scale: t, child: child),
      child: badge,
    );
  }
}
