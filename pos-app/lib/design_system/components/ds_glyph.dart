import 'package:flutter/widgets.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';

/// Глифы прототипа экрана выбора товаров (SVG, сетка 24 × 24; 03 §9.10, §9.25, §9.26; ADR-114), которых нет в наборе
/// Material Icons или которые в нём рисуются иначе. Контуры — линия [DsGlyph.color]; залитые — заливка [DsGlyph.color]
/// и белый знак [DsGlyph.markColor].
enum DsGlyphKind {
  /// «Четыре квадрата» контуром — заглушка карточки ленты подкатегорий и «Все товары» (линия 1,8).
  gridOutline,

  /// Штрихкод в рамке — кнопка сканера в поле поиска (линия 1,8).
  barcodeScan,

  /// Двойная стрелка «вниз · вверх» — кнопка сортировки строки управления каталога (линия 2).
  sortArrows,

  /// Маркированный список (три линии с точками) — сегмент «Список» строки управления каталога (линия 2,2).
  bulletList,

  /// Лупа поля поиска шапки (линия 2).
  magnifier,

  /// Тележка кнопки корзины в шапке (линия 2).
  cart,

  /// Колокол уведомлений (линия 1,8).
  bell,

  /// Звезда избранного: карточка товара (линия 1,8; заливка — [DsGlyph.fillColor]) и чип «Избранные» (линия 2).
  star,

  /// Часы — чип «Новые» (линия 2).
  clock,

  /// «Четыре квадрата» заливкой — сегмент «Сетка».
  gridFilled,

  /// Четыре линии — сегмент «Компакт» (линия 2,2).
  compactLines,

  /// Воронка — чип «Фильтры» (линия 2).
  filter,

  /// Картинка — плашка «Фото появится из 1С» (линия 1,6).
  photo,

  /// Человек — строка «Клиент» drawer корзины (линия 1,8).
  person,

  /// Крест — закрыть drawer (линия 2,2), удалить строку корзины (линия 2,4).
  cross,

  /// Шеврон «‹» — стрелка ленты подкатегорий (линия 2,4).
  chevronLeft,

  /// Шеврон «›» — стрелка ленты подкатегорий (линия 2,4), строка «Клиент» drawer (линия 2,2).
  chevronRight,

  /// Круг с галочкой — «В наличии» (заливка `stockIn`) и тост «Добавлено» (`toastCheck`); знак — линия 2,4.
  checkCircle,

  /// Треугольник с «!» — «Мало» (заливка `stockLowIcon`); знак — линия 2,2.
  warningTriangle,

  /// Круг с крестом — «Нет в наличии» (заливка `stockOutIcon`); знак — линия 2,2.
  crossCircle,

  /// Круг с «?» — «Остаток неизвестен» (заливка `stockOutIcon`; в прототипе состояния нет, глиф — в стиле
  /// [crossCircle]); знак — линия 2,2.
  questionCircle,
}

/// Декоративный глиф [kind] в квадрате [size] (сетка 24 × 24 прототипа). Толщина линии по умолчанию — как в прототипе
/// (см. [DsGlyphKind]); [strokeWidth] задаёт другую (в единицах сетки 24 — масштабируется вместе с глифом, как SVG).
/// Подпись задаёт родитель (кнопка, плитка, строка наличия) — глиф из семантики исключён.
class DsGlyph extends StatelessWidget {
  /// Создаёт глиф.
  const DsGlyph({
    super.key,
    required this.kind,
    required this.color,
    this.size = 24,
    this.strokeWidth,
    this.fillColor,
    this.markColor,
  });

  /// Вид глифа.
  final DsGlyphKind kind;

  /// Цвет линии контурного глифа или заливки залитого ([DsGlyphKind.gridFilled], круги и треугольник наличия).
  final Color color;

  /// Сторона квадрата (lp).
  final double size; // money-double: allow — размер глифа (lp)

  /// Толщина линии в единицах сетки 24; `null` — как в прототипе.
  final double? strokeWidth; // money-double: allow — толщина линии глифа (lp)

