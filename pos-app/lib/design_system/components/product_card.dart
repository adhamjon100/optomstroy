import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/ds_hairline.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/favorite_toggle.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/product_image.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/stock_badge.dart';
import 'package:optomstroy/design_system/layout/text_measure.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Что показывать на месте контрола количества карточки (02 ч. B §2.3, шаги 1, 7, 8; прототип 2026-10-29).
enum ProductCardActionKind {
  /// «+ Добавить» (сетка, список, компакт-таблица) / «+» (строки compact).
  add,

  /// Товар уже в корзине: «В корзине · N — ещё +1» (тинт; в компакт-таблице — «Ещё · N»); нажатие добавляет ещё
  /// шаг — тот же [ProductCardCallbacks.onAction] (ADR-112).
  inCart,

  /// Товар с вариантами: «Выбрать вариант» → SCR-15 (INV-014).
  chooseVariant,

  /// Добавление недоступно: нет в наличии / нет цены / остаток неизвестен (INV-013, INV-023, INV-052);
  /// причина — [ProductCardData.actionLabel] (серая недоступная кнопка).
  unavailable,

  /// Нет права `cart.manage.own` (`owner`) — контрол скрыт (место той же высоты).
  hidden,
}

/// Данные карточки товара — единая модель трёх видов (02 ч. B §2.3; `ProductSummary` 08 §3.6).
/// Строки уже локализованы вызывающим кодом (фича каталога); компонент только раскладывает.
@immutable
class ProductCardData {
  /// Создаёт данные карточки.
  const ProductCardData({
    required this.id,
    required this.name,
    required this.skuLabel,
    this.skuMissing = false,
    this.variantsLabel,
    this.imageUrl,
    this.thumbUrl,
    this.price,
    this.pricePrefix,
    this.priceUnit,
    this.priceMissingLabel,
    this.unitLabel,
    this.stockLevel,
    this.stockLabel = '',
    this.stockAsOf,
    this.isFavorite = false,
    this.favoriteLabel = '',
    this.showFavorite = true,
    this.matchLabel,
    this.action = ProductCardActionKind.hidden,
    this.actionLabel,
    this.actionShortLabel,
    this.actionBusy = false,
    this.dimmed = false,
    this.semanticLabel,
  });

  /// ID товара.
  final String id;

  /// Название (полное — в тултипе, INV-053).
  final String name;

  /// «Арт. F4252-CR» или «Артикул не указан».
  final String skuLabel;

  /// Артикула нет — подпись `textSecondary` курсивом не выделяется, только текстом.
  final bool skuMissing;

  /// «3 варианта» (товар с вариантами).
  final String? variantsLabel;

  /// URL фото `card` (сетка).
  final String? imageUrl;

  /// URL фото `thumb` (список, компакт).
  final String? thumbUrl;

  /// Цена (значение сервера); `null` — нет цены.
  final Money? price;

  /// «от {price}» для товара с вариантами разной цены.
  final String Function(String formatted)? pricePrefix;

  /// «/ шт».
  final String? priceUnit;

  /// «Цена не указана».
  final String? priceMissingLabel;

  /// Краткая единица («шт»).
  final String? unitLabel;

  /// Уровень наличия; `null` — бейдж не показывается.
  final StockBadgeLevel? stockLevel;

  /// Текст бейджа остатка.
  final String stockLabel;

  /// Метка устаревания «данные от 09:41».
  final String? stockAsOf;

  /// В избранном.
  final bool isFavorite;

  /// Подпись звезды для screen reader.
  final String favoriteLabel;

  /// Показывать звезду (`favorites.products.manage`).
  final bool showFavorite;

  /// Бейдж типа совпадения поиска («артикул», SCR-11 UI-11-014).
  final String? matchLabel;

  /// Контрол количества.
  final ProductCardActionKind action;

  /// Подпись действия: «+ Добавить», «В корзине · 3 — ещё +1», «Выбрать вариант», причина недоступности.
  final String? actionLabel;

  /// Короткая подпись для строки «Компакт» («Ещё · 3»); `null` — [actionLabel].
  final String? actionShortLabel;

  /// Добавление в корзину выполняется: кнопка сразу показывает загрузку и не принимает повторные нажатия
  /// (мгновенная обратная связь без лишних запросов и количеств).
  final bool actionBusy;

  /// Товар недоступен (нет в наличии): в строках compact — фото 60 %, текст `textSecondary`. Сетка, список medium+ и
  /// таблица «Компакт» не приглушаются (прототип, ADR-114): состояние видно в строке наличия и по серой кнопке.
  final bool dimmed;

  /// Метка карточки целиком («Смеситель…, 2 350 сом за штуку, в наличии 24 шт, артикул F4252»).
  final String? semanticLabel;
}

/// Общие колбэки карточки.
@immutable
class ProductCardCallbacks {
  /// Создаёт колбэки.
  const ProductCardCallbacks({this.onOpen, this.onFavorite, this.onAction});

  /// Тап по фото/названию/строке → SCR-14.
  final VoidCallback? onOpen;

  /// Звезда: новое значение.
  final ValueChanged<bool>? onFavorite;

  /// Контрол количества («+ Добавить» / «В корзине · N — ещё +1» / «Выбрать вариант»).
  final VoidCallback? onAction;
}

/// Высота поля фото карточки сетки (прототип: блок 150, отступ снизу 10).
const double kProductCardGridImageHeight = 150;

/// Наибольшая высота фото и плашки «Фото появится из 1С» в поле [kProductCardGridImageHeight] (прототип: 146).
const double kProductCardGridPhotoHeight = 146;

/// Наименьшая высота названия карточки сетки (прототип: `min-height: 37px`, 2 строки по 18,48).
const double kProductCardGridNameMinHeight = 37;

/// Высота строки CSS `line-height: normal` у Inter так, как её считает Chrome (восхождение 0,96875 и нисхождение
/// 0,2412 кегля, каждое округлено до пикселя): 12 → 15, 12,5 → 15, 13 → 16, 14 → 17, 18 → 21 (снимки прототипа).
double _cssLine(double fontSize) => (fontSize * 0.96875).roundToDouble() + (fontSize * 0.2412).roundToDouble();

/// Ширина строки «[price] · 4 · [unit]» карточки сетки при масштабе шрифта [scaler]: сумма как показана
/// («от 10 450,00 сом») стилем `catalogPrice`, зазор 4, единица («/ шт») стилем `meta` — как у `PriceText` с
/// `wrapUnit`.
double kProductCardGridPriceLineWidth(TextScaler scaler, String price, String unit) {
  const DsTypography t = DsTypography.inter;
  return dsTextWidthWith(price, t.catalogPrice, scaler: scaler) + 4 + dsTextWidthWith(unit, t.meta, scaler: scaler);
}

