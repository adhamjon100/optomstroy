// Локальная проверка номера SCR-01 (09 §3.2–§3.4; 02 SCR-01.8): 9 цифр после +996,
// мобильный диапазон KG по метаданным libphonenumber. Существование аккаунта — только сервер.
import 'package:optomstroy/core/utils/phone_number.dart';

/// Что не так с номером.
enum PhoneIssue {
  /// Пусто (`auth_phone_error_empty`).
  empty,

  /// Меньше 9 цифр (`auth_phone_error_short`).
  short,

  /// 9 цифр, но не мобильный номер KG (`auth_phone_error_invalid`).
  invalid,
}

/// Итог проверки.
final class PhoneCheck {
  const PhoneCheck._({required this.digits, this.e164, this.issue});

  /// Национальные цифры (≤ 9).
  final String digits;

  /// `+996XXXXXXXXX`, если номер валиден.
  final String? e164;
  final PhoneIssue? issue;

  bool get isValid => e164 != null;

  /// Сколько цифр осталось ввести (подсказка «Ещё {n} цифр»).
  int get remaining => PhoneNumber.nsnLength - digits.length;

  /// Без номера (NFR-LOG-001).
  @override
  String toString() => 'PhoneCheck(${digits.length} digits, ${issue?.name ?? 'ok'})';
}

/// Проверка ввода поля `PhoneField` (отображаемая строка «XXX XXX XXX» или цифры).
final class ValidatePhone {
  const ValidatePhone();

  PhoneCheck call(String input) {
    String digits = input.replaceAll(RegExp(r'\D'), '');
    if (digits.length > PhoneNumber.nsnLength) {
      digits = digits.substring(0, PhoneNumber.nsnLength);
    }
    if (digits.isEmpty) {
      return PhoneCheck._(digits: digits, issue: PhoneIssue.empty);
    }
    if (digits.length < PhoneNumber.nsnLength) {
      return PhoneCheck._(digits: digits, issue: PhoneIssue.short);
    }
    final PhoneNumber? phone = PhoneNumber.tryParse(digits);
    if (phone == null || !phone.isMobile) {
      return PhoneCheck._(digits: digits, issue: PhoneIssue.invalid);
    }
    return PhoneCheck._(digits: digits, e164: phone.e164);
  }
}
