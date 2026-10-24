// HID-сканер в режиме клавиатуры (USB/Bluetooth; D-42, Q-009; R3 §7; 02 п. 2.2.11, SCR-17.4).
//
// Глобальный обработчик `HardwareKeyboard` (+ ранний обработчик `FocusManager`, EQ-SCAN-04) буферизует символы и через [HidWedgeDetector]
// отличает скан (символы с интервалом < 50 мс + окончание Enter/Tab) от ручного ввода.
// Единое правило перехвата (02 п. 2.2.11):
//  * фокус вне полей ввода — скан перехватывается: символы быстрой серии и окончание не
//    доходят до экрана (горячие клавиши `+`/`−`/`Enter` не срабатывают), событие [HidScanned];
//  * фокус в `SearchBar` (поле с `TextInputAction.search`) или в зарегистрированном поле
//    ([registerScanTarget], тест сканера SCR-42) — символы попадают в поле как обычно,
//    окончание поглощается (поле не отправляется), событие [HidScanned] с `fromSearchField`;
//    потребитель заменяет запрос целиком (02 SCR-11.4);
//  * фокус в прочих текстовых полях (`AppTextField`, `DiscountInput`, адрес SCR-21) —
//    не перехватывается совсем;
//  * открыт модальный диалог/лист (`PopupRoute`) или действует [suspend] (нампад SCR-16,
//    финансовые формы) — скан игнорируется: символы серии и окончание поглощаются,
//    событие [HidScanIgnored] (экран может показать подсказку, например `payment_scan_disabled`).
// Первый символ серии не поглощается: до второго символа нельзя отличить скан от ручного ввода.
//
// Сервис подключает оболочка (`app/router/shells`, интегратор) через `scannerWedgeServiceProvider`
// (core/hardware/hardware_providers.dart); фичи подписываются на `hidScanEventsProvider`.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:optomstroy/core/hardware/barcode_value.dart';
import 'package:optomstroy/core/hardware/hid_wedge_detector.dart';
import 'package:optomstroy/core/hardware/scanner_wedge_config.dart';

/// Как обрабатывать ввод при текущем фокусе (02 п. 2.2.11).
enum HidCaptureMode {
  /// Вне полей ввода: перехват скана.
  capture,

  /// В поле поиска / тест сканера: символы в поле, окончание поглощается, событие скана.
  searchField,

  /// Модальный диалог, нампад, финансовая форма: скан поглощается без действия.
  ignore,

  /// Обычное текстовое поле: ввод не перехватывается.
  passThrough,
}

/// Событие HID-сканера.
sealed class HidScanEvent {
  const HidScanEvent(this.value);

  /// Значение (символы серии без окончания, без пробелов по краям). В логи не выводится.
  final String value;
}

/// Скан распознан и прошёл проверку формата (3…64 `[0-9A-Za-z-]`) — выполнить действие.
final class HidScanned extends HidScanEvent {
  /// Создаёт событие.
  const HidScanned(super.value, {this.fromSearchField = false});

  /// Символы скана уже вставлены в поле поиска — потребитель заменяет его текст целиком.
  final bool fromSearchField;
}

/// Скан распознан, но значение не похоже на штрихкод — `scan_invalid_code` без запроса.
final class HidScanRejected extends HidScanEvent {
  /// Создаёт событие.
  const HidScanRejected(super.value);
}

/// Скан пришёл, когда сканирование не действует (диалог, нампад, оплата).
final class HidScanIgnored extends HidScanEvent {
  /// Создаёт событие.
  const HidScanIgnored(super.value);
}

/// Быстрая серия символов без ожидаемого окончания (подсказка `settings_scanner_no_suffix`).
final class HidScanIncomplete extends HidScanEvent {
  /// Создаёт событие.
  const HidScanIncomplete(super.value);
}

/// Возвращает режим перехвата для текущего фокуса.
typedef HidCaptureModeResolver = HidCaptureMode Function();

/// Регистрация поля-цели скана или приостановки; [release] снимает её.
final class HidScanRegistration {
  HidScanRegistration._(this._onRelease);

  VoidCallback? _onRelease;

  /// Снимает регистрацию (повторный вызов ничего не делает).
  void release() {
    _onRelease?.call();
    _onRelease = null;
  }
}

