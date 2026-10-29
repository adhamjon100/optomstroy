// Зоны SCR-14 (02 SCR-14.3): B — галерея, C — основные данные и действие, D — остатки по складам,
// E — описание и характеристики. Тексты — ARB `product_*`, цвета/отступы — токены варианта B.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' show CustomerStockDisplay;
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/image_gallery.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/product_image.dart';
import 'package:optomstroy/design_system/components/quantity_stepper.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/components/stock_badge.dart';
import 'package:optomstroy/design_system/components/unit_selector.dart';
import 'package:optomstroy/design_system/components/variant_selector.dart';
import 'package:optomstroy/design_system/components/warehouse_stock_table.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_refs.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/product_details/domain/entities/variant_axes.dart';
import 'package:optomstroy/features/product_details/presentation/notifiers/product_details_notifier.dart';
import 'package:optomstroy/features/product_details/presentation/widgets/product_formatters.dart';
import 'package:optomstroy/features/product_details/presentation/widgets/product_numpad.dart';
import 'package:optomstroy/features/product_details/product_details_providers.dart';

// ---------------------------------------------------------------------------
// Зона B — галерея

/// Фото выбранного варианта, иначе товара, затем заглушка (INV-011; «никогда фото другого товара»).
List<ProductImageRef> galleryRefsOf(ProductDetailsState s) {
  final Product? p = s.product;
  if (p == null) return const <ProductImageRef>[];
  final Variant? v = s.variant;
  final List<ProductImageRef> own = <ProductImageRef>[
    for (final ProductImageRef r in p.images)
      if (r.productId == null || r.productId == p.id) r,
  ];
  final List<ProductImageRef> variantImages = <ProductImageRef>[
    if (v != null) ...v.images,
    if (v != null)
      for (final ProductImageRef r in own)
        if (r.variantId == v.id && !v.images.any((ProductImageRef x) => x.sha256 == r.sha256)) r,
  ];
  final List<ProductImageRef> productImages =
      <ProductImageRef>[
        for (final ProductImageRef r in own)
          if (r.variantId == null) r,
      ]..sort(
        (ProductImageRef a, ProductImageRef b) =>
            a.isPrimary == b.isPrimary ? a.sortOrder.compareTo(b.sortOrder) : (a.isPrimary ? -1 : 1),
      );
  final List<ProductImageRef> out = <ProductImageRef>[...variantImages];
  for (final ProductImageRef r in productImages) {
    if (!out.any((ProductImageRef x) => x.sha256 == r.sha256)) out.add(r);
  }
  return out;
}

/// Зона B: `ImageGallery` (UI-14-003/004/022).
class ProductGallerySection extends ConsumerStatefulWidget {
  const ProductGallerySection({super.key, required this.state, this.vertical = false, this.mainSize});

  final ProductDetailsState state;
  final bool vertical;
  final double? mainSize; // money-double: allow — геометрия UI (lp)

  @override
  ConsumerState<ProductGallerySection> createState() => _ProductGallerySectionState();
}

class _ProductGallerySectionState extends ConsumerState<ProductGallerySection> {
  int _index = 0;
  String? _variantId;

  @override
  Widget build(BuildContext context) {
    final ProductDetailsState s = widget.state;
    if (s.variant?.id != _variantId) {
      // Смена варианта — индекс на первое фото варианта (02 SCR-14.4 «Галерея»).
      _variantId = s.variant?.id;
      _index = 0;
    }
    final Uri base = ref.watch(productImageBaseUriProvider);
    final List<GalleryImage> images = <GalleryImage>[
      for (final ProductImageRef r in galleryRefsOf(s))
        GalleryImage(
          url: ProductFormat.imageUrl(r, ProductImageSize.full, base),
          thumbUrl: ProductFormat.imageUrl(r, ProductImageSize.thumb, base),
          fullUrl: ProductFormat.imageUrl(r, ProductImageSize.full, base),
          variantId: r.variantId,
        ),
    ];
    return ImageGallery(
      key: const ValueKey<String>('product-gallery'),
      images: images,
      index: _index,
      strip: widget.vertical ? ImageGalleryStrip.vertical : ImageGalleryStrip.horizontal,
      mainSize: widget.mainSize,
      onIndexChanged: (int i) => setState(() => _index = i),
    );
  }
}

