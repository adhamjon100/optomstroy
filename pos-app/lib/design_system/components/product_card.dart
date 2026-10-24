import 'package:flutter/material.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/favorite_toggle.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/product_image.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/stock_badge.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Что показывать на месте контрола количества карточки (02 ч. B §2.3, шаги 1, 7, 8).
enum ProductCardActionKind {
  /// «+ Добавить» (сетка) / «+» (список, компакт).
  add,

  /// Товар с вариантами, в корзине его нет: «Выбрать вариант» → SCR-15 (INV-014).
  chooseVariant,

  /// Добавление недоступно: нет в наличии / нет цены / остаток неизвестен (INV-013, INV-023, INV-052);
  /// причина — [ProductCardData.actionLabel].
  unavailable,

  /// Нет права `cart.manage.own` (`owner`) — контрол скрыт.
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

  /// Краткая единица («шт») — колонка «Ед.» компакта.
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

  /// Подпись действия: «+ Добавить», «Выбрать вариант», причина недоступности.
  final String? actionLabel;

  /// Товар недоступен (нет в наличии): фото 60 %, текст `textSecondary`.
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

  /// Контрол количества («+ Добавить» / «Выбрать вариант»).
  final VoidCallback? onAction;
}

/// Высота тела карточки сетки без фото (название 2 строки, артикул, бейдж, цена, кнопка) —
/// для `SliverGridDelegate.mainAxisExtent`.
const double kProductCardGridBodyHeight = 236;

/// Карточка товара в сетке `ProductCardGrid` (03 §9.11; 02 SCR-10 D′).
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
    final double pad = context.space.s3;
    return _CardShell(
      data: data,
      onOpen: callbacks.onOpen,
      radius: BorderRadius.all(context.radii.md),
      bordered: true,
      builder: (BuildContext context, DsInteractionState s) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Stack(
            children: <Widget>[
              Opacity(
                opacity: data.dimmed ? 0.6 : 1,
                child: ProductImage(
                  url: data.imageUrl,
                  size: ProductImageSize.card,
                  fit: BoxFit.cover,
                  borderRadius: BorderRadius.vertical(top: context.radii.md),
                  semanticLabel: data.name,
                ),
              ),
              if (data.showFavorite)
                PositionedDirectional(
                  top: 0,
                  end: 0,
                  child: FavoriteToggle(
                    selected: data.isFavorite,
                    onChanged: callbacks.onFavorite,
                    semanticLabel: data.favoriteLabel,
                    variant: FavoriteToggleVariant.onImage,
                  ),
                ),
            ],
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(pad, pad, pad, pad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // Верх (бейдж совпадения, название, артикул) сжимается первым — нижние контролы
                  // (остаток, цена, кнопка) всегда видны при фиксированной высоте ячейки сетки.
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        if (data.matchLabel != null) _MatchBadge(label: data.matchLabel!),
                        Flexible(child: _Name(data: data, maxLines: 2)),
                        SizedBox(height: context.space.s1),
                        _SkuLine(data: data, withVariants: true, maxLines: 1),
                      ],
                    ),
                  ),
                  if (data.stockLevel != null)
                    StockBadge(level: data.stockLevel!, label: data.stockLabel, asOf: data.stockAsOf, scaleToFit: true),
                  SizedBox(height: context.space.s2),
                  // «от 1 650 сом / шт» в карточке 160 lp: масштаб вниз вместо обрезки единицы (AC-UI-10-005).
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: AlignmentDirectional.centerStart,
                    child: PriceText(
                      amount: data.price,
                      unit: data.priceUnit,
                      prefix: data.pricePrefix,
                      missingLabel: data.priceMissingLabel,
                      disabled: data.dimmed,
                    ),
                  ),
                  SizedBox(height: context.space.s3),
                  _GridAction(data: data, onAction: callbacks.onAction),
                ],
              ),
            ),
          ),
        ],
      ),
      hoverElevation: true,
      background: c.surface,
    );
  }
}

/// Строка товара `ProductCardList` (03 §9.12): фото 56 (compact) / 48, название, «Арт. · шт»,
/// `StockBadge.inline`, цена справа, звезда, «+».
class ProductCardList extends StatelessWidget {
  /// Создаёт строку.
  const ProductCardList({super.key, required this.data, this.callbacks = const ProductCardCallbacks()});

  /// Данные.
  final ProductCardData data;

