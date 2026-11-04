import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Толщина рамок прототипа, заданных в CSS-px, — так, как их рисует Chrome (ADR-114): толщина округляется вниз до
/// целых пикселей экрана, но не меньше одного: `max(1, floor(css · dpr)) / dpr` логических пикселей.
///
/// Рамка 1,5 прототипа (плитки категорий, карточки ленты, «В корзине · N — ещё +1») при DPR 1 — 1 lp, при 1,25 — 0,8,
/// при 1,5 — 1,33, при 2 — 1,5; рамка 1 при DPR 1,25 — 0,8 (ровно один пиксель экрана, без размытия). Так линии
/// каталога, шапки и drawer корзины остаются чёткими на любом масштабе Windows и совпадают со снимками прототипа.
abstract final class DsHairline {
  /// Толщина (lp) рамки [css] CSS-px при плотности пикселей [devicePixelRatio].
  static double widthFor(double css, double devicePixelRatio) {
    final double dpr = devicePixelRatio > 0 ? devicePixelRatio : 1;
    // Запас 1e-6: 1,5 × 2 = 3 не должно стать 2 из-за ошибки округления.
    return math.max(1, (css * dpr + 1e-6).floorToDouble()) / dpr;
  }

  /// Толщина (lp) рамки [css] CSS-px для плотности пикселей окна [context].
  static double of(BuildContext context, [double css = 1]) =>
      widthFor(css, MediaQuery.maybeDevicePixelRatioOf(context) ?? 1);

  /// Сторона рамки цвета [color] толщиной [css] CSS-px.
  static BorderSide side(BuildContext context, Color color, [double css = 1]) =>
      BorderSide(color: color, width: of(context, css));

  /// Рамка со всех сторон цвета [color] толщиной [css] CSS-px.
  static Border all(BuildContext context, Color color, [double css = 1]) =>
      Border.fromBorderSide(side(context, color, css));
}
