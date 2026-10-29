import 'dart:collection';

import 'package:flutter/widgets.dart';

/// Ширина строки текста в lp с учётом масштаба шрифта и направления текста контекста — для оценки ширины
/// компонентов до раскладки (панель управления каталога выбирает, помещаются ли подписи в одну строку).
///
/// Результат запоминается (последние [_cacheLimit] пар «текст, стиль, масштаб, направление»): строка управления
/// каталога оценивает одни и те же подписи на каждой перестройке экрана — при вводе в поиск и при «+ Добавить».
double dsTextWidth(BuildContext context, String text, TextStyle style) {
  final TextDirection direction = Directionality.maybeOf(context) ?? TextDirection.ltr;
  final TextScaler scaler = MediaQuery.textScalerOf(context);
  final _MeasureKey key = _MeasureKey(text, style, scaler, direction);
  final double? cached = _cache.remove(key);
  if (cached != null) {
    _cache[key] = cached; // в конец — недавно использованная
    return cached;
  }
  final TextPainter painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: direction,
    textScaler: scaler,
    maxLines: 1,
  )..layout();
  final double width = painter.width;
  painter.dispose();
  _cache[key] = width;
  if (_cache.length > _cacheLimit) _cache.remove(_cache.keys.first);
  return width;
}

/// Наибольшее число запомненных измерений.
const int _cacheLimit = 256;

final LinkedHashMap<_MeasureKey, double> _cache = LinkedHashMap<_MeasureKey, double>();

@immutable
class _MeasureKey {
  const _MeasureKey(this.text, this.style, this.scaler, this.direction);

  final String text;
  final TextStyle style;
  final TextScaler scaler;
  final TextDirection direction;

  @override
  bool operator ==(Object other) =>
      other is _MeasureKey &&
      other.text == text &&
      other.style == style &&
      other.scaler == scaler &&
      other.direction == direction;

  @override
  int get hashCode => Object.hash(text, style, scaler, direction);
}