  /// Колбэки.
  final ProductCardCallbacks callbacks;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool compactWindow = context.windowClass == WindowClass.compact;
    final double photo = compactWindow ? 56 : 48;
    return _CardShell(
      data: data,
      onOpen: callbacks.onOpen,
      radius: BorderRadius.zero,
      bordered: false,
      background: c.surface,
      divider: true,
      builder: (BuildContext context, DsInteractionState s) => ConstrainedBox(
        constraints: BoxConstraints(minHeight: compactWindow ? 72 : 64),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.space.s3, vertical: context.space.s2),
          child: Row(
            children: <Widget>[
              Opacity(
                opacity: data.dimmed ? 0.6 : 1,
                child: ProductImage(
                  url: data.thumbUrl ?? data.imageUrl,
                  size: ProductImageSize.thumb,
                  dimension: photo,
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
              if (compactWindow)
                // compact: цена и кнопки — в правом столбце (03 §9.12).
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    PriceText(
                      amount: data.price,
                      unit: data.priceUnit,
                      prefix: data.pricePrefix,
                      missingLabel: data.priceMissingLabel,
                      variant: PriceTextVariant.list,
                      disabled: data.dimmed,
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (data.showFavorite)
                          FavoriteToggle(
                            selected: data.isFavorite,
                            onChanged: callbacks.onFavorite,
                            semanticLabel: data.favoriteLabel,
                          ),
                        _InlineAction(data: data, onAction: callbacks.onAction),
                      ],
                    ),
                  ],
                )
              else ...<Widget>[
                PriceText(
                  amount: data.price,
                  unit: data.priceUnit,
                  prefix: data.pricePrefix,
                  missingLabel: data.priceMissingLabel,
                  variant: PriceTextVariant.list,
                  disabled: data.dimmed,
                ),
                if (data.showFavorite)
                  FavoriteToggle(
                    selected: data.isFavorite,
                    onChanged: callbacks.onFavorite,
                    semanticLabel: data.favoriteLabel,
                  ),
                _InlineAction(data: data, onAction: callbacks.onAction),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Вариант `ProductCardCompact` (03 §9.13).
enum ProductCardCompactVariant {
  /// Таблица 48 lp (expanded/large, medium ≥ 840).
  table,

  /// Однострочная строка 44 lp (compact, medium < 840).
  row,

  /// Плитка ленты 64 lp (SCR-50 «Недавние товары» на compact, UI-50-010): миниатюра 40, название в 2 строки,
  /// под ним цена и статус наличия — без обрезки при ширине плитки 280 (FIX-EF-13).
  strip,
}

/// Ширины колонок таблицы «Компакт» (02 UI-10-118): Фото 48 · Артикул 96 · Наименование flex ·
/// Вар. 80 · Доступно 96 · Ед. 56 · Цена 112 · Кол-во 120 · ☆ 40.
abstract final class ProductCompactColumns {
  /// Фото.
  static const double photo = 48;

  /// Артикул.
  static const double sku = 96;

  /// Варианты.
  static const double variants = 80;

  /// Доступно.
  static const double stock = 96;

  /// Единица.
  static const double unit = 56;

  /// Цена.
  static const double price = 112; // money-double: allow — ширина колонки в lp, не деньги

  /// Количество.
  static const double qty = 120; // money-double: allow — ширина колонки в lp, не деньги

  /// Избранное.
  static const double favorite = 48;
}

/// Подписи заголовка таблицы «Компакт».
@immutable
class ProductCompactHeaderLabels {
  /// Создаёт подписи.
  const ProductCompactHeaderLabels({
    required this.photo,
    required this.sku,
    required this.name,
    required this.variants,
    required this.stock,
    required this.unit,
    required this.price,
    required this.qty,
    required this.favorite,
  });

  /// «Фото» (только `Semantics`).
  final String photo;

  /// «Артикул».
  final String sku;

  /// «Наименование».
  final String name;

  /// «Вар.».
  final String variants;

  /// «Доступно».
  final String stock;

  /// «Ед.».
  final String unit;

  /// «Цена».
  final String price;

  /// «Кол-во».
  final String qty;

  /// «Избранное» (только `Semantics`).
  final String favorite;
}

/// Заголовок таблицы «Компакт» 40 lp `surfaceVariant` (UI-10-118); закрепляется вызывающим.
class ProductCardCompactHeader extends StatelessWidget {
  /// Создаёт заголовок.
  const ProductCardCompactHeader({super.key, required this.labels});

  /// Подписи.
  final ProductCompactHeaderLabels labels;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final TextStyle style = context.text.label.copyWith(fontWeight: FontWeight.w500, color: c.textSecondary);
    Widget cell(String text, double? width, {TextAlign align = TextAlign.start, bool visible = true}) {
      final Widget t = Semantics(
        header: true,
        label: text,
        excludeSemantics: true,
        child: Text(visible ? text : '', maxLines: 1, overflow: TextOverflow.ellipsis, style: style, textAlign: align),
      );
      return width == null ? Expanded(child: t) : SizedBox(width: width, child: t);
    }

    return Container(
      height: 40,
      color: c.surfaceVariant,
      padding: EdgeInsets.symmetric(horizontal: context.space.s2),
      child: Row(
        children: <Widget>[
          cell(labels.photo, ProductCompactColumns.photo, visible: false),
          cell(labels.sku, ProductCompactColumns.sku),
          cell(labels.name, null),
          cell(labels.variants, ProductCompactColumns.variants),
          cell(labels.stock, ProductCompactColumns.stock),
          cell(labels.unit, ProductCompactColumns.unit),
          cell(labels.price, ProductCompactColumns.price, align: TextAlign.end),
          cell(labels.qty, ProductCompactColumns.qty, align: TextAlign.center),
          cell(labels.favorite, ProductCompactColumns.favorite, visible: false),
        ],
      ),
    );
  }
}

/// Строка «Компакт» `ProductCardCompact` (03 §9.13; 02 ч. B §2.3): таблица 48 или строка 44.
class ProductCardCompact extends StatelessWidget {
  /// Создаёт строку.
  const ProductCardCompact({
    super.key,
    required this.data,
    this.callbacks = const ProductCardCallbacks(),
    this.variant = ProductCardCompactVariant.table,
  });

  /// Данные.
  final ProductCardData data;

  /// Колбэки.
  final ProductCardCallbacks callbacks;

  /// Вариант раскладки.
  final ProductCardCompactVariant variant;

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
        height: 64,
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
                    Row(
                      children: <Widget>[
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
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stock(BuildContext context) => data.stockLevel == null
      ? const SizedBox.shrink()
      : StockBadge(
          level: data.stockLevel!,
          // Колонка «Доступно» 96 lp (02 UI-10-118): число с единицей; статус без числа — целиком.
          label: _bareNumber(data.stockLabel),
          asOf: null,
          variant: StockBadgeVariant.inline,
          semanticLabel: <String>[data.stockLabel, ?data.stockAsOf].join(', '),
        );

  Widget _table(BuildContext context) {
    final DsColors c = context.colors;
    final TextStyle caption = context.text.body.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric);
    return _CardShell(
      data: data,
      onOpen: callbacks.onOpen,
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
              SizedBox(
                width: ProductCompactColumns.photo,
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Opacity(
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
                ),
              ),
              SizedBox(
                width: ProductCompactColumns.sku,
                child: Text(
                  data.skuMissing ? '—' : _bareSku(data),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: caption,
                ),
              ),
              Expanded(child: _Name(data: data, maxLines: 1)),
              SizedBox(
                width: ProductCompactColumns.variants,
                child: Text(data.variantsLabel ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: caption),
              ),
              SizedBox(width: ProductCompactColumns.stock, child: _stock(context)),
              SizedBox(
                width: ProductCompactColumns.unit,
                child: Text(data.unitLabel ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: caption),
              ),
              SizedBox(
                width: ProductCompactColumns.price,
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: PriceText(
                    amount: data.price,
                    prefix: data.pricePrefix,
                    missingLabel: data.priceMissingLabel,
                    variant: PriceTextVariant.compact,
                    disabled: data.dimmed,
                  ),
                ),
              ),
              SizedBox(
                width: ProductCompactColumns.qty,
                child: Center(
                  child: _InlineAction(data: data, onAction: callbacks.onAction),
                ),
              ),
              SizedBox(
                width: ProductCompactColumns.favorite,
                child: data.showFavorite
                    ? FavoriteToggle(
                        selected: data.isFavorite,
                        onChanged: callbacks.onFavorite,
                        semanticLabel: data.favoriteLabel,
                      )
                    : null,
              ),
            ],
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

/// Скелетон карточки текущего вида (UI-10-117, ANIM-013).
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
    switch (_kind) {
      case 0:
        return Container(
          decoration: BoxDecoration(
            color: c.surface,
            border: Border.all(color: c.border),
            borderRadius: BorderRadius.all(context.radii.md),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const AspectRatio(aspectRatio: 1, child: SkeletonBox(radius: Radius.zero, height: null)),
              Padding(
                padding: EdgeInsets.all(context.space.s3),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const SkeletonBox.text(),
                    SizedBox(height: context.space.s2),
                    const SkeletonBox.text(width: 96),
                    SizedBox(height: context.space.s3),
                    const SkeletonBox(width: 80, height: 18),
                    SizedBox(height: context.space.s3),
                    const SkeletonBox(height: 44),
                  ],
                ),
              ),
            ],
          ),
        );
      case 1:
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
      default:
        return Container(
          height: 48,
          padding: EdgeInsets.symmetric(horizontal: context.space.s2),
          decoration: BoxDecoration(
            color: c.surface,
            border: Border(bottom: BorderSide(color: c.border)),
          ),
          child: Row(
            children: <Widget>[
              const SkeletonBox(width: 32, height: 32),
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
  final RegExpMatch? m = RegExp(r'\d[\d   ,]*\s*\S*$').firstMatch(label);
  return m == null ? label : m.group(0)!.trim();
}

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
    this.hoverElevation = false,
  });

  final ProductCardData data;
  final VoidCallback? onOpen;
  final VoidCallback? onLongPress;
  final DsInteractiveBuilder builder;
  final BorderRadius radius;
  final bool bordered;
  final bool divider;
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
          final Color bg = s.pressed ? c.surfacePressed : (s.hovered && !hoverElevation ? c.surfaceHover : background);
          final Widget box = AnimatedContainer(
            duration: context.motion.of(context.motion.fast),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: radius,
              border: bordered
                  ? Border.all(color: c.border)
                  : (divider ? Border(bottom: BorderSide(color: c.border)) : null),
              boxShadow: hoverElevation && s.hovered ? context.elevation.e1 : context.elevation.e0,
            ),
            child: builder(context, s),
          );
          return DsFocusRing(visible: s.focused, borderRadius: radius, child: box);
        },
      ),
    );
  }
}

