import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Ширина строки текста в lp с учётом масштаба шрифта и направления текста контекста — для оценки ширины
/// компонентов до раскладки (панель управления каталога выбирает, помещаются ли подписи в одну строку).
///
/// Результат запоминается (последние [_cacheLimit] пар «текст, стиль, масштаб, направление»): строка управления
/// каталога оценивает одни и те же подписи на каждой перестройке экрана — при вводе в поиск и при «+ Добавить».
/// Смена набора шрифтов (`PaintingBinding.systemFonts`: шрифт загружен позже первого измерения — запасной шрифт веба,
/// `FontLoader`) очищает запомненное — иначе ширина колонки и порядок сворачивания строки управления считались бы по
/// прежнему шрифту.
double dsTextWidth(BuildContext context, String text, TextStyle style) => dsTextWidthWith(
  text,
  style,
  scaler: MediaQuery.textScalerOf(context),
  direction: Directionality.maybeOf(context) ?? TextDirection.ltr,
);

/// [dsTextWidth] без `BuildContext`: масштаб [scaler] и направление [direction] заданы явно (высота ряда сетки
/// каталога по ценам карточек — `kProductCardGridPriceWraps`, ревью V-01). Тот же кэш.
double dsTextWidthWith(
  String text,
  TextStyle style, {
  TextScaler scaler = TextScaler.noScaling,
  TextDirection direction = TextDirection.ltr,
}) {
  _listenFontChanges();
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

/// Номер набора шрифтов измерений [dsTextWidth]: растёт при смене шрифтов (`PaintingBinding.systemFonts`). Экран,
/// который считает ширины в `build` (колонка и лента каталога, строка управления), подписывается и перестраивается —
/// иначе после поздней загрузки шрифта ширины оставались бы прежними до случайной перестройки (ревью R2C-14).
ValueListenable<int> get dsTextMeasureEpoch {
  _listenFontChanges();
  return _epoch;
}

final ValueNotifier<int> _epoch = ValueNotifier<int>(0);

/// Наибольшее число запомненных измерений.
const int _cacheLimit = 1024;

final LinkedHashMap<_MeasureKey, double> _cache = LinkedHashMap<_MeasureKey, double>();

bool _fontListener = false;

/// Один раз подписывает очистку [_cache] и шаг [dsTextMeasureEpoch] на смену шрифтов.
void _listenFontChanges() {
  if (_fontListener) {
    return;
  }
  _fontListener = true;
  PaintingBinding.instance.systemFonts.addListener(_onFontsChanged);
}

void _onFontsChanged() {
  _cache.clear();
  _epoch.value++;
}

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
