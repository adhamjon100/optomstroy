// `DateRangePicker` (03 §9.60; DS-092): выбор периода журналов — транзакции SCR-36, история клиента SCR-33, аудит
// SCR-47, отчёты SCR-48. Кнопка-поле `AppButton.outlined M` с иконкой `calendar_month` и текстом периода
// («18 окт – 24 окт», en dash с пробелами — 03 §16) → лист (compact) / диалог (medium+) с пресетами `CategoryChip`
// («Сегодня» · «Вчера» · «7 дней» · «Месяц» · «Период…») и полями «от»/«до». Период длиннее [DateRangePicker.journalMaxDays]
// (366 дней, ядро §19.4) не применяется: «Применить» неактивна, под полями — ошибка. Время — Asia/Bishkek (UTC+6
// круглый год); значения — моменты UTC начала первого и конца последнего дня. Тексты — от вызывающего кода
// ([DateRangePickerLabels]); компонент не знает о маршрутах и API.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/components/category_chip.dart';
import 'package:optomstroy/design_system/layout/window_class.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Время магазина (Asia/Bishkek, UTC+6 без перехода на летнее время; 02 §0.1) для журналов и периодов.
abstract final class DsBishkekTime {
  /// Смещение Asia/Bishkek.
  static const Duration offset = Duration(hours: 6);

  /// Момент [utc] на «стенных часах» Бишкека (поля `year…second` — местные; `isUtc` остаётся `true`).
  static DateTime wall(DateTime utc) => utc.toUtc().add(offset);

  /// Полночь Бишкека дня [utc] (момент UTC).
  static DateTime startOfDayUtc(DateTime utc) {
    final DateTime w = wall(utc);
    return DateTime.utc(w.year, w.month, w.day).subtract(offset);
  }

  /// Последняя миллисекунда дня Бишкека [utc] (момент UTC).
  static DateTime endOfDayUtc(DateTime utc) =>
      startOfDayUtc(utc).add(const Duration(days: 1)).subtract(const Duration(milliseconds: 1));

  /// Полночь Бишкека календарной даты [year]-[month]-[day] (момент UTC).
  static DateTime dayStartUtc(int year, int month, int day) => DateTime.utc(year, month, day).subtract(offset);

  static String _pad2(int v) => v.toString().padLeft(2, '0');

  /// «09:41».
  static String time(DateTime utc) {
    final DateTime w = wall(utc);
    return '${_pad2(w.hour)}:${_pad2(w.minute)}';
  }

  /// «09:41:07».
  static String timeSeconds(DateTime utc) {
    final DateTime w = wall(utc);
    return '${time(utc)}:${_pad2(w.second)}';
  }

  /// «22.10.2026».
  static String date(DateTime utc) {
    final DateTime w = wall(utc);
    return '${_pad2(w.day)}.${_pad2(w.month)}.${w.year}';
  }

  /// «22.10.2026 09:41».
  static String dateTime(DateTime utc) => '${date(utc)} ${time(utc)}';

  /// Метка времени данных: сегодня — «09:41», иначе — «22.10.2026 09:41».
  static String stamp(DateTime utc, DateTime nowUtc) =>
      startOfDayUtc(utc) == startOfDayUtc(nowUtc) ? time(utc) : dateTime(utc);

  /// Число полных календарных дней Бишкека в периоде [fromUtc]…[toUtc] (оба дня включительно).
  static int daysInclusive(DateTime fromUtc, DateTime toUtc) =>
      startOfDayUtc(toUtc).difference(startOfDayUtc(fromUtc)).inDays + 1;

  /// «18 окт» (локаль [locale]).
  static String dayMonthShort(DateTime utc, String locale) {
    final DateTime w = wall(utc);
    return DateFormat('d MMM', locale).format(DateTime(w.year, w.month, w.day)).replaceAll('.', '');
  }

