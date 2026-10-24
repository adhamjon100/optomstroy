// Телефон Кыргызстана (+996) — нормализация ввода и E.164 для API (R3 §10, 09 §4).
//
// Национальный номер (NSN) — 9 цифр; хранение и передача на сервер — E.164
// `+996XXXXXXXXX`; шаблон показа — «+996 XXX XXX XXX». Вставка «0XXX…», «996…»,
// «+996…» с любыми пробелами/скобками/дефисами нормализуется.
// Признак «мобильный» — по метаданным libphonenumber (`phone_numbers_parser`);
// операторские диапазоны требуют проверки у заказчика (R3 §10) — поэтому
// [PhoneNumber.tryParse] проверяет только структуру, а [PhoneNumber.isMobile] —
// отдельный признак для UI. Решение о существовании аккаунта — только сервер.
// Телефон пользователя на устройстве не хранится (07 §11.1 п.4).
import 'package:phone_numbers_parser/phone_numbers_parser.dart' as lib;

final class PhoneNumber {
  const PhoneNumber._(this.nsn);

  /// Разбор ввода пользователя или значения API; `null` — не номер КР.
  static PhoneNumber? tryParse(String input) {
    final trimmed = input.trim();
    final digits = trimmed.replaceAll(_nonDigits, '');
    final String nsn;
    if (digits.length == nsnLength) {
      nsn = digits;
    } else if (digits.length == nsnLength + 1 && digits.startsWith('0')) {
      nsn = digits.substring(1);
    } else if (digits.length == nsnLength + countryCode.length && digits.startsWith(countryCode)) {
      nsn = digits.substring(countryCode.length);
    } else {
      return null;
    }
    // «+» допустим только перед кодом страны.
    if (trimmed.startsWith('+') && !digits.startsWith(countryCode)) return null;
    if (nsn.startsWith('0')) return null;
    return PhoneNumber._(nsn);
  }

  /// Строгий разбор: E.164 `+996XXXXXXXXX` (формат API `PhoneE164`).
  static PhoneNumber? tryParseE164(String value) {
    final match = _e164.firstMatch(value);
    return match == null ? null : PhoneNumber._(match.group(1)!);
  }

  static const String countryCode = '996';
  static const int nsnLength = 9;

  /// Национальный номер — 9 цифр без кода страны.
  final String nsn;

  /// E.164 для API: `+996555123456`.
  String get e164 => '+$countryCode$nsn';

  /// Шаблон «+996 XXX XXX XXX» (маска поля SCR-01; DS-форматтер телефона повторяет его).
  String get grouped => '+$countryCode ${nsn.substring(0, 3)} ${nsn.substring(3, 6)} ${nsn.substring(6)}';

  /// Маска для логов и диагностики: `+996***3456` (06 §6.7, NFR-LOG-001).
  String get masked => '+$countryCode***${nsn.substring(nsnLength - 4)}';

  /// Мобильный номер по метаданным libphonenumber для KG.
  bool get isMobile => lib.PhoneNumber(isoCode: lib.IsoCode.KG, nsn: nsn).isValid(type: lib.PhoneNumberType.mobile);

  @override
  bool operator ==(Object other) => other is PhoneNumber && other.nsn == nsn;

  @override
  int get hashCode => nsn.hashCode;

  /// Без ПДн: только маска.
  @override
  String toString() => 'PhoneNumber($masked)';
}

final RegExp _nonDigits = RegExp(r'\D');
final RegExp _e164 = RegExp(r'^\+996([1-9]\d{8})$');
