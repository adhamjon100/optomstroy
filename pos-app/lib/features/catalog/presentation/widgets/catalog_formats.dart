// Форматы экранов каталога (03 §16.4): время магазина Asia/Bishkek (UTC+6, без перехода), дата шапки,
// количества (milli-units, без `double`), разбор строк ARB «текст · действие».
// До появления `design_system/formats/DsDateFormat`/`DsQtyFormat` (03 §17.1) — здесь (EQ-CAT-03).
import 'package:intl/intl.dart';
import 'package:optomstroy/core/utils/qty.dart';

abstract final class CatalogFormats {
  /// Смещение Asia/Bishkek.
  static const Duration bishkekOffset = Duration(hours: 6);

  static DateTime _shop(DateTime t) => t.toUtc().add(bishkekOffset);

  /// «09:41».
  static String time(DateTime t) {
    final DateTime s = _shop(t);
    return '${s.hour.toString().padLeft(2, '0')}:${s.minute.toString().padLeft(2, '0')}';
  }

  /// «пн, 29 июн» (`caption` шапки, 02 SCR-10.1 строка 9).
  static String headerDate(DateTime t, String locale) {
    final DateTime s = _shop(t);
    final DateTime local = DateTime(s.year, s.month, s.day);
    return DateFormat('E, d MMM', locale).format(local).replaceAll('.', '');
  }

  /// Количество: «24», «2,5», «−3» (знаки после запятой без хвостовых нулей).
  static String qty(Qty q) {
    final int milli = q.milli;
    final String sign = milli < 0 ? '−' : '';
    final int abs = milli.abs();
    final int whole = abs ~/ 1000;
    final int frac = abs % 1000;
    if (frac == 0) {
      return '$sign$whole';
    }
    final String f = frac.toString().padLeft(3, '0').replaceFirst(RegExp(r'0+$'), '');
    return '$sign$whole,$f';
  }

  /// Строка ARB «Не удалось загрузить · Повторить» → (сообщение, действие). Без « · » — действия нет.
  static (String, String?) splitAction(String text) {
    final int i = text.lastIndexOf(' · ');
    if (i <= 0) {
      return (text, null);
    }
    return (text.substring(0, i), text.substring(i + 3));
  }
}