/// «[price] / [unit]» не помещается в одну строку карточки сетки шириной [cardWidth] (с обводками) при масштабе
/// [scaler] — единица уходит на вторую строку (прототип: `flex-wrap`, `gap: 4px`). Решается по цене самой карточки,
/// а не по образцу: при 1366 × 768 (карточка 186,7) «10 450,00 сом / шт» помещается — ячейка 340, как в прототипе
/// (ревью V-01). Без единицы — не переносится.
bool kProductCardGridPriceWraps(TextScaler scaler, double cardWidth, {required String price, String? unit}) {
  if (unit == null || unit.isEmpty) {
    return false;
  }
  return kProductCardGridPriceLineWidth(scaler, price, unit) > cardWidth - 2 - _gridCardPadding.horizontal;
}

/// Строка цены карточки сетки [data] как она показана («от 10 450,00 сом») — для [kProductCardGridPriceWraps];
/// `null` — цены нет.
String? kProductCardGridPriceText(ProductCardData data) {
  final Money? price = data.price;
  if (price == null) {
    return null;
  }
  final String formatted = PriceText.format(price);
  return data.pricePrefix?.call(formatted) ?? formatted;
}

/// Поля карточки сетки внутри обводки (прототип: `padding: 10px 12px 12px`).
const EdgeInsets _gridCardPadding = EdgeInsets.fromLTRB(12, 10, 12, 12);

/// Высота бейджа типа совпадения над названием карточки сетки (20 + зазор 4).
const double _gridMatchBadgeHeight = 24;

/// Текстовая часть карточки сетки: [название ≥ 37] · 4 · «Арт.» · 8 · наличие · 6 · цена (· 4 · «/ шт», если [wraps])
/// — строки по правилу Chrome ([_cssLine]; у `catalogPrice` та же строка 21 задана токеном `lineHeight`, RV-15).
double _gridTextHeight(TextScaler scaler, {required bool wraps}) {
  double s(double v) => scaler.scale(v);
  final double name = math.max(kProductCardGridNameMinHeight, 2 * s(14) * 1.32);
  return name +
      4 +
      _cssLine(s(12)) +
      8 +
      math.max(StockBadge.glyphSize, _cssLine(s(12.5))) +
      6 +
      _cssLine(s(18)) +
      (wraps ? 4 + _cssLine(s(13)) : 0);
}

/// Высота ячейки карточки сетки (высота ряда сетки, 03 §9.11; прототип, ADR-114): обводка 1 · поле 10 · фото 150 ·
/// 10 · [название ≥ 37] · 4 · «Арт.» · 8 · наличие · 6 · цена · 10 · кнопка 40 · 12 · обводка 1 — 340 при масштабе
/// 1.0, как в прототипе (строки текста — по правилу Chrome, [_cssLine]); 360, если в ряду есть карточка, у которой
/// «цена / шт» не помещается в строку ([priceWraps] — [kProductCardGridPriceWraps] по ценам карточек ряда; единица —
/// второй строкой через зазор 4; ряд CSS-сетки прототипа растягивается по самой высокой карточке, 1920 × 1080).
/// Текстовая часть масштабируется [scaler] (крупный шрифт — без переполнения: название сжимается первым);
/// [matchBadge] — бейдж типа совпадения (SCR-11) над названием. В ячейке 340 карточка с более длинной ценой не
/// переносит «/ шт», а уменьшает строку цены (ревью RC-11).
double kProductCardGridExtent(TextScaler scaler, {bool matchBadge = false, bool priceWraps = false}) =>
    2 +
    _gridCardPadding.vertical +
    kProductCardGridImageHeight +
    10 +
    (matchBadge ? _gridMatchBadgeHeight : 0) +
    _gridTextHeight(scaler, wraps: priceWraps) +
    10 +
    AppButtonSize.card.height;

/// Карточка товара в сетке `ProductCardGrid` (03 §9.11; 02 SCR-10 D′; прототип, ADR-114): белая карточка с обводкой
/// `border` 1, радиус `catalogCard` 14, поля 10/12/12, тень `elevation.cardHover` при наведении (120 мс). Звезда —
/// белый круг 34 сверху справа (8/8 от обводки). Поле фото 150: фото ≤ 146 `scaleDown` (не увеличивается), без фона;
/// без фото — плашка «Фото появится из 1С». Ниже, через 10: бейдж совпадения (SCR-11), название
/// `cardName 14/600 catalogName` в 2 строки (не ниже 37), «Арт. …» `sku catalogMeta` (через 4), строка наличия
/// `StockBadge.inline` (через 8), цена `catalogPrice` с «/ шт» (через 6; не помещается — единица второй строкой),
/// кнопка 40 у низа карточки (через ≥ 10).
/// Нет в наличии — без приглушения фото и названия (состояние — в строке наличия и на кнопке).
class ProductCardGrid extends StatelessWidget {
  /// Создаёт карточку.
  const ProductCardGrid({super.key, required this.data, this.callbacks = const ProductCardCallbacks()});

  /// Данные.
  final ProductCardData data;

  /// Колбэки.
  final ProductCardCallbacks callbacks;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    // Кнопка 40 — в цели 48 (по 4 сверху и снизу): поле снизу 12 − 4, отступ над кнопкой 10 − 4.
    final double targetInset = (AppButtonSize.card.target - AppButtonSize.card.height) / 2;
    return _CardShell(
      data: data,
      onOpen: callbacks.onOpen,
      radius: BorderRadius.all(context.radii.catalogCard),
      bordered: true,
      hoverElevation: true,
      background: c.surface,
      builder: (BuildContext context, DsInteractionState s) => Stack(
        children: <Widget>[
          Padding(
            padding: _gridCardPadding.copyWith(bottom: _gridCardPadding.bottom - targetInset),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SizedBox(
                  height: kProductCardGridImageHeight,
                  child: Center(
                    child: ProductImage(
                      url: data.imageUrl,
                      size: ProductImageSize.card,
                      height: kProductCardGridPhotoHeight,
                      fit: BoxFit.scaleDown,
                      background: Colors.transparent,
                      borderRadius: BorderRadius.zero,
                      semanticLabel: data.name,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: LayoutBuilder(
                    builder: (BuildContext context, BoxConstraints box) {
                      // Вторая строка «/ шт» — только если ячейка ряда под неё рассчитана (kProductCardGridExtent 360);
                      // в ячейке 340 длинная цена уменьшается в одну строку, а название не сжимается (ревью RC-11).
                      final double unitLineNeed =
                          (data.matchLabel != null ? _gridMatchBadgeHeight : 0) + _gridTextHeight(scaler, wraps: true);
                      final bool unitLine = !box.hasBoundedHeight || box.maxHeight + 0.5 >= unitLineNeed;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          if (data.matchLabel != null) _MatchBadge(label: data.matchLabel!),
                          // Название не короче 2 строк (строки ряда на одной линии); при нехватке места сжимается
                          // первым — наличие, цена и кнопка видны всегда.
                          Flexible(
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                minHeight: math.max(kProductCardGridNameMinHeight, 2 * scaler.scale(14) * 1.32),
                              ),
                              child: _Name(
                                data: data,
                                maxLines: 2,
                                style: context.text.cardName.copyWith(color: c.catalogName),
                              ),
                            ),
                          ),
                          SizedBox(height: context.space.s1),
                          _SkuLine(data: data, withVariants: true, maxLines: 1, style: context.text.sku),
                          if (data.stockLevel != null) ...<Widget>[
                            SizedBox(height: context.space.s2),
                            StockBadge(
                              level: data.stockLevel!,
                              label: data.stockLabel,
                              asOf: data.stockAsOf,
                              variant: StockBadgeVariant.inline,
                              scaleToFit: true,
                            ),
                          ],
                          const SizedBox(height: 6),
                          // «Цена / шт»: не помещается — «/ шт» второй строкой (прототип: flex-wrap, gap 4).
                          PriceText(
                            amount: data.price,
                            unit: data.priceUnit,
                            prefix: data.pricePrefix,
                            missingLabel: data.priceMissingLabel,
                            wrapUnit: true,
                            allowUnitLine: unitLine,
                          ),
                        ],
                      );
                    },
                  ),
                ),
                SizedBox(height: 10 - targetInset),
                _GridAction(data: data, onAction: callbacks.onAction),
              ],
            ),
          ),
          if (data.showFavorite)
            // Круг 34 — на 8 от обводки карточки (цель 48 вокруг него).
            PositionedDirectional(
              top: 8 - (48 - FavoriteToggle.onImageSize) / 2,
              end: 8 - (48 - FavoriteToggle.onImageSize) / 2,
              child: FavoriteToggle(
                selected: data.isFavorite,
                onChanged: callbacks.onFavorite,
                semanticLabel: data.favoriteLabel,
                variant: FavoriteToggleVariant.onImage,
              ),
            ),
        ],
      ),
    );
  }
}

