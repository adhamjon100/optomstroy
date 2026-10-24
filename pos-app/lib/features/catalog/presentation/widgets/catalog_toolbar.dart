// Зона C SCR-10/11/12 (02 SCR-10.3 C1–C7, SCR-11 UI-11-003/004, SCR-12 UI-12-001…003): заголовок и
// «Найдено: N», `ViewModeSegmented`, `SortMenu`, «Фильтры» с бейджем, полоса чипов (подкатегории,
// подборки «Недавние»/«Избранное», «Все категории ›» на compact/medium), активные фильтры.
import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_badge.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/category_chip.dart';
import 'package:optomstroy/design_system/components/found_count_text.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/sort_menu.dart';
import 'package:optomstroy/design_system/components/view_mode_segmented.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/category.dart';
import 'package:optomstroy/features/catalog/presentation/state/catalog_filter_codec.dart';

/// Пункты сортировки каталога (CAT-006; ядро §19.2) и поиска (UI-11-008).
List<SortMenuOption<CatalogSort>> catalogSortOptions(AppLocalizations l10n, {required bool search}) => search
    ? <SortMenuOption<CatalogSort>>[
        SortMenuOption<CatalogSort>(value: CatalogSort.relevanceDesc, label: l10n.catalog_sort_relevance),
        SortMenuOption<CatalogSort>(value: CatalogSort.priceAsc, label: l10n.catalog_sort_price_asc),
        SortMenuOption<CatalogSort>(value: CatalogSort.priceDesc, label: l10n.catalog_sort_price_desc),
        SortMenuOption<CatalogSort>(value: CatalogSort.nameAsc, label: l10n.catalog_sort_name_asc),
        SortMenuOption<CatalogSort>(value: CatalogSort.availableDesc, label: l10n.catalog_sort_in_stock_first),
        SortMenuOption<CatalogSort>(value: CatalogSort.skuAsc, label: l10n.catalog_sort_sku),
      ]
    : <SortMenuOption<CatalogSort>>[
        SortMenuOption<CatalogSort>(value: CatalogSort.nameAsc, label: l10n.catalog_sort_name_asc),
        SortMenuOption<CatalogSort>(value: CatalogSort.nameDesc, label: l10n.catalog_sort_name_desc),
        SortMenuOption<CatalogSort>(value: CatalogSort.priceAsc, label: l10n.catalog_sort_price_asc),
        SortMenuOption<CatalogSort>(value: CatalogSort.priceDesc, label: l10n.catalog_sort_price_desc),
        SortMenuOption<CatalogSort>(value: CatalogSort.updatedAtDesc, label: l10n.catalog_sort_newest),
        SortMenuOption<CatalogSort>(value: CatalogSort.availableDesc, label: l10n.catalog_sort_in_stock_first),
        SortMenuOption<CatalogSort>(value: CatalogSort.skuAsc, label: l10n.catalog_sort_sku),
      ];

/// Заголовок контента: [крошки] → h2 → «Найдено: N».
class CatalogTitleBlock extends StatelessWidget {
  const CatalogTitleBlock({
    super.key,
    required this.title,
    required this.found,
    this.breadcrumbs,
    this.compact = false,
  });

  /// `null` — скелетон.
  final String? title;
  final String? found;
  final Widget? breadcrumbs;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ?breadcrumbs,
        if (!compact)
          Semantics(
            header: true,
            child: Text(
              title ?? '',
              key: const ValueKey<String>('catalog-title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.text.h2.copyWith(color: c.textPrimary),
            ),
          ),
        if (!compact) SizedBox(height: context.space.s1),
        FoundCountText(key: const ValueKey<String>('catalog-found'), text: found),
      ],
    );
  }
}

/// Хлебные крошки SCR-12 (UI-12-001): при глубине ≥ 2.
class CatalogBreadcrumbs extends StatelessWidget {
  const CatalogBreadcrumbs({super.key, required this.path, required this.onRoot, required this.onCategory});

