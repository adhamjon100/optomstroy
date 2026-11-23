// `DsWordSafeLabel` — подпись в 1–2 строки, которая переносится только между словами (03 §9.10; указание владельца
// 2026-11-18 об адаптивности, 15 §5.8 — [ВЫВОД исполнителя]): «Смесител|и», «Санфаян|с», «Смесит|ели» не бывает.
// Помещаются все слова — обычный `Text` с переносом по словам; слово шире строки — строки собираются по словам
// (не больше двух, по высоте места), каждая — в одну линию с многоточием. Общая для плиток категорий
// (`CategoryTile`: сетка, колонка, лента) и строки сайдбара (`CategorySidebarItem`).
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/layout/text_measure.dart';

/// Подпись с переносом только между словами.
class DsWordSafeLabel extends StatelessWidget {
  /// Создаёт подпись.
  const DsWordSafeLabel({
    super.key,
    required this.text,
    required this.style,
    this.textAlign = TextAlign.center,
    this.maxLines = 2,
    this.firstLineKey,
  });

  final String text;
  final TextStyle style;

  /// Выравнивание строк (плитки — по центру, сайдбар — от начала).
  final TextAlign textAlign;

  /// Не больше строк (при недостатке высоты — одна).
  final int maxLines;

  /// Ключ первой строки (тесты: `category-tile-label`).
  final Key? firstLineKey;

  CrossAxisAlignment get _cross => switch (textAlign) {
    TextAlign.center || TextAlign.justify => CrossAxisAlignment.center,
    TextAlign.end || TextAlign.right => CrossAxisAlignment.end,
    TextAlign.start || TextAlign.left => CrossAxisAlignment.start,
  };

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints box) {
      final TextScaler scaler = MediaQuery.textScalerOf(context);
      final double lineHeight = scaler.scale(style.fontSize ?? 12) * (style.height ?? 1.2);
      final int lines = maxLines > 1 && (!box.hasBoundedHeight || box.maxHeight + 0.5 >= lineHeight * 2) ? maxLines : 1;
      final List<String> words = text.split(RegExp(r'\s+')).where((String w) => w.isNotEmpty).toList();
      final double maxWidth = box.maxWidth;
      double widest = 0;
      for (final String word in words) {
        widest = math.max(widest, dsTextWidth(context, word, style));
      }
      if (!box.hasBoundedWidth || widest <= maxWidth) {
        // Все слова помещаются в строку — обычный перенос по словам.
        return Text(
          text,
          key: firstLineKey,
          maxLines: lines,
          textAlign: textAlign,
          overflow: TextOverflow.ellipsis,
          style: style,
        );
      }
      // Слово шире строки: строки собираются по словам (≤ lines), каждая — в одну линию с многоточием.
      final double space = dsTextWidth(context, ' ', style);
      final List<String> out = <String>[];
      String current = '';
      double width = 0;
      for (final String word in words) {
        final double w = dsTextWidth(context, word, style);
        if (current.isEmpty) {
          current = word;
          width = w;
        } else if (out.isEmpty && width + space + w <= maxWidth - 1) {
          current = '$current $word';
          width += space + w;
        } else if (out.isEmpty) {
          out.add(current);
          current = word;
          width = w;
        } else {
          current = '$current $word';
        }
      }
      if (current.isNotEmpty) out.add(current);
      if (out.length > lines) {
        out.replaceRange(lines - 1, out.length, <String>[out.sublist(lines - 1).join(' ')]);
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: _cross,
        children: <Widget>[
          for (int i = 0; i < out.length; i++)
            Text(
              out[i],
              key: i == 0 ? firstLineKey : null,
              maxLines: 1,
              softWrap: false,
              textAlign: textAlign,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
        ],
      );
    },
  );
}