/// Сервис HID-сканера.
class ScannerWedgeService {
  /// Создаёт сервис. [resolver] заменяет правило фокуса (тесты); [now] — монотонные часы;
  /// [keyboard] — источник событий клавиатуры (по умолчанию `HardwareKeyboard.instance`).
  ScannerWedgeService({
    ScannerWedgeConfig config = const ScannerWedgeConfig(),
    HidCaptureModeResolver? resolver,
    Duration Function()? now,
    HardwareKeyboard? keyboard,
  }) : _detector = HidWedgeDetector(config),
       _resolverOverride = resolver,
       _keyboard = keyboard ?? HardwareKeyboard.instance {
    if (now != null) {
      _now = now;
    } else {
      final stopwatch = Stopwatch()..start();
      _now = () => stopwatch.elapsed;
    }
  }

  final HidWedgeDetector _detector;
  final HidCaptureModeResolver? _resolverOverride;
  final HardwareKeyboard _keyboard;
  late final Duration Function() _now;
  final StreamController<HidScanEvent> _events = StreamController<HidScanEvent>.broadcast();
  final Set<PhysicalKeyboardKey> _swallowedDown = <PhysicalKeyboardKey>{};
  // События, поглощённые обработчиком `HardwareKeyboard`: тот же объект затем приходит в
  // ранний обработчик `FocusManager` (обработчики `HardwareKeyboard` не останавливают обход
  // дерева фокуса — только передачу в текстовый ввод ОС), там он и гасится.
  final Set<KeyEvent> _swallowedEvents = Set<KeyEvent>.identity();
  final Set<FocusNode> _targets = <FocusNode>{};
  int _suspensions = 0;
  bool _attached = false;
  bool _disposed = false;
  Timer? _timer;

  /// Поток событий сканера (broadcast).
  Stream<HidScanEvent> get events => _events.stream;

  /// Текущие настройки.
  ScannerWedgeConfig get config => _detector.config;

  /// Новые настройки (из SCR-42); текущая серия сбрасывается.
  set config(ScannerWedgeConfig value) {
    if (value == _detector.config) return;
    _detector
      ..config = value
      ..reset();
    _cancelTimer();
  }

  /// Обработчик подключён к клавиатуре.
  bool get isAttached => _attached;

  /// Сканирование приостановлено ([suspend]).
  bool get isSuspended => _suspensions > 0;

  /// Подключает обработчик к `HardwareKeyboard` (повторный вызов ничего не делает).
  void attach() {
    if (_attached || _disposed) return;
    _keyboard.addHandler(handleKeyEvent);
    FocusManager.instance.addEarlyKeyEventHandler(_earlyFocusHandler);
    _attached = true;
  }

  /// Отключает обработчик.
  void detach() {
    if (!_attached) return;
    _keyboard.removeHandler(handleKeyEvent);
    FocusManager.instance.removeEarlyKeyEventHandler(_earlyFocusHandler);
    _attached = false;
    _detector.reset();
    _swallowedDown.clear();
    _swallowedEvents.clear();
    _cancelTimer();
  }

  /// Поле [node] — цель скана (как `SearchBar`): символы в поле, окончание поглощается.
  HidScanRegistration registerScanTarget(FocusNode node) {
    _targets.add(node);
    return HidScanRegistration._(() => _targets.remove(node));
  }

  /// Приостанавливает сканирование (нампад SCR-16, прямой ввод количества, оплата):
  /// пока регистрация не снята, скан поглощается с событием [HidScanIgnored].
  HidScanRegistration suspend() {
    _suspensions++;
    return HidScanRegistration._(() => _suspensions--);
  }

  /// Режим для текущего фокуса.
  HidCaptureMode currentMode() => _resolverOverride?.call() ?? _resolveFromFocus();

  /// Обработчик `HardwareKeyboard` (публичный для тестов): `true` — событие поглощено.
  bool handleKeyEvent(KeyEvent event) {
    if (_disposed) return false;
    final swallow = _decide(event);
    if (swallow) {
      // Ранний обработчик фокуса вызывается только при наличии фокуса — ограничиваем «хвост».
      if (_swallowedEvents.length > 16) _swallowedEvents.clear();
      _swallowedEvents.add(event);
    }
    return swallow;
  }

  KeyEventResult _earlyFocusHandler(KeyEvent event) =>
      _swallowedEvents.remove(event) ? KeyEventResult.handled : KeyEventResult.ignored;