// ---------------------------------------------------------------------------
// Зона C — основные данные

/// Название, артикул и коды, цена с условиями, наличие, варианты, единица (UI-14-005…009, 018, 019,
/// 021, 024, 026, 030, 031, 032).
class ProductMainInfo extends StatelessWidget {
  const ProductMainInfo({
    super.key,
    required this.state,
    required this.notifier,
    this.large = false,
    this.onShowWarehouses,
    this.onOpenVariantList,
  });

  final ProductDetailsState state;
  final ProductDetailsNotifier notifier;

  /// `h3` на expanded, `title` на compact.
  final bool large;

  /// Тап по `StockBadge` (compact — лист со складами UI-14-028).
  final VoidCallback? onShowWarehouses;

  /// «Все варианты списком» — SCR-15.
  final VoidCallback? onOpenVariantList;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ProductDetailsState s = state;
    final Product p = s.product!;
    final Variant? v = s.variant;
    final bool deleted = p.deletionMark || (v?.deletionMark ?? false);
    final List<Widget> children = <Widget>[
      if (deleted && !s.isCustomer) ...<Widget>[
        ErrorState.banner(message: l10n.product_discontinued_banner, tone: ErrorStateTone.warning),
        const SizedBox(height: 12),
      ],
      SelectableText(
        p.name,
        key: const ValueKey<String>('product-name'),
        style: (large ? context.text.h3 : context.text.title).copyWith(
          color: c.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 4),
      _SkuLine(state: s),
      if (!s.isCustomer) _BarcodesLine(state: s),
      const SizedBox(height: 12),
      _PriceBlock(state: s),
      const SizedBox(height: 12),
      _StockLine(state: s, onTap: onShowWarehouses),
      if (s.axes.isNotEmpty) ...<Widget>[
        const SizedBox(height: 16),
        _Variants(state: s, notifier: notifier, onOpenList: onOpenVariantList),
      ],
      if (s.packagings.isNotEmpty) ...<Widget>[
        const SizedBox(height: 16),
        Text(l10n.product_unit_title, style: context.text.label.copyWith(color: c.textSecondary)),
        const SizedBox(height: 8),
        UnitSelector(
          options: ProductUnits(s).options(),
          selectedId: s.packagingId ?? baseUnitOptionId,
          semanticLabel: l10n.product_unit_title,
          onChanged: (String id) => notifier.selectPackaging(id == baseUnitOptionId ? null : id),
        ),
        if (s.unitHint != null) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            l10n.qty_pack_conversion(
              ProductFormat.qty(s.unitHint!.base),
              s.packaging == null ? '' : ProductUnits(s).packLabel(s.packaging!),
              '${s.unitHint!.packs}',
              ProductUnits(s).baseLabel,
            ),
            key: const ValueKey<String>('product-unit-hint'),
            style: context.text.caption.copyWith(color: c.textSecondary),
          ),
        ],
      ],
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: children);
  }
}

class _SkuLine extends StatelessWidget {
  const _SkuLine({required this.state});

  final ProductDetailsState state;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final Variant? v = state.variant;
    final String? variantSku = v?.sku;
    final String? productSku = state.product?.summary.sku;
    final String? sku = (variantSku != null && variantSku.isNotEmpty) ? variantSku : productSku;
    final bool productNote = (variantSku == null || variantSku.isEmpty) && sku != null && sku.isNotEmpty;
    final TextStyle ts = context.text.caption.copyWith(color: c.textSecondary, fontFeatures: _tnum);
    final String? onec = state.isCustomer ? null : state.product?.onecCode;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 4,
      children: <Widget>[
        Text(
          sku == null || sku.isEmpty ? l10n.product_sku_missing : l10n.product_sku_variant(sku),
          key: const ValueKey<String>('product-sku'),
          style: ts,
        ),
        if (productNote)
          StatusChip(label: l10n.product_sku_product_note, variant: StatusChipVariant.neutral, dense: true),
        if (onec != null && onec.isNotEmpty) Text('· ${l10n.product_onec_code(onec)}', style: ts),
        if (sku != null && sku.isNotEmpty)
          AppIconButton(
            icon: Icons.content_copy_rounded,
            iconSize: 20,
            small: true,
            semanticLabel: l10n.ds_copied,
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: sku));
              if (context.mounted) AppSnackbar.show(context, message: l10n.product_sku_copied);
            },
          ),
      ],
    );
  }
}

