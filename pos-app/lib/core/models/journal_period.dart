// Период журналов этапа G (RM-G-011, RM-G-012; ядро §19.4): транзакции SCR-36, аудит SCR-47, отчёты SCR-48 —
// не более 366 дней; запрос за больший период сервер отклоняет `VALIDATION_FAILED`, UI не даёт его выбрать.
// Значения периода по умолчанию — Q-215 (не решено; экраны берут «Сегодня»). Чистый Dart (FL-01).

final class JournalPeriod {
  const JournalPeriod._(this.from, this.to);

  /// Период [from]…[to] (оба включительно по времени) или `null`, если `to < from` или длина > [maxDays].
  static JournalPeriod? tryCreate(DateTime from, DateTime to) {
    if (to.isBefore(from)) return null;
    if (to.difference(from) > const Duration(days: maxDays)) return null;
    return JournalPeriod._(from, to);
  }

  /// Максимальная длина периода журнала (RM-G-011 п. 5).
  static const int maxDays = 366;

  final DateTime from;
  final DateTime to;

  @override
  bool operator ==(Object other) => other is JournalPeriod && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);

  @override
  String toString() => 'JournalPeriod(${from.toIso8601String()}…${to.toIso8601String()})';
}