  bool _decide(KeyEvent event) {
    if (event is KeyUpEvent) {
      return _swallowedDown.remove(event.physicalKey);
    }
    if (event is KeyRepeatEvent) {
      _detector.reset();
      return _swallowedDown.contains(event.physicalKey);
    }
    final mode = currentMode();
    if (mode == HidCaptureMode.passThrough) {
      _detector.reset();
      _cancelTimer();
      return false;
    }
    final at = _now();
    final key = event.logicalKey;
    final HidKeyOutcome outcome;
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      outcome = _detector.onSuffixKey(ScannerSuffix.enter, at);
    } else if (key == LogicalKeyboardKey.tab) {
      outcome = _detector.onSuffixKey(ScannerSuffix.tab, at);
    } else if (_isModifier(key)) {
      // Shift для заглавных букв Code128 и т. п. — серию не прерывает.
      return false;
    } else if (_printable(event.character) && !_withShortcutModifier()) {
      outcome = _detector.onCharacter(event.character!, at);
    } else {
      outcome = _detector.onOtherKey(at);
    }
    final detection = outcome.detection;
    if (detection != null) _emit(detection, mode);
    _schedule();

    final swallow = switch (outcome.role) {
      HidKeyRole.continuation => mode != HidCaptureMode.searchField,
      HidKeyRole.scanSuffix => true,
      HidKeyRole.start || HidKeyRole.plainSuffix || HidKeyRole.other => false,
    };
    if (swallow) _swallowedDown.add(event.physicalKey);
    return swallow;
  }

  /// Освобождает ресурсы.
  void dispose() {
    if (_disposed) return;
    detach();
    _disposed = true;
    unawaited(_events.close());
  }

  void _emit(HidDetection detection, HidCaptureMode mode) {
    if (_events.isClosed) return;
    final value = BarcodeValue.normalize(detection.value);
    final HidScanEvent event;
    if (detection.kind == HidDetectionKind.incomplete) {
      event = HidScanIncomplete(value);
    } else if (mode == HidCaptureMode.ignore) {
      event = HidScanIgnored(value);
    } else if (!BarcodeValue.isValid(value)) {
      event = HidScanRejected(value);
    } else {
      event = HidScanned(value, fromSearchField: mode == HidCaptureMode.searchField);
    }
    _events.add(event);
  }

  void _schedule() {
    _cancelTimer();
    final deadline = _detector.nextDeadline;
    if (deadline == null) return;
    final delay = deadline - _now();
    _timer = Timer(delay.isNegative ? Duration.zero : delay, () {
      _timer = null;
      // Таймер сработал — срок наступил, даже если часы [now] в тесте не сдвинуты.
      final at = _detector.nextDeadline;
      if (at == null) return;
      final detection = _detector.onIdle(at);
      if (detection != null) _emit(detection, currentMode());
    });
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  bool _withShortcutModifier() => _keyboard.isControlPressed || _keyboard.isAltPressed || _keyboard.isMetaPressed;

  HidCaptureMode _resolveFromFocus() {
    if (_suspensions > 0) return HidCaptureMode.ignore;
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null) return HidCaptureMode.capture;
    if (_targets.contains(focus)) return HidCaptureMode.searchField;
    final context = focus.context;
    if (context == null || !context.mounted) return HidCaptureMode.capture;
    if (ModalRoute.of(context) is PopupRoute<Object?>) return HidCaptureMode.ignore;
    final widget = context.widget;
    final editable = widget is EditableText ? widget : context.findAncestorWidgetOfExactType<EditableText>();
    if (editable == null) return HidCaptureMode.capture;
    return editable.textInputAction == TextInputAction.search ? HidCaptureMode.searchField : HidCaptureMode.passThrough;
  }

  static bool _printable(String? character) {
    if (character == null || character.length != 1) return false;
    final code = character.codeUnitAt(0);
    return code >= 0x20 && code != 0x7f;
  }

  static final Set<LogicalKeyboardKey> _modifiers = <LogicalKeyboardKey>{
    LogicalKeyboardKey.shift,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.alt,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.meta,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.capsLock,
    LogicalKeyboardKey.numLock,
  };

  static bool _isModifier(LogicalKeyboardKey key) => _modifiers.contains(key);
}