class _Name extends StatelessWidget {
  const _Name({required this.data, required this.maxLines});

  final ProductCardData data;
  final int maxLines;

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
        style: context.text.bodyMedium.copyWith(color: data.dimmed ? c.textSecondary : c.textPrimary),
      ),
    );
  }
}

class _SkuLine extends StatelessWidget {
  const _SkuLine({required this.data, this.withVariants = false, this.withUnit = false, this.maxLines = 2});

  final ProductCardData data;
  final bool withVariants;
  final bool withUnit;
  final int maxLines;

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
      style: context.text.caption.copyWith(color: context.colors.textSecondary, fontFeatures: DsTypography.numeric),
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

class _GridAction extends StatelessWidget {
  const _GridAction({required this.data, required this.onAction});

  final ProductCardData data;
  final VoidCallback? onAction;

  /// Уже этого кнопка «Выбрать вариант ›» без шеврона (карточка 160 lp, 03 §7.3; FIX-EF-13).
  static const double narrowWidth = 168;

  @override
  Widget build(BuildContext context) {
    final String label = data.actionLabel ?? '';
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final bool narrow = box.maxWidth < narrowWidth;
        return switch (data.action) {
          ProductCardActionKind.add => AppButton(label: label, onPressed: onAction, expand: true, fitLabel: true),
          ProductCardActionKind.chooseVariant => AppButton(
            label: label,
            onPressed: onAction,
            variant: AppButtonVariant.tonal,
            trailingIcon: narrow ? null : Icons.chevron_right_rounded,
            expand: true,
            fitLabel: true,
          ),
          ProductCardActionKind.unavailable => AppButton(label: label, onPressed: null, expand: true, fitLabel: true),
          ProductCardActionKind.hidden => const SizedBox(height: 44),
        };
      },
    );
  }
}

class _InlineAction extends StatelessWidget {
  const _InlineAction({required this.data, required this.onAction});

  final ProductCardData data;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final String label = data.actionLabel ?? '';
    return switch (data.action) {
      ProductCardActionKind.add => AppIconButton(
        icon: Icons.add_rounded,
        semanticLabel: label,
        tooltip: label,
        onPressed: onAction,
        variant: AppIconButtonVariant.filled,
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