class _BarcodesLine extends StatelessWidget {
  const _BarcodesLine({required this.state});

  final ProductDetailsState state;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final Variant? v = state.variant;
    final List<String> codes = <String>[
      ...?v?.barcodes,
      for (final Packaging pk in state.packagings)
        if (pk.barcode != null) pk.barcode!,
    ];
    if (codes.isEmpty) return const SizedBox.shrink();
    final String shown = codes.take(2).join(', ');
    final String text = codes.length > 2
        ? '${l10n.product_barcodes(shown)} · ${l10n.product_barcodes_more(codes.length - 2)}'
        : l10n.product_barcodes(shown);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        text,
        style: context.text.caption.copyWith(color: context.colors.textSecondary, fontFeatures: _tnum),
      ),
    );
  }
}

class _PriceBlock extends StatefulWidget {
  const _PriceBlock({required this.state});

  final ProductDetailsState state;

  @override
  State<_PriceBlock> createState() => _PriceBlockState();
}

class _PriceBlockState extends State<_PriceBlock> {
  bool _allOpen = false;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ProductDetailsState s = widget.state;
    final Price? price = s.price;
    final String unit = s.baseUnit?.label ?? '';
    if (price == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(l10n.ds_price_missing, style: context.text.h3.copyWith(color: c.textSecondary)),
          const SizedBox(height: 4),
          Text(l10n.product_price_missing_hint, style: context.text.caption.copyWith(color: c.textSecondary)),
        ],
      );
    }
    final List<Widget> packPrices = <Widget>[
      for (final Packaging pk in s.packagings)
        if (s.packPriceOf(pk) case final Price pp)
          Text(
            l10n.product_price_per_pack(
              '${ProductUnits(s).packLabel(pk)} (${ProductFormat.qty(pk.factor)} $unit)',
              PriceText.format(pp.amount),
            ),
            style: context.text.caption.copyWith(color: c.textSecondary, fontFeatures: _tnum),
          ),
    ];
    final List<Price> allPrices = <Price>[
      for (final Price pr in s.product?.prices ?? const <Price>[])
        if (pr.packagingId == null) pr,
    ];
    final bool showAll = s.isSeniorStaff && allPrices.length > 1 && s.variant?.id == s.product?.defaultVariant?.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: <Widget>[
            PriceText(
              key: const ValueKey<String>('product-price'),
              amount: price.amount,
              unit: l10n.product_price_unit(unit),
              variant: PriceTextVariant.card,
            ),
            if (price.priceListName != null)
              StatusChip(
                key: const ValueKey<String>('product-price-list'),
                // Клиенту — «Ваш вид цены: …» (вид цены выбирает сервер, CUST-021; 02 UI-50-007).
                label: s.isCustomer ? l10n.home_price_list_label(price.priceListName!) : price.priceListName!,
                variant: StatusChipVariant.priceList,
                tooltip: s.isCustomer ? null : l10n.product_price_list_tooltip,
              ),
          ],
        ),
        ...packPrices,
        if (showAll) ...<Widget>[
          const SizedBox(height: 4),
          AppButton(
            label: l10n.product_price_lists_all,
            onPressed: () => setState(() => _allOpen = !_allOpen),
            variant: AppButtonVariant.text,
            size: AppButtonSize.s,
            trailingIcon: _allOpen ? Icons.expand_less_rounded : Icons.expand_more_rounded,
          ),
          if (_allOpen)
            for (final Price pr in allPrices)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        pr.priceListName ?? pr.priceListId,
                        style: context.text.body.copyWith(color: c.textPrimary),
                      ),
                    ),
                    Text(
                      PriceText.format(pr.amount),
                      style: context.text.body.copyWith(color: c.textPrimary, fontFeatures: _tnum),
                    ),
                  ],
                ),
              ),
        ],
      ],
    );
  }
}

/// `StockBadge` по складу корзины: число — только staff и `customer` в режиме `quantity`
/// (ядро v1.9 §24.2); «Есть на складе «…»» при нуле (INV-026).
class _StockLine extends StatelessWidget {
  const _StockLine({required this.state, this.onTap});