/// Строка товара `ProductCardList` (03 §9.12; прототип, ADR-114). medium и шире — отдельная карточка: обводка `border`
/// 1, радиус `md`, поля 10/14, зазор колонок 18 (между карточками 8 даёт список), тень `cardHover` при наведении; фото
/// в поле 72×60 `scaleDown` (без фото — плашка 60×52 `photoPlaceholderBg`), название `listName 15/600 catalogName` и
/// «Арт.» `sku catalogMeta` (зазор 3), звезда после названия (паритет функций), наличие текстом 13/500 колонкой 150,
/// цена `listPrice 17/800` с «/ шт» справа колонкой 150 (не помещается — «/ шт» второй строкой), кнопка 168×40.
/// Узкая строка (< 860) — наличие под артикулом, цена 120, кнопка 140. compact — прежняя строка 72 с разделителем,
/// ценой и «+» справа.
class ProductCardList extends StatelessWidget {
  /// Создаёт строку.
  const ProductCardList({super.key, required this.data, this.callbacks = const ProductCardCallbacks()});

  /// Данные.
  final ProductCardData data;

  /// Колбэки.
  final ProductCardCallbacks callbacks;

  /// Ширина строки, от которой остаток — отдельной колонкой.
  static const double wideFrom = 860;

  /// Зазор между колонками строки (прототип: `gap: 12px 18px`).
  static const double columnGap = 18;

  /// Поля строки внутри обводки (прототип: `padding: 10px 14px`).
  static const EdgeInsets padding = EdgeInsets.symmetric(horizontal: 14, vertical: 10);

  @override
  Widget build(BuildContext context) {
    if (context.windowClass == WindowClass.compact) {
      return _compact(context);
    }
    final DsColors c = context.colors;
    return _CardShell(
      data: data,
      onOpen: callbacks.onOpen,
      radius: BorderRadius.all(context.radii.md),
      bordered: true,
      hoverElevation: true,
      background: c.surface,
      builder: (BuildContext context, DsInteractionState s) => LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final bool wide = box.maxWidth >= wideFrom;
          const SizedBox gap = SizedBox(width: columnGap);
          final Widget stock = data.stockLevel == null
              ? const SizedBox.shrink()
              : StockBadge(
                  level: data.stockLevel!,
                  label: data.stockLabel,
                  asOf: data.stockAsOf,
                  variant: StockBadgeVariant.text,
                );
          // Высота строки — как в прототипе: поля 10 + фото 60 + 10 (с обводкой 82).
          return ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 80),
            child: Padding(
              padding: padding,
              child: Row(
                children: <Widget>[
                  ProductImage(
                    url: data.thumbUrl ?? data.imageUrl,
                    size: ProductImageSize.thumb,
                    dimension: 72,
                    height: 60,
                    fit: BoxFit.scaleDown,
                    background: Colors.transparent,
                    showPlaceholderLabel: false,
                    borderRadius: BorderRadius.zero,
                    plateSize: const Size(60, 52),
                    plateRadius: BorderRadius.all(context.radii.sm),
                    semanticLabel: data.name,
                  ),
                  gap,
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        if (data.matchLabel != null) _MatchBadge(label: data.matchLabel!),
                        _Name(
                          data: data,
                          maxLines: 2,
                          style: context.text.listName.copyWith(color: c.catalogName),
                        ),
                        const SizedBox(height: 3),
                        _SkuLine(data: data, withVariants: true, maxLines: 1, style: context.text.sku),
                        if (!wide && data.stockLevel != null) ...<Widget>[const SizedBox(height: 3), stock],
                      ],
                    ),
                  ),
                  // Звезда — небольшая, после названия (02: избранное доступно и в «Списке»; ADR-112), цвета звезды
                  // сетки (03 §9.23 ред. 1.18, ревью RV-17).
                  if (data.showFavorite)
                    FavoriteToggle(
                      selected: data.isFavorite,
                      onChanged: callbacks.onFavorite,
                      semanticLabel: data.favoriteLabel,
                      variant: FavoriteToggleVariant.catalogInline,
                    ),
                  if (wide) ...<Widget>[gap, SizedBox(width: 150, child: stock)],
                  gap,
                  SizedBox(
                    width: wide ? 150 : 120,
                    child: Align(
                      alignment: AlignmentDirectional.centerEnd,
                      // Прототип: «цена / шт» справа; шестизначная цена — «/ шт» второй строкой.
                      child: PriceText(
                        amount: data.price,
                        unit: data.priceUnit,
                        prefix: data.pricePrefix,
                        missingLabel: data.priceMissingLabel,
                        variant: PriceTextVariant.list,
                        wrapUnit: true,
                        alignEnd: true,
                      ),
                    ),
                  ),
                  gap,
                  SizedBox(
                    width: wide ? 168 : 140,
                    child: _CardAction(data: data, onAction: callbacks.onAction),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// compact: строка 72 с разделителем — фото 56, название, «Арт. · шт», остаток; справа цена, звезда и «+».
  Widget _compact(BuildContext context) {
    final DsColors c = context.colors;
    return _CardShell(
      data: data,
      onOpen: callbacks.onOpen,
      radius: BorderRadius.zero,
      bordered: false,
      background: c.surface,
      divider: true,
      builder: (BuildContext context, DsInteractionState s) => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 72),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.space.s3, vertical: context.space.s2),
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints box) => _compactRow(
              context,
              // Цена — не шире половины места после фото 56 и зазоров.
              sideMax: math.max(0, (box.maxWidth - 56 - context.space.s3 - context.space.s2) / 2),
            ),
          ),
        ),
      ),
    );
  }

  /// Строка compact: фото 56 · название, «Арт. · шт», остаток · цена (не шире [sideMax], длинная уменьшается),
  /// звезда и «+».
  Widget _compactRow(BuildContext context, {required double sideMax}) {
    return Row(
      children: <Widget>[
        Opacity(
          opacity: data.dimmed ? 0.6 : 1,
          child: ProductImage(
            url: data.thumbUrl ?? data.imageUrl,
            size: ProductImageSize.thumb,
            dimension: 56,
            fit: BoxFit.cover,
            showPlaceholderLabel: false,
            borderRadius: BorderRadius.all(context.radii.sm),
            semanticLabel: data.name,
          ),
        ),
        SizedBox(width: context.space.s3),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (data.matchLabel != null) _MatchBadge(label: data.matchLabel!),
              _Name(data: data, maxLines: 2),
              SizedBox(height: context.space.s1 / 2),
              _SkuLine(data: data, withVariants: true, withUnit: true),
              if (data.stockLevel != null) ...<Widget>[
                SizedBox(height: context.space.s1 / 2),
                StockBadge(
                  level: data.stockLevel!,
                  label: data.stockLabel,
                  asOf: data.stockAsOf,
                  variant: StockBadgeVariant.inline,
                ),
              ],
            ],
          ),
        ),
        SizedBox(width: context.space.s2),
        // compact: цена и кнопки — в правом столбце (03 §9.12). Цена всегда с копейками (ADR-114): длинная
        // («от 1 234 567,00 сом / шт») уменьшается до половины строки, название не сжимается в ноль.
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: sideMax),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerEnd,
                child: PriceText(
                  amount: data.price,
                  unit: data.priceUnit,
                  prefix: data.pricePrefix,
                  missingLabel: data.priceMissingLabel,
                  variant: PriceTextVariant.list,
                  disabled: data.dimmed,
                  // Строка красит фон при наведении и нажатии: «/ шт» — `textSecondary` (CP-013, CP-014), `catalogMeta`
                  // на этих фонах ниже 4.5:1 (CP-124, CP-125; ревью RC-07).
                  unitStyle: context.text.meta.copyWith(color: context.colors.textSecondary),
                ),
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (data.showFavorite)
                  FavoriteToggle(
                    selected: data.isFavorite,
                    onChanged: callbacks.onFavorite,
                    semanticLabel: data.favoriteLabel,
                    variant: FavoriteToggleVariant.catalogInline,
                  ),
                _InlineAction(data: data, onAction: callbacks.onAction),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

