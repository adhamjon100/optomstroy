// Персонаж `Mascot` (03 §9.52, §13; D-40) — заглушка до утверждения стиля (Q-035).
//
// Rive-ассета `assets/rive/mascot_auth.riv` пока нет, поэтому рисует [PlaceholderMascotRenderer]
// (плоский геометрический персонаж палитры 03 §13.2). Рендерер получает те же входы
// `MascotAuth` ([MascotInputs]) — будущий `RiveMascotRenderer` подставляется параметром
// [Mascot.renderer] без изменения экранов и [MascotController].
// Персонаж не фокусируется и исключён из семантики: результат проверки объявляется
// текстом сообщения экрана (03 §13.7).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/auth/presentation/mascot/mascot_controller.dart';
import 'package:optomstroy/features/auth/presentation/mascot/success_check.dart';

/// Рендерер персонажа: заглушка или Rive.
abstract interface class MascotRenderer {
  /// [reduceMotion] — статичные кадры (03 §13.7).
  Widget build(
    BuildContext context,
    MascotInputs inputs,
    double size, { // money-double: allow — геометрия UI (lp)
    required bool reduceMotion,
  });
}

/// Персонаж экранов SCR-01/02/08.
class Mascot extends StatelessWidget {
  const Mascot({
    super.key,
    required this.controller,
    this.size = 160,
    this.renderer = const PlaceholderMascotRenderer(),
  });

  /// Ключ корня (тесты: персонаж на экране / скрыт).
  static const Key rootKey = Key('auth-mascot');

  final MascotController controller;

  /// 160 (compact) / 200 (medium+); 96/72 при клавиатуре.
  final double size; // money-double: allow — геометрия UI (lp)
  final MascotRenderer renderer;

  @override
  Widget build(BuildContext context) {
    final bool reduce = context.motion.reduceMotion;
    return ExcludeSemantics(
      child: SizedBox.square(
        key: rootKey,
        dimension: size,
        child: ValueListenableBuilder<MascotInputs>(
          valueListenable: controller,
          builder: (BuildContext context, MascotInputs inputs, Widget? _) =>
              renderer.build(context, inputs, size, reduceMotion: reduce),
        ),
      ),
    );
  }
}

/// Плоская заглушка: одно лицо, выражение по состоянию, зрачки по `lookX`/`lookY`,
/// «три точки» при `verifying`, `SuccessCheck` при `success`. Бесконечных циклов в `idle`
/// нет (дыхание/моргание появятся в `.riv`); при reduce-motion — статичный кадр.
class PlaceholderMascotRenderer implements MascotRenderer {
  const PlaceholderMascotRenderer();

  /// Ключ статичного кадра (reduce-motion).
  static const Key staticFrameKey = Key('auth-mascot-static');

  @override
  Widget build(
    BuildContext context,
    MascotInputs inputs,
    double /* money-double: allow — геометрия UI */ size, {
    required bool reduceMotion,
  }) {
    final DsColors c = context.colors;
    final Widget face = CustomPaint(
      size: Size.square(size),
      painter: MascotFacePainter(colors: c, state: inputs.state, lookX: inputs.lookX, lookY: inputs.lookY),
    );
    final double check = size >= 120 ? 48 : size * 0.4; // money-double: allow — геометрия UI (lp)
    final List<Widget> layers = <Widget>[
      if (reduceMotion)
        KeyedSubtree(key: staticFrameKey, child: face)
      else
        AnimatedSwitcher(
          duration: context.motion.mascotTransition,
          switchInCurve: context.motion.standard,
          child: KeyedSubtree(key: ValueKey<MascotState>(inputs.state), child: face),
        ),
      if (inputs.state == MascotState.verifying)
        Positioned(
          top: 0,
          right: size * 0.08,
          child: _ThinkingDots(size: size * 0.07, color: c.textSecondary, animate: !reduceMotion),
        ),
      if (inputs.state == MascotState.success) Positioned(right: 0, bottom: 0, child: SuccessCheck(size: check)),
    ];
    return Stack(clipBehavior: Clip.none, children: layers);
  }
}

/// Три точки «думает» (ANIM-004): цикл 1,2 с только в `verifying` и без reduce-motion.
class _ThinkingDots extends StatefulWidget {
  const _ThinkingDots({required this.size, required this.color, required this.animate});

  final double size; // money-double: allow — геометрия UI (lp)
  final Color color;
  final bool animate;

  @override
  State<_ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<_ThinkingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      unawaited(_c.repeat());
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (BuildContext context, Widget? _) {
      final int lit = widget.animate ? (_c.value * 3).floor().clamp(0, 2) : 2;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < 3; i++)
            Container(
              width: widget.size,
              height: widget.size,
              margin: EdgeInsets.only(left: i == 0 ? 0 : widget.size * 0.5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i <= lit ? widget.color : widget.color.withValues(alpha: 0.3),
              ),
            ),
        ],
      );
    },
  );
}

/// Рисует лицо персонажа (палитра 03 §13.2: тело `surfaceVariant`, контур `textSecondary`,
/// глаза `textPrimary`, румянец `primaryContainer`, каска `brandAccent` ≤ 20 % площади).
class MascotFacePainter extends CustomPainter {
  const MascotFacePainter({required this.colors, required this.state, this.lookX = 0, this.lookY = 0});

