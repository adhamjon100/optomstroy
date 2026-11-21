import 'package:flutter/material.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/layout/text_measure.dart';
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
/// по прототипу без округления (ADR-114 п. 6, design-spec §13): без своего фона и разделителя, строки подряд с
/// зазором 12 — «Товаров (N)» и сумма 14/400 `textSecondary` #5B6478 (высота 17), «Итого» `totalLabel` 18/800
/// `textPrimary` и сумма `cartTotal` 24/800 `primaryText` по базовой линии (высота 29), примечание 12/400
/// `catalogMeta` #6B7487 (CP-094); цифры без `tnum`.
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

  /// «предварительно»; `null` — метка скрыта. В строке «Итого» метке — остаток места (уже — с многоточием), сумме — её
  /// полная ширина; не помещаются оба — сумма строкой ниже (T-UI-117).
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

  /// Подвал drawer корзины (прототип): фон и верхнюю границу задаёт `CartPanel`; строки с зазором [drawerGap] —
  /// подпись и сумма 14/400 `textSecondary`, без разделителя; «Итого» 18/800 `textPrimary`, сумма 24/800
  /// `primaryText`; примечание 12 `catalogMeta`.
  final bool drawer;

  /// Зазор строк подвала drawer (прототип: `gap: 12px`).
  static const double drawerGap = 12;

  /// Ключ суммы «Итого» (тесты).
  static const Key totalKey = ValueKey<String>('cart-summary-total');

  /// Ключ примечания UI-20-034 (тесты).
  static const Key noteKey = ValueKey<String>('cart-summary-note');

  /// Наименьшая ширина метки «предварительно» в строке «Итого» (lp): уже — сумма строкой ниже.
  static const double _preliminaryMin = 48;

  /// Метка «предварительно»: [maxWidth] `null` — `Flexible` (остаток строки делится с другими flex-детьми); иначе —
  /// не flex-ребёнок не шире [maxWidth] (сумма — единственный flex-ребёнок строки и получает свою полную ширину).
  static Widget _preliminaryText(Text text, double? maxWidth) => maxWidth == null
      ? Flexible(child: text)
      : ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: text,
        );

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    // Drawer (прототип): 14/400, строка `normal` (17) — `chip` с весом 400.
    final TextStyle rowStyle = drawer
        ? context.text.chip.copyWith(fontWeight: FontWeight.w400, color: c.textSecondary)
        : context.text.body.copyWith(color: c.textSecondary);
    final TextStyle valueStyle = drawer
        ? rowStyle
        : context.text.bodyLg.copyWith(
            fontWeight: FontWeight.w500,
            color: c.textPrimary,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          );
    final TextStyle totalStyle = drawer
        ? context.text.cartTotal.copyWith(color: c.primaryText)
        : context.text.priceOf(large ? context.text.display : context.text.h2).copyWith(color: c.primaryText);
    final Money? t = total;
    Widget totalValue = loading
        ? SkeletonBox(width: 120, height: drawer ? 29 : 32)
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
          for (final CartSummaryRow r in rows) ...<Widget>[
            SizedBox(
              height: drawer ? null : 28,
              child: Row(
                children: <Widget>[
                  // Подпись и пометка — во всё свободное место, сумма прижата к правому краю (как «Итого»).
                  Expanded(
                    child: Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(r.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: rowStyle),
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
            if (drawer) const SizedBox(height: drawerGap),
          ],
          if (rows.isNotEmpty && !drawer) Divider(height: context.space.s4, thickness: 1, color: c.border),
          ConstrainedBox(
            constraints: BoxConstraints(minHeight: drawer ? 0 : 48),
            // «Итого» и сумма не помещаются в строку (телефон, крупный текст; drawer планшета 360) — сумма строкой ниже
            // у конца целиком, а не уменьшается `FittedBox` (T-UI-117, пакет own-server:GAP-APP); помещаются — прежняя
            // строка. `FittedBox` — только защита, если сумма шире всей строки.
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints box) {
                final TextStyle labelStyle = drawer
                    ? context.text.totalLabel.copyWith(color: c.textPrimary)
                    : context.text.title.copyWith(fontWeight: FontWeight.w600, color: c.textPrimary);
                final Widget label = Text(totalLabel, style: labelStyle);
                final double need =
                    t == null ||
                        loading // money-double: allow — геометрия UI (lp)
                    ? 0
                    : dsTextWidth(context, totalLabel, labelStyle) +
                          (preliminaryLabel == null ? 0 : context.space.s2 + 16 + context.space.s1 + _preliminaryMin) +
                          context.space.s2 +
                          dsTextWidth(context, PriceText.format(t, fixed2: true), totalStyle);
                final bool stacked = box.hasBoundedWidth && need > box.maxWidth;
                // Метка «предварительно» в строке с суммой — не flex-ребёнок: `Row` делит свободное место поровну
                // между flex-детьми, и `Flexible` метки отнимал у `Expanded` суммы половину — сумма уменьшалась
                // `FittedBox` (×0,63…0,84 на 360…420; ревью own-server:FIX-app). Метке — остаток строки сверх оценки
                // [need] (не меньше [_preliminaryMin]), сумме — её полная ширина. Итог неизвестен (`need` = 0:
                // скелетон, «—») или сумма строкой ниже — прежний `Flexible`.
                final double? preliminaryMax = stacked || need == 0 || !box.hasBoundedWidth
                    ? null
                    : box.maxWidth - need + _preliminaryMin;
                final List<Widget> preliminary = <Widget>[
                  if (preliminaryLabel != null) ...<Widget>[
                    SizedBox(width: context.space.s2),
                    Icon(Icons.schedule_rounded, size: 16, color: c.textSecondary),
                    SizedBox(width: context.space.s1),
                    _preliminaryText(
                      Text(
                        preliminaryLabel!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.caption.copyWith(color: c.textSecondary),
                      ),
                      preliminaryMax,
                    ),
                  ],
                ];
                if (stacked) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Row(children: <Widget>[label, ...preliminary]),
                      Align(alignment: AlignmentDirectional.centerEnd, child: totalValue),
                    ],
                  );
                }
                return Row(
                  // Drawer (прототип): «Итого» и сумма — по базовой линии (`align-items: baseline`).
                  crossAxisAlignment: drawer ? CrossAxisAlignment.baseline : CrossAxisAlignment.center,
                  textBaseline: TextBaseline.alphabetic,
                  children: <Widget>[
                    label,
                    ...preliminary,
                    SizedBox(width: context.space.s2),
                    Expanded(
                      child: Align(alignment: AlignmentDirectional.centerEnd, child: totalValue),
                    ),
                  ],
                );
              },
            ),
          ),
          if (note != null)
            Padding(
              padding: EdgeInsets.only(top: drawer ? drawerGap : context.space.s1),
              child: Text(
                note!,
                key: noteKey,
                // Drawer (прототип): 12/400 #6B7487 на #FBFCFE — 4,57:1 (CP-094); иначе `caption textSecondary`.
                style: drawer
                    ? context.text.sku.copyWith(color: c.catalogMeta)
                    : context.text.caption.copyWith(color: c.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}