  final ProductDetailsState state;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ProductDetailsState s = state;
    final StockBalance? other = s.isCustomer ? null : s.otherWarehouseStock;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ProductStockBadge(state: s, onTap: onTap),
        if (other != null) ...<Widget>[
          const SizedBox(height: 8),
          StatusChip(
            key: const ValueKey<String>('product-other-warehouse'),
            label: l10n.product_other_warehouse(
              ProductFormat.qty(other.available!),
              s.baseUnit?.label ?? '',
              other.warehouseName ?? other.warehouseId,
            ),
            variant: StatusChipVariant.info,
            tooltip: l10n.product_other_warehouse(
              ProductFormat.qty(other.available!),
              s.baseUnit?.label ?? '',
              other.warehouseName ?? other.warehouseId,
            ),
          ),
        ],
      ],
    );
  }
}

/// Уровень `StockBadge` по остатку склада корзины.
StockBadgeLevel stockBadgeLevelOf(StockBalance? s) {
  if (s == null || s.isUnknown) return StockBadgeLevel.unknown;
  final Qty? a = s.available;
  if (s.stockLevel == StockLevel.out || (a != null && a.milli <= 0)) return StockBadgeLevel.out;
  if (s.stockLevel == StockLevel.low) return StockBadgeLevel.low;
  return StockBadgeLevel.inStock;
}

/// Текст `StockBadge` (03 §9.17): «В наличии · 24 шт», «Мало · 3 шт»; без числа (`customer` в режиме
/// `status`, AC-UI-50-004) — «В наличии» / «Мало»; «Нет в наличии» ([outLabel]) и «Остаток неизвестен».
String stockBadgeLabel(AppLocalizations l10n, StockBadgeLevel level, Qty? available, String unit, {String? outLabel}) =>
    switch (level) {
      StockBadgeLevel.out => outLabel ?? l10n.catalog_card_out_of_stock,
      StockBadgeLevel.unknown => l10n.ds_stock_unknown,
      StockBadgeLevel.low =>
        available == null ? l10n.stock_badge_low : l10n.stock_badge_low_qty(ProductFormat.qty(available), unit),
      StockBadgeLevel.inStock =>
        available == null
            ? l10n.stock_badge_in_stock
            : l10n.stock_badge_in_stock_qty(ProductFormat.qty(available), unit),
    };

/// Показывать ли числа остатков зрителю (staff — да; `customer` — только в режиме `quantity`).
bool showsStockNumbers(ProductDetailsState s) => !s.isCustomer || s.stockDisplay == CustomerStockDisplay.quantity;

/// `StockBadge` карточки (UI-14-031).
class ProductStockBadge extends ConsumerWidget {
  const ProductStockBadge({super.key, required this.state, this.onTap});

  final ProductDetailsState state;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ProductDetailsState s = state;
    final StockBalance? stock = s.stock;
    final StockBadgeLevel level = stockBadgeLevelOf(stock);
    final Qty? available = showsStockNumbers(s) ? stock?.available : null;
    final String unit = s.baseUnit?.label ?? '';
    final String label = stockBadgeLabel(l10n, level, available, unit);
    final DateTime? asOf = stock?.asOf;
    final DateTime now = ref.watch(clockProvider).nowUtc();
    final bool stale = asOf != null && now.difference(asOf.toUtc()) > const Duration(minutes: 30);
    final Widget badge = StockBadge(
      key: const ValueKey<String>('product-stock-badge'),
      level: level,
      label: label,
      asOf: stale ? l10n.ds_updated_at(ProductFormat.time(asOf)) : null,
    );
    if (onTap == null || s.isCustomer) return badge;
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.all(context.radii.full),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Flexible(child: badge),
              const SizedBox(width: 4),
              Text(l10n.product_warehouses_tab, style: context.text.label.copyWith(color: context.colors.primaryText)),
              Icon(Icons.expand_more_rounded, size: 20, color: context.colors.primaryText),
            ],
          ),
        ),
      ),
    );
  }
}

class _Variants extends StatelessWidget {
  const _Variants({required this.state, required this.notifier, this.onOpenList});

