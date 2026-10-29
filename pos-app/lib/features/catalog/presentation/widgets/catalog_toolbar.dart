// Зона C SCR-10/11/12 (02 SCR-10.3 C1–C7, SCR-11 UI-11-003/004, SCR-12 UI-12-001…003): заголовок и
// «Найдено: N», `ViewModeSegmented`, `SortMenu`, «Фильтры» с бейджем, полоса чипов (подкатегории,
// подборки «Недавние»/«Избранное», «Все категории ›» на compact), активные фильтры; строка управления
// medium и шире по прототипу 2026-10-29 (ADR-112) — [CatalogToolbarRow]: «Новые», «Избранные», «Недавние»,
// «Найдено: N» | вид, сортировка, «Фильтры» — кнопки `ToolbarToggleButton` и стиль `toolbar`.
import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_badge.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/category_chip.dart';
import 'package:optomstroy/design_system/components/found_count_text.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/sort_menu.dart';
import 'package:optomstroy/design_system/components/toolbar_toggle_button.dart';
import 'package:optomstroy/design_system/components/view_mode_segmented.dart';
import 'package:optomstroy/design_system/layout/text_measure.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/category.dart';
import 'package:optomstroy/features/catalog/presentation/state/catalog_filter_codec.dart';

/// Геометрия UI в lp (не деньги).
typedef _Lp = double; // money-double: allow — геометрия UI (lp)

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

/// Подпись текущей сортировки («По названию А–Я»).
String catalogSortLabel(AppLocalizations l10n, CatalogSort sort, {required bool search}) {
  final List<SortMenuOption<CatalogSort>> options = catalogSortOptions(l10n, search: search);
  return options.firstWhere((SortMenuOption<CatalogSort> o) => o.value == sort, orElse: () => options.first).label;
}

/// Заголовок контента: [крошки] → название раздела `h1 700` (прототип 2026-10-29). «Найдено: N» на medium+ — в
/// строке управления ([CatalogToolbarRow]); на compact — здесь ([showFound]).
class CatalogTitleBlock extends StatelessWidget {
  const CatalogTitleBlock({
    super.key,
    required this.title,
    required this.found,
    this.breadcrumbs,
    this.compact = false,
    this.showFound = true,
  });

  /// `null` — скелетон.
  final String? title;
  final String? found;
  final Widget? breadcrumbs;
  final bool compact;

  /// Показать «Найдено: N» под заголовком (compact; на medium+ счётчик — в строке управления).
  final bool showFound;

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
              style: context.text.h1.copyWith(fontWeight: FontWeight.w700, color: c.textPrimary),
            ),
          ),
        if (showFound) ...<Widget>[
          if (!compact) SizedBox(height: context.space.s1),
          FoundCountText(key: const ValueKey<String>('catalog-found'), text: found),
        ],
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

