// Локальная валидация SCR-03/SCR-04 (09 §7.1, §7.4, §9.6; 02 SCR-03.8, SCR-04.4). Сервер валидирует повторно
// (`400 VALIDATION_FAILED`); клиент лишь подсказывает раньше. Чистый Dart.

/// Ошибка поля «ФИО».
enum FullNameError { required, length, invalid }

/// Итог проверки ФИО: ошибка (блокирует) и предупреждение «одно слово» (не блокирует).
final class FullNameCheck {
  const FullNameCheck({this.error, this.oneWordWarning = false});

  final FullNameError? error;
  final bool oneWordWarning;

  bool get isValid => error == null;
}

/// Ошибка поля «Год рождения».
enum BirthYearError { required, range }

/// Слабый PIN (09 §9.6, Q-163) — причина для тестов; UI показывает один текст `reg_error_pin_weak`.
enum PinWeakness { length, nonDigit, repeated, sequence, birthYear }

abstract final class RegistrationValidation {
  /// Минимальный год рождения (ядро §19.3; до ответа Q-161).
  static const int minBirthYear = 1920;

  /// Минимальный возраст: `год ≤ текущий − 14`.
  static const int minAge = 14;

  static const int fullNameMinLength = 2;
  static const int fullNameMaxLength = 120;

  /// Уточнение «Другое» (UI-03-016).
  static const int otherSphereMaxLength = 60;

  /// Допустимые символы ФИО: кириллица (включая кыргызские Ң Ө Ү), латиница, пробел, дефис, апостроф.
  static final RegExp fullNameAllowed = RegExp(r"^[A-Za-zЀ-ӿ \-'’]*$");

  /// Символы, которые фильтр ввода удаляет (цифры и прочие).
  static final RegExp fullNameDisallowedChar = RegExp(r"[^A-Za-zЀ-ӿ \-'’]");

  static final RegExp _spaces = RegExp(r'\s+');
  static final RegExp _digits = RegExp(r'^\d+$');

  /// trim + схлопывание повторных пробелов (при потере фокуса и перед отправкой).
  static String normalizeFullName(String raw) => raw.trim().replaceAll(_spaces, ' ');

  static int maxBirthYear(int currentYear) => currentYear - minAge;

  static FullNameCheck checkFullName(String raw) {
    final value = normalizeFullName(raw);
    if (value.isEmpty) return const FullNameCheck(error: FullNameError.required);
    if (!fullNameAllowed.hasMatch(value)) return const FullNameCheck(error: FullNameError.invalid);
    if (value.length < fullNameMinLength || value.length > fullNameMaxLength) {
      return const FullNameCheck(error: FullNameError.length);
    }
    return FullNameCheck(oneWordWarning: !value.contains(' '));
  }

  static BirthYearError? checkBirthYear(String raw, {required int currentYear}) {
    final value = raw.trim();
    if (value.isEmpty) return BirthYearError.required;
    if (value.length != 4 || !_digits.hasMatch(value)) return BirthYearError.range;
    final year = int.parse(value);
    if (year < minBirthYear || year > maxBirthYear(currentYear)) return BirthYearError.range;
    return null;
  }

  /// Слабый PIN или `null`. [birthYear] — из черновика (PIN не должен содержать год рождения).
  static PinWeakness? pinWeakness(String pin, {required int length, int? birthYear}) {
    if (pin.length != length) return PinWeakness.length;
    if (!_digits.hasMatch(pin)) return PinWeakness.nonDigit;
    final codes = pin.codeUnits;
    if (codes.every((c) => c == codes.first)) return PinWeakness.repeated;
    var ascending = true;
    var descending = true;
    for (var i = 1; i < codes.length; i++) {
      final step = codes[i] - codes[i - 1];
      ascending &= step == 1;
      descending &= step == -1;
    }
    if (ascending || descending) return PinWeakness.sequence;
    if (birthYear != null && pin.contains('$birthYear')) return PinWeakness.birthYear;
    return null;
  }

  /// SCR-03 «Продолжить» активна: ФИО непустое, год — 4 цифры, отмечено ознакомление (AC-UI-03-003).
  static bool formReady({required String fullName, required String birthYear, required bool personalDataAck}) =>
      fullName.trim().isNotEmpty && birthYear.length == 4 && _digits.hasMatch(birthYear) && personalDataAck;
}
