import 'package:flutter/services.dart';

/// Форматирование телефона Кыргызстана для UI (03 §17.8): отображение `+996 XXX XXX XXX`,
/// нормализация ввода в E.164 `+996XXXXXXXXX` (ядро §17.2). Только отображение и разбор
/// строки; проверка типа номера (`phone_numbers_parser`) — на уровне фичи.
abstract final class DsPhoneFormat {
  /// Код страны.
  static const String countryCode = '996';

  /// Длина национального номера.
  static const int nationalLength = 9;

  /// `+996XXXXXXXXX` → `+996 XXX XXX XXX`. Нераспознанная строка возвращается как есть.
  static String display(String e164) {
    final String? national = nationalDigits(e164);
    if (national == null || national.length != nationalLength) {
      return e164;
    }
    return '+$countryCode ${groupNational(national)}';
  }

  /// Ввод пользователя («0XXX…», «996…», «+996…», с пробелами/скобками) → E.164 или `null`.
  static String? normalize(String input) {
    final String? national = nationalDigits(input);
    if (national == null || national.length != nationalLength) {
      return null;
    }
    return '+$countryCode$national';
  }

  /// Национальные цифры (≤ 9) из произвольной строки; `null` — нет ни одной цифры.
  static String? nationalDigits(String input) {
    String digits = input.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) {
      return null;
    }
    final bool hasPlus = input.trimLeft().startsWith('+');
    if (digits.length > nationalLength && digits.startsWith(countryCode)) {
      digits = digits.substring(countryCode.length);
    } else if (hasPlus && digits.startsWith(countryCode)) {
      digits = digits.substring(countryCode.length);
    } else if (digits.length == nationalLength + 1 && digits.startsWith('0')) {
      digits = digits.substring(1);
    }
    return digits.length > nationalLength ? digits.substring(0, nationalLength) : digits;
  }

  /// `700123456` → `700 123 456` (частичный ввод группируется по мере набора).
  static String groupNational(String digits) {
    final StringBuffer b = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      if (i == 3 || i == 6) {
        b.write(' ');
      }
      b.write(digits[i]);
    }
    return b.toString();
  }
}

/// Маска поля `PhoneField`: только цифры, ≤ 9, группы `XXX XXX XXX`; вставка «0…», «996…»,
/// «+996…» нормализуется (03 §9.4).
class DsPhoneInputFormatter extends TextInputFormatter {
  /// Создаёт форматтер.
  const DsPhoneInputFormatter();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final String raw = newValue.text;
    final int inserted = raw.length - oldValue.text.length;
    // Вставка целого номера — нормализация с кодом страны; посимвольный ввод — только цифры.
    final String digits = inserted > 1
        ? (DsPhoneFormat.nationalDigits(raw) ?? '')
        : _limit(raw.replaceAll(RegExp(r'\D'), ''));
    final String text = DsPhoneFormat.groupNational(digits);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  static String _limit(String d) => d.length > DsPhoneFormat.nationalLength ? d.substring(0, 9) : d;
}
