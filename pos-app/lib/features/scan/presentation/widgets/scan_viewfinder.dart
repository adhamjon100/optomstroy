// Видоискатель SCR-17 (UI-17-003): затемнение `overlay` вокруг рамки ≈ 70 % ширины (3:2),
// смещение рамки −10 % по вертикали, углы 3 lp `onInverseSurface` (в палитре B `onPrimary` тёмный — EQ-SCAN-06); линия-подсказка `primary` 2 lp —
// ANIM-029 (сверху вниз, 1,5 с, loop; reduce motion — статичная линия по центру);
// подтверждение ANIM-030 — рамка `success`/`error` 300 мс (цвет задаёт экран через [flash]).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';

/// Подсветка рамки после распознавания.
enum ViewfinderFlash {
  /// Найден/распознан.
  success,

  /// Не найден / не распознан.
  error,
}

/// Рамка-видоискатель поверх превью.
class ScanViewfinder extends StatefulWidget {
  /// Создаёт видоискатель.
  const ScanViewfinder({super.key, this.flash, this.active = true});

  /// Подсветка рамки (`null` — обычная).
  final ViewfinderFlash? flash;

  /// Сканирование активно (линия движется).
  final bool active;

  /// Доля ширины, занятая рамкой.
  static const double frameWidthFactor = 0.7; // money-double: allow — геометрия UI (lp)

  /// Прямоугольник рамки в области [size].
  static Rect frameRect(Size size) {
    final width = size.width * frameWidthFactor;
    final height = width * 2 / 3;
    final center = Offset(size.width / 2, size.height / 2 - size.height * 0.1);
    return Rect.fromCenter(center: center, width: width, height: height);
  }

  @override
  State<ScanViewfinder> createState() => _ScanViewfinderState();
}

class _ScanViewfinderState extends State<ScanViewfinder> with SingleTickerProviderStateMixin {
  late final AnimationController _line = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(ScanViewfinder oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  void _syncAnimation() {
    final animate = widget.active && !context.motion.reduceMotion;
    if (animate && !_line.isAnimating) {
      unawaited(_line.repeat());
    } else if (!animate && _line.isAnimating) {
      _line.stop();
    }
  }

  @override
  void dispose() {
    _line.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final reduce = context.motion.reduceMotion;
    final frameColor = switch (widget.flash) {
      ViewfinderFlash.success => c.success,
      ViewfinderFlash.error => c.error,
      null => c.onInverseSurface,
    };
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _line,
        builder: (context, _) => CustomPaint(
          size: Size.infinite,
          painter: _ViewfinderPainter(
            dim: c.overlay,
            frame: frameColor,
            line: c.primary,
            progress: reduce || !widget.active ? 0.5 : _line.value,
            showLine: widget.active || reduce,
          ),
        ),
      ),
    );
  }
}

class _ViewfinderPainter extends CustomPainter {
  _ViewfinderPainter({
    required this.dim,
    required this.frame,
    required this.line,
    required this.progress,
    required this.showLine,
  });

  final Color dim;
  final Color frame;
  final Color line;
  final double progress; // money-double: allow — геометрия UI (lp)
  final bool showLine;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = ScanViewfinder.frameRect(size);
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(rect);
    canvas.drawPath(outside, Paint()..color = dim);

    final corner = rect.shortestSide * 0.15;
    final paint = Paint()
      ..color = frame
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square;
    for (final (Offset p, double /* money-double: allow — геометрия UI */ dx, double dy) in <(Offset, double, double)>[
      (rect.topLeft, 1, 1),
      (rect.topRight, -1, 1),
      (rect.bottomLeft, 1, -1),
      (rect.bottomRight, -1, -1),
    ]) {
      canvas
        ..drawLine(p, p + Offset(corner * dx, 0), paint)
        ..drawLine(p, p + Offset(0, corner * dy), paint);
    }
    if (showLine) {
      final y = rect.top + rect.height * progress;
      canvas.drawLine(
        Offset(rect.left + 8, y),
        Offset(rect.right - 8, y),
        Paint()
          ..color = line
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_ViewfinderPainter old) =>
      old.progress != progress || old.frame != frame || old.dim != dim || old.line != line || old.showLine != showLine;
}
