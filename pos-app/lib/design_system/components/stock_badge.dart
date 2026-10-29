import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Уровень наличия для `StockBadge` (03 §9.17; `StockLevel` 08 §3.6).
enum StockBadgeLevel {
  /// В наличии — `success`, `check_circle`.
  inStock,

  /// Мало — `warning`, `warning`.
  low,

  /// Нет — `error`, `cancel`.
  out,

  /// Остаток неизвестен — `surfaceVariant`/`textSecondary`, `help` (INV-052).
  unknown,
}

/// Вид `StockBadge` (03 §9.17).
enum StockBadgeVariant {
  /// Пилюля 24 с фоном (сетка, карточка).
  pill,

  /// Без фона: иконка 14 + текст `caption 500` (строка остатка карточек каталога, список, компакт; прототип
  /// 2026-10-29). «Мало» — `warning_amber` (иконка обязательна).
  inline,

  /// На фото в сетке: только иконка + число, фон `surface` 90 %, высота 20.
  compact,
}

/// Статус наличия и доступный остаток `StockBadge` (03 §9.17; D-22, A11Y-004): цвет + иконка +
/// текст. Число — `available` сервера (клиент не вычисляет); для `customer` текст без числа.
/// [asOf] — метка устаревания «данные от 09:41» (`stale`, иконка `schedule`).
class StockBadge extends StatelessWidget {
  /// Создаёт бейдж.
  const StockBadge({
    super.key,
    required this.level,
    required this.label,
    this.variant = StockBadgeVariant.pill,
    this.asOf,
    this.semanticLabel,
    this.scaleToFit = false,
  });

  /// Уровень.
  final StockBadgeLevel level;

  /// Текст («Доступно 24 шт», «Нет в наличии», «Остаток неизвестен»); пусто — только иконка.
  final String label;

  /// Вид.
  final StockBadgeVariant variant;

  /// Метка устаревания (уже локализованная).
  final String? asOf;

  /// Подпись для screen reader (по умолчанию — [label] и [asOf]).
  final String? semanticLabel;

  /// Одна строка с уменьшением текста до ширины (карточка сетки 160 lp с фиксированной высотой ячейки:
  /// перенос сжал бы название — FIX-EF-13), как у цены карточки (AC-UI-10-005).
  final bool scaleToFit;

  /// Текст для показа: «В наличии · 24 шт» переносится только после «·» — число и единица (и «·» с первой
  /// частью) связаны неразрывными пробелами. Подпись для screen reader не меняется.
  static String displayLabel(String label) =>
      label.replaceAll(' · ', ' · ').replaceAllMapped(RegExp(r'(\d) (\S)'), (Match m) => '${m[1]} ${m[2]}');

  /// Цвета (фон, текст/иконка) и глиф уровня.
  static (Color, Color, IconData) styleOf(DsColors c, StockBadgeLevel level) => switch (level) {
    StockBadgeLevel.inStock => (c.successContainer, c.success, Icons.check_circle_rounded),
    StockBadgeLevel.low => (c.warningContainer, c.warning, Icons.warning_rounded),
    StockBadgeLevel.out => (c.errorContainer, c.error, Icons.cancel_rounded),
    StockBadgeLevel.unknown => (c.surfaceVariant, c.textSecondary, Icons.help_rounded),
  };

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final (Color bg, Color fg, IconData icon) = styleOf(c, level);
    final bool small = variant == StockBadgeVariant.compact;
    final bool line = variant == StockBadgeVariant.inline;
    final IconData glyph = line && level == StockBadgeLevel.low ? Icons.warning_amber_rounded : icon;
    // Пилюля и строка списка в узкой колонке переносят текст на 2-ю строку по разделителю «·»: число
    // с единицей не разрывается и не обрезается (FIX-EF-13).
    final bool wraps = variant != StockBadgeVariant.compact;
    final TextStyle style = (small || line ? context.text.caption : context.text.label).copyWith(
      color: fg,
      fontWeight: FontWeight.w500,
      fontFeatures: DsTypography.numeric,
    );
    final Widget content = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(glyph, size: small || line ? 14 : 16, color: fg),
        if (label.isNotEmpty) ...<Widget>[
          SizedBox(width: context.space.s1),
          Flexible(
            child: scaleToFit
                ? FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(displayLabel(label), maxLines: 1, style: style),
                  )
                : Text(displayLabel(label), maxLines: wraps ? 2 : 1, overflow: TextOverflow.ellipsis, style: style),
          ),
        ],
        if (asOf != null) ...<Widget>[
          SizedBox(width: context.space.s2),
          Icon(Icons.schedule_rounded, size: 14, color: c.textSecondary),
          SizedBox(width: context.space.s1 / 2),
          Flexible(
            child: Text(
              asOf!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.text.caption.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      ],
    );
    final Widget body = switch (variant) {
      StockBadgeVariant.inline => content,
      StockBadgeVariant.pill || StockBadgeVariant.compact => Container(
        height: small ? 20 : null,
        constraints: small ? null : const BoxConstraints(minHeight: 24),
        padding: EdgeInsets.symmetric(horizontal: context.space.s2, vertical: small ? 0 : 2),
        decoration: BoxDecoration(
          color: small ? c.surface.withValues(alpha: 0.9) : bg,
          borderRadius: BorderRadius.all(context.radii.full),
        ),
        child: content,
      ),
    };
    return Semantics(
      label: semanticLabel ?? <String>[label, ?asOf].where((String s) => s.isNotEmpty).join(', '),
      excludeSemantics: true,
      child: body,
    );
  }
}
