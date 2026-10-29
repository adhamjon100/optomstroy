import 'package:flutter/material.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Строка итогов `CartSummary` (подпись → сумма); [amount] `null` — «…».
@immutable
class CartSummaryRow {
  /// Создаёт строку.
  const CartSummaryRow({required this.label, required this.amount, this.negative = false, this.trailing});

  /// «Товаров (5)», «Скидка (5 %)».
  final String label;

  /// Сумма сервера (тыйыны); клиент её не вычисляет (D-23).
  final Money? amount;

  /// Показать со знаком «−» (U+2212) — скидка.
  final bool negative;

  /// Пометка справа от подписи («Подтвердил: …»).
  final Widget? trailing;
}

/// Итоги корзины/заказа `CartSummary` (03 §9.29): строки `body textSecondary` слева / `bodyLg 16/500 tnum`
/// справа → разделитель `border` → «Итого» `title 18/600` + сумма `display 32/700 primaryText` ([large], expanded)
/// или `h2 24/700` (compact). Фон `background`, паддинг 16, строки 28, итог 48. [drawer] — подвал drawer корзины
/// по прототипу: без своего фона и разделителя, строки `body textSecondary` 24, «Итого» `title 700`, итог 40.
///
/// Все суммы — с сервера (D-19, D-23): компонент только форматирует целые тыйыны. [preliminaryLabel] — метка
/// «предварительно» (UI-20-030) рядом с «Итого», пока изменения не подтверждены сервером или нет сети.
/// [note] — примечание под «Итого» (UI-20-034 «Итог пересчитывает сервер по ценам 1С при оформлении»):
/// `caption textSecondary` (12 lp — не `textTertiary`, DS-007), отступ сверху 4, на всю ширину.
class CartSummary extends StatelessWidget {
  /// Создаёт итоги.
  const CartSummary({
    super.key,
    required this.rows,
    required this.totalLabel,
    required this.total,
    this.preliminaryLabel,
    this.large = false,
    this.loading = false,
    this.tooltip,
    this.totalSemanticLabel,
    this.note,
    this.padding,
    this.drawer = false,
  });

  /// Строки над итогом.
  final List<CartSummaryRow> rows;

  /// «Итого».
  final String totalLabel;

  /// Итог сервера; `null` — ещё не рассчитан («—»; при [loading] — скелетон).
  final Money? total;

  /// «предварительно»; `null` — метка скрыта.
  final String? preliminaryLabel;

  /// Итог `display 32/700` (expanded); иначе `h2 24/700`.
  final bool large;

  /// Загрузка: `SkeletonBox` 120×32 на месте итога.
  final bool loading;

  /// «Суммы рассчитаны сервером, 09:42».
  final String? tooltip;

  /// Читаемая форма итога («Итого 16 007 сом 50 тыйын»).
  final String? totalSemanticLabel;

  /// Примечание под «Итого» (UI-20-034); `null` — нет.
  final String? note;

  /// Поля блока; `null` — 16 со всех сторон (drawer корзины — 20 по бокам, как зона G).
  final EdgeInsetsGeometry? padding;

  /// Подвал drawer корзины (прототип 2026-10-29): фон и верхнюю границу задаёт `CartPanel`; строки — подпись и сумма
  /// `body textSecondary` высотой 24, без разделителя; «Итого» `title 700 textPrimary`, сумма `h2 700 primaryText`.
  final bool drawer;

  /// Ключ суммы «Итого» (тесты).
  static const Key totalKey = ValueKey<String>('cart-summary-total');

  /// Ключ примечания UI-20-034 (тесты).
  static const Key noteKey = ValueKey<String>('cart-summary-note');

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final TextStyle valueStyle = drawer
        ? context.text.body.copyWith(
            color: c.textSecondary,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          )
        : context.text.bodyLg.copyWith(
            fontWeight: FontWeight.w500,
            color: c.textPrimary,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          );
    final TextStyle totalStyle = context.text
        .priceOf(large ? context.text.display : context.text.h2)
        .copyWith(color: c.primaryText);
    final Money? t = total;
    Widget totalValue = loading
        ? const SkeletonBox(width: 120, height: 32)
        : t == null
        ? Text(
            '—',
            key: totalKey,
            style: totalStyle.copyWith(color: c.textSecondary),
          )
        : Semantics(
            label: totalSemanticLabel,
            liveRegion: true,
            excludeSemantics: totalSemanticLabel != null,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerEnd,
              child: Text(
                PriceText.format(t, fixed2: true),
                key: totalKey,
                maxLines: 1,
                style: preliminaryLabel == null ? totalStyle : totalStyle.copyWith(color: c.textSecondary),
              ),
            ),
          );
    if (tooltip != null) totalValue = Tooltip(message: tooltip, child: totalValue);
    return Container(
      color: drawer ? null : c.background,
      padding: padding ?? EdgeInsets.all(context.space.s4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final CartSummaryRow r in rows)
            SizedBox(
              height: drawer ? 24 : 28,
              child: Row(
                children: <Widget>[
                  // Подпись и пометка — во всё свободное место, сумма прижата к правому краю (как «Итого»).
                  Expanded(
                    child: Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            r.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.text.body.copyWith(color: c.textSecondary),
                          ),
                        ),
                        if (r.trailing != null) ...<Widget>[SizedBox(width: context.space.s2), r.trailing!],
                      ],
                    ),
                  ),
                  SizedBox(width: context.space.s2),
                  Text(
                    r.amount == null ? '…' : PriceText.format(r.negative ? -r.amount! : r.amount!, fixed2: true),
                    maxLines: 1,
                    style: valueStyle,
                  ),
                ],
              ),
            ),
          if (rows.isNotEmpty)
            drawer
                ? SizedBox(height: context.space.s1)
                : Divider(height: context.space.s4, thickness: 1, color: c.border),
          ConstrainedBox(
            constraints: BoxConstraints(minHeight: drawer ? 40 : 48),
            child: Row(
              children: <Widget>[
                Text(
                  totalLabel,
                  style: context.text.title.copyWith(
                    fontWeight: drawer ? FontWeight.w700 : FontWeight.w600,
                    color: c.textPrimary,
                  ),
                ),
                if (preliminaryLabel != null) ...<Widget>[
                  SizedBox(width: context.space.s2),
                  Icon(Icons.schedule_rounded, size: 16, color: c.textSecondary),
                  SizedBox(width: context.space.s1),
                  Flexible(
                    child: Text(
                      preliminaryLabel!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.caption.copyWith(color: c.textSecondary),
                    ),
                  ),
                ],
                SizedBox(width: context.space.s2),
                Expanded(
                  child: Align(alignment: AlignmentDirectional.centerEnd, child: totalValue),
                ),
              ],
            ),
          ),
          if (note != null)
            Padding(
              padding: EdgeInsets.only(top: context.space.s1),
              child: Text(
                note!,
                key: noteKey,
                style: context.text.caption.copyWith(color: c.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}