/// Вариант `ProductCardCompact` (03 §9.13).
enum ProductCardCompactVariant {
  /// Таблица (expanded/large, medium ≥ 840): Артикул · Наименование (миниатюра 40, звезда) · Наличие · Цена «/ шт» ·
  /// кнопка (прототип 2026-10-29; паритет функций ADR-112).
  table,

  /// Однострочная строка 44 lp (compact, medium < 840).
  row,

  /// Плитка ленты 64 lp (SCR-50 «Недавние товары» на compact, UI-50-010): миниатюра 40, название в 2 строки,
  /// под ним цена и статус наличия — без обрезки при ширине плитки 280 (FIX-EF-13).
  strip,
}

/// Ширины колонок таблицы «Компакт» (прототип 2026-10-29, ADR-112; 02 UI-10-118): Артикул 120 · Наименование flex
/// (миниатюра 40, название с числом вариантов, звезда избранного) · Наличие 150 · Цена 150 (с единицей «/ шт») ·
/// кнопка 132, зазор 12. Строка уже [narrowBelow] — узкий набор без колонки «Артикул»: артикул — второй строкой под
/// названием, «Наличие» 120 и «Цена» 130 остаются (паритет функций ADR-112: остаток в таблице виден всегда; без
/// горизонтальной прокрутки).
@immutable
final class ProductCompactLayout {
  /// Создаёт набор ширин.
  const ProductCompactLayout({required this.sku, required this.stock, required this.price, required this.action});

  /// Полный набор.
  static const ProductCompactLayout standard = ProductCompactLayout(
    sku: skuWidth,
    stock: stockWidth,
    price: priceWidth,
    action: actionWidth,
  );

  /// Узкий набор: без колонки «Артикул» (артикул — под названием), «Наличие» и «Цена» уже.
  static const ProductCompactLayout narrow = ProductCompactLayout(
    sku: 0,
    stock: narrowStockWidth,
    price: narrowPriceWidth,
    action: actionWidth,
  );

  /// Артикул.
  static const double skuWidth = 120;

  /// Наличие (статус с количеством).
  static const double stockWidth = 150;

  /// Наличие в узком наборе (статус ужимается `scaleToFit`).
  static const double narrowStockWidth = 120;

  /// Цена.
  static const double priceWidth = 150; // money-double: allow — ширина колонки в lp, не деньги

  /// Цена в узком наборе.
  static const double narrowPriceWidth = 130; // money-double: allow — ширина колонки в lp, не деньги

  /// Кнопка.
  static const double actionWidth = 132;

  /// Миниатюра товара в колонке «Наименование» и зазор после неё.
  static const double thumb = 40;
  static const double thumbGap = 8;

  /// Зазор между колонками.
  static const double gap = 12;

  /// Поля строки по горизонтали.
  static const double sidePadding = 16;

  /// Строка (с полями) уже этого — узкий набор.
  static const double narrowBelow = 840;

  /// Минимальная ширина «Наименования» (с миниатюрой и звездой 48) в полном наборе.
  static const double nameMin =
      narrowBelow - sidePadding * 2 - skuWidth - stockWidth - priceWidth - actionWidth - gap * 4;

  /// 0 — колонки нет.
  final double sku;

  /// Наличие.
  final double stock;
  final double price; // money-double: allow — ширина колонки в lp, не деньги
  final double action;

  /// Колонка «Артикул» показана (иначе артикул — под названием).
  bool get full => sku > 0;

  /// Набор для строки шириной [width] без полей ([sidePadding]).
  static ProductCompactLayout of(BuildContext context, double width) =>
      width + sidePadding * 2 < narrowBelow ? narrow : standard;
}

/// Подписи заголовка таблицы «Компакт».
@immutable
class ProductCompactHeaderLabels {
  /// Создаёт подписи.
  const ProductCompactHeaderLabels({
    required this.sku,
    required this.name,
    required this.stock,
    required this.price,
    this.action,
  });

  /// «Артикул».
  final String sku;

  /// «Наименование».
  final String name;

  /// «Наличие».
  final String stock;

  /// «Цена».
  final String price;

  /// Колонка кнопки (только `Semantics`, без текста); `null` — без подписи.
  final String? action;

