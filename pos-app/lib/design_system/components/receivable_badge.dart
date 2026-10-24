import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Тон `ReceivableBadge` (03 §9.37; D-24, A11Y-004): цвет + иконка + текст, не только цвет.
enum ReceivableBadgeTone {
  /// «Долга нет» / аванс — `successContainer`/`success`, `check_circle`.
  zero,

  /// Долг без просрочки, «Есть долг» — `warningContainer`/`warning`, `schedule` (иконка обязательна, DS-098).
  due,

  /// Просрочка — `errorContainer`/`error`, `error`.
  overdue,

  /// Лимит — `infoContainer`/`info`, `account_balance_wallet`.
  limit,

  /// «Нет данных из 1С» / «Финансовые данные доступны только онлайн» — `surfaceVariant`/`textSecondary`, `help`.
  noData,
}

/// Статус задолженности клиента `ReceivableBadge` (03 §9.37). Два режима (ядро §22.13 п.1):
/// * [ReceivableBadge.compact] — индикатор строк поиска/списков для всех ролей: «Есть долг» / «Просрочка» без сумм
///   (высота 20);
/// * [ReceivableBadge.new] — пилюля 24 с суммой и датой снимка (`zero`/`due`/`overdue`/`limit`/`noData`); `stale`
///   — [staleLabel] с иконкой `schedule` («на 09:41» — данные старше порога).
///
/// Компонент не знает сущностей фич (FL-05): подписи и суммы — готовыми строками; суммы не вычисляет.
class ReceivableBadge extends StatelessWidget {
  /// Пилюля с суммой (`full`-блоки SCR-32/SCR-34 собирают из неё сводку).
  const ReceivableBadge({
    super.key,
    required this.tone,
    required this.label,
    this.staleLabel,
    this.tooltip,
    this.semanticLabel,
    this.onTap,
  }) : dense = false,
       loading = false;

  /// Индикатор без суммы: [overdue] — «Просрочка», иначе «Есть долг».
  const ReceivableBadge.compact({
    super.key,
    required bool overdue,
    required this.label,
    this.tooltip,
    this.semanticLabel,
    this.onTap,
  }) : tone = overdue ? ReceivableBadgeTone.overdue : ReceivableBadgeTone.due,
       staleLabel = null,
       dense = true,
       loading = false;

  /// Скелетон 96×24.
  const ReceivableBadge.loading({super.key})
    : tone = ReceivableBadgeTone.noData,
      label = '',
      staleLabel = null,
      tooltip = null,
      semanticLabel = null,
      onTap = null,
      dense = false,
      loading = true;

  /// Тон.
  final ReceivableBadgeTone tone;

  /// Текст («Долг 12 000,00 сом», «Есть долг»).
  final String label;

  /// «на 09:41» — снимок устарел (иконка `schedule`).
  final String? staleLabel;

  /// Тултип («Данные 1С на 09:41» / «Есть долг · подробности в карточке клиента»).
  final String? tooltip;

  /// Подпись для диктора; по умолчанию — [label] и [staleLabel].
  final String? semanticLabel;

  /// Тап (`compact` → SCR-32, полный → SCR-34); `null` — не интерактивен.
  final VoidCallback? onTap;

  /// Индикатор без суммы (высота 20).
  final bool dense;

  /// Скелетон.
  final bool loading;

  /// Высота пилюли.
  static const double height = 24;

  /// Высота индикатора `compact`.
  static const double compactHeight = 20;

  /// Доля полосы лимита «Доступно (прогноз) X из Y» (03 §9.37, 02 AC-UI-32-015): только визуальная пропорция двух
  /// серверных значений в минимальных единицах (тыйынах), 0…1; не денежное значение.
  static double limitShare(int remainingMinor, int limitMinor) =>
      limitMinor <= 0 ? 0 : (remainingMinor / limitMinor).clamp(0, 1).toDouble();

  /// Пара (контейнер, цвет переднего плана) и иконка тона.
  static (Color, Color, IconData) styleOf(DsColors c, ReceivableBadgeTone t) => switch (t) {
    ReceivableBadgeTone.zero => (c.successContainer, c.success, Icons.check_circle_rounded),
    ReceivableBadgeTone.due => (c.warningContainer, c.warning, Icons.schedule_rounded),
    ReceivableBadgeTone.overdue => (c.errorContainer, c.error, Icons.error_rounded),
    ReceivableBadgeTone.limit => (c.infoContainer, c.info, Icons.account_balance_wallet_outlined),
    ReceivableBadgeTone.noData => (c.surfaceVariant, c.textSecondary, Icons.help_outline_rounded),
  };

  @override
  Widget build(BuildContext context) {
    if (loading) return const SkeletonBox(width: 96, height: height);
    final DsColors c = context.colors;
    final (Color bg, Color fg, IconData icon) = styleOf(c, tone);
    final TextStyle style = (dense ? context.text.caption : context.text.label).copyWith(
      color: fg,
      fontWeight: FontWeight.w600,
      fontFeatures: DsTypography.numeric,
    );
    final Widget pill = Container(
      constraints: BoxConstraints(minHeight: dense ? compactHeight : height),
      padding: EdgeInsets.symmetric(horizontal: dense ? 6 : 8, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.all(context.radii.full)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: dense ? 14 : 16, color: fg),
          const SizedBox(width: 4),
          Flexible(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
          ),
          if (staleLabel != null) ...<Widget>[
            const SizedBox(width: 6),
            Icon(Icons.schedule_rounded, size: dense ? 14 : 16, color: fg),
            const SizedBox(width: 2),
            Text(staleLabel!, maxLines: 1, style: style.copyWith(fontWeight: FontWeight.w500)),
          ],
        ],
      ),
    );
    final Widget body = onTap == null
        ? pill
        : DsInteractive(
            onTap: onTap,
            builder: (BuildContext context, DsInteractionState s) => Opacity(opacity: s.pressed ? .8 : 1, child: pill),
          );
    return Semantics(
      container: true,
      button: onTap != null,
      label: semanticLabel ?? <String>[label, ?staleLabel].join(', '),
      excludeSemantics: true,
      child: tooltip == null ? body : Tooltip(message: tooltip, child: body),
    );
  }
}