/// Вид, сортировка, «Фильтры». [toolbarStyle] — строка управления SCR-10/11/12 на medium+ (прототип 2026-10-29):
/// `ViewModeSegmented` и `SortMenu` в стиле `toolbar`, «Фильтры» — `ToolbarToggleButton` с бейджем (подсвечена при
/// открытой панели или активных фильтрах). SCR-50 и compact — прежний стиль.
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
    this.toolbarStyle = false,
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

  /// Стиль строки управления medium+.
  final bool toolbarStyle;

  /// Зазор между видом, сортировкой и «Фильтрами» в стиле строки управления (прототип 10).
  static double gap(BuildContext context) => context.space.s2; // money-double: allow — геометрия UI (lp)

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final List<SortMenuOption<CatalogSort>> options = catalogSortOptions(l10n, search: searchMode);
    final String sortLabel = options
        .firstWhere((SortMenuOption<CatalogSort> o) => o.value == sort, orElse: () => options.first)
        .label;
    if (toolbarStyle && !compact) {
      return Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: gap(context),
        runSpacing: context.space.s1,
        children: <Widget>[
          ViewModeSegmented(
            value: view,
            onChanged: onView,
            showText: showViewText,
            style: ViewModeSegmentedStyle.toolbar,
            labels: <ProductViewMode, String>{
              ProductViewMode.grid: l10n.catalog_view_grid,
              ProductViewMode.list: l10n.catalog_view_list,
              ProductViewMode.compact: l10n.catalog_view_compact,
            },
          ),
          IntrinsicWidth(
            child: SortMenu<CatalogSort>(
              key: const ValueKey<String>('catalog-sort'),
              options: options,
              selected: sort,
              onSelected: onSort,
              semanticLabel: sortLabel,
              sheetTitle: sortLabel,
              style: SortMenuStyle.toolbar,
            ),
          ),
          if (onFilters != null)
            ToolbarToggleButton(
              key: const ValueKey<String>('catalog-filters-button'),
              label: l10n.catalog_filters_button,
              icon: Icons.filter_alt_outlined,
              selectedIcon: Icons.filter_alt_rounded,
              selected: filtersOpen || filterCount > 0,
              badgeCount: filterCount,
              onTap: onFilters,
            ),
        ],
      );
    }
    // Wrap, а не Row: в узкой колонке (открыта FilterPanel) кнопки переносятся, а не выходят за край. Кнопки с
    // целью 48 центрируют себя (`Center`) — `IntrinsicWidth` держит их по содержимому, а не по ширине строки.
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: context.space.s3,
      runSpacing: context.space.s1,
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
        IntrinsicWidth(
          child: SortMenu<CatalogSort>(
            key: const ValueKey<String>('catalog-sort'),
            options: options,
            selected: sort,
            onSelected: onSort,
            iconOnly: compact,
            semanticLabel: sortLabel,
            sheetTitle: sortLabel,
          ),
        ),
        if (onFilters == null)
          ...<Widget>[]
        else if (compact)
          IntrinsicWidth(
            child: AppIconButton(
              key: const ValueKey<String>('catalog-filters-button'),
              icon: Icons.filter_list_rounded,
              semanticLabel: l10n.catalog_filters_button,
              tooltip: l10n.catalog_filters_button,
              onPressed: onFilters,
              badge: filterCount > 0 ? AppBadge(count: filterCount, tone: AppBadgeTone.cart) : null,
            ),
          )
        else
          IntrinsicWidth(
            child: Stack(
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
    this.selectedIcon,
    this.count,
    this.selected = false,
    this.chevron = false,
    this.enabled = true,
    this.reselect = false,
    this.collapsible = false,
  });

  final String key;
  final String label;
  final VoidCallback onTap;
  final IconData? icon;

  /// Иконка выбранного (залитая) — для кнопок строки управления (`ToolbarToggleButton`).
  final IconData? selectedIcon;
  final int? count;
  final bool selected;
  final bool chevron;

  /// Доступен (недоступный — `disabled`, тап не принимается).
  final bool enabled;

  /// Выбранный чип нажимается (переключатель подборки; корень, когда открыта его подкатегория).
  final bool reselect;

  /// В узкой строке управления — только иконка с тултипом (подборка «Недавние»; [CatalogToolbarRow]).
  final bool collapsible;
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
            enabled: ch.enabled,
            onTap: ch.selected && !ch.reselect ? null : ch.onTap,
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
              // Сброс — текстовая кнопка `primaryText` (ссылки — `primaryText`, ядро §24.1, DS-098).
              variant: AppButtonVariant.text,
              size: AppButtonSize.s,
            ),
          ),
        ],
      ),
    );
  }
}

/// Подборки панели управления: чипы-переключатели и действие «Очистить» для «Недавних».
final class CatalogPresetBarData {
  const CatalogPresetBarData({required this.chips, this.clearRecentLabel, this.onClearRecent});

  final List<CatalogStripChip> chips;

  /// «Очистить» (показывается при выбранной подборке «Недавние»); `null` — нет.
  final String? clearRecentLabel;

  /// `null` при показанной подписи — действие недоступно (список пуст).
  final VoidCallback? onClearRecent;
}

/// Строка управления над списком (прототип 2026-10-29, ADR-112) — один `Wrap` (`spaceBetween`, между группами 16):
/// слева кнопки-переключатели «Новые», «Избранные», «Недавние» (+ «Очистить») и «Найдено: N» ([found]); справа вид
/// «Сетка / Список / Компакт», сортировка и «Фильтры» ([controls]); внутри групп — зазор 8. Раскладка по ширине, от
/// полной к узкой: все подписи в одну линию; «Недавние» ([CatalogStripChip.collapsible]) — иконкой с тултипом, подписи
/// вида остаются (окно 1280); вид — иконками; не помещается и так — правая группа переносится на вторую линию с
/// подписями (без обрезки и горизонтальной прокрутки). Ширина оценивается до раскладки (`estimateWidth`
/// компонентов), без лишнего кадра.
class CatalogToolbarRow extends StatelessWidget {
  const CatalogToolbarRow({
    super.key,
    required this.presets,
    required this.controls,
    required this.viewLabels,
    required this.sortLabel,
    required this.filtersLabel,
    this.found,
    this.showFound = true,
    this.filterCount = 0,
  });

  final CatalogPresetBarData? presets;

  /// Вид/сортировка/фильтры с подписями вида или без.
  final Widget Function(bool showViewText) controls;
  final List<String> viewLabels;
  final String sortLabel;
  final String filtersLabel;

  /// «Найдено: N товаров»; `null` — скелетон.
  final String? found;

  /// Показать «Найдено: N» в строке (medium+).
  final bool showFound;