  /// Заливка под контуром ([DsGlyphKind.star] в избранном); `null` — без заливки.
  final Color? fillColor;

  /// Цвет знака на залитых глифах наличия и тоста; `null` — `surface` (белый, как в прототипе).
  final Color? markColor;

  /// Толщина линии прототипа для [kind] (единицы сетки 24).
  static double defaultStrokeOf(DsGlyphKind kind) => switch (kind) {
    DsGlyphKind.photo => 1.6,
    DsGlyphKind.gridOutline ||
    DsGlyphKind.barcodeScan ||
    DsGlyphKind.bell ||
    DsGlyphKind.star ||
    DsGlyphKind.person => 1.8,
    DsGlyphKind.bulletList ||
    DsGlyphKind.compactLines ||
    DsGlyphKind.cross ||
    DsGlyphKind.warningTriangle ||
    DsGlyphKind.crossCircle ||
    DsGlyphKind.questionCircle => 2.2,
    DsGlyphKind.chevronLeft || DsGlyphKind.chevronRight || DsGlyphKind.checkCircle => 2.4,
    DsGlyphKind.sortArrows ||
    DsGlyphKind.magnifier ||
    DsGlyphKind.cart ||
    DsGlyphKind.clock ||
    DsGlyphKind.gridFilled ||
    DsGlyphKind.filter => 2,
  };

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: CustomPaint(
      size: Size.square(size),
      painter: _GlyphPainter(
        kind: kind,
        color: color,
        stroke: strokeWidth ?? defaultStrokeOf(kind),
        fill: fillColor,
        mark: markColor ?? context.colors.surface,
      ),
    ),
  );
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter({
    required this.kind,
    required this.color,
    required this.stroke,
    required this.fill,
    required this.mark,
  });

  final DsGlyphKind kind;
  final Color color;
  final double stroke; // money-double: allow — толщина линии глифа (lp)
  final Color? fill;
  final Color mark;

  Paint _line(Color c, double width, {StrokeJoin join = StrokeJoin.round}) => Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = join
    ..strokeWidth = width
    ..isAntiAlias = true;

  Paint _solid(Color c) => Paint()
    ..color = c
    ..style = PaintingStyle.fill
    ..isAntiAlias = true;

  @override
  void paint(Canvas canvas, Size size) {
    final double k = size.width / 24; // money-double: allow — масштаб сетки 24 (lp)
    canvas.scale(k);
    final Paint paint = _line(color, stroke);
    switch (kind) {
      case DsGlyphKind.gridOutline:
        for (final Offset o in const <Offset>[Offset(4, 4), Offset(13, 4), Offset(4, 13), Offset(13, 13)]) {
          canvas.drawRRect(RRect.fromRectAndRadius(o & const Size(7, 7), const Radius.circular(1.5)), paint);
        }
      case DsGlyphKind.gridFilled:
        for (final Offset o in const <Offset>[Offset(3, 3), Offset(13, 3), Offset(3, 13), Offset(13, 13)]) {
          canvas.drawRRect(RRect.fromRectAndRadius(o & const Size(8, 8), const Radius.circular(1.5)), _solid(color));
        }
      case DsGlyphKind.barcodeScan:
        const Radius r = Radius.circular(1);
        final Path frame = Path()
          ..moveTo(4, 7)
          ..lineTo(4, 5)
          ..arcToPoint(const Offset(5, 4), radius: r)
          ..lineTo(7, 4)
          ..moveTo(17, 4)
          ..lineTo(19, 4)
          ..arcToPoint(const Offset(20, 5), radius: r)
          ..lineTo(20, 7)
          ..moveTo(20, 17)
          ..lineTo(20, 19)
          ..arcToPoint(const Offset(19, 20), radius: r)
          ..lineTo(17, 20)
          ..moveTo(7, 20)
          ..lineTo(5, 20)
          ..arcToPoint(const Offset(4, 19), radius: r)
          ..lineTo(4, 17);
        for (final double x in const <double>[8, 11, 14, 16.5]) {
          frame
            ..moveTo(x, 8)
            ..lineTo(x, 16);
        }
        canvas.drawPath(frame, paint);
      case DsGlyphKind.sortArrows:
        final Path arrows = Path()
          ..moveTo(7, 4)
          ..lineTo(7, 20)
          ..moveTo(3.5, 16.5)
          ..lineTo(7, 20)
          ..lineTo(10.5, 16.5)
          ..moveTo(17, 20)
          ..lineTo(17, 4)
          ..moveTo(13.5, 7.5)
          ..lineTo(17, 4)
          ..lineTo(20.5, 7.5);
        canvas.drawPath(arrows, paint);
      case DsGlyphKind.bulletList:
        // Прототип: path M9 6h12 M9 12h12 M9 18h12 + круги r = 1 в (4,5; 6 / 12 / 18), stroke 2,2.
        final Path lines = Path();
        for (final double y in const <double>[6, 12, 18]) {
          lines
            ..moveTo(9, y)
            ..lineTo(21, y)
            ..addOval(Rect.fromCircle(center: Offset(4.5, y), radius: 1));
        }
        canvas.drawPath(lines, paint);
      case DsGlyphKind.compactLines:
        final Path lines = Path();
        for (final double y in const <double>[5, 9.7, 14.3, 19]) {
          lines
            ..moveTo(4, y)
            ..lineTo(20, y);
        }
        canvas.drawPath(lines, paint);
      case DsGlyphKind.magnifier:
        canvas
          ..drawCircle(const Offset(11, 11), 7, paint)
          ..drawLine(const Offset(20, 20), const Offset(16.5, 16.5), paint);
      case DsGlyphKind.cart:
        const Radius r = Radius.circular(1);
        final Path body = Path()
          ..moveTo(3, 4)
          ..lineTo(5, 4)
          ..lineTo(7.2, 14.2)
          ..arcToPoint(const Offset(8.2, 15), radius: r, clockwise: false)
          ..lineTo(16.8, 15)
          ..arcToPoint(const Offset(17.8, 14.2), radius: r, clockwise: false)
          ..lineTo(19.5, 8)
          ..lineTo(6.2, 8);
        canvas
          ..drawPath(body, paint)
          ..drawCircle(const Offset(9, 19), 1.4, paint)
          ..drawCircle(const Offset(17, 19), 1.4, paint);
      case DsGlyphKind.bell:
        // M6 9a6 6 0 0 1 12 0c0 5 2 6.5 2 6.5H4S6 14 6 9 + M10 19a2 2 0 0 0 4 0.
        final Path bell = Path()
          ..moveTo(6, 9)
          ..arcToPoint(const Offset(18, 9), radius: const Radius.circular(6))
          ..cubicTo(18, 14, 20, 15.5, 20, 15.5)
          ..lineTo(4, 15.5)
          ..cubicTo(4, 15.5, 6, 14, 6, 9)
          ..moveTo(10, 19)
          ..arcToPoint(const Offset(14, 19), radius: const Radius.circular(2), clockwise: false);
        canvas.drawPath(bell, paint);
      case DsGlyphKind.star:
        final Path star = Path()
          ..moveTo(12, 3.8)
          ..lineTo(14.5, 9)
          ..lineTo(20.1, 9.7)
          ..lineTo(16, 13.6)
          ..lineTo(17, 19.2)
          ..lineTo(12, 16.5)
          ..lineTo(7, 19.2)
          ..lineTo(8, 13.6)
          ..lineTo(3.9, 9.7)
          ..lineTo(9.5, 9)
          ..close();
        if (fill != null) {
          canvas.drawPath(star, _solid(fill!));
        }
        canvas.drawPath(star, paint);
      case DsGlyphKind.clock:
        // Прототип: stroke-linecap round без linejoin — угол стрелок острый (miter).
        final Paint miter = _line(color, stroke, join: StrokeJoin.miter);
        canvas
          ..drawCircle(const Offset(12, 12), 8.5, miter)
          ..drawPath(
            Path()
              ..moveTo(12, 7.5)
              ..lineTo(12, 12)
              ..lineTo(15, 14),
            miter,
          );
      case DsGlyphKind.filter:
        final Path funnel = Path()
          ..moveTo(4, 5)
          ..lineTo(20, 5)
          ..lineTo(13.8, 12.4)
          ..lineTo(13.8, 19)
          ..lineTo(10.2, 17.2)
          ..lineTo(10.2, 12.4)
          ..close();
        canvas.drawPath(funnel, paint);
      case DsGlyphKind.photo:
        canvas
          ..drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(3.5, 5, 17, 14), const Radius.circular(2)), paint)
          ..drawCircle(const Offset(9, 10), 1.6, paint)
          ..drawPath(
            Path()
              ..moveTo(20.5, 16)
              ..lineTo(16, 11.5)
              ..lineTo(8, 19),
            paint,
          );
      case DsGlyphKind.person:
        // circle 12,8 r4 + M4 20c1.5-4 4.5-6 8-6s6.5 2 8 6.
        canvas
          ..drawCircle(const Offset(12, 8), 4, paint)
          ..drawPath(
            Path()
              ..moveTo(4, 20)
              ..cubicTo(5.5, 16, 8.5, 14, 12, 14)
              ..cubicTo(15.5, 14, 18.5, 16, 20, 20),
            paint,
          );
      case DsGlyphKind.cross:
        canvas
          ..drawLine(const Offset(6, 6), const Offset(18, 18), paint)
          ..drawLine(const Offset(18, 6), const Offset(6, 18), paint);
      case DsGlyphKind.chevronLeft:
        canvas.drawPath(
          Path()
            ..moveTo(15, 6)
            ..lineTo(9, 12)
            ..lineTo(15, 18),
          paint,
        );
      case DsGlyphKind.chevronRight:
        canvas.drawPath(
          Path()
            ..moveTo(9, 6)
            ..lineTo(15, 12)
            ..lineTo(9, 18),
          paint,
        );
      case DsGlyphKind.checkCircle:
        canvas
          ..drawCircle(const Offset(12, 12), 10, _solid(color))
          ..drawPath(
            Path()
              ..moveTo(7.5, 12.3)
              ..lineTo(10.5, 15.3)
              ..lineTo(16.5, 9),
            _line(mark, stroke),
          );
      case DsGlyphKind.warningTriangle:
        canvas
          ..drawPath(
            Path()
              ..moveTo(12, 3)
              ..lineTo(21.5, 20)
              ..lineTo(2.5, 20)
              ..close(),
            _solid(color),
          )
          ..drawLine(const Offset(12, 9.5), const Offset(12, 14), _line(mark, stroke))
          ..drawLine(const Offset(12, 16.8), const Offset(12, 17), _line(mark, stroke));
      case DsGlyphKind.crossCircle:
        canvas
          ..drawCircle(const Offset(12, 12), 10, _solid(color))
          ..drawLine(const Offset(8.5, 8.5), const Offset(15.5, 15.5), _line(mark, stroke))
          ..drawLine(const Offset(15.5, 8.5), const Offset(8.5, 15.5), _line(mark, stroke));
      case DsGlyphKind.questionCircle:
        // Знак «?» в стиле знаков прототипа: дуга r 2,6 + хвост и точка, линия 2,2.
        canvas
          ..drawCircle(const Offset(12, 12), 10, _solid(color))
          ..drawPath(
            Path()
              ..moveTo(9.4, 9.6)
              ..arcToPoint(const Offset(14.6, 9.8), radius: const Radius.circular(2.6))
              ..cubicTo(14.6, 11.4, 12, 11.8, 12, 13.6),
            _line(mark, stroke),
          )
          ..drawLine(const Offset(12, 16.8), const Offset(12, 17), _line(mark, stroke));
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.kind != kind || old.color != color || old.stroke != stroke || old.fill != fill || old.mark != mark;
}
