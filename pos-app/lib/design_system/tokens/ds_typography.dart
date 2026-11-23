// GENERATED CODE - DO NOT EDIT BY HAND.
// Generator: scripts/gen_tokens_dart.py (RM-B-006)
// Source: contracts/design-tokens/tokens.json (canonical sha256 3ebfbea11ac1b07857647df0f051bfc81a9e8913262e3229e90dfa6e4dc40544)
// DsTypography - ds.text.* (03 §6.2, §17.3); component styles ADR-114
// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';

/// Text scale `ds.text.*` (font family Inter, D-17). Sizes in logical pixels.
///
/// Component styles (`text.component`, ADR-114) are the prototype values without rounding to the
/// scale, for the goods selection screen SCR-10/11/12, the staff header and the cart drawer. Weight 800
/// is the static Inter-ExtraBold.ttf instanced from the bundled Inter-Variable.ttf.
@immutable
class DsTypography extends ThemeExtension<DsTypography> {
  const DsTypography({
    required this.display,
    required this.h1,
    required this.h2,
    required this.h3,
    required this.title,
    required this.bodyLg,
    required this.body,
    required this.label,
    required this.caption,
    required this.micro,
    required this.avatarInitial,
    required this.bellBadge,
    required this.brandWordmark,
    required this.cardName,
    required this.cartBadge,
    required this.cartTotal,
    required this.catalogPrice,
    required this.catalogTitle,
    required this.chip,
    required this.columnTitle,
    required this.compactPrice,
    required this.drawerTitle,
    required this.lineSum,
    required this.listName,
    required this.listPrice,
    required this.meta,
    required this.ribbonLabel,
    required this.sku,
    required this.sortLabel,
    required this.stock,
    required this.tileLabel,
    required this.totalLabel,
  });

  /// 32/40/700, letter-spacing -0.2; contrast class: large.
  final TextStyle display;

  /// 28/36/700, letter-spacing -0.2; contrast class: large.
  final TextStyle h1;

  /// 24/32/600, letter-spacing -0.2; contrast class: large.
  final TextStyle h2;

  /// 20/28/600, letter-spacing 0; contrast class: normal.
  final TextStyle h3;

  /// 18/26/600, letter-spacing 0; contrast class: normal.
  final TextStyle title;

  /// 16/24/400, letter-spacing 0; contrast class: normal.
  final TextStyle bodyLg;

  /// 14/20/400, letter-spacing 0; contrast class: normal.
  final TextStyle body;

  /// 13/18/500, letter-spacing 0; contrast class: normal.
  final TextStyle label;

  /// 12/16/400, letter-spacing 0; contrast class: normal.
  final TextStyle caption;

  /// 11/14/600, letter-spacing 0; contrast class: normal.
  final TextStyle micro;

  /// ADR-114: 15/700, line height 19 lp, letter-spacing 0 - буква аватара в шапке.
  final TextStyle avatarInitial;

  /// ADR-114: 10/700, line height 17 lp, letter-spacing 0 - бейдж колокола уведомлений (круг 17); 10 lp — отклонение от
  /// A11Y-008 (минимум 11), ADR-114.
  final TextStyle bellBadge;

  /// ADR-114: 21/700, height 1.21, letter-spacing -0.2 - надпись «Оптомстрой» в шапке сотрудника.
  final TextStyle brandWordmark;

  /// ADR-114: 14/600, height 1.32, letter-spacing 0 - название товара в карточке сетки (2 строки, min-height 37).
  final TextStyle cardName;

  /// ADR-114: 11/700, line height 18 lp, letter-spacing 0 - бейдж числа позиций на кнопке корзины (круг 18).
  final TextStyle cartBadge;

  /// ADR-114: 24/800, height 1.21, letter-spacing 0 - сумма «Итого» в подвале корзины.
  final TextStyle cartTotal;

  /// ADR-114: 18/800, line height 21 lp, letter-spacing -0.2 - цена в карточке сетки.
  final TextStyle catalogPrice;

  /// ADR-114: 30/800, height 1.21, letter-spacing -0.4 - H1 экрана выбора товаров (имя категории, «Поиск: «…»»).
  final TextStyle catalogTitle;

  /// ADR-114: 14/600, height 1.21, letter-spacing 0 - чипы «Новые / Избранные / Фильтры», кнопки сегмента.
  final TextStyle chip;

  /// ADR-114: 19/700, height 1.21, letter-spacing 0 - заголовок колонки «Каталог» (блок 23).
  final TextStyle columnTitle;

  /// ADR-114: 14/800, height 1.21, letter-spacing 0 - цена в компакт-таблице.
  final TextStyle compactPrice;

