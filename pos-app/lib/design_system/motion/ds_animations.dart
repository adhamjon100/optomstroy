import 'package:flutter/widgets.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_motion.dart';

/// Именованная конфигурация анимации реестра ANIM-NNN (03 §11.2, §17.5).
@immutable
class AnimSpec {
  /// Создаёт конфигурацию.
  const AnimSpec({required this.id, required this.duration, required this.curve, this.amplitude = 0});

  /// ID реестра (`ANIM-012`).
  final String id;

  /// Длительность (без учёта reduce-motion; виджеты берут её через `DsMotion.of`).
  final Duration duration;

  /// Кривая.
  final Curve curve;

  /// Амплитуда в lp (shake).
  final double amplitude;
}

/// Анимации, используемые компонентами первой очереди RM-C-003. Остальные ANIM-NNN
/// добавляют задачи, реализующие соответствующие компоненты (фичи этапов D–G).
abstract final class DsAnimations {
  /// ANIM-012: shake ±4 lp, 0→−4→4→−2→0 за 300 мс.
  static const AnimSpec shake = AnimSpec(
    id: 'ANIM-012',
    duration: Duration(milliseconds: 300),
    curve: Curves.linear,
    amplitude: 4,
  );

  /// ANIM-013: шиммер скелетона, цикл 1,2 с, linear.
  static const AnimSpec skeletonShimmer = AnimSpec(
    id: 'ANIM-013',
    duration: Duration(milliseconds: 1200),
    curve: Curves.linear,
  );

  /// ANIM-015: hover / pressed — 150 мс `standard`.
  static AnimSpec get hoverPressed =>
      AnimSpec(id: 'ANIM-015', duration: DsMotion.defaults.fast, curve: DsMotion.defaults.standard);

  /// ANIM-022: пустое состояние — fade-in 200 мс `standardDecelerate`.
  static AnimSpec get emptyState =>
      AnimSpec(id: 'ANIM-022', duration: DsMotion.defaults.base, curve: DsMotion.defaults.standardDecelerate);

  /// ANIM-023: диалог — scale .96→1 + fade, 250 мс `standardDecelerate`.
  static AnimSpec get dialog => AnimSpec(
    id: 'ANIM-023',
    duration: DsMotion.defaults.mascotTransition,
    curve: DsMotion.defaults.standardDecelerate,
  );

  /// ANIM-025: bottom sheet — slide-up 250 мс `standardDecelerate`.
  static AnimSpec get bottomSheet => AnimSpec(
    id: 'ANIM-025',
    duration: DsMotion.defaults.mascotTransition,
    curve: DsMotion.defaults.standardDecelerate,
  );

  /// ANIM-027: снекбар — slide-up 8 lp + fade 150 мс.
  static AnimSpec get snackbar =>
      AnimSpec(id: 'ANIM-027', duration: DsMotion.defaults.fast, curve: DsMotion.defaults.standard);
}

/// Shake ANIM-012: запускается при увеличении [trigger] (ошибка OTP/PIN/поля).
/// Под reduce-motion — без движения (состояние error передают цвет и текст).
class DsShake extends StatefulWidget {
  /// Создаёт обёртку.
  const DsShake({super.key, required this.trigger, required this.child});

  /// Счётчик ошибок: каждое увеличение запускает один цикл.
  final int trigger;

  /// Элемент.
  final Widget child;

  @override
  State<DsShake> createState() => _DsShakeState();
}

class _DsShakeState extends State<DsShake> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: DsAnimations.shake.duration);

  static final Animatable<double> _offset = TweenSequence<double>(<TweenSequenceItem<double>>[
    TweenSequenceItem<double>(tween: Tween<double>(begin: 0, end: -1), weight: 1),
    TweenSequenceItem<double>(tween: Tween<double>(begin: -1, end: 1), weight: 2),
    TweenSequenceItem<double>(tween: Tween<double>(begin: 1, end: -0.5), weight: 1.5),
    TweenSequenceItem<double>(tween: Tween<double>(begin: -0.5, end: 0), weight: 0.5),
  ]);

  @override
  void didUpdateWidget(DsShake oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.trigger > oldWidget.trigger && !context.motion.reduceMotion) {
      _c
        ..reset()
        ..forward().ignore();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (BuildContext context, Widget? child) =>
          Transform.translate(offset: Offset(_offset.evaluate(_c) * DsAnimations.shake.amplitude, 0), child: child),
    );
  }
}
