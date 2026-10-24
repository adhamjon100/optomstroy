// MascotController (02 §0.3; 03 §13.3–§13.5; 09 §11.1–§11.3; D-40).
//
// Вычисляет состояние персонажа по событиям процесса входа. Не имеет доступа к сети и к
// результату проверки: `success`/`error` вызывает экран только после ответа сервера (И1)
// или локальной валидации (`error`). Состояния и входы совпадают с Rive state machine
// `MascotAuth` (`isTyping`, `isChecking`, `success`, `error`, `retry`, `lookX`, `lookY`,
// `reduceMotion`, `blink`) — заглушка-рендерер и будущий `.riv` читают один и тот же
// [MascotInputs], поэтому замена ассета не меняет код экранов (Q-035).
import 'dart:async';

import 'package:flutter/foundation.dart';

/// Сигнал персонажу (09 §11.1).
enum MascotSignal {
  /// Запрос отправлен → `verifying`.
  requestStarted,

  /// 2xx → `success`.
  success,

  /// `OTP_INVALID` / `VALIDATION_FAILED` / локальная валидация → `error` → 1,5 с → `retry`.
  errorRecoverable,

  /// Блокирующий отказ (лимит, блокировка, сеть, 5xx) → `error` без авто-`retry`.
  errorBlocking,

  /// «Повторить» / «Отправить код повторно» → `retry`.
  retry,

  /// Ошибки нет (например, офлайн до запроса) → `idle`/`typing`.
  idle,
}

/// Шесть состояний `MascotAuth` (D-40).
enum MascotState { idle, typing, verifying, success, error, retry }

/// Входы state machine `MascotAuth` (03 §13.5). Триггеры — счётчики: рендерер реагирует
/// на увеличение значения (одно срабатывание на событие).
@immutable
final class MascotInputs {
  const MascotInputs({
    this.state = MascotState.idle,
    this.isTyping = false,
    this.isChecking = false,
    this.lookX = 0,
    this.lookY = 0,
    this.successTrigger = 0,
    this.errorTrigger = 0,
    this.retryTrigger = 0,
    this.nodTrigger = 0,
  });

  final MascotState state;
  final bool isTyping;
  final bool isChecking;

  /// −1…1: позиция каретки относительно центра поля.
  final double lookX; // money-double: allow — геометрия UI (lp)

  /// −1…1: положение поля относительно персонажа (по умолчанию — вниз, на поле).
  final double lookY; // money-double: allow — геометрия UI (lp)
  final int successTrigger;
  final int errorTrigger;
  final int retryTrigger;

  /// Микрокивок на введённый символ (не чаще 1/300 мс).
  final int nodTrigger;

  MascotInputs copyWith({
    MascotState? state,
    bool? isTyping,
    bool? isChecking,
    double? lookX, // money-double: allow — геометрия UI (lp)
    double? lookY, // money-double: allow — геометрия UI (lp)
    int? successTrigger,
    int? errorTrigger,
    int? retryTrigger,
    int? nodTrigger,
  }) => MascotInputs(
    state: state ?? this.state,
    isTyping: isTyping ?? this.isTyping,
    isChecking: isChecking ?? this.isChecking,
    lookX: lookX ?? this.lookX,
    lookY: lookY ?? this.lookY,
    successTrigger: successTrigger ?? this.successTrigger,
    errorTrigger: errorTrigger ?? this.errorTrigger,
    retryTrigger: retryTrigger ?? this.retryTrigger,
    nodTrigger: nodTrigger ?? this.nodTrigger,
  );

  @override
  bool operator ==(Object other) =>
      other is MascotInputs &&
      other.state == state &&
      other.isTyping == isTyping &&
      other.isChecking == isChecking &&
      other.lookX == lookX &&
      other.lookY == lookY &&
      other.successTrigger == successTrigger &&
      other.errorTrigger == errorTrigger &&
      other.retryTrigger == retryTrigger &&
      other.nodTrigger == nodTrigger;

  @override
  int get hashCode =>
      Object.hash(state, isTyping, isChecking, lookX, lookY, successTrigger, errorTrigger, retryTrigger, nodTrigger);

  @override
  String toString() => 'MascotInputs(${state.name})';
}

/// Контроллер персонажа. Методы — 03 §17.6: [onFieldFocus], [onCaret], [onRequestStarted],
/// [onSuccess], [onError], [onUserRetry]; плюс [onInput] (символ введён).
class MascotController extends ValueNotifier<MascotInputs> {
  MascotController() : super(const MascotInputs());

  /// Потеря фокуса дольше 2 с → `idle` (09 §11.2).
  static const Duration blurToIdle = Duration(seconds: 2);

  /// `error` → `retry` для неблокирующих ошибок (OTP_INVALID, PIN_INVALID, VALIDATION_FAILED).
  static const Duration errorToRetry = Duration(milliseconds: 1500);

  /// `retry` — переходное состояние (250 + 50 мс).
  static const Duration retrySettle = Duration(milliseconds: 300);

  /// `verifying` не дольше таймаута запроса (И2).
  static const Duration verifyingTimeout = Duration(seconds: 15);