  @override
  bool operator ==(Object other) =>
      other is ProductCompactHeaderLabels &&
      other.sku == sku &&
      other.name == name &&
      other.stock == stock &&
      other.price == price &&
      other.action == action;

  @override
  int get hashCode => Object.hash(sku, name, stock, price, action);
}

/// Заголовок таблицы «Компакт» 36 lp (UI-10-118; прототип, ADR-114): `sku 12/600 catalogMeta`, поля 10/16, нижняя
/// линия `border` 1; закрепляется вызывающим. Колонки — как у строк ([ProductCompactLayout]).
class ProductCardCompactHeader extends StatelessWidget {
  /// Создаёт заголовок.
  const ProductCardCompactHeader({super.key, required this.labels});

  /// Подписи.
  final ProductCompactHeaderLabels labels;

  /// Высота заголовка с нижней линией (прототип: поля 10 + строка 15 + 10 + линия 1).
  static const double headerHeight = 36;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final TextStyle style = context.text.sku.copyWith(fontWeight: FontWeight.w600, color: c.catalogMeta);
    Widget cell(String text, double? width, {TextAlign align = TextAlign.start, bool visible = true}) {
      final Widget t = Semantics(
        header: true,
        label: text,
        excludeSemantics: true,
        child: Text(visible ? text : '', maxLines: 1, overflow: TextOverflow.ellipsis, style: style, textAlign: align),
      );
      return width == null ? Expanded(child: t) : SizedBox(width: width, child: t);
    }

    const SizedBox gap = SizedBox(width: ProductCompactLayout.gap);
    return Container(
      height: headerHeight,
      padding: const EdgeInsets.symmetric(horizontal: ProductCompactLayout.sidePadding),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: DsHairline.side(context, c.border)),
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final ProductCompactLayout w = ProductCompactLayout.of(context, box.maxWidth);
          return Row(
            children: <Widget>[
              if (w.full) ...<Widget>[cell(labels.sku, w.sku), gap],
              // «Наименование» — над названием (после миниатюры 40 + 8).
              const SizedBox(width: ProductCompactLayout.thumb + ProductCompactLayout.thumbGap),
              cell(labels.name, null),
              gap,
              cell(labels.stock, w.stock),
              gap,
              cell(labels.price, w.price, align: TextAlign.end),
              gap,
              cell(labels.action ?? '', w.action, visible: false),
            ],
          );
        },
      ),
    );
  }
}

/// Строка «Компакт» `ProductCardCompact` (03 §9.13; 02 ч. B §2.3): таблица (строка 50 + линия), строка 44 или
/// плитка ленты.
class ProductCardCompact extends StatelessWidget {
  /// Создаёт строку.
  const ProductCardCompact({
    super.key,
    required this.data,
    this.callbacks = const ProductCardCallbacks(),
    this.variant = ProductCardCompactVariant.table,
  });

  /// Высота плитки «Недавние товары» ([ProductCardCompactVariant.strip]): 64 при обычном размере текста, крупный текст —
  /// выше на прирост двух строк названия `caption` (16 + 16), зазора 2 и строки цены (≈ 17) — 51 lp при 1 (как лента
  /// кабинета `96 + scale(72) − 72`): 1,3 → ≈ 79. Строка цены не срезается.
  static double stripHeight(BuildContext context) => 64 + MediaQuery.textScalerOf(context).scale(51) - 51;

  /// Данные.
  final ProductCardData data;

  /// Колбэки.
  final ProductCardCallbacks callbacks;

  /// Вариант раскладки.
  final ProductCardCompactVariant variant;

  /// Высота строки таблицы без нижней линии: кнопка 34 + поля 8 (цель 44 — внутри строки).
  static const double tableRowHeight = 50;

  @override
  Widget build(BuildContext context) => switch (variant) {
    ProductCardCompactVariant.table => _table(context),
    ProductCardCompactVariant.row => _row(context),
    ProductCardCompactVariant.strip => _strip(context),
  };