  /// «18 октября» (заголовок дня журнала, 03 §9.38).
  static String dayMonthLong(DateTime utc, String locale) {
    final DateTime w = wall(utc);
    return DateFormat('d MMMM', locale).format(DateTime(w.year, w.month, w.day));
  }

  /// «пн, 29 июн» (дата шапки SCR-10/11/12 и прочих экранов сотрудника, 02 UI-10-032).
  static String headerDateShort(DateTime utc, String locale) {
    final DateTime w = wall(utc);
    return DateFormat('E, d MMM', locale).format(DateTime(w.year, w.month, w.day)).replaceAll('.', '');
  }

  /// «Пн, 29 июня 2026» (шапка SCR-30, AC-UI-30-020).
  static String headerDate(DateTime utc, String locale) {
    final DateTime w = wall(utc);
    final String s = DateFormat('EEE, d MMMM y', locale).format(DateTime(w.year, w.month, w.day));
    return s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
  }

  /// Текст периода «18 окт – 24 окт»; разные годы — «18 окт 2025 – 3 янв 2026»; один день — «18 окт».
  static String rangeText(DateTime fromUtc, DateTime toUtc, String locale) {
    final DateTime a = wall(fromUtc);
    final DateTime b = wall(toUtc);
    if (startOfDayUtc(fromUtc) == startOfDayUtc(toUtc)) return dayMonthShort(fromUtc, locale);
    if (a.year != b.year) {
      String full(DateTime w) =>
          DateFormat('d MMM y', locale).format(DateTime(w.year, w.month, w.day)).replaceAll('.', '');
      return '${full(a)} – ${full(b)}';
    }
    return '${dayMonthShort(fromUtc, locale)} – ${dayMonthShort(toUtc, locale)}';
  }

  /// Разбор «дд.мм.гггг» → полночь Бишкека (UTC) или `null`.
  static DateTime? parseDate(String text) {
    final RegExpMatch? m = RegExp(r'^\s*(\d{1,2})\.(\d{1,2})\.(\d{4})\s*$').firstMatch(text);
    if (m == null) return null;
    final int d = int.parse(m.group(1)!);
    final int mo = int.parse(m.group(2)!);
    final int y = int.parse(m.group(3)!);
    final DateTime probe = DateTime.utc(y, mo, d);
    if (probe.year != y || probe.month != mo || probe.day != d) return null;
    return dayStartUtc(y, mo, d);
  }
}

/// Быстрый пресет периода (02 UI-36-005).
enum DateRangePreset {
  /// Сегодня (по умолчанию — Q-215).
  today,

  /// Вчера.
  yesterday,

  /// 7 дней, включая сегодня.
  last7Days,

  /// С 1-го числа текущего месяца по сегодня.
  month,

  /// Произвольный период.
  custom,
}

/// Период: начало первого и конец последнего дня (моменты UTC).
@immutable
final class DateRangeValue {
  /// Создаёт период.
  const DateRangeValue({required this.fromUtc, required this.toUtc});

  /// Пресет относительно [nowUtc] (Бишкек).
  factory DateRangeValue.preset(DateRangePreset preset, DateTime nowUtc) {
    final DateTime today = DsBishkekTime.startOfDayUtc(nowUtc);
    final DateTime todayEnd = DsBishkekTime.endOfDayUtc(nowUtc);
    switch (preset) {
      case DateRangePreset.today:
      case DateRangePreset.custom:
        return DateRangeValue(fromUtc: today, toUtc: todayEnd);
      case DateRangePreset.yesterday:
        final DateTime y = today.subtract(const Duration(days: 1));
        return DateRangeValue(fromUtc: y, toUtc: DsBishkekTime.endOfDayUtc(y));
      case DateRangePreset.last7Days:
        return DateRangeValue(fromUtc: today.subtract(const Duration(days: 6)), toUtc: todayEnd);
      case DateRangePreset.month:
        final DateTime w = DsBishkekTime.wall(nowUtc);
        return DateRangeValue(fromUtc: DsBishkekTime.dayStartUtc(w.year, w.month, 1), toUtc: todayEnd);
    }
  }

