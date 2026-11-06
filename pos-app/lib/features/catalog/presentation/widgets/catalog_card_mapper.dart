// `ProductSummary` (08 §3.6) → данные карточки `ProductCard*` (02 ч. B §2.3): строки ARB, правила
// контрола количества (INV-013, INV-014, INV-023, INV-052) и показа остатка по роли (CUST-022:
// покупатель — `customer` и планшет магазина `kiosk` (10 KIOSK-007) — по `customer_stock_display`: статус или доступное
// количество; количества скрывает и сервер). Клиент ничего не вычисляет: цена и `available` — значения сервера (D-22, D-23). Товар уже в корзине —
// «В корзине · N — ещё +1» (прототип 2026-10-29, ADR-112): N — количество строки черновика, не вычисляется.
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/product_card.dart';
import 'package:optomstroy/design_system/components/stock_badge.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_formats.dart';

/// Контекст отображения карточек экрана.
final class CatalogCardContext {
  const CatalogCardContext({
    required this.l10n,
    required this.now,
    this.role,
    this.favoriteIds = const <String>{},
    this.favoriteOverrides = const <String, bool>{},
    this.favoritesEnabled = false,
    this.staleAfter = const Duration(minutes: 30),
    this.offline = false,
    this.showMatch = false,
    this.customerStockDisplay = CustomerStockDisplay.status,
    this.busyIds = const <String>{},
    this.addDisabled = false,
  });

  final AppLocalizations l10n;
  final DateTime now;

  /// Роль (`catalogViewerRoleProvider`): `owner` — без контролов корзины, `customer` и `kiosk` — без чисел остатка
  /// (кроме `customer_stock_display=quantity`).
  final RoleCode? role;
  final Set<String> favoriteIds;

  /// Оптимистичные переключения звезды до ответа сервера.
  final Map<String, bool> favoriteOverrides;
  final bool favoritesEnabled;

  /// Порог устаревания остатка (INV-027: 30 мин [НЕ ПОДТВЕРЖДЕНО, Q-020]).
  final Duration staleAfter;

  /// Данные из кэша без сети — метка возраста на каждом бейдже (AC-UI-10-017).
  final bool offline;

  /// Бейдж типа совпадения (SCR-11).
  final bool showMatch;

  /// Показ остатков покупателю (`customer_stock_display`, RM-E-017; планшет магазина — 10 KIOSK-007): `quantity` —
  /// доступное количество (без «остатка» и «резерва»), `status` — только статус. Для staff не используется.
  final CustomerStockDisplay customerStockDisplay;

  /// Товары, для которых «+ Добавить» уже выполняется (кнопка в загрузке, повторные нажатия игнорируются).
  final Set<String> busyIds;

  /// «+ Добавить» недоступна (серая кнопка, нажатие не принимается): планшет магазина без связи, при `426` и метке
  /// сброса без сети (02 UI-51-010, SCR-51.7). По умолчанию — `false` (сотрудник и `customer` — как прежде).
  final bool addDisabled;

  /// Покупатель: `customer` (свой телефон) и планшет магазина `kiosk` (02 ч. F; ADR-115).
  bool get buyer => role == RoleCode.customer || role == RoleCode.kiosk;

  /// Число доступного на бейдже: staff — всегда; покупатель — только при `quantity` (CUST-022, KIOSK-007).
  bool get showsStockQuantity => !buyer || customerStockDisplay == CustomerStockDisplay.quantity;

  /// Метка возраста данных «данные от HH:MM» на бейдже и в описании карточки для диктора: у всех, кроме планшета
  /// магазина — каталог из кэша «без отметки времени для покупателя» (02 SCR-51.7; без связи — баннер UI-51-014).
  bool get showsDataAge => role != RoleCode.kiosk;

  bool isFavorite(ProductSummary p) => favoriteOverrides[p.id] ?? (favoriteIds.contains(p.id) || p.isFavorite);
}

abstract final class CatalogCardMapper {
  /// Число вариантов для подписи «3 варианта».
  static String? variantsLabel(AppLocalizations l10n, ProductSummary p) =>
      p.hasVariants && p.variantCount != null ? l10n.variants_count(p.variantCount!) : null;

  /// Цена карточки: товар с вариантами разной цены — «от min» (Q-206).
  static (Money?, bool) price(ProductSummary p) {
    final MoneyRange? range = p.priceRange;
    if (p.hasVariants && range != null && range.min != range.max) {
      return (range.min, true);
    }
    return (p.price?.amount ?? range?.min, false);
  }

