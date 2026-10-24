// Правило допустимого значения штрихкода (08 §4.5.2; 02 SCR-17.8): 3…64 символа `[0-9A-Za-z-]`.
// Общее для HID-сканера (core/hardware/scanner_wedge_service.dart) и камеры (SCR-17).
// Чистый Dart.

/// Проверка и нормализация значения штрихкода.
abstract final class BarcodeValue {
  /// Минимальная длина кода (08 §4.5.2).
  static const int minLength = 3;

  /// Максимальная длина кода (08 §4.5.2).
  static const int maxLength = 64;

  static final RegExp _allowed = RegExp(r'^[0-9A-Za-z-]+$');

  /// Значение без пробелов по краям (сканеры иногда добавляют пробел/CR в начале или конце).
  static String normalize(String raw) => raw.trim();

  /// `true` — [value] (после [normalize]) можно отправлять в `GET /search/barcode/{value}`.
  static bool isValid(String value) {
    final v = normalize(value);
    return v.length >= minLength && v.length <= maxLength && _allowed.hasMatch(v);
  }

  /// Символ допустим в значении штрихкода.
  static bool isAllowedChar(String char) => char.length == 1 && _allowed.hasMatch(char);
}