  final List<Category> path;
  final VoidCallback onRoot;
  final ValueChanged<Category> onCategory;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final Widget sep = Icon(Icons.chevron_right_rounded, size: 16, color: c.textSecondary);
    return SizedBox(
      height: 32,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: <Widget>[
            AppButton(
              label: l10n.category_breadcrumb_root,
              onPressed: onRoot,
              variant: AppButtonVariant.text,
              size: AppButtonSize.s,
            ),
            for (int i = 0; i < path.length; i++) ...<Widget>[
              sep,
              if (i == path.length - 1)
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: context.space.s2),
                  child: Text(
                    path[i].name,
                    style: context.text.label.copyWith(fontWeight: FontWeight.w600, color: c.textPrimary),
                  ),
                )
              else
                AppButton(
                  label: path[i].name,
                  onPressed: () => onCategory(path[i]),
                  variant: AppButtonVariant.text,
                  size: AppButtonSize.s,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Вид, сортировка, «Фильтры».
class CatalogToolbarControls extends StatelessWidget {
  const CatalogToolbarControls({
    super.key,
    required this.view,
    required this.onView,
    required this.sort,
    required this.onSort,
    required this.searchMode,
    required this.filterCount,
    required this.onFilters,
    required this.compact,
    this.showViewText = false,
    this.filtersOpen = false,
  });

  final ProductViewMode view;
  final ValueChanged<ProductViewMode> onView;
  final CatalogSort sort;
  final ValueChanged<CatalogSort> onSort;
  final bool searchMode;
  final int filterCount;

  /// Фильтры; `null` — кнопки нет (SCR-50: вид и сортировка без фильтров).
  final VoidCallback? onFilters;
  final bool compact;
  final bool showViewText;
  final bool filtersOpen;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final List<SortMenuOption<CatalogSort>> options = catalogSortOptions(l10n, search: searchMode);
    final String sortLabel = options
        .firstWhere((SortMenuOption<CatalogSort> o) => o.value == sort, orElse: () => options.first)
        .label;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ViewModeSegmented(
          value: view,
          onChanged: onView,
          showText: showViewText,
          labels: <ProductViewMode, String>{
            ProductViewMode.grid: l10n.catalog_view_grid,
            ProductViewMode.list: l10n.catalog_view_list,
            ProductViewMode.compact: l10n.catalog_view_compact,
          },
        ),
        SizedBox(width: context.space.s3),
        SortMenu<CatalogSort>(
          key: const ValueKey<String>('catalog-sort'),
          options: options,
          selected: sort,
          onSelected: onSort,
          iconOnly: compact,
          semanticLabel: sortLabel,
          sheetTitle: sortLabel,
        ),
        if (onFilters != null) SizedBox(width: context.space.s3),
        if (onFilters == null)
          const SizedBox.shrink()
        else if (compact)
          AppIconButton(
            key: const ValueKey<String>('catalog-filters-button'),
            icon: Icons.filter_list_rounded,
            semanticLabel: l10n.catalog_filters_button,
            tooltip: l10n.catalog_filters_button,
            onPressed: onFilters,
            badge: filterCount > 0 ? AppBadge(count: filterCount, tone: AppBadgeTone.cart) : null,
          )
        else
          Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              AppButton(
                key: const ValueKey<String>('catalog-filters-button'),
                label: l10n.catalog_filters_button,
                icon: Icons.filter_list_rounded,
                onPressed: onFilters,
                variant: filtersOpen ? AppButtonVariant.tonal : AppButtonVariant.outlined,
                size: AppButtonSize.s,
              ),
              if (filterCount > 0)
                PositionedDirectional(
                  top: -2,
                  end: -2,
                  child: AppBadge(count: filterCount, tone: AppBadgeTone.cart),
                ),
            ],
          ),
      ],
    );
  }
}

