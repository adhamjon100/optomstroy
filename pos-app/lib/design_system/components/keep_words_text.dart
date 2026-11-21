// `DsKeepWordsText` — текст, который переносится только по обычным пробелам: «слово» — сумма с неразрывными пробелами
// («16 007,50 сом»), номер заказа («POS-2026-000123»), подпись («Предварительно:») — не разрывается между буквами или
// цифрами и не сжимается (`FittedBox`). Самое длинное слово шире строки в [style] — берётся следующее начертание из
// [fallback] (на ступень меньше), пока слово не поместится; не поместилось и в последнем — последнее начертание
// (дальше — как обычный `Text`). Так суммы и номера в заголовках остаются целыми при крупном тексте (масштаб 1,3–1,5)
// на телефоне и в узких колонках (T-UI-117: находки `midword` и `shrunk`; 03 §8.8; пакет own-server:GAP-APP).
// Ширина известна только при раскладке (`LayoutBuilder`): виджет не для детей `IntrinsicWidth`/`IntrinsicHeight`.
import 'package:flutter/widgets.dart';
import 'package:optomstroy/design_system/layout/text_measure.dart';

/// Текст без разрыва слов: начертание на ступень меньше вместо разрыва или сжатия.
class DsKeepWordsText extends StatelessWidget {
  /// Создаёт текст.
  const DsKeepWordsText(
    this.text, {
    super.key,
    required this.style,
    this.fallback = const <TextStyle>[],
    this.textKey,
    this.textAlign,
    this.maxLines,
    this.overflow,
  });

  /// Текст.
  final String text;

  /// Основное начертание.
  final TextStyle style;

  /// Запасные начертания по убыванию кегля (цвет, вес и цифры — как у [style], их задаёт вызывающий).
  final List<TextStyle> fallback;

  /// Ключ самого `Text` (тесты экранов ищут текст по нему).
  final Key? textKey;

  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;

  /// Начертание для ширины строки [width]: первое из [style] и [fallback], в котором самое длинное слово помещается.
  static TextStyle pick(BuildContext context, String text, double width, TextStyle style, List<TextStyle> fallback) {
    TextStyle chosen = style;
    for (final TextStyle s in <TextStyle>[style, ...fallback]) {
      chosen = s;
      if (dsLongestWordWidth(context, text, s) <= width + 0.01) break;
    }
    return chosen;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints box) => Text(
      text,
      key: textKey,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
      style: box.hasBoundedWidth && fallback.isNotEmpty ? pick(context, text, box.maxWidth, style, fallback) : style,
    ),
  );
}