  /// Строка цены карточки сетки как показана («от 10 450,00 сом») и единица («/ шт») — высота ряда сетки по ценам его
  /// карточек (`kProductCardGridPriceWraps`, ревью V-01); цены нет — `(null, null)`. Те же строки, что у [map].
  static (String?, String?) priceLine(CatalogCardContext ctx, ProductSummary p) {
    final (Money? amount, bool from) = price(p);
    if (amount == null) {
      return (null, null);
    }
    final String formatted = PriceText.format(amount);
    final String unit = p.baseUnit?.label ?? '';
    return (
      from ? ctx.l10n.catalog_card_price_from(formatted) : formatted,
      unit.isEmpty ? null : ctx.l10n.catalog_card_price_unit(unit),
    );
  }

  /// Уровень и текст бейджа остатка.
  static (StockBadgeLevel, String) stock(CatalogCardContext ctx, ProductSummary p) {
    final AppLocalizations l10n = ctx.l10n;
    final StockBalance? s = p.stock;
    if (s == null || s.isUnknown) {
      return (StockBadgeLevel.unknown, l10n.ds_stock_unknown);
    }
    final StockBadgeLevel level = switch (s.stockLevel) {
      StockLevel.inStock => StockBadgeLevel.inStock,
      StockLevel.low => StockBadgeLevel.low,
      StockLevel.out => StockBadgeLevel.out,
      StockLevel.unknown => StockBadgeLevel.unknown,
    };
    if (level == StockBadgeLevel.out) {
      return (level, l10n.catalog_card_out_of_stock);
    }
    if (level == StockBadgeLevel.unknown) {
      return (level, l10n.ds_stock_unknown);
    }
    final bool low = level == StockBadgeLevel.low;
    final bool hideQty = !ctx.showsStockQuantity || s.available == null;
    if (hideQty) {
      // Статус без числа (CUST-022, AC-UI-50-004): «В наличии» / «Мало» — текст, иконка и цвет (03 §9.17).
      return (level, low ? l10n.stock_badge_low : l10n.stock_badge_in_stock);
    }
    final String qty = CatalogFormats.qty(s.available!);
    final String unit = p.baseUnit?.label ?? '';
    return (level, low ? l10n.stock_badge_low_qty(qty, unit) : l10n.stock_badge_in_stock_qty(qty, unit));
  }

  static String? _asOf(CatalogCardContext ctx, ProductSummary p) {
    if (!ctx.showsDataAge) {
      return null;
    }
    final DateTime? at = p.stock?.asOf;
    if (at == null) {
      return null;
    }
    final bool stale = ctx.offline || ctx.now.difference(at) > ctx.staleAfter;
    return stale ? ctx.l10n.ds_data_as_of(CatalogFormats.time(at)) : null;
  }

  /// Ключ количества товара в корзине: вариант по умолчанию; у товара с вариантами — `null` (остаётся «Выбрать
  /// вариант», N не показывается).
  static String? cartKey(ProductSummary p) => p.hasVariants ? null : p.defaultVariantId;

  /// Подписи «уже в корзине»: кнопка сетки и списка «В корзине · N — ещё +1» и строки «Компакт» «Ещё · N».
  static (String, String) inCartLabels(AppLocalizations l10n, Qty qty) {
    final String n = CatalogFormats.qty(qty);
    return (l10n.catalog_card_in_cart_add_more(n), l10n.catalog_card_in_cart_short(n));
  }

  /// Действие карточки; [cartQty] > 0 у доступного к добавлению товара — `inCart` (нажатие — ещё шаг).
  static (ProductCardActionKind, String?) action(CatalogCardContext ctx, ProductSummary p, {Qty? cartQty}) {
    final AppLocalizations l10n = ctx.l10n;
    if (ctx.role == RoleCode.owner) {
      return (ProductCardActionKind.hidden, null);
    }
    if (p.hasVariants) {
      return (ProductCardActionKind.chooseVariant, l10n.catalog_card_choose_variant);
    }
    if (p.price == null) {
      return (ProductCardActionKind.unavailable, l10n.ds_price_missing);
    }
    if (p.stockUnknown) {
      return (ProductCardActionKind.unavailable, l10n.ds_stock_unknown);
    }
    if (p.stock!.stockLevel == StockLevel.out) {
      return (ProductCardActionKind.unavailable, l10n.catalog_card_out_of_stock);
    }
    if (ctx.addDisabled) {
      // Планшет без связи / `426` / метка сброса: «+ Добавить» серая (02 UI-51-010), в очередь ничего не встаёт.
      return (ProductCardActionKind.unavailable, l10n.ds_button_add);
    }
    if (cartQty != null && cartQty.milli > 0) {
      return (ProductCardActionKind.inCart, inCartLabels(l10n, cartQty).$1);
    }
    return (ProductCardActionKind.add, l10n.ds_button_add);
  }

