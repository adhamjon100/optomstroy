// Настройки HID-сканера в режиме клавиатуры (D-42, Q-009; 02 п. 2.2.11, SCR-42 UI-42-012/018).
// Суффикс — `Settings.scanner.suffix` (`enter|tab|none`, 08 §3.14); порог между символами —
// настройка устройства (E_spec_questions EQ-SCAN-01). Чистый Dart.
import 'dart:convert';

/// Окончание скана, которое сканер добавляет после кода (`Settings.scanner.suffix`).
enum ScannerSuffix {
  /// `Enter` (стандартная настройка сканеров).
  enter('enter'),

  /// `Tab`.
  tab('tab'),

  /// Без окончания: скан завершается паузой после последнего символа.
  none('none');

  const ScannerSuffix(this.apiValue);

  /// Значение в API (`Settings.scanner.suffix`).
  final String apiValue;

  /// Значение по строке API; неизвестное — [enter].
  static ScannerSuffix parse(String? value) {
    for (final s in values) {
      if (s.apiValue == value) return s;
    }
    return enter;
  }
}

/// Параметры распознавания скана среди нажатий клавиш.
final class ScannerWedgeConfig {
  /// Создаёт настройки.
  const ScannerWedgeConfig({
    this.suffix = ScannerSuffix.enter,
    this.interKeyThreshold = defaultInterKeyThreshold,
    this.suffixTimeout = defaultSuffixTimeout,
    this.noSuffixIdle = defaultNoSuffixIdle,
    this.minLength = 3,
    this.maxLength = 64,
  });

  /// Из JSON настройки устройства (`settings.scanner.wedge`); неизвестные/битые поля — по умолчанию.
  factory ScannerWedgeConfig.fromJson(Map<String, Object?> json) {
    final ms = json['interKeyMs'];
    final threshold = ms is int && allowedThresholdsMs.contains(ms)
        ? Duration(milliseconds: ms)
        : defaultInterKeyThreshold;
    final suffix = json['suffix'];
    return ScannerWedgeConfig(
      suffix: ScannerSuffix.parse(suffix is String ? suffix : null),
      interKeyThreshold: threshold,
    );
  }

  /// Порог по умолчанию: символы с интервалом < 50 мс — сканер (02 п. 2.2.11, RM-E-010).
  static const Duration defaultInterKeyThreshold = Duration(milliseconds: 50);

  /// Если после быстрых символов окончание не пришло за 300 мс — обрыв (02 SCR-42 UI-42-012).
  static const Duration defaultSuffixTimeout = Duration(milliseconds: 300);

  /// Режим «Без суффикса»: скан завершён, если 150 мс нет нового символа [ТИПОВО, EQ-SCAN-02].
  static const Duration defaultNoSuffixIdle = Duration(milliseconds: 150);

  /// Значения порога, доступные в настройке SCR-42 (мс) [ТИПОВО, EQ-SCAN-01].
  static const List<int> allowedThresholdsMs = <int>[30, 50, 80, 100];

  /// Окончание скана.
  final ScannerSuffix suffix;

  /// Интервал между символами, меньше которого ввод считается сканом.
  final Duration interKeyThreshold;

  /// Сколько ждать окончание после последнего быстрого символа.
  final Duration suffixTimeout;

  /// Пауза, завершающая скан при [ScannerSuffix.none].
  final Duration noSuffixIdle;

  /// Минимальная длина скана (08 §4.5.2).
  final int minLength;

  /// Максимальная длина скана (08 §4.5.2).
  final int maxLength;

  /// Копия с изменениями.
  ScannerWedgeConfig copyWith({ScannerSuffix? suffix, Duration? interKeyThreshold}) => ScannerWedgeConfig(
    suffix: suffix ?? this.suffix,
    interKeyThreshold: interKeyThreshold ?? this.interKeyThreshold,
    suffixTimeout: suffixTimeout,
    noSuffixIdle: noSuffixIdle,
    minLength: minLength,
    maxLength: maxLength,
  );

  /// JSON для локального хранения (только сохраняемые поля).
  Map<String, Object?> toJson() => <String, Object?>{
    'suffix': suffix.apiValue,
    'interKeyMs': interKeyThreshold.inMilliseconds,
  };

  /// Разбор строки JSON (битая строка — настройки по умолчанию).
  static ScannerWedgeConfig decode(String? raw) {
    if (raw == null || raw.isEmpty) return const ScannerWedgeConfig();
    try {
      final json = jsonDecode(raw);
      return json is Map<String, Object?> ? ScannerWedgeConfig.fromJson(json) : const ScannerWedgeConfig();
    } on FormatException {
      return const ScannerWedgeConfig();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ScannerWedgeConfig &&
      other.suffix == suffix &&
      other.interKeyThreshold == interKeyThreshold &&
      other.suffixTimeout == suffixTimeout &&
      other.noSuffixIdle == noSuffixIdle &&
      other.minLength == minLength &&
      other.maxLength == maxLength;

  @override
  int get hashCode => Object.hash(suffix, interKeyThreshold, suffixTimeout, noSuffixIdle, minLength, maxLength);
}