  /// ADR-114: 20/800, height 1.21, letter-spacing 0 - «Корзина» в шапке drawer.
  final TextStyle drawerTitle;

  /// ADR-114: 15/800, line height 19 lp, letter-spacing 0 - сумма строки корзины.
  final TextStyle lineSum;

  /// ADR-114: 15/600, line height 19 lp, letter-spacing 0 - название товара в строке списка.
  final TextStyle listName;

  /// ADR-114: 17/800, line height 20 lp, letter-spacing 0 - цена в строке списка.
  final TextStyle listPrice;

  /// ADR-114: 13/400, height 1.21, letter-spacing 0 - «/ шт», «Найдено: N товаров».
  final TextStyle meta;

  /// ADR-114: 13/500, selected 700, height 1.2, letter-spacing 0 - подпись карточки ленты подкатегорий (2 строки,
  /// min-height 31).
  final TextStyle ribbonLabel;

  /// ADR-114: 12/400, height 1.21, letter-spacing 0 - «Арт. X», роль в шапке, примечание корзины.
  final TextStyle sku;

  /// ADR-114: 14/500, height 1.21, letter-spacing 0 - кнопка сортировки.
  final TextStyle sortLabel;

  /// ADR-114: 12.5/500, height 1.21, letter-spacing 0 - строка наличия в карточке сетки (в списке и компакте — 13/500).
  final TextStyle stock;

  /// ADR-114: 12/600, selected 700, height 1.2, letter-spacing 0 - подпись плитки корневой категории в колонке.
  final TextStyle tileLabel;

  /// ADR-114: 18/800, line height 21 lp, letter-spacing 0 - «Итого» в подвале корзины.
  final TextStyle totalLabel;

  /// Tabular figures for prices, stock, quantities, codes, OTP timers (03 §6.1).
  static const List<FontFeature> numeric = <FontFeature>[FontFeature.tabularFigures()];

  static const String fontFamily = 'Inter';

