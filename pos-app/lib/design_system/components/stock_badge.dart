import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/ds_glyph.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Уровень наличия для `StockBadge` (03 §9.17; `StockLevel` 08 §3.6).
enum StockBadgeLevel {
  /// В наличии — `success`, `check_circle` (строка наличия — `stockIn`, круг с галочкой).
  inStock,

  /// Мало — `warning`, `warning` (строка наличия — текст `stockLowText`, треугольник `stockLowIcon`).
  low,

  /// Нет — `error`, `cancel` (строка наличия — серый `stockOutText`, круг `stockOutIcon` с крестом; ADR-114).
  out,

  /// Остаток неизвестен — `surfaceVariant`/`textSecondary`, `help` (INV-052; строка наличия — серый, круг с «?»).
  unknown,
}

/// Вид `StockBadge` (03 §9.17).
enum StockBadgeVariant {
  /// Пилюля 24 с фоном (сетка, карточка).
  pill,

  /// Без фона (строка остатка карточки сетки каталога; прототип, ADR-114): глиф 14 прототипа + зазор 6 + текст
  /// `stock 12.5/500` цвета уровня — «В наличии» `stockIn`, «Мало» `stockLowText` с треугольником `stockLowIcon`,
  /// «Нет в наличии» и «Остаток неизвестен» — серые `stockOutText` с кругом `stockOutIcon`.
  inline,

  /// На фото в сетке: только иконка + число, фон `surface` 90 %, высота 20.
  compact,

  /// Только текст 13/500 (`meta`, вес 500) цвета уровня (как [inline]) — колонка «Наличие» строки «Списка» и таблицы
  /// «Компакт» (прототип, ADR-114).
  text,
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

  /// Размер глифа строки наличия (прототип: SVG 14 × 14).
  static const double glyphSize = 14;

  /// Текст для показа: «В наличии · 24 шт» переносится только после «·» — число и единица (и «·» с первой
  /// частью) связаны неразрывными пробелами. Подпись для screen reader не меняется.
  static String displayLabel(String label) =>
      label.replaceAll(' · ', ' · ').replaceAllMapped(RegExp(r'(\d) (\S)'), (Match m) => '${m[1]} ${m[2]}');

  /// Цвета (фон, текст/иконка) и глиф уровня — пилюли [StockBadgeVariant.pill] и [StockBadgeVariant.compact].
  static (Color, Color, IconData) styleOf(DsColors c, StockBadgeLevel level) => switch (level) {
    StockBadgeLevel.inStock => (c.successContainer, c.success, Icons.check_circle_rounded),
    StockBadgeLevel.low => (c.warningContainer, c.warning, Icons.warning_rounded),
    StockBadgeLevel.out => (c.errorContainer, c.error, Icons.cancel_rounded),
    StockBadgeLevel.unknown => (c.surfaceVariant, c.textSecondary, Icons.help_rounded),
  };

  /// Строка наличия прототипа (ADR-114): цвет текста, глиф и его заливка для [level].
  static (Color, DsGlyphKind, Color) lineStyleOf(DsColors c, StockBadgeLevel level) => switch (level) {
    StockBadgeLevel.inStock => (c.stockIn, DsGlyphKind.checkCircle, c.stockIn),
    StockBadgeLevel.low => (c.stockLowText, DsGlyphKind.warningTriangle, c.stockLowIcon),
    StockBadgeLevel.out => (c.stockOutText, DsGlyphKind.crossCircle, c.stockOutIcon),
    StockBadgeLevel.unknown => (c.stockOutText, DsGlyphKind.questionCircle, c.stockOutIcon),
  };

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool line = variant == StockBadgeVariant.inline || variant == StockBadgeVariant.text;
    final Widget body = line ? _line(context, c) : _pill(context, c);
    return Semantics(
      label: semanticLabel ?? <String>[label, ?asOf].where((String s) => s.isNotEmpty).join(', '),
      excludeSemantics: true,
      child: body,
    );
  }

  Widget _labelText(TextStyle style, {required bool wraps}) => scaleToFit
      ? FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Text(displayLabel(label), maxLines: 1, style: style),
        )
      : Text(displayLabel(label), maxLines: wraps ? 2 : 1, overflow: TextOverflow.ellipsis, style: style);

  /// Метка устаревания «данные от 09:41» после текста (иконка `schedule` 14 + `caption textSecondary`).
  List<Widget> _stale(BuildContext context, DsColors c) => asOf == null
      ? const <Widget>[]
      : <Widget>[
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
        ];

  /// Строка наличия прототипа: [StockBadgeVariant.inline] — глиф 14 + зазор 6 + `stock 12.5/500`;
  /// [StockBadgeVariant.text] — только `meta 13` с весом 500.
  Widget _line(BuildContext context, DsColors c) {
    final (Color fg, DsGlyphKind glyph, Color fill) = lineStyleOf(c, level);
    final bool withGlyph = variant == StockBadgeVariant.inline;
    final TextStyle style = (withGlyph ? context.text.stock : context.text.meta).copyWith(
      color: fg,
      fontWeight: FontWeight.w500,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (withGlyph) DsGlyph(kind: glyph, size: glyphSize, color: fill),
        if (label.isNotEmpty) ...<Widget>[
          // Прототип: gap 6 между глифом и текстом (между `space.s1` и `space.s2`).
          if (withGlyph) SizedBox(width: context.space.s1 + 2),
          Flexible(child: _labelText(style, wraps: true)),
        ],
        ..._stale(context, c),
      ],
    );
  }

  Widget _pill(BuildContext context, DsColors c) {
    final (Color bg, Color fg, IconData icon) = styleOf(c, level);
    final bool small = variant == StockBadgeVariant.compact;
    final TextStyle style = (small ? context.text.caption : context.text.label).copyWith(
      color: fg,
      fontWeight: FontWeight.w500,
      fontFeatures: DsTypography.numeric,
    );
    // Пилюля переносит текст на 2-ю строку по разделителю «·»: число с единицей не разрывается и не обрезается
    // (FIX-EF-13); вид `compact` — одна строка.
    final Widget content = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: small ? 14 : 16, color: fg),
        if (label.isNotEmpty) ...<Widget>[
          SizedBox(width: context.space.s1),
          Flexible(child: _labelText(style, wraps: !small)),
        ],
        ..._stale(context, c),
      ],
    );
    return Container(
      height: small ? 20 : null,
      constraints: small ? null : const BoxConstraints(minHeight: 24),
      padding: EdgeInsets.symmetric(horizontal: context.space.s2, vertical: small ? 0 : 2),
      decoration: BoxDecoration(
        color: small ? c.surface.withValues(alpha: 0.9) : bg,
        borderRadius: BorderRadius.all(context.radii.full),
      ),
      child: content,
    );
  }
}