  final DsColors colors;
  final MascotState state;
  final double lookX; // money-double: allow — геометрия UI (lp)
  final double lookY; // money-double: allow — геометрия UI (lp)

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.shortestSide; // money-double: allow — геометрия UI (lp)
    final double stroke = math.max(1.5, s / 80); // money-double: allow — геометрия UI (lp)
    final Paint outline = Paint()
      ..color = colors.textSecondary
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    final Paint fill = Paint()..color = colors.surfaceVariant;

    // Голова — скруглённый квадрат.
    final Rect head = Rect.fromLTWH(s * 0.16, s * 0.24, s * 0.68, s * 0.66);
    final RRect headR = RRect.fromRectAndRadius(head, Radius.circular(s * 0.22));
    canvas
      ..drawRRect(headR, fill)
      ..drawRRect(headR, outline);

    // Каска (бренд-акцент) и козырёк.
    final Path helmet = Path()
      ..moveTo(head.left + s * 0.02, head.top + s * 0.14)
      ..quadraticBezierTo(head.center.dx, head.top - s * 0.2, head.right - s * 0.02, head.top + s * 0.14)
      ..close();
    canvas
      ..drawPath(helmet, Paint()..color = colors.brandAccent)
      ..drawPath(helmet, outline)
      ..drawLine(
        Offset(head.left - s * 0.02, head.top + s * 0.14),
        Offset(head.right + s * 0.02, head.top + s * 0.14),
        outline..strokeWidth = stroke * 1.4,
      );
    outline.strokeWidth = stroke;

    // Румянец.
    final Paint blush = Paint()..color = colors.primaryContainer;
    canvas
      ..drawCircle(Offset(head.left + s * 0.12, head.top + s * 0.44), s * 0.05, blush)
      ..drawCircle(Offset(head.right - s * 0.12, head.top + s * 0.44), s * 0.05, blush);

    // Глаза: белки + зрачки (взгляд ±6 lp на 160 по lookX/lookY).
    final double eyeY = head.top + s * 0.3; // money-double: allow — геометрия UI (lp)
    final double eyeR = s * 0.075; // money-double: allow — геометрия UI (lp)
    final Offset left = Offset(head.center.dx - s * 0.13, eyeY);
    final Offset right = Offset(head.center.dx + s * 0.13, eyeY);
    final Paint white = Paint()..color = colors.surface;
    final Paint pupil = Paint()..color = colors.textPrimary;
    final double shift = s * 0.0375; // money-double: allow — геометрия UI (lp)
    final Offset look = switch (state) {
      MascotState.verifying => Offset(shift, -shift),
      MascotState.typing || MascotState.retry => Offset(lookX * shift, lookY * shift),
      _ => Offset.zero,
    };
    for (final Offset eye in <Offset>[left, right]) {
      if (state == MascotState.success) {
        // Глаза-полумесяцы.
        canvas.drawArc(
          Rect.fromCircle(center: eye.translate(0, eyeR * 0.3), radius: eyeR),
          math.pi,
          math.pi,
          false,
          outline..strokeWidth = stroke * 1.6,
        );
        outline.strokeWidth = stroke;
        continue;
      }
      final double r = state == MascotState.typing ? eyeR * 1.05 : eyeR; // money-double: allow — геометрия UI (lp)
      canvas
        ..drawCircle(eye, r, white)
        ..drawCircle(eye, r, outline)
        ..drawCircle(eye + look, r * 0.5, pupil);
    }

    // Брови.
    final double browY = eyeY - eyeR * 1.7; // money-double: allow — геометрия UI (lp)
    for (final (Offset eye, double /* money-double: allow — геометрия UI */ dir) in <(Offset, double)>[
      (left, -1),
      (right, 1),
    ]) {
      final double /* money-double: allow — геометрия UI */ lift = switch (state) {
        MascotState.typing => -s * 0.015,
        MascotState.error => 0,
        _ => 0,
      };
      final double tilt = state == MascotState.error ? s * 0.03 * dir : 0; // money-double: allow — геометрия UI (lp)
      canvas.drawLine(
        Offset(eye.dx - eyeR, browY + lift + (state == MascotState.error ? -tilt : 0)),
        Offset(eye.dx + eyeR, browY + lift + (state == MascotState.error ? tilt : 0)),
        outline,
      );
    }

    // Рот.
    final Offset mouth = Offset(head.center.dx, head.top + s * 0.5);
    switch (state) {
      case MascotState.success:
        canvas.drawArc(
          Rect.fromCenter(center: mouth.translate(0, -s * 0.03), width: s * 0.2, height: s * 0.12),
          0,
          math.pi,
          false,
          outline,
        );
      case MascotState.error:
        canvas.drawCircle(mouth, s * 0.035, outline);
      case MascotState.verifying:
        canvas.drawLine(mouth.translate(-s * 0.03, 0), mouth.translate(s * 0.03, 0), outline);
      case MascotState.idle || MascotState.typing || MascotState.retry:
        canvas.drawArc(
          Rect.fromCenter(center: mouth.translate(0, -s * 0.02), width: s * 0.14, height: s * 0.05),
          0,
          math.pi,
          false,
          outline,
        );
    }
  }

  @override
  bool shouldRepaint(MascotFacePainter old) =>
      old.state != state || old.lookX != lookX || old.lookY != lookY || old.colors != colors;
}
