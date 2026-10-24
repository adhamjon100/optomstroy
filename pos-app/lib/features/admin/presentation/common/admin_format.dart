// Время и период экранов админа SCR-46/SCR-47: Asia/Bishkek (UTC+6 круглый год, 03 §16.4) — время записей аудита
// до секунд (AC-UI-47-010); период журнала — пресеты 02 SCR-47.4 («Сегодня» по умолчанию · «Вчера» · «7 дней» ·
// «30 дней» · «Период…»), не длиннее 366 дней (`JournalPeriod`, ядро §20.2 п. 15). Граница `to` — исключительная
// (начало следующего дня или «сейчас»).
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/journal_period.dart';

/// Пресет периода журнала.
enum AuditPeriodPreset { today, yesterday, days7, days30, custom }

/// Период журнала: пресет + границы.
final class AuditPeriod {
  const AuditPeriod(this.preset, this.period);

  final AuditPeriodPreset preset;
  final JournalPeriod period;

  @override
  bool operator ==(Object other) => other is AuditPeriod && other.preset == preset && other.period == period;

  @override
  int get hashCode => Object.hash(preset, period);
}

abstract final class AdminFormat {
  static const Duration bishkekOffset = Duration(hours: 6);

  static DateTime wall(DateTime utc) => utc.toUtc().add(bishkekOffset);

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

  /// «09:42:17».
  static String timeSeconds(DateTime utc) {
    final DateTime w = wall(utc);
    return '${_pad2(w.hour)}:${_pad2(w.minute)}:${_pad2(w.second)}';
  }

  /// «22.10.2026 09:42:17».
  static String dateTimeSeconds(DateTime utc) => '${date(utc)} ${timeSeconds(utc)}';

  /// «22.10.2026 09:42».
  static String dateTime(DateTime utc) {
    final DateTime w = wall(utc);
    return '${date(utc)} ${_pad2(w.hour)}:${_pad2(w.minute)}';
  }

  /// ISO-8601 UTC для URL.
  static String iso(DateTime utc) => utc.toUtc().toIso8601String();

  /// Период пресета относительно [nowUtc].
  static AuditPeriod preset(AuditPeriodPreset p, DateTime nowUtc) {
    final DateTime today = startOfDayUtc(nowUtc);
    final DateTime tomorrow = today.add(const Duration(days: 1));
    final (DateTime, DateTime) range = switch (p) {
      AuditPeriodPreset.today || AuditPeriodPreset.custom => (today, tomorrow),
      AuditPeriodPreset.yesterday => (today.subtract(const Duration(days: 1)), today),
      AuditPeriodPreset.days7 => (today.subtract(const Duration(days: 6)), tomorrow),
      AuditPeriodPreset.days30 => (today.subtract(const Duration(days: 29)), tomorrow),
    };
    return AuditPeriod(p, JournalPeriod.tryCreate(range.$1, range.$2)!);
  }

  /// Дни Бишкека [firstDayUtc]…[lastDayUtc] включительно; `null` — длиннее 366 дней или перевёрнут.
  static AuditPeriod? days(DateTime firstDayUtc, DateTime lastDayUtc) {
    final JournalPeriod? p = JournalPeriod.tryCreate(
      startOfDayUtc(firstDayUtc),
      startOfDayUtc(lastDayUtc).add(const Duration(days: 1)),
    );
    return p == null ? null : AuditPeriod(AuditPeriodPreset.custom, p);
  }

  /// Период из URL; без параметров — «Сегодня»; недопустимый (> 366 дней, перевёрнут) — `null`.
  static AuditPeriod? fromQuery(String? from, String? to, DateTime nowUtc) {
    final DateTime? f = from == null ? null : DateTime.tryParse(from)?.toUtc();
    final DateTime? t = to == null ? null : DateTime.tryParse(to)?.toUtc();
    if (f == null || t == null) return preset(AuditPeriodPreset.today, nowUtc);
    for (final AuditPeriodPreset p in AuditPeriodPreset.values) {
      if (p == AuditPeriodPreset.custom) continue;
      final AuditPeriod candidate = preset(p, nowUtc);
      if (candidate.period.from == f && candidate.period.to == t) return candidate;
    }
    final JournalPeriod? custom = JournalPeriod.tryCreate(f, t);
    return custom == null ? null : AuditPeriod(AuditPeriodPreset.custom, custom);
  }

  /// Подпись пресета (общие ключи периода журналов 02 §7).
  static String presetLabel(AppLocalizations l10n, AuditPeriodPreset p) => switch (p) {
    AuditPeriodPreset.today => l10n.transactions_period_today,
    AuditPeriodPreset.yesterday => l10n.transactions_period_yesterday,
    AuditPeriodPreset.days7 => l10n.transactions_period_7d,
    AuditPeriodPreset.days30 => l10n.customer_history_preset_30,
    AuditPeriodPreset.custom => l10n.transactions_period_custom,
  };

  /// «22.10.2026 – 28.10.2026».
  static String range(JournalPeriod p) {
    final String a = date(p.from);
    final String b = date(p.to.subtract(const Duration(seconds: 1)));
    return a == b ? a : '$a – $b';
  }
}