  /// Число активных фильтров (бейдж «Фильтры» — для оценки ширины).
  final int filterCount;

  /// Зазор внутри группы (прототип 10).
  static double itemGap(BuildContext context) => context.space.s2; // money-double: allow — геометрия UI (lp)

  /// Зазор между группами (прототип 16).
  static double groupGap(BuildContext context) => context.space.s4; // money-double: allow — геометрия UI (lp)

  @override
  Widget build(BuildContext context) {
    final CatalogPresetBarData? p = presets;
    final double gap = itemGap(context); // money-double: allow — геометрия UI (lp)
    final Widget? foundText = showFound
        ? ConstrainedBox(
            constraints: const BoxConstraints(minHeight: ToolbarToggleButton.target),
            child: Padding(
              padding: EdgeInsetsDirectional.only(start: context.space.s1),
              child: Align(
                widthFactor: 1,
                child: FoundCountText(key: const ValueKey<String>('catalog-found'), text: found, toolbar: true),
              ),
            ),
          )
        : null;
    bool iconOnly(CatalogStripChip ch, bool collapse) => collapse && ch.collapsible && ch.icon != null;
    Widget? presetGroup(bool collapse) => p == null && foundText == null
        ? null
        : Wrap(
            key: const ValueKey<String>('catalog-presets'),
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: gap,
            runSpacing: context.space.s1,
            children: <Widget>[
              if (p != null)
                for (final CatalogStripChip ch in p.chips)
                  ToolbarToggleButton(
                    key: ValueKey<String>('chip-${ch.key}'),
                    label: ch.label,
                    icon: ch.icon,
                    selectedIcon: ch.selectedIcon,
                    selected: ch.selected,
                    enabled: ch.enabled,
                    showLabel: !iconOnly(ch, collapse),
                    onTap: ch.selected && !ch.reselect ? null : ch.onTap,
                  ),
              if (p != null && p.clearRecentLabel != null)
                AppButton(
                  key: const ValueKey<String>('catalog-recent-clear'),
                  label: p.clearRecentLabel!,
                  onPressed: p.onClearRecent,
                  variant: AppButtonVariant.text,
                  size: AppButtonSize.s,
                ),
              ?foundText,
            ],
          );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        _Lp presetsWidth(bool collapse) {
          _Lp width = 0;
          if (p != null) {
            for (final CatalogStripChip ch in p.chips) {
              width +=
                  ToolbarToggleButton.estimateWidth(
                    context,
                    ch.label,
                    withIcon: ch.icon != null,
                    showLabel: !iconOnly(ch, collapse),
                  ) +
                  gap;
            }
            if (p.clearRecentLabel != null) {
              width += AppButton.estimateWidth(context, p.clearRecentLabel!, size: AppButtonSize.s) + gap;
            }
          }
          if (showFound) {
            width += _foundWidth(context) + context.space.s1;
          }
          return width + groupGap(context);
        }

        double controlsWidth(bool text) => // money-double: allow — геометрия UI (lp)
            ViewModeSegmented.estimateWidth(
              context,
              viewLabels,
              showText: text,
              style: ViewModeSegmentedStyle.toolbar,
            ) +
            CatalogToolbarControls.gap(context) * 2 +
            SortMenu.estimateWidth(context, sortLabel, style: SortMenuStyle.toolbar) +
            ToolbarToggleButton.estimateWidth(context, filtersLabel, withBadge: filterCount > 0);
        final double width = box.maxWidth; // money-double: allow — геометрия UI (lp)
        final bool collapsible = p?.chips.any((CatalogStripChip ch) => iconOnly(ch, true)) ?? false;
        bool collapse = false;
        final bool showText;
        if (presetsWidth(false) + controlsWidth(true) <= width) {
          showText = true;
        } else if (collapsible && presetsWidth(true) + controlsWidth(true) <= width) {
          // Окно 1280: «Недавние» — иконкой, подписи вида видны.
          collapse = true;
          showText = true;
        } else if (presetsWidth(collapsible) + controlsWidth(false) <= width) {
          collapse = collapsible;
          showText = false;
        } else {
          // Перенос правой группы: подписи, пока она с ними не шире области.
          showText = controlsWidth(true) <= width;
        }
        return Wrap(
          key: const ValueKey<String>('catalog-toolbar'),
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: groupGap(context),
          runSpacing: context.space.s3,
          children: <Widget>[?presetGroup(collapse), controls(showText)],
        );
      },
    );
  }

  /// Ширина «Найдено: N» (до раскладки; без числа — по скелетону 120).
  double _foundWidth(BuildContext context) => // money-double: allow — геометрия UI (lp)
      found == null || found!.isEmpty ? 120 : dsTextWidth(context, found!, context.text.label);
}