  Widget _strip(BuildContext context) {
    final DsColors c = context.colors;
    return _CardShell(
      data: data,
      onOpen: callbacks.onOpen,
      radius: BorderRadius.zero,
      bordered: false,
      background: c.surface,
      builder: (BuildContext context, DsInteractionState s) => SizedBox(
        height: stripHeight(context),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.space.s2),
          child: Row(
            children: <Widget>[
              Opacity(
                opacity: data.dimmed ? 0.6 : 1,
                child: ProductImage(
                  url: data.thumbUrl ?? data.imageUrl,
                  size: ProductImageSize.thumb,
                  dimension: 40,
                  fit: BoxFit.cover,
                  showPlaceholderLabel: false,
                  borderRadius: BorderRadius.all(context.radii.sm),
                  semanticLabel: data.name,
                ),
              ),
              SizedBox(width: context.space.s2),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    // При крупном шрифте название уступает место строке цены (высота плитки фиксирована).
                    Flexible(
                      child: Text(
                        data.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.caption.copyWith(
                          color: data.dimmed ? c.textSecondary : c.textPrimary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    // Цена — раньше наличия и целиком (не делит строку с наличием поровну): своя ширина, уменьшение
                    // `FittedBox` — только защита, если цена шире всей строки; наличие — в остатке, с многоточием
                    // (02 UI-50-004…009 «Недавние товары»; указание владельца 2026-11-18 — [ВЫВОД исполнителя]).
                    LayoutBuilder(
                      builder: (BuildContext context, BoxConstraints box) => Row(
                        children: <Widget>[
                          ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: box.maxWidth),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: AlignmentDirectional.centerStart,
                              child: PriceText(
                                amount: data.price,
                                prefix: data.pricePrefix,
                                missingLabel: data.priceMissingLabel,
                                variant: PriceTextVariant.compact,
                                disabled: data.dimmed,
                                semanticLabel: data.semanticLabel,
                              ),
                            ),
                          ),
                          if (data.stockLevel != null) ...<Widget>[
                            SizedBox(width: context.space.s2),
                            Flexible(
                              child: StockBadge(
                                level: data.stockLevel!,
                                label: _bareNumber(data.stockLabel),
                                variant: StockBadgeVariant.inline,
                                semanticLabel: data.stockLabel,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Таблица (прототип, ADR-114): Артикул 120 (`body 14` `textSecondary`) · Наименование flex (`chip 14/600`
  /// `catalogName`, одна строка; миниатюра 40, число вариантов и звезда избранного — паритет функций) · Наличие 150
  /// (текст 13/500 цвета уровня) · Цена 150 справа (`compactPrice 14/800`, с единицей «/ шт» — паритет) · кнопка 132
  /// высотой 34 (цель 44). Поля 8/16, строка 50 + линия `rowDivider` 1, при наведении — `surfaceHover`. Узкая строка —
  /// без колонки «Артикул» (артикул — под названием), «Наличие» 120, «Цена» 130. Подписи строки, которых нет в
  /// прототипе («N вариантов», артикул узкой строки, «/ шт»), — `sku 12` `textSecondary` (цвет артикула прототипа):
  /// `catalogMeta` на фонах hover и pressed ниже 4.5:1 (CP-124, CP-125; ревью RC-07).
  Widget _table(BuildContext context) {
    final DsColors c = context.colors;
    final TextStyle skuStyle = context.text.body.copyWith(color: c.textSecondary);
    final TextStyle caption = context.text.sku.copyWith(color: c.textSecondary);
    return _CardShell(
      data: data,
      onOpen: callbacks.onOpen,
      radius: BorderRadius.zero,
      bordered: false,
      // Фон строки — у контейнера таблицы (скругление `md`); строка красит только hover/pressed.
      background: Colors.transparent,
      divider: true,
      dividerColor: c.rowDivider,
      builder: (BuildContext context, DsInteractionState s) => SizedBox(
        height: tableRowHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: ProductCompactLayout.sidePadding),
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints box) {
              final ProductCompactLayout w = ProductCompactLayout.of(context, box.maxWidth);
              final String? variants = data.variantsLabel;
              const SizedBox gap = SizedBox(width: ProductCompactLayout.gap);
              final Widget name = Row(
                children: <Widget>[
                  Expanded(
                    child: _Name(
                      data: data,
                      maxLines: 1,
                      style: context.text.chip.copyWith(color: c.catalogName),
                    ),
                  ),
                  if (variants != null) ...<Widget>[
                    SizedBox(width: context.space.s2),
                    Text(variants, maxLines: 1, style: caption),
                  ],
                ],
              );
              return Row(
                children: <Widget>[
                  if (w.full) ...<Widget>[
                    SizedBox(
                      width: w.sku,
                      child: Text(
                        data.skuMissing ? '—' : _bareSku(data),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: skuStyle,
                      ),
                    ),
                    gap,
                  ],
                  ProductImage(
                    url: data.thumbUrl ?? data.imageUrl,
                    size: ProductImageSize.thumb,
                    dimension: ProductCompactLayout.thumb,
                    fit: BoxFit.scaleDown,
                    background: Colors.transparent,
                    showPlaceholderLabel: false,
                    borderRadius: BorderRadius.zero,
                    plateRadius: BorderRadius.all(context.radii.sm),
                    semanticLabel: data.name,
                  ),
                  const SizedBox(width: ProductCompactLayout.thumbGap),
                  Expanded(
                    child: w.full
                        ? name
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              name,
                              Text(
                                data.skuMissing ? '—' : data.skuLabel,
                                key: const ValueKey<String>('product-compact-sku-line'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: caption,
                              ),
                            ],
                          ),
                  ),
                  // Звезда избранного — в строке таблицы (паритет функций ADR-112: прежняя колонка ☆), цвета звезды
                  // сетки (03 §9.23 ред. 1.18, ревью RV-17).
                  if (data.showFavorite)
                    FavoriteToggle(
                      selected: data.isFavorite,
                      onChanged: callbacks.onFavorite,
                      semanticLabel: data.favoriteLabel,
                      variant: FavoriteToggleVariant.catalogInline,
                    ),
                  gap,
                  SizedBox(
                    width: w.stock,
                    child: data.stockLevel == null
                        ? null
                        : Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: StockBadge(
                              level: data.stockLevel!,
                              label: data.stockLabel,
                              variant: StockBadgeVariant.text,
                              scaleToFit: true,
                              semanticLabel: <String>[data.stockLabel, ?data.stockAsOf].join(', '),
                            ),
                          ),
                  ),
                  gap,
                  SizedBox(
                    width: w.price,
                    child: Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerEnd,
                        child: PriceText(
                          amount: data.price,
                          // Единица «/ шт» (паритет функций ADR-112: прежняя колонка «Ед.») — `textSecondary` (RC-07).
                          unit: data.priceUnit,
                          prefix: data.pricePrefix,
                          missingLabel: data.priceMissingLabel,
                          variant: PriceTextVariant.compact,
                          unitStyle: caption,
                        ),
                      ),
                    ),
                  ),
                  gap,
                  SizedBox(
                    width: w.action,
                    child: _CardAction(data: data, onAction: callbacks.onAction, compact: true),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context) {
    final DsColors c = context.colors;
    final TextStyle caption = context.text.caption.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric);
    return _CardShell(
      data: data,
      onOpen: callbacks.onOpen,
      onLongPress: callbacks.onFavorite == null ? null : () => callbacks.onFavorite!(!data.isFavorite),
      radius: BorderRadius.zero,
      bordered: false,
      background: c.surface,
      divider: true,
      builder: (BuildContext context, DsInteractionState s) => SizedBox(
        height: 48,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.space.s2),
          child: Row(
            children: <Widget>[
              Opacity(
                opacity: data.dimmed ? 0.6 : 1,
                child: ProductImage(
                  url: data.thumbUrl ?? data.imageUrl,
                  size: ProductImageSize.thumb,
                  dimension: 32,
                  fit: BoxFit.cover,
                  showPlaceholderLabel: false,
                  borderRadius: BorderRadius.all(context.radii.sm),
                  semanticLabel: data.name,
                ),
              ),
              SizedBox(width: context.space.s2),
              SizedBox(
                width: 64,
                child: Text(
                  data.variantsLabel ?? (data.skuMissing ? '—' : _bareSku(data)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: caption,
                ),
              ),
              SizedBox(width: context.space.s2),
              Expanded(child: _Name(data: data, maxLines: 1)),
              SizedBox(width: context.space.s2),
              if (data.stockLevel != null)
                Flexible(
                  child: StockBadge(
                    level: data.stockLevel!,
                    label: _bareNumber(data.stockLabel),
                    variant: StockBadgeVariant.inline,
                    semanticLabel: data.stockLabel,
                  ),
                ),
              SizedBox(width: context.space.s2),
              Flexible(
                child: PriceText(
                  amount: data.price,
                  prefix: data.pricePrefix,
                  missingLabel: data.priceMissingLabel,
                  variant: PriceTextVariant.compact,
                  disabled: data.dimmed,
                  semanticLabel: data.semanticLabel,
                ),
              ),
              _InlineAction(data: data, onAction: callbacks.onAction),
            ],
          ),
        ),
      ),
    );
  }
}

/// Скелетон карточки текущего вида (UI-10-117, ANIM-013): геометрия — как у карточек (сетка — радиус 14, поля 10/12/12,
/// фото 150 и кнопка внизу ячейки; список medium+ — карточка 82; таблица — строка 50 + линия).
class ProductCardSkeleton extends StatelessWidget {
  /// Сетка.
  const ProductCardSkeleton.grid({super.key}) : _kind = 0;

  /// Строка списка.
  const ProductCardSkeleton.list({super.key}) : _kind = 1;

  /// Строка компакта.
  const ProductCardSkeleton.compact({super.key}) : _kind = 2;

  final int _kind;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool compactWindow = context.windowClass == WindowClass.compact;
    switch (_kind) {
      case 0:
        return Container(
          padding: _gridCardPadding,
          decoration: BoxDecoration(
            color: c.surface,
            border: DsHairline.all(context, c.border),
            borderRadius: BorderRadius.all(context.radii.catalogCard),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const SkeletonBox(height: kProductCardGridImageHeight),
              const SizedBox(height: 10),
              const SkeletonBox.text(),
              SizedBox(height: context.space.s2),
              const SkeletonBox.text(width: 96),
              SizedBox(height: context.space.s3),
              const SkeletonBox(width: 96, height: 18),
              const Spacer(),
              const SkeletonBox(height: 40),
            ],
          ),
        );
      case 1:
        if (compactWindow) {
          return Container(
            height: 72,
            padding: EdgeInsets.symmetric(horizontal: context.space.s3),
            decoration: BoxDecoration(
              color: c.surface,
              border: Border(bottom: BorderSide(color: c.border)),
            ),
            child: Row(
              children: <Widget>[
                const SkeletonBox(width: 48, height: 48),
                SizedBox(width: context.space.s3),
                const Expanded(child: SkeletonBox.text()),
                SizedBox(width: context.space.s4),
                const SkeletonBox(width: 80, height: 18),
              ],
            ),
          );
        }
        return Container(
          height: 82,
          padding: EdgeInsets.symmetric(horizontal: ProductCardList.padding.left),
          decoration: BoxDecoration(
            color: c.surface,
            border: DsHairline.all(context, c.border),
            borderRadius: BorderRadius.all(context.radii.md),
          ),
          child: const Row(
            children: <Widget>[
              SkeletonBox(width: 72, height: 60),
              SizedBox(width: ProductCardList.columnGap),
              Expanded(child: SkeletonBox.text()),
              SizedBox(width: ProductCardList.columnGap),
              SkeletonBox(width: 96, height: 18),
              SizedBox(width: ProductCardList.columnGap),
              SkeletonBox(width: 168, height: 40),
            ],
          ),
        );
      default:
        return Container(
          height: compactWindow ? 48 : ProductCardCompact.tableRowHeight + 1,
          padding: EdgeInsets.symmetric(
            horizontal: compactWindow ? context.space.s2 : ProductCompactLayout.sidePadding,
          ),
          decoration: BoxDecoration(
            color: c.surface,
            border: Border(bottom: DsHairline.side(context, compactWindow ? c.border : c.rowDivider)),
          ),
          child: Row(
            children: <Widget>[
              SkeletonBox(width: compactWindow ? 32 : 80, height: compactWindow ? 32 : 16),
              SizedBox(width: context.space.s3),
              const Expanded(child: SkeletonBox.text(height: 16)),
              SizedBox(width: context.space.s4),
              const SkeletonBox(width: 72, height: 16),
            ],
          ),
        );
    }
  }
}

String _bareSku(ProductCardData d) {
  // «Арт. F4252» → «F4252» для узкой колонки; если формат иной — как есть.
  final int space = d.skuLabel.indexOf(' ');
  return space > 0 && space < d.skuLabel.length - 1 ? d.skuLabel.substring(space + 1) : d.skuLabel;
}

String _bareNumber(String label) {
  // «В наличии · 24 шт» → «24 шт»; подпись без числа («В наличии», «Нет в наличии») остаётся целиком.
  final RegExpMatch? m = RegExp(r'\d[\d   ,]*\s*\S*$').firstMatch(label);
  return m == null ? label : m.group(0)!.trim();
}

/// Смена тени и фона карточки при наведении (прототип: 120 мс).
const Duration _hoverTransition = Duration(milliseconds: 120);

class _CardShell extends StatelessWidget {
  const _CardShell({
    required this.data,
    required this.onOpen,
    required this.builder,
    required this.radius,
    required this.bordered,
    required this.background,
    this.onLongPress,
    this.divider = false,
    this.dividerColor,
    this.hoverElevation = false,
  });

  final ProductCardData data;
  final VoidCallback? onOpen;
  final VoidCallback? onLongPress;
  final DsInteractiveBuilder builder;
  final BorderRadius radius;
  final bool bordered;
  final bool divider;

  /// Цвет нижней линии ([divider]); `null` — `border`.
  final Color? dividerColor;

  /// Тень `elevation.cardHover` при наведении и нажатии (прототип: `.card:hover`, отдельного `:active` нет) вместо фона
  /// `surfaceHover` / `surfacePressed`: фон карточки не меняется, и «Арт.», «/ шт» `catalogMeta` остаются на `surface`
  /// (CP-093; на фонах hover и pressed — ниже 4.5:1, CP-124, CP-125; ревью RC-07).
  final bool hoverElevation;
  final Color background;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Semantics(
      container: true,
      label: data.semanticLabel,
      child: DsInteractive(
        onTap: onOpen,
        onLongPress: onLongPress,
        builder: (BuildContext context, DsInteractionState s) {
          final Color bg = hoverElevation
              ? background
              : (s.pressed ? c.surfacePressed : (s.hovered ? c.surfaceHover : background));
          final bool lifted = hoverElevation && (s.hovered || s.pressed);
          final Widget box = AnimatedContainer(
            // Прототип: `transition: box-shadow 120ms ease`.
            duration: context.motion.of(_hoverTransition),
            curve: Curves.ease,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: radius,
              border: bordered
                  ? DsHairline.all(context, c.border)
                  : (divider ? Border(bottom: DsHairline.side(context, dividerColor ?? c.border)) : null),
              boxShadow: lifted ? context.elevation.cardHover : context.elevation.e0,
            ),
            child: builder(context, s),
          );
          return DsFocusRing(visible: s.focused, borderRadius: radius, child: box);
        },
      ),
    );
  }
}

/// Название с полным текстом в подсказке (INV-053): [style] (карточки каталога по прототипу — `catalogName`), иначе
/// `body 500` `textPrimary` (приглушённое — `textSecondary`, строки compact).
class _Name extends StatelessWidget {
  const _Name({required this.data, required this.maxLines, this.style});

  final ProductCardData data;
  final int maxLines;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return AppTooltip(
      message: data.name,
      waitDuration: const Duration(milliseconds: 700),
      child: Text(
        data.name,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: style ?? context.text.bodyMedium.copyWith(color: data.dimmed ? c.textSecondary : c.textPrimary),
      ),
    );
  }
}

class _SkuLine extends StatelessWidget {
  const _SkuLine({required this.data, this.withVariants = false, this.withUnit = false, this.maxLines = 2, this.style});

  final ProductCardData data;
  final bool withVariants;
  final bool withUnit;
  final int maxLines;

  /// Стиль карточек каталога по прототипу (`sku 12/400` `catalogMeta`, без tnum); `null` — `caption textSecondary`
  /// tnum (строки compact; кегль 12 — не `textTertiary`, DS-007).
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final List<String> parts = <String>[
      data.skuLabel,
      if (withVariants && data.variantsLabel != null) data.variantsLabel!,
      if (withUnit && data.unitLabel != null && data.unitLabel!.isNotEmpty) data.unitLabel!,
    ];
    return Text(
      parts.join(' · '),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style:
          style?.copyWith(color: context.colors.catalogMeta) ??
          context.text.caption.copyWith(color: context.colors.textSecondary, fontFeatures: DsTypography.numeric),
    );
  }
}

class _MatchBadge extends StatelessWidget {
  const _MatchBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Padding(
      padding: EdgeInsets.only(bottom: context.space.s1),
      child: Container(
        height: 20,
        padding: EdgeInsets.symmetric(horizontal: context.space.s2),
        decoration: BoxDecoration(color: c.surfaceVariant, borderRadius: BorderRadius.all(context.radii.full)),
        child: Text(label, maxLines: 1, style: context.text.captionMedium.copyWith(color: c.textSecondary)),
      ),
    );
  }
}

/// Кнопка карточки сетки во всю ширину (40 визуально, цель 48).
class _GridAction extends StatelessWidget {
  const _GridAction({required this.data, required this.onAction});

  final ProductCardData data;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => _CardAction(data: data, onAction: onAction);
}

/// Кнопка действия карточки по [ProductCardActionKind] (сетка, список medium+, таблица «Компакт»):
/// - `add` — `AppButton.primary` «+ Добавить»;
/// - `inCart` — `AppButton.tint` «В корзине · N — ещё +1» (таблица — «Ещё · N»), одна строка с уменьшением;
/// - `chooseVariant` — `AppButton.tonal` «Выбрать вариант ›» (шеврон — при ширине ≥ [narrowWidth]);
/// - `unavailable` — серая недоступная кнопка `disabledBg` с причиной `catalogMeta` (прототип, ADR-114);
/// - `hidden` — пустое место той же высоты (кнопки ряда на одной линии).
class _CardAction extends StatelessWidget {
  const _CardAction({required this.data, required this.onAction, this.compact = false});

  final ProductCardData data;
  final VoidCallback? onAction;

  /// Строка таблицы «Компакт»: 34 (цель 44), `chip 14` вес 700, короткая подпись.
  final bool compact;

  /// Уже этого кнопка «Выбрать вариант ›» без шеврона (карточка 176 lp; FIX-EF-13).
  static const double narrowWidth = 168;

  @override
  Widget build(BuildContext context) {
    final AppButtonSize size = compact ? AppButtonSize.cardCompact : AppButtonSize.card;
    final String label = (compact ? data.actionShortLabel : null) ?? data.actionLabel ?? '';
    return _BusyTapAbsorber(
      busy: data.actionBusy,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final bool narrow = compact || box.maxWidth < narrowWidth;
          return switch (data.action) {
            ProductCardActionKind.add => AppButton(
              label: label,
              onPressed: onAction,
              size: size,
              expand: true,
              fitLabel: true,
              loading: data.actionBusy,
            ),
            ProductCardActionKind.inCart => AppButton(
              label: label,
              onPressed: onAction,
              variant: AppButtonVariant.tint,
              size: size,
              expand: true,
              fitLabel: true,
              loading: data.actionBusy,
              semanticLabel: data.actionLabel,
            ),
            ProductCardActionKind.chooseVariant => AppButton(
              label: label,
              onPressed: onAction,
              variant: AppButtonVariant.tonal,
              size: size,
              trailingIcon: narrow ? null : Icons.chevron_right_rounded,
              expand: true,
              fitLabel: true,
            ),
            ProductCardActionKind.unavailable => _UnavailableAction(
              label: label,
              size: size,
              fullLabel: data.actionLabel,
            ),
            ProductCardActionKind.hidden => SizedBox(height: size.target),
          };
        },
      ),
    );
  }
}

