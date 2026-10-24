// Распознавание скана HID-сканера среди нажатий клавиш (D-42; 02 п. 2.2.11; R3 §7).
//
// Чистый Dart, без Flutter: на вход — символы и клавиши-окончания с метками времени
// (монотонные `Duration`), на выход — решение по каждому нажатию и событие «скан»/«обрыв».
// Правило: символы, пришедшие с интервалом < `interKeyThreshold` (50 мс), образуют «быструю
// серию»; серия из ≥ `minLength` символов, завершённая настроенным окончанием (`Enter`/`Tab`)
// не позже `suffixTimeout` после последнего символа, — скан. Медленный символ (интервал
// ≥ порога) — ручной ввод: серия начинается заново с него. Быстрая серия без окончания —
// «обрыв» (подсказка SCR-42 `settings_scanner_no_suffix`). При окончании «Без суффикса» скан
// завершается паузой `noSuffixIdle`.
import 'package:optomstroy/core/hardware/scanner_wedge_config.dart';

/// Роль нажатия в серии.
enum HidKeyRole {
  /// Первый символ возможной серии (или символ после паузы — ручной ввод).
  start,

  /// Символ быстрой серии (интервал < порога) — часть возможного скана.
  continuation,

  /// Окончание, завершившее скан.
  scanSuffix,

  /// `Enter`/`Tab`, не относящийся к скану (ручное нажатие).
  plainSuffix,

  /// Прочая клавиша (стрелки, сочетания с Ctrl/Alt) — серия сброшена.
  other,
}

/// Что распознано.
enum HidDetectionKind {
  /// Скан с окончанием (или паузой при «Без суффикса»).
  scan,

  /// Быстрая серия без ожидаемого окончания.
  incomplete,
}

/// Распознанная серия.
final class HidDetection {
  /// Создаёт результат.
  const HidDetection(this.kind, this.value);

  /// Вид.
  final HidDetectionKind kind;

  /// Символы серии без окончания.
  final String value;

  @override
  bool operator ==(Object other) => other is HidDetection && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);

  @override
  String toString() => 'HidDetection(${kind.name}, ${value.length} chars)';
}

/// Решение по нажатию.
final class HidKeyOutcome {
  /// Создаёт решение.
  const HidKeyOutcome(this.role, [this.detection]);

  /// Роль нажатия.
  final HidKeyRole role;

  /// Событие, завершённое этим нажатием (скан или обрыв предыдущей серии).
  final HidDetection? detection;
}

/// Автомат распознавания HID-скана.
final class HidWedgeDetector {
  /// Создаёт автомат с настройками [config].
  HidWedgeDetector([this.config = const ScannerWedgeConfig()]);

  /// Настройки (меняются из SCR-42 без пересоздания).
  ScannerWedgeConfig config;

  final StringBuffer _buffer = StringBuffer();
  int _length = 0;
  Duration? _lastAt;

  /// Символов в текущей серии.
  int get pendingLength => _length;

  /// Время, когда нужно вызвать [onIdle] (ожидание окончания/паузы); `null` — ждать нечего.
  Duration? get nextDeadline {
    final last = _lastAt;
    if (last == null || _length < config.minLength) return null;
    return last + (config.suffix == ScannerSuffix.none ? config.noSuffixIdle : config.suffixTimeout);
  }

  /// Символ [char] пришёл в момент [at].
  HidKeyOutcome onCharacter(String char, Duration at) {
    final last = _lastAt;
    if (last != null && at - last < config.interKeyThreshold && _length > 0) {
      _buffer.write(char);
      _length++;
      _lastAt = at;
      return const HidKeyOutcome(HidKeyRole.continuation);
    }
    // Пауза ≥ порога: прежняя серия закончилась без окончания (если была достаточной длины):
    // при «Без суффикса» это скан, иначе — обрыв.
    final previous = _length >= config.minLength ? HidDetection(_endKind, _buffer.toString()) : null;
    _reset();
    _buffer.write(char);
    _length = 1;
    _lastAt = at;
    return HidKeyOutcome(HidKeyRole.start, previous);
  }

  /// Нажата клавиша-окончание [key] (`enter`/`tab`) в момент [at].
  HidKeyOutcome onSuffixKey(ScannerSuffix key, Duration at) {
    final last = _lastAt;
    final burst = last != null && _length >= config.minLength;
    if (!burst) {
      _reset();
      return const HidKeyOutcome(HidKeyRole.plainSuffix);
    }
    final value = _buffer.toString();
    final gap = at - last;
    final expected = config.suffix;
    // «Без суффикса», но сканер всё-таки прислал Enter/Tab сразу после серии — скан завершён им.
    final inTime = gap < (expected == ScannerSuffix.none ? config.noSuffixIdle : config.suffixTimeout);
    _reset();
    if (inTime && (expected == key || expected == ScannerSuffix.none)) {
      return HidKeyOutcome(HidKeyRole.scanSuffix, HidDetection(HidDetectionKind.scan, value));
    }
    // Окончание не то (Tab вместо Enter) или пришло слишком поздно — обрыв, клавиша проходит дальше.
    return HidKeyOutcome(HidKeyRole.plainSuffix, HidDetection(HidDetectionKind.incomplete, value));
  }

  /// Прочая клавиша (не символ и не окончание) в момент [at]: серия сброшена без события.
  HidKeyOutcome onOtherKey(Duration at) {
    _reset();
    return const HidKeyOutcome(HidKeyRole.other);
  }

  /// Проверка таймаутов в момент [at] (по таймеру сервиса): завершение «Без суффикса» или обрыв.
  HidDetection? onIdle(Duration at) {
    final detection = _expired(at);
    if (detection != null) _reset();
    return detection;
  }

  /// Сброс серии.
  void reset() => _reset();

  HidDetection? _expired(Duration at) {
    final deadline = nextDeadline;
    if (deadline == null || at < deadline) return null;
    return HidDetection(_endKind, _buffer.toString());
  }

  HidDetectionKind get _endKind =>
      config.suffix == ScannerSuffix.none ? HidDetectionKind.scan : HidDetectionKind.incomplete;

  void _reset() {
    _buffer.clear();
    _length = 0;
    _lastAt = null;
  }
}