  static String? matchLabel(AppLocalizations l10n, MatchType? m) => switch (m) {
    MatchType.barcode => l10n.search_badge_barcode_exact,
    MatchType.sku => l10n.search_badge_sku,
    MatchType.fts || MatchType.trgm => l10n.search_badge_name,
    null => null,
  };

  /// Данные карточки. [cartQty] — количество товара в корзине по варианту (`catalogCartQuantitiesProvider`, ключ —
  /// [cartKey]; карточка подписана на своё значение); без него — «+ Добавить».
  static ProductCardData map(CatalogCardContext ctx, ProductSummary p, {Qty? cartQty}) {
    final AppLocalizations l10n = ctx.l10n;
    final String? sku = p.sku?.trim().isEmpty ?? true ? null : p.sku!.trim();
    final String unit = p.baseUnit?.label ?? '';
    final (Money? amount, bool from) = price(p);
    final (StockBadgeLevel level, String stockText) = stock(ctx, p);
    final (ProductCardActionKind kind, String? actionLabel) = action(ctx, p, cartQty: cartQty);
    final bool favorite = ctx.isFavorite(p);
    // Цена для диктора — форма `PriceText.spoken` («2 350 сом», «16 007 сом 50 тыйын»; без нулевых тыйынов и без
    // «запятой», 03 A11Y-020, ADR-114 п. 4), у вариантов — с «от».
    final String? spokenPrice = amount == null ? null : PriceText.spoken(amount);
    final String priceA11y = spokenPrice == null
        ? l10n.ds_price_missing
        : (from ? l10n.catalog_card_price_from(spokenPrice) : spokenPrice);
    final String stockA11y = stockText;
    return ProductCardData(
      id: p.id,
      name: p.name,
      skuLabel: sku == null ? l10n.catalog_card_sku_missing : l10n.catalog_card_sku(sku),
      skuMissing: sku == null,
      variantsLabel: variantsLabel(l10n, p),
      imageUrl: p.primaryImage?.cardUrl ?? p.primaryImage?.thumbUrl,
      thumbUrl: p.primaryImage?.thumbUrl ?? p.primaryImage?.cardUrl,
      price: amount,
      pricePrefix: from ? l10n.catalog_card_price_from : null,
      priceUnit: unit.isEmpty ? null : l10n.catalog_card_price_unit(unit),
      priceMissingLabel: l10n.ds_price_missing,
      unitLabel: unit.isEmpty ? null : unit,
      stockLevel: level,
      stockLabel: stockText,
      stockAsOf: _asOf(ctx, p),
      isFavorite: favorite,
      favoriteLabel: favorite ? l10n.ds_favorite_on_a11y : l10n.ds_favorite_add_a11y,
      showFavorite: ctx.favoritesEnabled,
      matchLabel: ctx.showMatch ? matchLabel(l10n, p.matchType) : null,
      action: kind,
      actionLabel: actionLabel,
      actionShortLabel: switch (kind) {
        ProductCardActionKind.inCart => inCartLabels(l10n, cartQty!).$2,
        // «Компакт»: «Нет данных» тем же кеглем, что соседние кнопки; «Остаток неизвестен» — в тултипе (UI-10-118).
        ProductCardActionKind.unavailable when actionLabel == l10n.ds_stock_unknown =>
          l10n.catalog_card_stock_unknown_short,
        // Прототип «Компакта»: «Нет» (полное «Нет в наличии» — в тултипе и в строке наличия; ADR-114).
        ProductCardActionKind.unavailable when actionLabel == l10n.catalog_card_out_of_stock =>
          l10n.catalog_card_out_short,
        _ => null,
      },
      actionBusy:
          (kind == ProductCardActionKind.add || kind == ProductCardActionKind.inCart) && ctx.busyIds.contains(p.id),
      dimmed: level == StockBadgeLevel.out,
      semanticLabel: l10n.catalog_card_a11y(p.name, priceA11y, sku ?? l10n.catalog_card_sku_missing, stockA11y, unit),
    );
  }
}
