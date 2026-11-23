import 'package:flutter/services.dart';

/// Правка поля `oldValue` → `newValue`, разобранная на неизменные части и вставленный фрагмент (03 §9.4, §9.5;
/// 02 SCR-01.4 п. 3, п. 5, SCR-02.4 п. 5).
///
/// Вставка (`Ctrl+V`, «Вставить» меню, вставка браузера, подсказка клавиатуры) заменяет выделение прежнего значения:
/// новый текст = [before] + [inserted] + [after], где [before] и [after] — текст до и после выделения. Удаление
/// подряд идущих символов при свёрнутом курсоре (`Backspace`, `Delete`, отмена `Ctrl+Z`) так не раскладывается, но
/// новый текст — прежний без одного отрезка: [inserted] пуст, [before] и [after] — оставшиеся части, это не вставка.
/// Иначе (замена всего значения автозаполнением или `enterText` тестов) фрагментом считается весь новый текст,
/// [before] и [after] пусты. Поэтому вставка поверх выделенного номера распознаётся по фрагменту, а не по разнице
/// длин (ревью вставки 2026-11-08, R3), а стирание разделителя в номере из 9 цифр вставкой не считается.
final class DsTextEdit {
  const DsTextEdit._(this.before, this.inserted, this.after);

  /// Разбор правки.
  factory DsTextEdit.of(TextEditingValue oldValue, TextEditingValue newValue) {
    final String oldText = oldValue.text;
    final String newText = newValue.text;
    final TextSelection sel = oldValue.selection;
    if (sel.isValid && sel.start >= 0 && sel.end <= oldText.length) {
      final String before = oldText.substring(0, sel.start);
      final String after = oldText.substring(sel.end);
      if (newText.length >= before.length + after.length && newText.startsWith(before) && newText.endsWith(after)) {
        return DsTextEdit._(before, newText.substring(before.length, newText.length - after.length), after);
      }
    }
    if (newText.length < oldText.length) {
      // Удаление одного отрезка: новый текст = общее начало + общий конец прежнего (конец не заходит в начало).
      int p = 0;
      while (p < newText.length && oldText.codeUnitAt(p) == newText.codeUnitAt(p)) {
        p++;
      }
      int s = 0;
      while (s < newText.length - p &&
          oldText.codeUnitAt(oldText.length - 1 - s) == newText.codeUnitAt(newText.length - 1 - s)) {
        s++;
      }
      if (p + s == newText.length) return DsTextEdit._(newText.substring(0, p), '', newText.substring(p));
    }
    return DsTextEdit._('', newText, '');
  }

  /// Прежний текст до выделения.
  final String before;

  /// Вставленный или набранный фрагмент.
  final String inserted;

  /// Прежний текст после выделения.
  final String after;

  /// Вставка, а не набор одного символа: фрагмент длиннее одного символа.
  bool get isPaste => inserted.length > 1;

  /// Только ASCII-цифры [text].
  static String digitsOf(String text) => text.replaceAll(RegExp(r'\D'), '');
}