  /// Scale of 03 §6.2 and the component styles of ADR-114 with the Inter family.
  static const DsTypography inter = DsTypography(
    display: TextStyle(
      fontFamily: fontFamily,
      fontSize: 32,
      height: 40 / 32,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
    ),
    h1: TextStyle(
      fontFamily: fontFamily,
      fontSize: 28,
      height: 36 / 28,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
    ),
    h2: TextStyle(
      fontFamily: fontFamily,
      fontSize: 24,
      height: 32 / 24,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.2,
    ),
    h3: TextStyle(fontFamily: fontFamily, fontSize: 20, height: 28 / 20, fontWeight: FontWeight.w600, letterSpacing: 0),
    title: TextStyle(
      fontFamily: fontFamily,
      fontSize: 18,
      height: 26 / 18,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
    bodyLg: TextStyle(
      fontFamily: fontFamily,
      fontSize: 16,
      height: 24 / 16,
      fontWeight: FontWeight.w400,
      letterSpacing: 0,
    ),
    body: TextStyle(
      fontFamily: fontFamily,
      fontSize: 14,
      height: 20 / 14,
      fontWeight: FontWeight.w400,
      letterSpacing: 0,
    ),
    label: TextStyle(
      fontFamily: fontFamily,
      fontSize: 13,
      height: 18 / 13,
      fontWeight: FontWeight.w500,
      letterSpacing: 0,
    ),
    caption: TextStyle(
      fontFamily: fontFamily,
      fontSize: 12,
      height: 16 / 12,
      fontWeight: FontWeight.w400,
      letterSpacing: 0,
    ),
    micro: TextStyle(
      fontFamily: fontFamily,
      fontSize: 11,
      height: 14 / 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
    avatarInitial: TextStyle(
      fontFamily: fontFamily,
      fontSize: 15,
      height: 19 / 15,
      fontWeight: FontWeight.w700,
      letterSpacing: 0,
    ),
    bellBadge: TextStyle(
      fontFamily: fontFamily,
      fontSize: 10,
      height: 17 / 10,
      fontWeight: FontWeight.w700,
      letterSpacing: 0,
    ),
    brandWordmark: TextStyle(
      fontFamily: fontFamily,
      fontSize: 21,
      height: 1.21,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
    ),
    cardName: TextStyle(
      fontFamily: fontFamily,
      fontSize: 14,
      height: 1.32,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
    cartBadge: TextStyle(
      fontFamily: fontFamily,
      fontSize: 11,
      height: 18 / 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 0,
    ),
    cartTotal: TextStyle(
      fontFamily: fontFamily,
      fontSize: 24,
      height: 1.21,
      fontWeight: FontWeight.w800,
      letterSpacing: 0,
    ),
    catalogPrice: TextStyle(
      fontFamily: fontFamily,
      fontSize: 18,
      height: 21 / 18,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.2,
    ),
    catalogTitle: TextStyle(
      fontFamily: fontFamily,
      fontSize: 30,
      height: 1.21,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.4,
    ),
    chip: TextStyle(fontFamily: fontFamily, fontSize: 14, height: 1.21, fontWeight: FontWeight.w600, letterSpacing: 0),
    columnTitle: TextStyle(
      fontFamily: fontFamily,
      fontSize: 19,
      height: 1.21,
      fontWeight: FontWeight.w700,
      letterSpacing: 0,
    ),
    compactPrice: TextStyle(
      fontFamily: fontFamily,
      fontSize: 14,
      height: 1.21,
      fontWeight: FontWeight.w800,
      letterSpacing: 0,
    ),
    drawerTitle: TextStyle(
      fontFamily: fontFamily,
      fontSize: 20,
      height: 1.21,
      fontWeight: FontWeight.w800,
      letterSpacing: 0,
    ),
    lineSum: TextStyle(
      fontFamily: fontFamily,
      fontSize: 15,
      height: 19 / 15,
      fontWeight: FontWeight.w800,
      letterSpacing: 0,
    ),
    listName: TextStyle(
      fontFamily: fontFamily,
      fontSize: 15,
      height: 19 / 15,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
    listPrice: TextStyle(
      fontFamily: fontFamily,
      fontSize: 17,
      height: 20 / 17,
      fontWeight: FontWeight.w800,
      letterSpacing: 0,
    ),
    meta: TextStyle(fontFamily: fontFamily, fontSize: 13, height: 1.21, fontWeight: FontWeight.w400, letterSpacing: 0),
    ribbonLabel: TextStyle(
      fontFamily: fontFamily,
      fontSize: 13,
      height: 1.2,
      fontWeight: FontWeight.w500,
      letterSpacing: 0,
    ),
    sku: TextStyle(fontFamily: fontFamily, fontSize: 12, height: 1.21, fontWeight: FontWeight.w400, letterSpacing: 0),
    sortLabel: TextStyle(
      fontFamily: fontFamily,
      fontSize: 14,
      height: 1.21,
      fontWeight: FontWeight.w500,
      letterSpacing: 0,
    ),
    stock: TextStyle(
      fontFamily: fontFamily,
      fontSize: 12.5,
      height: 1.21,
      fontWeight: FontWeight.w500,
      letterSpacing: 0,
    ),
    tileLabel: TextStyle(
      fontFamily: fontFamily,
      fontSize: 12,
      height: 1.2,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
    totalLabel: TextStyle(
      fontFamily: fontFamily,
      fontSize: 18,
      height: 21 / 18,
      fontWeight: FontWeight.w800,
      letterSpacing: 0,
    ),
  );

  /// `bodyLg` with weight 500.
  TextStyle get bodyLgMedium => bodyLg.copyWith(fontWeight: FontWeight.w500);

  /// `body` with weight 500.
  TextStyle get bodyMedium => body.copyWith(fontWeight: FontWeight.w500);

  /// `caption` with weight 500.
  TextStyle get captionMedium => caption.copyWith(fontWeight: FontWeight.w500);

  /// `ribbonLabel` in the selected state: weight 700 (ADR-114).
  TextStyle get ribbonLabelSelected => ribbonLabel.copyWith(fontWeight: FontWeight.w700);

  /// `tileLabel` in the selected state: weight 700 (ADR-114).
  TextStyle get tileLabelSelected => tileLabel.copyWith(fontWeight: FontWeight.w700);

  /// Price: bodyLg/700 + tabular figures.
  TextStyle get price => priceOf(bodyLg);

  /// Any scale step as a price: weight and tabular figures (03 §6.2 rules).
  TextStyle priceOf(TextStyle base) => base.copyWith(fontWeight: FontWeight.w700, fontFeatures: numeric);

  @override
  DsTypography copyWith({
    TextStyle? display,
    TextStyle? h1,
    TextStyle? h2,
    TextStyle? h3,
    TextStyle? title,
    TextStyle? bodyLg,
    TextStyle? body,
    TextStyle? label,
    TextStyle? caption,
    TextStyle? micro,
    TextStyle? avatarInitial,
    TextStyle? bellBadge,
    TextStyle? brandWordmark,
    TextStyle? cardName,
    TextStyle? cartBadge,
    TextStyle? cartTotal,
    TextStyle? catalogPrice,
    TextStyle? catalogTitle,
    TextStyle? chip,
    TextStyle? columnTitle,
    TextStyle? compactPrice,
    TextStyle? drawerTitle,
    TextStyle? lineSum,
    TextStyle? listName,
    TextStyle? listPrice,
    TextStyle? meta,
    TextStyle? ribbonLabel,
    TextStyle? sku,
    TextStyle? sortLabel,
    TextStyle? stock,
    TextStyle? tileLabel,
    TextStyle? totalLabel,
  }) {
    return DsTypography(
      display: display ?? this.display,
      h1: h1 ?? this.h1,
      h2: h2 ?? this.h2,
      h3: h3 ?? this.h3,
      title: title ?? this.title,
      bodyLg: bodyLg ?? this.bodyLg,
      body: body ?? this.body,
      label: label ?? this.label,
      caption: caption ?? this.caption,
      micro: micro ?? this.micro,
      avatarInitial: avatarInitial ?? this.avatarInitial,
      bellBadge: bellBadge ?? this.bellBadge,
      brandWordmark: brandWordmark ?? this.brandWordmark,
      cardName: cardName ?? this.cardName,
      cartBadge: cartBadge ?? this.cartBadge,
      cartTotal: cartTotal ?? this.cartTotal,
      catalogPrice: catalogPrice ?? this.catalogPrice,
      catalogTitle: catalogTitle ?? this.catalogTitle,
      chip: chip ?? this.chip,
      columnTitle: columnTitle ?? this.columnTitle,
      compactPrice: compactPrice ?? this.compactPrice,
      drawerTitle: drawerTitle ?? this.drawerTitle,
      lineSum: lineSum ?? this.lineSum,
      listName: listName ?? this.listName,
      listPrice: listPrice ?? this.listPrice,
      meta: meta ?? this.meta,
      ribbonLabel: ribbonLabel ?? this.ribbonLabel,
      sku: sku ?? this.sku,
      sortLabel: sortLabel ?? this.sortLabel,
      stock: stock ?? this.stock,
      tileLabel: tileLabel ?? this.tileLabel,
      totalLabel: totalLabel ?? this.totalLabel,
    );
  }

  @override
  DsTypography lerp(DsTypography? other, double t) {
    if (other == null) {
      return this;
    }
    return DsTypography(
      display: TextStyle.lerp(display, other.display, t)!,
      h1: TextStyle.lerp(h1, other.h1, t)!,
      h2: TextStyle.lerp(h2, other.h2, t)!,
      h3: TextStyle.lerp(h3, other.h3, t)!,
      title: TextStyle.lerp(title, other.title, t)!,
      bodyLg: TextStyle.lerp(bodyLg, other.bodyLg, t)!,
      body: TextStyle.lerp(body, other.body, t)!,
      label: TextStyle.lerp(label, other.label, t)!,
      caption: TextStyle.lerp(caption, other.caption, t)!,
      micro: TextStyle.lerp(micro, other.micro, t)!,
      avatarInitial: TextStyle.lerp(avatarInitial, other.avatarInitial, t)!,
      bellBadge: TextStyle.lerp(bellBadge, other.bellBadge, t)!,
      brandWordmark: TextStyle.lerp(brandWordmark, other.brandWordmark, t)!,
      cardName: TextStyle.lerp(cardName, other.cardName, t)!,
      cartBadge: TextStyle.lerp(cartBadge, other.cartBadge, t)!,
      cartTotal: TextStyle.lerp(cartTotal, other.cartTotal, t)!,
      catalogPrice: TextStyle.lerp(catalogPrice, other.catalogPrice, t)!,
      catalogTitle: TextStyle.lerp(catalogTitle, other.catalogTitle, t)!,
      chip: TextStyle.lerp(chip, other.chip, t)!,
      columnTitle: TextStyle.lerp(columnTitle, other.columnTitle, t)!,
      compactPrice: TextStyle.lerp(compactPrice, other.compactPrice, t)!,
      drawerTitle: TextStyle.lerp(drawerTitle, other.drawerTitle, t)!,
      lineSum: TextStyle.lerp(lineSum, other.lineSum, t)!,
      listName: TextStyle.lerp(listName, other.listName, t)!,
      listPrice: TextStyle.lerp(listPrice, other.listPrice, t)!,
      meta: TextStyle.lerp(meta, other.meta, t)!,
      ribbonLabel: TextStyle.lerp(ribbonLabel, other.ribbonLabel, t)!,
      sku: TextStyle.lerp(sku, other.sku, t)!,
      sortLabel: TextStyle.lerp(sortLabel, other.sortLabel, t)!,
      stock: TextStyle.lerp(stock, other.stock, t)!,
      tileLabel: TextStyle.lerp(tileLabel, other.tileLabel, t)!,
      totalLabel: TextStyle.lerp(totalLabel, other.totalLabel, t)!,
    );
  }
}