  final ProductDetailsState state;
  final ProductDetailsNotifier notifier;
  final VoidCallback? onOpenList;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ProductDetailsState s = state;
    final List<Variant> variants = s.variants;
    final List<String> axes = s.axes;
    final Variant? current = s.variant;
    final List<VariantAxis> models = <VariantAxis>[
      for (final String axis in axes)
        VariantAxis(
          key: axis,
          label: axis == VariantAxes.nameAxis ? l10n.variant_mode_list : axis,
          selected: current == null ? null : VariantAxes.valueOf(current, axis),
          values: <VariantAxisValue>[
            for (final String value in VariantAxes.valuesOf(variants, axis))
              VariantAxisValue(
                value: value,
                available: _hasStock(variants, axis, value),
                combinationExists: VariantAxes.combinationExists(variants, axes, current, axis, value),
              ),
          ],
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        VariantSelector(
          axes: models,
          combinationMissingHint: l10n.product_variant_combination_missing,
          titleFor: (VariantAxis a) => a.key == VariantAxes.nameAxis
              ? (a.selected ?? '')
              : (a.selected == null ? a.label : l10n.product_variant_axis(a.label, a.selected!)),
          onSelected: notifier.selectAxisValue,
        ),
        if (onOpenList != null && variants.length > 1)
          AppButton(
            key: const ValueKey<String>('product-variants-list'),
            label: l10n.variant_mode_list,
            onPressed: onOpenList,
            variant: AppButtonVariant.text,
            size: AppButtonSize.s,
            icon: Icons.list_rounded,
          ),
      ],
    );
  }

  static bool _hasStock(List<Variant> variants, String axis, String value) => variants.any((Variant v) {
    if (VariantAxes.valueOf(v, axis) != value) return false;
    final StockBalance? s = v.stock;
    return s == null ||
        s.isUnknown ||
        (s.stockLevel != StockLevel.out && (s.available == null || s.available!.milli > 0));
  });
}

// ---------------------------------------------------------------------------
// Количество и «В корзину»

/// Подпись CTA (UI-14-011/020).
String ctaLabelOf(AppLocalizations l10n, ProductDetailsState s) => switch (s.cta) {
  ProductCta.add || ProductCta.invalidQuantity =>
    s.ctaSum == null ? l10n.product_cta_unavailable : l10n.product_cta_add(PriceText.format(s.ctaSum!)),
  ProductCta.addMore => l10n.product_cta_add_more,
  ProductCta.outOfStock => l10n.product_cta_out_of_stock,
  ProductCta.unavailable || ProductCta.hidden => l10n.product_cta_unavailable,
};

/// Степпер + CTA (UI-14-010/011/012/029); на compact — внутри закреплённой панели UI-14-027.
class ProductQuantityBar extends StatelessWidget {
  const ProductQuantityBar({super.key, required this.state, required this.notifier, this.showRules = true});

  final ProductDetailsState state;
  final ProductDetailsNotifier notifier;
  final bool showRules;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ProductDetailsState s = state;
    if (s.cta == ProductCta.hidden) return const SizedBox.shrink();
    final ProductUnits units = ProductUnits(s);
    final Packaging? pk = s.packaging;
    final String unitLabel = pk == null ? units.baseLabel : units.packLabel(pk);
    final String value = ProductFormat.qty(s.lineQuantity);
    final String? issue = qtyIssueText(l10n, s.quantityIssue, unit: units.baseLabel, warehouse: s.stock?.warehouseName);
    final bool enabled = s.cta == ProductCta.add || s.cta == ProductCta.addMore;
    final bool stockBlocked = s.stockUnknown || s.outOfStock;
    final Widget stepper = QuantityStepper(
      key: const ValueKey<String>('product-quantity-stepper'),
      value: value,
      unit: unitLabel,
      error: issue != null,
      increaseLabel: l10n.ds_qty_increase_a11y,
      decreaseLabel: l10n.ds_qty_decrease_a11y,
      onIncrement: s.canIncrement ? notifier.increment : null,
      onDecrement: s.canDecrement && !stockBlocked ? notifier.decrement : null,
      onValueTap: stockBlocked ? null : () => openProductNumpad(context, state: s, notifier: notifier),
      onIncrementLongPress: stockBlocked ? null : () => openProductNumpad(context, state: s, notifier: notifier),
    );
    final String fullLabel = ctaLabelOf(l10n, s);
    final Widget cta = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        // Узкое окно (compact 360–412 lp): если «В корзину · 2 850 сом» не помещается в CTA L
        // рядом со степпером md, сумма показывается без «сом» (EQ-PD-04); screen reader читает полный текст.
        String label = fullLabel;
        final Money? sum = s.ctaSum;
        if (box.hasBoundedWidth && sum != null && (s.cta == ProductCta.add || s.cta == ProductCta.invalidQuantity)) {
          final double room = box.maxWidth - 2 * AppButtonSize.l.padding; // money-double: allow — геометрия UI (lp)
          final TextStyle ts = context.text.bodyLg.copyWith(fontWeight: FontWeight.w600);
          final TextPainter tp = TextPainter(
            text: TextSpan(text: fullLabel, style: ts),
            maxLines: 1,
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout();
          if (tp.width > room) label = l10n.product_cta_add(PriceText.formatAmount(sum));
          tp.dispose();
        }
        return AppButton(
          key: const ValueKey<String>('product-cta'),
          label: label,
          semanticLabel: fullLabel,
          onPressed: enabled ? notifier.add : null,
          loading: s.adding,
          size: AppButtonSize.l,
          expand: true,
        );
      },
    );
    final Widget? hintOrError = issue != null
        ? Text(
            issue,
            key: const ValueKey<String>('product-qty-error'),
            style: context.text.caption.copyWith(color: c.error),
          )
        : (s.price == null && !stockBlocked
              ? Text(l10n.product_price_missing_hint, style: context.text.caption.copyWith(color: c.textSecondary))
              : null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            stepper,
            const SizedBox(width: 12),
            Expanded(child: cta),
          ],
        ),
        if (showRules) ...<Widget>[const SizedBox(height: 8), ProductQuantityRules(state: s)],
        if (hintOrError != null) ...<Widget>[const SizedBox(height: 4), hintOrError],
      ],
    );
  }
}