  /// Начало периода.
  final DateTime fromUtc;

  /// Конец периода.
  final DateTime toUtc;

  /// Длина в календарных днях Бишкека.
  int get days => DsBishkekTime.daysInclusive(fromUtc, toUtc);

  /// Какому пресету равен период (или [DateRangePreset.custom]).
  DateRangePreset presetFor(DateTime nowUtc) {
    for (final DateRangePreset p in DateRangePreset.values) {
      if (p == DateRangePreset.custom) continue;
      if (DateRangeValue.preset(p, nowUtc) == this) return p;
    }
    return DateRangePreset.custom;
  }

  @override
  bool operator ==(Object other) => other is DateRangeValue && other.fromUtc == fromUtc && other.toUtc == toUtc;

  @override
  int get hashCode => Object.hash(fromUtc, toUtc);
}

/// Подписи пикера (ARB вызывающего экрана).
@immutable
final class DateRangePickerLabels {
  /// Создаёт подписи.
  const DateRangePickerLabels({
    required this.presets,
    required this.from,
    required this.to,
    required this.apply,
    required this.cancel,
    required this.tooLong,
    required this.invalid,
  });

  /// Подписи журналов (ключи SCR-36 `transactions_period_*`, общие `ds_button_*`; «от»/«до» — `filters_price_*`).
  factory DateRangePickerLabels.journal(AppLocalizations l10n, {int maxDays = DateRangePicker.journalMaxDays}) =>
      DateRangePickerLabels(
        presets: <DateRangePreset, String>{
          DateRangePreset.today: l10n.transactions_period_today,
          DateRangePreset.yesterday: l10n.transactions_period_yesterday,
          DateRangePreset.last7Days: l10n.transactions_period_7d,
          DateRangePreset.month: l10n.transactions_period_month,
          DateRangePreset.custom: l10n.transactions_period_custom,
        },
        from: l10n.filters_price_from,
        to: l10n.filters_price_to,
        apply: l10n.ds_button_apply,
        cancel: l10n.ds_button_cancel,
        tooLong: l10n.transactions_period_too_long('$maxDays'),
        invalid: l10n.transactions_filter_failed,
      );

  /// Пресеты.
  final Map<DateRangePreset, String> presets;

  /// «от».
  final String from;

  /// «до».
  final String to;

  /// «Применить».
  final String apply;

  /// «Отмена».
  final String cancel;

  /// «Период больше 366 дней».
  final String tooLong;

  /// Неверная дата / конец раньше начала.
  final String invalid;
}

/// Кнопка-поле периода; выбор — в листе (compact) или диалоге (medium+).
class DateRangePicker extends StatelessWidget {
  /// Создаёт пикер.
  const DateRangePicker({
    super.key,
    required this.value,
    required this.nowUtc,
    required this.onChanged,
    this.labels,
    this.maxDays = DateRangePicker.journalMaxDays,
    this.enabled = true,
    this.allowFuture = false,
    this.semanticLabel,
  });

  /// Максимальная длина периода журналов (ядро §19.4, DS-092).
  static const int journalMaxDays = 366;

  /// Текущий период.
  final DateRangeValue value;

  /// «Сейчас» (Clock).
  final DateTime nowUtc;

  /// Новый период (после «Применить» или выбора пресета).
  final ValueChanged<DateRangeValue> onChanged;

  /// Подписи (по умолчанию — [DateRangePickerLabels.journal]).
  final DateRangePickerLabels? labels;

  /// Предел длины.
  final int maxDays;

  /// Доступен.
  final bool enabled;

  /// Будущие даты допустимы (для журналов — нет).
  final bool allowFuture;

  /// Подпись для screen reader.
  final String? semanticLabel;

