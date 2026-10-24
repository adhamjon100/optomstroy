// Форматы экранов оформления (03 §16.4; 02 §3.10): суммы — `PriceText.format` (тыйыны, D-19), проценты — из сотых
// долей, время — магазина Asia/Bishkek (UTC+6, без перехода на летнее время), телефоны — `+996 700 123 456`.
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/formats/ds_phone_format.dart';

abstract final class CheckoutFormats {
  /// Смещение Asia/Bishkek.
  static const Duration bishkekOffset = Duration(hours: 6);

  /// Сумма «16 007,50 сом».
  static String money(Money m) => PriceText.format(m, fixed2: true);

  /// Процент «5» / «5,5» (без знака %).
  static String percent(Percent p) {
    final int whole = p.hundredths ~/ 100;
    final int frac = p.hundredths.abs() % 100;
    if (frac == 0) return '$whole';
    final String f = frac % 10 == 0 ? '${frac ~/ 10}' : frac.toString().padLeft(2, '0');
    return '$whole,$f';
  }

  /// Момент в часовом поясе магазина.
  static DateTime bishkek(DateTime utc) => utc.toUtc().add(bishkekOffset);

  /// «HH:MM» по Бишкеку.
  static String time(DateTime utc) {
    final DateTime b = bishkek(utc);
    return '${_two(b.hour)}:${_two(b.minute)}';
  }

  /// «ДД.ММ.ГГГГ» (дата без времени — как есть).
  static String date(DateTime d) => '${_two(d.day)}.${_two(d.month)}.${d.year}';

  /// «ММ:СС» для обратного отсчёта.
  static String countdown(Duration d) {
    final int s = d.isNegative ? 0 : d.inSeconds;
    return '${_two(s ~/ 60)}:${_two(s % 60)}';
  }

  /// Телефон E.164 → «+996 700 123 456».
  static String phone(String e164) => DsPhoneFormat.display(e164);

  /// Минуты «HH:MM» → минуты от полуночи; `null` — неверный формат.
  static int? minutesOf(String hhmm) {
    final List<String> p = hhmm.split(':');
    if (p.length != 2) return null;
    final int? h = int.tryParse(p[0]);
    final int? m = int.tryParse(p[1]);
    if (h == null || m == null) return null;
    return h * 60 + m;
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}