/// Правила количества и «В корзине: N» (UI-14-012, UI-14-029).
class ProductQuantityRules extends StatelessWidget {
  const ProductQuantityRules({super.key, required this.state});

  final ProductDetailsState state;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ProductDetailsState s = state;
    if (s.cta == ProductCta.hidden) return const SizedBox.shrink();
    final ProductUnits units = ProductUnits(s);
    final Packaging? pk = s.packaging;
    final String unitLabel = pk == null ? units.baseLabel : units.packLabel(pk);
    final Qty? inCart = s.inCartQuantity;
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        if (!s.isCustomer)
          Text(
            l10n.product_qty_rules(
              ProductFormat.qty(s.rules.initialFor()),
              ProductFormat.qty(s.rules.stepFor()),
              units.baseLabel,
            ),
            style: context.text.caption.copyWith(color: c.textSecondary, fontFeatures: _tnum),
          ),
        if (inCart != null)
          StatusChip(
            key: const ValueKey<String>('product-in-cart'),
            label: l10n.product_in_cart(ProductFormat.qty(inCart), unitLabel),
            variant: StatusChipVariant.info,
            icon: Icons.shopping_cart_rounded,
          ),
      ],
    );
  }
}

/// Закреплённая нижняя панель compact (UI-14-027): 72, `surface`, граница `border`, `elevation.2`.
class ProductBottomBar extends StatelessWidget {
  const ProductBottomBar({super.key, required this.state, required this.notifier});

  final ProductDetailsState state;
  final ProductDetailsNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    if (state.cta == ProductCta.hidden) return const SizedBox.shrink();
    return Container(
      key: const ValueKey<String>('product-bottom-bar'),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.border)),
        boxShadow: context.elevation.e2,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: ProductQuantityBar(state: state, notifier: notifier, showRules: false),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Зона D — остатки по складам

/// `WarehouseStockTable` (UI-14-013, 025, D3): staff; `customer` — таблицы нет (02 SCR-14.10).
class ProductStockSection extends ConsumerWidget {
  const ProductStockSection({super.key, required this.state, this.onRetry, this.showTitle = true});