/// Чип полосы (C5/C6, UI-12-003, UI-12-010).
final class CatalogStripChip {
  const CatalogStripChip({
    required this.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.count,
    this.selected = false,
    this.chevron = false,
  });

  final String key;
  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final int? count;
  final bool selected;
  final bool chevron;
}

/// Горизонтальная полоса чипов 48.
class CatalogChipStrip extends StatelessWidget {
  const CatalogChipStrip({super.key, required this.chips, this.loading = false, this.padding});

  final List<CatalogStripChip> chips;
  final bool loading;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return SizedBox(
        height: 48,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: padding,
          child: Center(child: CategoryChip.skeletonStrip(context)),
        ),
      );
    }
    return SizedBox(
      height: 48,
      child: ListView.separated(
        key: const ValueKey<String>('catalog-chip-strip'),
        scrollDirection: Axis.horizontal,
        padding: padding,
        itemCount: chips.length,
        separatorBuilder: (BuildContext context, int i) => SizedBox(width: context.space.s2),
        itemBuilder: (BuildContext context, int i) {
          final CatalogStripChip ch = chips[i];
          return CategoryChip(
            key: ValueKey<String>('chip-${ch.key}'),
            label: ch.label,
            icon: ch.icon,
            count: ch.count,
            selected: ch.selected,
            trailingChevron: ch.chevron,
            onTap: ch.selected ? null : ch.onTap,
          );
        },
      ),
    );
  }
}

/// Активные фильтры (C7, UI-10-017): чипы `input` с крестиком + «Сбросить все».
class CatalogActiveFilters extends StatelessWidget {
  const CatalogActiveFilters({super.key, required this.filter, required this.onChanged, this.padding});

  final CatalogFilter filter;
  final ValueChanged<CatalogFilter> onChanged;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final CatalogFilter f = filter;
    final List<(String, String, CatalogFilter)> items = <(String, String, CatalogFilter)>[
      if (f.inStock == true) ('stock', l10n.filters_in_stock, rebuildFilter(f, inStock: null)),
      if (f.priceMin != null || f.priceMax != null)
        (
          'price',
          '${f.priceMin == null ? '' : PriceText.format(f.priceMin!)} — ${f.priceMax == null ? '' : PriceText.format(f.priceMax!)}',
          rebuildFilter(f, priceMin: null, priceMax: null),
        ),
      for (final String b in f.brands)
        ('brand-$b', b, rebuildFilter(f, brands: f.brands.where((String x) => x != b).toList())),
      for (final MapEntry<String, String> a in f.attrs.entries)
        ('attr-${a.key}', a.value, rebuildFilter(f, attrs: Map<String, String>.of(f.attrs)..remove(a.key))),
      if (f.favorite == true) ('fav', l10n.filters_favorites_only, rebuildFilter(f, favorite: null)),
      if (f.hasImage == true) ('img', l10n.filters_with_photo_only, rebuildFilter(f, hasImage: null)),
    ];
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      height: 48,
      child: ListView(
        key: const ValueKey<String>('catalog-active-filters'),
        scrollDirection: Axis.horizontal,
        padding: padding,
        children: <Widget>[
          for (final (String key, String label, CatalogFilter without) in items) ...<Widget>[
            CategoryChip(
              key: ValueKey<String>('active-filter-$key'),
              label: label,
              variant: CategoryChipVariant.input,
              onRemove: () => onChanged(without),
              removeLabel: l10n.ds_button_reset,
            ),
            SizedBox(width: context.space.s2),
          ],
          Center(
            child: AppButton(
              key: const ValueKey<String>('active-filters-reset'),
              label: l10n.filters_reset_all,
              onPressed: () => onChanged(CatalogFilterCodec.cleared(f)),
              variant: AppButtonVariant.text,
              size: AppButtonSize.s,
            ),
          ),
        ],
      ),
    );
  }
}
