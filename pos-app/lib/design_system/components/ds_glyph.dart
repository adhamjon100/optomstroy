import 'package:flutter/widgets.dart';

/// Контурные глифы прототипа 2026-10-29, которых нет в наборе Material Icons (03 §9.10, §9.25, §9.26).
enum DsGlyphKind {
  /// «Четыре квадрата» контуром — заглушка карточки ленты подкатегорий и «Все товары».
  gridOutline,

  /// Штрихкод в рамке — кнопка сканера в поле поиска.
  barcodeScan,

  /// Двойная стрелка «вниз · вверх» — кнопка сортировки строки управления каталога.
  sortArrows,

  /// Маркированный список (три линии с точками) — сегмент «Список» строки управления каталога.
  bulletList,
}

/// Декоративный контурный глиф [kind] в квадрате [size] (сетка 24 × 24 прототипа, толщина линии — как в прототипе:
/// 1,8 у сетки и штрихкода, 2 у стрелок, 2,2 у списка). Подпись задаёт родитель (кнопка, плитка) — глиф из семантики
/// исключён.
class DsGlyph extends StatelessWidget {
  /// Создаёт глиф.
  const DsGlyph({super.key, required this.kind, required this.color, this.size = 24});

  /// Вид глифа.
  final DsGlyphKind kind;

  /// Цвет линии.
  final Color color;

  /// Сторона квадрата (lp).
  final double size; // money-double: allow — размер глифа (lp)

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: CustomPaint(size: Size.square(size), painter: _GlyphPainter(kind, color)),
  );
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.kind, this.color);

  final DsGlyphKind kind;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double k = size.width / 24; // money-double: allow — масштаб сетки 24 (lp)
    canvas.scale(k);
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = switch (kind) {
        DsGlyphKind.sortArrows => 2,
        DsGlyphKind.bulletList => 2.2,
        DsGlyphKind.gridOutline || DsGlyphKind.barcodeScan => 1.8,
      };
    switch (kind) {
      case DsGlyphKind.gridOutline:
        for (final Offset o in const <Offset>[Offset(4, 4), Offset(13, 4), Offset(4, 13), Offset(13, 13)]) {
          canvas.drawRRect(RRect.fromRectAndRadius(o & const Size(7, 7), const Radius.circular(1.5)), paint);
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
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.kind != kind || old.color != color;
}