  /// Микрокивки не чаще 1/300 мс.
  static const Duration nodInterval = Duration(milliseconds: 300);

  Timer? _blurTimer;
  Timer? _retryTimer;
  Timer? _settleTimer;
  Timer? _verifyTimer;
  bool _focused = false;
  DateTime? _lastNod;
  bool _disposed = false;

  MascotState get state => value.state;

  /// Фокус в поле ввода (`PhoneField`/`OtpField`/`PinField`).
  void onFieldFocus(bool focused) {
    _focused = focused;
    _blurTimer?.cancel();
    if (focused) {
      if (state == MascotState.idle || state == MascotState.retry) {
        _set(MascotState.typing);
      } else {
        value = value.copyWith(isTyping: true);
      }
      return;
    }
    _blurTimer = Timer(blurToIdle, () {
      if (!_focused && (state == MascotState.typing || state == MascotState.retry)) {
        _set(MascotState.idle);
      } else {
        value = value.copyWith(isTyping: false);
      }
    });
  }

  /// Позиция каретки (−1…1) и поля (−1…1); обновляется не чаще кадра.
  void onCaret(double /* money-double: allow — геометрия UI */ lookX, [double lookY = 0.6]) {
    value = value.copyWith(lookX: lookX.clamp(-1.0, 1.0), lookY: lookY.clamp(-1.0, 1.0));
  }

  /// Введён символ: из `error` сразу в `typing` (минуя `retry`, 02 §0.3 п.6), иначе — кивок.
  void onInput({DateTime? now}) {
    if (state == MascotState.verifying || state == MascotState.success) {
      return;
    }
    if (state != MascotState.typing) {
      _retryTimer?.cancel();
      _settleTimer?.cancel();
      _set(MascotState.typing);
      return;
    }
    final DateTime at = now ?? DateTime.now();
    if (_lastNod == null || at.difference(_lastNod!) >= nodInterval) {
      _lastNod = at;
      value = value.copyWith(nodTrigger: value.nodTrigger + 1);
    }
  }

  /// Отправлен запрос (`/auth/otp/request`, `/auth/otp/verify`, `/auth/unlock`, …) или
  /// авто-промпт биометрии SCR-08.
  void onRequestStarted() {
    _cancelAll();
    _set(MascotState.verifying);
    _verifyTimer = Timer(verifyingTimeout, () {
      if (state == MascotState.verifying) {
        onError(autoRetry: false);
      }
    });
  }

  /// Ответ 2xx (`authenticated` / `201`) — только после ответа сервера.
  void onSuccess() {
    _cancelAll();
    value = value.copyWith(state: MascotState.success, isChecking: false, successTrigger: value.successTrigger + 1);
  }

  /// Ответ 4xx/5xx, сеть, таймаут или локальная ошибка формы.
  ///
  /// [autoRetry] — `OTP_INVALID`/`PIN_INVALID`/`VALIDATION_FAILED`: через 1,5 с `retry`;
  /// блокирующие отказы (`OTP_LOCKED`, `PIN_LOCKED`, …) — без авто-`retry` (09 §11.1).
  void onError({required bool autoRetry}) {
    _cancelAll();
    value = value.copyWith(state: MascotState.error, isChecking: false, errorTrigger: value.errorTrigger + 1);
    if (autoRetry) {
      _retryTimer = Timer(errorToRetry, onUserRetry);
    }
  }

  /// «Повторить», «Отправить код повторно», новый ввод после ошибки.
  void onUserRetry() {
    _cancelAll();
    value = value.copyWith(state: MascotState.retry, isChecking: false, retryTrigger: value.retryTrigger + 1);
    _settleTimer = Timer(retrySettle, () {
      if (state == MascotState.retry) {
        _set(_focused ? MascotState.typing : MascotState.idle);
      }
    });
  }

  /// Сброс в `idle` (нет сети — ошибки нет, 03 §13.8).
  void onIdle() {
    _cancelAll();
    _set(_focused ? MascotState.typing : MascotState.idle);
  }

  void _set(MascotState s) {
    if (_disposed) {
      return;
    }
    value = value.copyWith(
      state: s,
      isTyping: s == MascotState.typing || (_focused && s != MascotState.idle),
      isChecking: s == MascotState.verifying,
    );
  }

  void _cancelAll() {
    _retryTimer?.cancel();
    _settleTimer?.cancel();
    _verifyTimer?.cancel();
  }

  @override
  set value(MascotInputs newValue) {
    if (!_disposed) {
      super.value = newValue;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _blurTimer?.cancel();
    _cancelAll();
    super.dispose();
  }
}

/// Передача сигнала потока в контроллер (экран вызывает при смене `mascotSeq`).
extension MascotSignalDispatch on MascotController {
  void apply(MascotSignal signal) {
    switch (signal) {
      case MascotSignal.requestStarted:
        onRequestStarted();
      case MascotSignal.success:
        onSuccess();
      case MascotSignal.errorRecoverable:
        onError(autoRetry: true);
      case MascotSignal.errorBlocking:
        onError(autoRetry: false);
      case MascotSignal.retry:
        onUserRetry();
      case MascotSignal.idle:
        onIdle();
    }
  }
}
