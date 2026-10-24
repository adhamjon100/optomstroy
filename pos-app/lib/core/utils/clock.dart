// Источник времени (06 §6.2 core/utils/clock.dart, `clockProvider`).
// Все `*_at` локальной БД — unix-ms UTC (07 §11.2); отображение в Asia/Bishkek —
// design_system/formats (03 §17.1).

abstract interface class Clock {
  /// Текущий момент в UTC.
  DateTime nowUtc();
}

/// Системные часы.
final class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime nowUtc() => DateTime.now().toUtc();
}

/// Управляемые часы для тестов и детерминированных сценариев.
final class FixedClock implements Clock {
  FixedClock(DateTime now) : _now = now.toUtc();

  DateTime _now;

  @override
  DateTime nowUtc() => _now;

  void set(DateTime now) => _now = now.toUtc();

  void advance(Duration delta) => _now = _now.add(delta);
}

extension ClockMillis on Clock {
  /// unix-ms UTC — формат `*_at` локальной БД.
  int nowMillis() => nowUtc().millisecondsSinceEpoch;
}
