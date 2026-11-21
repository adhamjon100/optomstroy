import 'package:flutter/services.dart';
import 'package:optomstroy/design_system/formats/ds_text_edit.dart';

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

  /// Маска номера `+996 7** *** *01` (03 §16.4, §9.4; DS-102): видны первая цифра оператора и две последние цифры.
  ///
  /// Только для номера, который ввёл сам покупатель на планшете магазина (шаг «Код» SCR-52): ответ
  /// `POST /kiosk/order-otp` номер не повторяет (08 §4.25). Остальные экраны показывают `phoneMasked` сервера.
  /// Принимается только номер целиком (`+996` и 9 цифр, «0» и 9 цифр или 9 цифр), без усечения лишних цифр, как у
  /// [normalize]; иначе номер не раскрывается — `+996 *** *** ***`.
  static String masked(String e164) {
    final String digits = e164.replaceAll(RegExp(r'\D'), '');
    final String? national = switch (digits.length) {
      nationalLength => digits,
      10 when digits.startsWith('0') => digits.substring(1),
      12 when digits.startsWith(countryCode) => digits.substring(countryCode.length),
      _ => null,
    };
    if (national == null) {
      return '+$countryCode ${groupNational(_hidden * nationalLength)}';
    }
    final String shown = national[0] + _hidden * (nationalLength - 3) + national.substring(nationalLength - 2);
    return '+$countryCode ${groupNational(shown)}';
  }

  /// Знак скрытой цифры маски.
  static const String _hidden = '*';

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
    final bool hasPlus = input.replaceAll(formatChars, '').trimLeft().startsWith('+');
    if (digits.length > nationalLength && digits.startsWith(countryCode)) {
      digits = digits.substring(countryCode.length);
    } else if (hasPlus && digits.startsWith(countryCode)) {
      digits = digits.substring(countryCode.length);
    } else if (digits.length == nationalLength + 1 && digits.startsWith('0')) {
      digits = digits.substring(1);
    }
    return digits.length > nationalLength ? digits.substring(0, nationalLength) : digits;
  }

  /// Невидимые знаки форматирования (Unicode `Cf`: знаки направления U+200E, U+202A…U+202C, U+2066…U+2069, ZWSP,
  /// BOM), которыми мессенджеры обрамляют скопированный номер: перед проверкой «+» в начале строки отбрасываются.
  static final RegExp formatChars = RegExp(r'\p{Cf}', unicode: true);

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

/// Итог правки поля номера `PhoneField` (03 §9.4; 09 §3.2 п. 1–3; 02 SCR-01.4 п. 3, п. 5): национальные цифры
/// поля и что потеряно при нормализации. Вставленный фрагмент — по [DsTextEdit] (вставка поверх выделения и в
/// непустое поле распознаётся по фрагменту, а не по разнице длин).
///
/// * **Номер целиком** — вставлено (не набрано) 9 цифр и больше или строка с «+» и цифрами после кода страны: он
///   **заменяет** поле, а не дописывается к прежним цифрам. Нормализация: «+996…», «00996…» (международный префикс
///   «00») и «996…» длиннее 9 цифр — без кода страны; «0…» длиннее 9 цифр — без национального префикса «0»;
///   пробелы, скобки, дефисы, неразрывные пробелы, знаки направления и переводы строк отбрасываются. «8…» длиннее
///   9 цифр, «+» или «00» с другим кодом страны — [unsupportedFormat], в поле — первые 9 цифр, как прежде. «+» ищется
///   после невидимых знаков форматирования ([DsPhoneFormat.formatChars]).
/// * **Один код страны** — вставлено «+996» без цифр номера: префикс поля и так «+996», цифр в поле не добавляется
///   (прежние цифры поля остаются).
/// * **Иначе** (набор цифры, вставка части номера, удаление) — цифры до выделения, фрагмента и после него.
///
/// Во всех случаях в поле не больше 9 цифр; лишние отбрасываются — [overflow] (09 §3.3: `auth_phone_error_long`).
final class DsPhoneEdit {
  const DsPhoneEdit._(this.digits, {this.overflow = false, this.unsupportedFormat = false});

  /// Разбор правки `oldValue` → `newValue`.
  factory DsPhoneEdit.of(TextEditingValue oldValue, TextEditingValue newValue) {
    final DsTextEdit edit = DsTextEdit.of(oldValue, newValue);
    final String inserted = DsTextEdit.digitsOf(edit.inserted);
    final bool plus = edit.inserted.replaceAll(DsPhoneFormat.formatChars, '').trimLeft().startsWith('+');
    const String cc = DsPhoneFormat.countryCode;
    if (edit.isPaste && plus && inserted == cc) {
      // Только код страны «+996»: префикс поля его уже показывает — цифр номера вставка не добавляет.
      return _limited(DsTextEdit.digitsOf(edit.before) + DsTextEdit.digitsOf(edit.after));
    }
    if (edit.isPaste && (inserted.length >= DsPhoneFormat.nationalLength || (plus && inserted.length > cc.length))) {
      return _whole(inserted, plus: plus);
    }
    return _limited(DsTextEdit.digitsOf(edit.before) + inserted + DsTextEdit.digitsOf(edit.after));
  }

  /// Национальные цифры поля (≤ 9).
  final String digits;

  /// Цифр было больше 9 — лишние отброшены.
  final bool overflow;

  /// Вставлен номер в неподдерживаемом формате («8 (…)», чужой код страны).
  final bool unsupportedFormat;

  /// Значение поля: группы `XXX XXX XXX`, курсор в конце.
  TextEditingValue get value {
    final String text = DsPhoneFormat.groupNational(digits);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  static DsPhoneEdit _limited(String national, {bool unsupported = false}) {
    const int max = DsPhoneFormat.nationalLength;
    final bool overflow = national.length > max;
    return DsPhoneEdit._(
      overflow ? national.substring(0, max) : national,
      overflow: overflow,
      unsupportedFormat: unsupported,
    );
  }

  /// Вставлен номер целиком: [digits] — его цифры, [plus] — строка начинается с «+».
  static DsPhoneEdit _whole(String digits, {required bool plus}) {
    const String cc = DsPhoneFormat.countryCode;
    const int max = DsPhoneFormat.nationalLength;
    if (plus) {
      return digits.startsWith(cc) ? _limited(digits.substring(cc.length)) : _limited(digits, unsupported: true);
    }
    if (digits.startsWith('00')) {
      // Международный префикс «00»: «00996…» = «+996…».
      final String rest = digits.substring(2);
      return rest.startsWith(cc) ? _limited(rest.substring(cc.length)) : _limited(digits, unsupported: true);
    }
    if (digits.length > max) {
      if (digits.startsWith(cc)) return _limited(digits.substring(cc.length));
      if (digits.startsWith('0')) return _limited(digits.substring(1));
      if (digits.startsWith('8')) return _limited(digits, unsupported: true);
    }
    return _limited(digits);
  }
}

/// Маска поля `PhoneField`: только цифры, ≤ 9, группы `XXX XXX XXX`, курсор в конце; вставленный номер целиком
/// («0…», «996…», «+996…», «00996…» — в том числе поверх выделения и в непустое поле) нормализуется и заменяет
/// поле (03 §9.4; правило — [DsPhoneEdit]).
class DsPhoneInputFormatter extends TextInputFormatter {
  /// Создаёт форматтер.
  const DsPhoneInputFormatter();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      DsPhoneEdit.of(oldValue, newValue).value;
}