/// Недоступное действие карточки (нет в наличии, нет цены, остаток неизвестен; прототип, ADR-114): серая кнопка
/// `disabledBg` радиус `control` 10, причина `chip 14` вес 700 `catalogMeta` (4,14:1 — недоступный элемент, WCAG 1.4.3)
/// — не нажимается, для screen reader — недоступная кнопка с причиной. Короткая подпись «Компакта» («Нет») — с полной
/// причиной [fullLabel] в тултипе и для экранного диктора.
class _UnavailableAction extends StatelessWidget {
  const _UnavailableAction({required this.label, required this.size, this.fullLabel});

  final String label;
  final AppButtonSize size;

  /// Полная причина, если [label] — короткая подпись.
  final String? fullLabel;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final TextStyle style = context.text.chip.copyWith(fontWeight: FontWeight.w700, color: c.catalogMeta);
    final String full = fullLabel ?? label;
    final Widget button = Semantics(
      button: true,
      enabled: false,
      label: full,
      excludeSemantics: true,
      child: SizedBox(
        width: double.infinity,
        height: size.target,
        child: Center(
          child: Container(
            key: const ValueKey<String>('product-card-unavailable'),
            height: size.height,
            padding: EdgeInsets.symmetric(horizontal: size.padding),
            decoration: BoxDecoration(color: c.disabledBg, borderRadius: BorderRadius.all(context.radii.control)),
            alignment: Alignment.center,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(label, maxLines: 1, textAlign: TextAlign.center, style: style),
            ),
          ),
        ),
      ),
    );
    return full == label ? button : AppTooltip(message: full, child: button);
  }
}

