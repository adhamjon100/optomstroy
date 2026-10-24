// Фильтр распознаваний камеры (02 SCR-17.4, SCR-17.11; Q-207; AC-UI-17-005):
//  * код принимается, когда он распознан в 2 последовательных кадрах [ТИПОВО];
//  * тот же код, пока он виден в рамке и ещё 1,5 с после этого, повторно не принимается
//    (удержание в рамке 5 с — одно добавление).
// Очередь «другой код во время запроса» ведёт экран. Чистый Dart.

/// Фильтр кадров камеры.
final class CameraCodeFilter {
  /// Создаёт фильтр.
  CameraCodeFilter({this.requiredFrames = 2, this.repeatWindow = const Duration(milliseconds: 1500)});

  /// Сколько подряд кадров должен быть виден код.
  final int requiredFrames;

  /// Окно подавления повтора того же кода.
  final Duration repeatWindow;

  String? _candidate;
  int _count = 0;
  String? _lastAccepted;
  Duration? _lastSeenAccepted;

  /// Кадр с кодами [values] в момент [at]; возвращает принятый код или `null`.
  String? onFrame(List<String> values, Duration at) {
    final last = _lastAccepted;
    final lastSeen = _lastSeenAccepted;
    final recentlyAccepted = last != null && lastSeen != null && at - lastSeen < repeatWindow;
    if (recentlyAccepted && values.contains(last)) {
      // Код всё ещё в рамке — продлеваем подавление.
      _lastSeenAccepted = at;
    }
    if (values.isEmpty) {
      _candidate = null;
      _count = 0;
      return null;
    }
    final next = values.contains(_candidate) ? _candidate! : values.first;
    if (next == _candidate) {
      _count++;
    } else {
      _candidate = next;
      _count = 1;
    }
    if (_count < requiredFrames) return null;
    if (recentlyAccepted && next == last) return null;
    _lastAccepted = next;
    _lastSeenAccepted = at;
    _candidate = null;
    _count = 0;
    return next;
  }

  /// Сброс (повтор того же кода снова разрешён — например, после «Повторить»).
  void reset() {
    _candidate = null;
    _count = 0;
    _lastAccepted = null;
    _lastSeenAccepted = null;
  }
}
