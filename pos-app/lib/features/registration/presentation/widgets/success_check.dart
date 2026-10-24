// `SuccessCheck` (03 §9.67; ANIM-005; ядро §17.5): галочка подтверждения ПОЛУЧЕННОГО от сервера успеха.
// Круг `success` scale 0→1 (250 мс `emphasized`) + штрих галочки `onSuccess` 0→100 % (200 мс, старт через 100 мс);
// reduce-motion — crossfade ≤ 80 мс к финальному кадру. Навигацию не выполняет: [onCompleted] — экрану.
// Не фокусируется, `excludeSemantics` (результат объявляет текст экрана). Rive/Lottie-артборда в сборке нет
// (assets/rive не поставлен) — анимация нарисована CustomPainter, финальный кадр совпадает со статичной иконкой.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';

class SuccessCheck extends StatefulWidget {
  const SuccessCheck({super.key, this.size = 48, this.play = true, this.onCompleted});

  /// 48 (с персонажем, шаг «Готово») / 72 (SCR-06) / 96.
  final double size; // money-double: allow — геометрия UI (lp)

  /// Запуск анимации.
  final bool play;

  /// Анимация завершена (финальный кадр виден).
  final VoidCallback? onCompleted;

  @override
  State<SuccessCheck> createState() => _SuccessCheckState();
}

class _SuccessCheckState extends State<SuccessCheck> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeStart();
  }

  @override
  void didUpdateWidget(SuccessCheck oldWidget) {
    super.didUpdateWidget(oldWidget);
    _maybeStart();
  }

  void _maybeStart() {
    if (!widget.play || _started) return;
    _started = true;
    if (context.motion.reduceMotion) {
      _controller.value = 1;
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onCompleted?.call());
      return;
    }
    unawaited(_controller.forward().whenComplete(() => widget.onCompleted?.call()));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final curve = context.motion.emphasized;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: widget.size,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final t = _controller.value;
            final circle = curve.transform((t / (250 / 350)).clamp(0.0, 1.0));
            final stroke = ((t * 350 - 100) / 200).clamp(0.0, 1.0);
            return CustomPaint(
              painter: _CheckPainter(circle: circle, stroke: stroke, fill: c.success, mark: c.onSuccess),
            );
          },
        ),
      ),
    );
  }
}

class _CheckPainter extends CustomPainter {
  _CheckPainter({required this.circle, required this.stroke, required this.fill, required this.mark});

  final double circle; // money-double: allow — геометрия UI (lp)
  final double stroke; // money-double: allow — геометрия UI (lp)
  final Color fill;
  final Color mark;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 * circle;
    canvas.drawCircle(center, radius, Paint()..color = fill);
    if (stroke <= 0) return;
    final s = size.shortestSide;
    final path = Path()
      ..moveTo(s * 0.28, s * 0.52)
      ..lineTo(s * 0.44, s * 0.67)
      ..lineTo(s * 0.73, s * 0.36);
    final metric = path.computeMetrics().first;
    canvas.drawPath(
      metric.extractPath(0, metric.length * stroke),
      Paint()
        ..color = mark
        ..style = PaintingStyle.stroke
        ..strokeWidth = s / 12
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.circle != circle || old.stroke != stroke;
}