/// Пока добавление выполняется, нажатия по кнопке не уходят карточке (иначе повторный тап по кнопке в загрузке
/// открыл бы SCR-14): жест поглощается без действия.
class _BusyTapAbsorber extends StatelessWidget {
  const _BusyTapAbsorber({required this.busy, required this.child});

  final bool busy;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      GestureDetector(behavior: HitTestBehavior.opaque, onTap: busy ? () {} : null, child: child);
}

/// Кнопка-иконка строк compact («+», «›»).
class _InlineAction extends StatelessWidget {
  const _InlineAction({required this.data, required this.onAction});

  final ProductCardData data;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final String label = data.actionLabel ?? '';
    return _BusyTapAbsorber(busy: data.actionBusy, child: _button(label));
  }

  Widget _button(String label) {
    return switch (data.action) {
      ProductCardActionKind.add || ProductCardActionKind.inCart => AppIconButton(
        icon: Icons.add_rounded,
        semanticLabel: label,
        tooltip: label,
        onPressed: onAction,
        variant: AppIconButtonVariant.filled,
        loading: data.actionBusy,
      ),
      ProductCardActionKind.chooseVariant => AppIconButton(
        icon: Icons.chevron_right_rounded,
        semanticLabel: label,
        tooltip: label,
        onPressed: onAction,
        variant: AppIconButtonVariant.tonal,
      ),
      ProductCardActionKind.unavailable => AppIconButton(
        icon: Icons.add_rounded,
        semanticLabel: label,
        tooltip: label,
        onPressed: null,
        variant: AppIconButtonVariant.filled,
      ),
      ProductCardActionKind.hidden => const SizedBox.shrink(),
    };
  }
}
