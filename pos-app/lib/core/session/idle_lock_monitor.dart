// Idle-блокировка и блокировка при возврате из фона (09 §8.8; ядро §17.7, §19.3; SESS-024, SESS-025):
// - 30 мин без ввода (касания, клавиатура, сканер) → onLock(idle);
// - Android/iOS: возврат из фона позже 5 мин → onLock(background); Windows — только idle.
// Таймер — `dart:async Timer` (в тестах — fake async `tester.pump`), время ухода в фон — [Clock].
import 'dart:async';

import 'package:optomstroy/core/session/session_policy.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/core/utils/clock.dart';

final class IdleLockMonitor {
  IdleLockMonitor({
    required SessionPolicy policy,
    required Clock clock,
    required void Function(SessionLockReason) onLock,
  }) : _policy = policy,
       _clock = clock,
       _onLock = onLock;

  final SessionPolicy _policy;
  final Clock _clock;
  final void Function(SessionLockReason reason) _onLock;
  Timer? _timer;
  DateTime? _backgroundedAt;
  bool _active = false;

  /// Отсчёт идёт (сессия разблокирована и правило применяется к пользователю).
  bool get isActive => _active;

  /// Запустить отсчёт простоя (после входа / разблокировки).
  void start() {
    _active = true;
    _restart();
  }

  /// Остановить (блокировка, выход, клиент без idle-блокировки).
  void stop() {
    _active = false;
    _backgroundedAt = null;
    _timer?.cancel();
    _timer = null;
  }

  /// Ввод пользователя — отсчёт заново.
  void activity() {
    if (_active && _backgroundedAt == null) _restart();
  }

  /// Приложение ушло в фон (AppLifecycleState.hidden/paused).
  void backgrounded() {
    if (!_active || _backgroundedAt != null) return;
    _backgroundedAt = _clock.nowUtc();
  }

  /// Приложение вернулось (AppLifecycleState.resumed).
  void foregrounded() {
    final since = _backgroundedAt;
    _backgroundedAt = null;
    if (!_active || since == null) return;
    if (_policy.backgroundLockEnabled && _clock.nowUtc().difference(since) >= _policy.backgroundLock) {
      _fire(SessionLockReason.background);
      return;
    }
    // Таймер простоя продолжал идти в фоне (Windows: свёрнутое окно — тоже простой).
  }

  void _restart() {
    _timer?.cancel();
    _timer = Timer(_policy.idleLock, () => _fire(SessionLockReason.idle));
  }

  void _fire(SessionLockReason reason) {
    stop();
    _onLock(reason);
  }

  void dispose() => stop();
}
