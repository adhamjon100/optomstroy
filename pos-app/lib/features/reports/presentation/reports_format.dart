// Форматирование и период SCR-48: время Бишкека (UTC+6 круглый год, 03 §16.4), деньги — `PriceText` (тыйыны, D-19;
// финансовый контекст — всегда 2 знака), пресеты периода 02 UI-48-001 («Сегодня» по умолчанию · «Вчера» · «7 дней» ·
// «Месяц» · «Период…»), предел — 366 дней (`JournalPeriod`, ядро §20.2 п. 15). Средний чек — целочисленно в тыйынах,
// HALF_UP до тыйына (UI-48-008, MNY-*).
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/journal_period.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/price_text.dart';

/// Пресет периода SCR-48.
enum ReportsPeriodPreset { today, yesterday, days7, month, custom }

/// Период отчётов: пресет + границы (UTC; [JournalPeriod.to] — исключительная граница дня или «сейчас»).
final class ReportsPeriod {
  const ReportsPeriod(this.preset, this.period);

  final ReportsPeriodPreset preset;
  final JournalPeriod period;

  @override
  bool operator ==(Object other) => other is ReportsPeriod && other.preset == preset && other.period == period;

  @override
  int get hashCode => Object.hash(preset, period);
}

abstract final class ReportsFormat {
  /// Смещение Asia/Bishkek.
  static const Duration bishkekOffset = Duration(hours: 6);

  static DateTime wall(DateTime utc) => utc.toUtc().add(bishkekOffset);

  /// Полночь Бишкека дня [utc] (в UTC).
  static DateTime startOfDayUtc(DateTime utc) {
    final DateTime w = wall(utc);
    return DateTime.utc(w.year, w.month, w.day).subtract(bishkekOffset);
  }

  static String _pad2(int v) => v.toString().padLeft(2, '0');

  /// «22.10.2026».
  static String date(DateTime utc) {
    final DateTime w = wall(utc);
    return '${_pad2(w.day)}.${_pad2(w.month)}.${w.year}';
  }

  /// «09:41».
  static String time(DateTime utc) {
    final DateTime w = wall(utc);
    return '${_pad2(w.hour)}:${_pad2(w.minute)}';
  }

  /// Метка времени данных: сегодня — «09:41», иначе — «22.10.2026 09:41».
  static String stamp(DateTime utc, DateTime nowUtc) =>
      startOfDayUtc(utc) == startOfDayUtc(nowUtc) ? time(utc) : '${date(utc)} ${time(utc)}';

  /// «16 007,50 сом».
  static String money(Money? m) => m == null ? '—' : PriceText.format(m, fixed2: true);

  /// Средний чек: `total / count` в тыйынах, HALF_UP (UI-48-008); `null` при нуле заказов.
  static Money? average(Money? total, int? count) {
    if (total == null || count == null || count <= 0) return null;
    final int abs = total.tyiyn.abs();
    final int q = (abs * 2 + count) ~/ (count * 2);
    return Money(total.tyiyn < 0 ? -q : q);
  }

  /// Период пресета относительно [nowUtc].
  static ReportsPeriod preset(ReportsPeriodPreset p, DateTime nowUtc) {
    final DateTime today = startOfDayUtc(nowUtc);
    final DateTime tomorrow = today.add(const Duration(days: 1));
    final (DateTime, DateTime) range = switch (p) {
      ReportsPeriodPreset.today || ReportsPeriodPreset.custom => (today, tomorrow),
      ReportsPeriodPreset.yesterday => (today.subtract(const Duration(days: 1)), today),
      ReportsPeriodPreset.days7 => (today.subtract(const Duration(days: 6)), tomorrow),
      ReportsPeriodPreset.month => (today.subtract(const Duration(days: 29)), tomorrow),
    };
    return ReportsPeriod(p, JournalPeriod.tryCreate(range.$1, range.$2)!);
  }

  /// Период дней Бишкека [firstDayUtc]…[lastDayUtc] включительно; `null` — длиннее 366 дней или перевёрнут.
  static ReportsPeriod? days(DateTime firstDayUtc, DateTime lastDayUtc) {
    final JournalPeriod? p = JournalPeriod.tryCreate(
      startOfDayUtc(firstDayUtc),
      startOfDayUtc(lastDayUtc).add(const Duration(days: 1)),
    );
    return p == null ? null : ReportsPeriod(ReportsPeriodPreset.custom, p);
  }

  /// Период из URL (`?from=&to=` ISO-8601); иначе — «Сегодня». Недопустимый (> 366 дней) — `null`.
  static ReportsPeriod? fromQuery(String? from, String? to, DateTime nowUtc) {
    final DateTime? f = from == null ? null : DateTime.tryParse(from)?.toUtc();
    final DateTime? t = to == null ? null : DateTime.tryParse(to)?.toUtc();
    if (f == null || t == null) return preset(ReportsPeriodPreset.today, nowUtc);
    for (final ReportsPeriodPreset p in ReportsPeriodPreset.values) {
      if (p == ReportsPeriodPreset.custom) continue;
      final ReportsPeriod candidate = preset(p, nowUtc);
      if (candidate.period.from == f && candidate.period.to == t) return candidate;
    }
    final JournalPeriod? custom = JournalPeriod.tryCreate(f, t);
    return custom == null ? null : ReportsPeriod(ReportsPeriodPreset.custom, custom);
  }

  /// ISO-8601 UTC для URL.
  static String iso(DateTime utc) => utc.toUtc().toIso8601String();

  /// Подпись пресета.
  static String presetLabel(AppLocalizations l10n, ReportsPeriodPreset p) => switch (p) {
    ReportsPeriodPreset.today => l10n.transactions_period_today,
    ReportsPeriodPreset.yesterday => l10n.transactions_period_yesterday,
    ReportsPeriodPreset.days7 => l10n.transactions_period_7d,
    ReportsPeriodPreset.month => l10n.transactions_period_month,
    ReportsPeriodPreset.custom => l10n.transactions_period_custom,
  };

  /// «22.10.2026 – 28.10.2026» (последний день — включительно).
  static String range(JournalPeriod p) {
    final DateTime last = p.to.subtract(const Duration(seconds: 1));
    final String a = date(p.from);
    final String b = date(last);
    return a == b ? a : '$a – $b';
  }
}