  /// Открыть выбор периода; результат — новый период или `null` (отмена).
  static Future<DateRangeValue?> pick(
    BuildContext context, {
    required DateRangeValue value,
    required DateTime nowUtc,
    DateRangePickerLabels? labels,
    int maxDays = DateRangePicker.journalMaxDays,
    bool allowFuture = false,
  }) {
    final DateRangePickerLabels l = labels ?? DateRangePickerLabels.journal(AppLocalizations.of(context));
    Widget panel(BuildContext ctx) => DateRangePickerPanel(
      initial: value,
      nowUtc: nowUtc,
      labels: l,
      maxDays: maxDays,
      allowFuture: allowFuture,
      onApply: (DateRangeValue v) => Navigator.of(ctx).pop(v),
      onCancel: () => Navigator.of(ctx).pop(),
    );
    if (context.windowClass == WindowClass.compact) {
      return AppBottomSheet.show<DateRangeValue>(
        context,
        body: Builder(builder: panel),
        variant: AppBottomSheetVariant.fullHeight,
      );
    }
    final DsColors c = context.colors;
    return showDialog<DateRangeValue>(
      context: context,
      barrierColor: c.overlay,
      builder: (BuildContext ctx) => Dialog(
        backgroundColor: c.surface,
        surfaceTintColor: c.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(ctx.radii.lg)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(padding: EdgeInsets.all(ctx.space.s6), child: panel(ctx)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final String text = DsBishkekTime.rangeText(value.fromUtc, value.toUtc, locale);
    return Semantics(
      label: semanticLabel,
      button: true,
      child: AppButton(
        key: const ValueKey<String>('date-range-picker'),
        label: text,
        icon: Icons.calendar_month_outlined,
        variant: AppButtonVariant.outlined,
        onPressed: !enabled
            ? null
            : () async {
                final DateRangeValue? picked = await pick(
                  context,
                  value: value,
                  nowUtc: nowUtc,
                  labels: labels,
                  maxDays: maxDays,
                  allowFuture: allowFuture,
                );
                if (picked != null && picked != value) onChanged(picked);
              },
      ),
    );
  }
}

/// Содержимое выбора периода: пресеты, поля «от»/«до» (`дд.мм.гггг`, календарь по кнопке), ошибка, «Применить».
class DateRangePickerPanel extends StatefulWidget {
  /// Создаёт панель.
  const DateRangePickerPanel({
    super.key,
    required this.initial,
    required this.nowUtc,
    required this.labels,
    required this.onApply,
    this.onCancel,
    this.maxDays = DateRangePicker.journalMaxDays,
    this.allowFuture = false,
  });

  /// Исходный период.
  final DateRangeValue initial;

  /// «Сейчас».
  final DateTime nowUtc;

  /// Подписи.
  final DateRangePickerLabels labels;

  /// «Применить».
  final ValueChanged<DateRangeValue> onApply;

  /// «Отмена».
  final VoidCallback? onCancel;

  /// Предел длины.
  final int maxDays;

  /// Будущие даты допустимы.
  final bool allowFuture;

  @override
  State<DateRangePickerPanel> createState() => _DateRangePickerPanelState();
}

class _DateRangePickerPanelState extends State<DateRangePickerPanel> {
  late final TextEditingController _from = TextEditingController(text: DsBishkekTime.date(widget.initial.fromUtc));
  late final TextEditingController _to = TextEditingController(text: DsBishkekTime.date(widget.initial.toUtc));
  late DateRangePreset _preset = widget.initial.presetFor(widget.nowUtc);

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  DateTime? get _fromDay => DsBishkekTime.parseDate(_from.text);
  DateTime? get _toDay => DsBishkekTime.parseDate(_to.text);

  /// Ошибка ввода или `null`.
  String? get _error {
    final DateTime? a = _fromDay;
    final DateTime? b = _toDay;
    if (a == null || b == null || b.isBefore(a)) return widget.labels.invalid;
    if (!widget.allowFuture && a.isAfter(DsBishkekTime.startOfDayUtc(widget.nowUtc))) return widget.labels.invalid;
    if (DsBishkekTime.daysInclusive(a, b) > widget.maxDays) return widget.labels.tooLong;
    return null;
  }

  DateRangeValue? get _value {
    final DateTime? a = _fromDay;
    final DateTime? b = _toDay;
    if (a == null || b == null || _error != null) return null;
    return DateRangeValue(fromUtc: a, toUtc: DsBishkekTime.endOfDayUtc(b));
  }

  void _selectPreset(DateRangePreset p) {
    setState(() {
      _preset = p;
      if (p == DateRangePreset.custom) return;
      final DateRangeValue v = DateRangeValue.preset(p, widget.nowUtc);
      _from.text = DsBishkekTime.date(v.fromUtc);
      _to.text = DsBishkekTime.date(v.toUtc);
    });
  }

  Future<void> _calendar(TextEditingController target) async {
    final DateTime now = DsBishkekTime.wall(widget.nowUtc);
    final DateTime? current = DsBishkekTime.parseDate(target.text);
    final DateTime initial = current == null ? now : DsBishkekTime.wall(current);
    final DateTime last = widget.allowFuture ? DateTime(now.year + 1, 12, 31) : DateTime(now.year, now.month, now.day);
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: DateTime(initial.year, initial.month, initial.day).isAfter(last)
          ? last
          : DateTime(initial.year, initial.month, initial.day),
      firstDate: DateTime(now.year - 5),
      lastDate: last,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _preset = DateRangePreset.custom;
      target.text = DsBishkekTime.date(DsBishkekTime.dayStartUtc(picked.year, picked.month, picked.day));
    });
  }

  Widget _field(String label, TextEditingController c, String key) => Expanded(
    child: AppTextField(
      key: ValueKey<String>(key),
      controller: c,
      label: label,
      keyboardType: TextInputType.datetime,
      textStyle: context.text.body.copyWith(fontFeatures: DsTypography.numeric, color: context.colors.textPrimary),
      onChanged: (_) => setState(() => _preset = DateRangePreset.custom),
      suffix: AppIconButton(
        icon: Icons.calendar_month_outlined,
        semanticLabel: label,
        small: true,
        onPressed: () => _calendar(c),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final String? error = _error;
    final DateRangeValue? value = _value;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          spacing: context.space.s2,
          runSpacing: context.space.s2,
          children: <Widget>[
            for (final MapEntry<DateRangePreset, String> p in widget.labels.presets.entries)
              IntrinsicWidth(
                child: CategoryChip(
                  key: ValueKey<String>('date-range-preset-${p.key.name}'),
                  label: p.value,
                  selected: _preset == p.key,
                  onTap: () => _selectPreset(p.key),
                ),
              ),
          ],
        ),
        SizedBox(height: context.space.s4),
        Row(
          children: <Widget>[
            _field(widget.labels.from, _from, 'date-range-from'),
            SizedBox(width: context.space.s3),
            _field(widget.labels.to, _to, 'date-range-to'),
          ],
        ),
        if (error != null) ...<Widget>[
          SizedBox(height: context.space.s2),
          Row(
            children: <Widget>[
              Icon(Icons.error_outline_rounded, size: 16, color: c.error),
              SizedBox(width: context.space.s1),
              Expanded(
                child: Text(
                  error,
                  key: const ValueKey<String>('date-range-error'),
                  style: context.text.caption.copyWith(color: c.error),
                ),
              ),
            ],
          ),
        ],
        SizedBox(height: context.space.s6),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: context.space.s2,
          runSpacing: context.space.s2,
          children: <Widget>[
            if (widget.onCancel != null)
              AppButton(label: widget.labels.cancel, variant: AppButtonVariant.text, onPressed: widget.onCancel),
            AppButton(
              key: const ValueKey<String>('date-range-apply'),
              label: widget.labels.apply,
              onPressed: value == null ? null : () => widget.onApply(value),
            ),
          ],
        ),
      ],
    );
  }
}