  final ProductDetailsState state;
  final VoidCallback? onRetry;
  final bool showTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DsColors c = context.colors;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ProductDetailsState s = state;
    if (s.isCustomer) return const SizedBox.shrink();
    final Variant? v = s.variant;
    final String unit = s.baseUnit?.label ?? '';
    final String? cartWh = s.cartWarehouseId ?? s.stock?.warehouseId;
    final List<Packaging> packs = s.packagings;
    final Packaging? pack = packs.where((Packaging p) => p.isDefault).firstOrNull ?? packs.firstOrNull;
    DateTime? asOf;
    final List<WarehouseStockRow> rows = <WarehouseStockRow>[
      for (final StockBalance b in v?.stockByWarehouse ?? const <StockBalance>[])
        WarehouseStockRow(
          warehouseId: b.warehouseId,
          name: b.warehouseName ?? b.warehouseId,
          available: b.available == null ? '—' : ProductFormat.qty(b.available!),
          availableMilli: b.available?.milli,
          reserved: b.reserved == null ? null : ProductFormat.qty(b.reserved!),
          quantity: b.quantity == null ? null : ProductFormat.qty(b.quantity!),
          packHint: pack == null || b.available == null || b.available!.milli < pack.factor.milli
              ? null
              : '(${b.available!.milli ~/ pack.factor.milli} ${ProductUnits(s).packLabel(pack)})',
          isCartWarehouse: b.warehouseId == cartWh,
        ),
    ];
    for (final StockBalance b in v?.stockByWarehouse ?? const <StockBalance>[]) {
      if (b.asOf != null && (asOf == null || b.asOf!.isAfter(asOf))) asOf = b.asOf;
    }
    final bool stale =
        asOf != null && ref.watch(clockProvider).nowUtc().difference(asOf.toUtc()) > const Duration(minutes: 30);
    final Qty? total = s.product?.availableTotal;
    final bool isDefaultVariant = v?.id == s.product?.defaultVariant?.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (showTitle) ...<Widget>[
          Text(l10n.product_stock_title, style: context.text.title.copyWith(color: c.textPrimary)),
          const SizedBox(height: 8),
        ],
        WarehouseStockTable(
          key: const ValueKey<String>('product-stock-table'),
          rows: rows,
          variant: s.isSeniorStaff ? WarehouseStockTableVariant.cashier : WarehouseStockTableVariant.seller,
          unit: unit,
          // «Доступно всего» — только значение сервера (D-22); `availableTotal` относится к товару
          // (вариант по умолчанию), для других вариантов строка итога не показывается.
          totalQuantity: total != null && isDefaultVariant ? ProductFormat.qty(total) : null,
          asOfTime: asOf == null ? null : ProductFormat.time(asOf),
          stale: stale,
          error: rows.isEmpty && s.failure != null && s.source == null,
          onRetry: onRetry,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Зона E — описание и характеристики

/// Характеристики (UI-14-016): ≤ 8 + «Показать все (N)»; оси вариантов помечены `tune`.
class ProductSpecsSection extends StatefulWidget {
  const ProductSpecsSection({super.key, required this.state, this.showTitle = true});

  final ProductDetailsState state;
  final bool showTitle;

  /// Сколько характеристик видно до «Показать все».
  static const int collapsedCount = 8;

  @override
  State<ProductSpecsSection> createState() => _ProductSpecsSectionState();
}

class _ProductSpecsSectionState extends State<ProductSpecsSection> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ProductDetailsState s = widget.state;
    final Map<String, String> specs = <String, String>{...?s.product?.attributes, ...?s.variant?.attributes};
    if (specs.isEmpty) return const SizedBox.shrink();
    final Set<String> axes = s.axes.toSet();
    final List<MapEntry<String, String>> entries = specs.entries.toList();
    final List<MapEntry<String, String>> shown = _all
        ? entries
        : entries.take(ProductSpecsSection.collapsedCount).toList();
    return Column(
      key: const ValueKey<String>('product-specs'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (widget.showTitle) ...<Widget>[
          Text(l10n.product_specs_title, style: context.text.title.copyWith(color: c.textPrimary)),
          const SizedBox(height: 8),
        ],
        _SizeAnimation(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final MapEntry<String, String> e in shown)
                Container(
                  constraints: const BoxConstraints(minHeight: 40),
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: c.border)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        child: Row(
                          children: <Widget>[
                            if (axes.contains(e.key)) ...<Widget>[
                              Icon(Icons.tune_rounded, size: 16, color: c.textSecondary),
                              const SizedBox(width: 4),
                            ],
                            Flexible(
                              child: Text(e.key, style: context.text.body.copyWith(color: c.textSecondary)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(e.value, style: context.text.body.copyWith(color: c.textPrimary)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        if (entries.length > ProductSpecsSection.collapsedCount && !_all)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: AppButton(
              label: l10n.product_specs_show_all(entries.length),
              onPressed: () => setState(() => _all = true),
              variant: AppButtonVariant.text,
              size: AppButtonSize.s,
            ),
          ),
      ],
    );
  }
}

/// Описание (UI-14-014/023): 3 строки + «Читать полностью» / «Свернуть»; пустое — блока нет.
class ProductDescriptionSection extends StatefulWidget {
  const ProductDescriptionSection({super.key, required this.state, this.showTitle = true});

  final ProductDetailsState state;
  final bool showTitle;

  @override
  State<ProductDescriptionSection> createState() => _ProductDescriptionSectionState();
}

class _ProductDescriptionSectionState extends State<ProductDescriptionSection> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String? text = widget.state.product?.description?.trim();
    if (text == null || text.isEmpty) return const SizedBox.shrink();
    final TextStyle ts = context.text.body.copyWith(color: c.textPrimary);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final TextPainter tp = TextPainter(
          text: TextSpan(text: text, style: ts),
          maxLines: 3,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: box.maxWidth);
        final bool long = tp.didExceedMaxLines;
        tp.dispose();
        return Column(
          key: const ValueKey<String>('product-description'),
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (widget.showTitle) ...<Widget>[
              Text(l10n.product_description_title, style: context.text.title.copyWith(color: c.textPrimary)),
              const SizedBox(height: 8),
            ],
            _SizeAnimation(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Text(
                  text,
                  style: ts,
                  maxLines: _open ? null : 3,
                  overflow: _open ? null : TextOverflow.ellipsis,
                ),
              ),
            ),
            if (long)
              AppButton(
                label: _open ? l10n.product_description_collapse : l10n.product_description_expand,
                onPressed: () => setState(() => _open = !_open),
                variant: AppButtonVariant.text,
                size: AppButtonSize.s,
              ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Скелетон (нет кэша, SCR-14.7 «Загрузка»)

/// Скелетоны галереи, названия, цены, вариантов, таблицы (ANIM-013).
class ProductDetailsSkeleton extends StatelessWidget {
  const ProductDetailsSkeleton({super.key, this.wide = false});

  final bool wide;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final Widget data = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SkeletonBox.text(width: 280, semanticLabel: l10n.ds_loading),
        const SizedBox(height: 8),
        const SkeletonBox.text(width: 200),
        const SizedBox(height: 16),
        const SkeletonBox(width: 140, height: 28),
        const SizedBox(height: 16),
        const SkeletonBox(width: 220, height: 40),
        const SizedBox(height: 16),
        for (int i = 0; i < 3; i++) ...<Widget>[const SkeletonBox(height: 32), const SizedBox(height: 8)],
      ],
    );
    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Expanded(flex: 2, child: SkeletonBox.image()),
          const SizedBox(width: 24),
          Expanded(flex: 3, child: data),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[const SkeletonBox.image(), const SizedBox(height: 16), data],
    );
  }
}

/// Снекбар после добавления (compact, ANIM-006): «Добавлено {qty} {unit} · Открыть корзину».
void showAddedSnackbar(BuildContext context, ProductDetailsState s) {
  final ({Qty quantity, String unitLabel})? added = s.lastAdded;
  if (added == null) return;
  final AppLocalizations l10n = AppLocalizations.of(context);
  AppSnackbar.show(
    context,
    message: l10n.product_added_snackbar(ProductFormat.qty(added.quantity), added.unitLabel),
    variant: AppSnackbarVariant.success,
  );
}

/// Тултип-обёртка цены (expanded).
Widget withPriceTooltip(BuildContext context, Widget child) =>
    AppTooltip(message: AppLocalizations.of(context).product_price_list_tooltip, child: child);

const List<FontFeature> _tnum = <FontFeature>[FontFeature.tabularFigures()];

/// ANIM-016 «Показать все» / «Читать полностью»: `AnimatedSize` 200 мс; под reduce-motion —
/// без анимации (нулевая длительность `AnimatedSize` недопустима).
class _SizeAnimation extends StatelessWidget {
  const _SizeAnimation({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Duration d = context.motion.of(const Duration(milliseconds: 200));
    if (d == Duration.zero) return child;
    return AnimatedSize(duration: d, alignment: Alignment.topCenter, child: child);
  }
}

/// Сумма для подписи CTA без «сом» (для тестов и a11y).
String moneyLabel(Money m) => PriceText.format(m);
