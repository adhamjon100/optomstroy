// Маскирование ПДн и секретов в строках для логов (06 §6.7, NFR-LOG-001, 11 SEC-*).
// Логгер не пишет тела запросов/ответов вовсе; маскер — вторая линия защиты
// для сообщений ошибок, путей и query-строк.

abstract final class PiiMasker {
  /// Заменяет телефоны (`+996***1234`), Bearer/JWT, значения полей-секретов
  /// (`refreshToken`, `accessToken`, `otp`, `code`, `pin`, `password`, `token`)
  /// и одиночные коды из 4–6 цифр.
  static String mask(String input) {
    var out = input.replaceAllMapped(_bearer, (m) => '${m.group(1)} ***');
    out = out.replaceAll(_jwt, '***');
    out = out.replaceAllMapped(_secretField, (m) => '${m.group(1)}***');
    out = out.replaceAllMapped(_phone, (m) {
      final digits = m.group(0)!.replaceAll(RegExp(r'\D'), '');
      return '+996***${digits.substring(digits.length - 4)}';
    });
    return out.replaceAll(_shortCode, '***');
  }
}

final RegExp _bearer = RegExp(r'(Bearer)\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false);
final RegExp _jwt = RegExp(r'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*');
final RegExp _secretField = RegExp(
  r'''(["']?(?:refreshToken|accessToken|registrationToken|stepUpToken|biometricRefresh|otp|code|pin|password|token)["']?\s*[:=]\s*["']?)[^"'&,\s}]+''',
  caseSensitive: false,
);
final RegExp _phone = RegExp(r'(?:\+?996|\b0)[\s()-]*\d{3}[\s()-]*\d{3}[\s()-]*\d{3}\b');
final RegExp _shortCode = RegExp(r'(?<![\d*])\d{4,6}(?![\d*])');
