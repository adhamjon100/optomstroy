// Зона C SCR-10/11/12 (02 SCR-10.3 C1–C7, SCR-11 UI-11-003/004, SCR-12 UI-12-001…003): заголовок и
// «Найдено: N», `ViewModeSegmented`, `SortMenu`, «Фильтры» с бейджем, полоса чипов (подкатегории,
// подборки «Недавние»/«Избранное», «Все категории ›» на compact), активные фильтры; строка управления
// medium и шире по прототипу (ADR-112, ADR-114) — [CatalogToolbarRow]: «Новые», «Избранные», «Недавние»,
// «Найдено: N» | вид, сортировка, «Фильтры» — кнопки `ToolbarToggleButton` (глифы прототипа) и стиль `toolbar`;
// заголовок раздела — `catalogTitle 30/800`, крошки — только при глубине ≥ 3.
import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_badge.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/category_chip.dart';
import 'package:optomstroy/design_system/components/ds_glyph.dart';
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
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_filter_form.dart';

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

/// Заголовок контента: [крошки] → название раздела `catalogTitle 30/800 −0,4` (прототип, ADR-114: строка 36).
/// «Найдено: N» на medium+ — в строке управления ([CatalogToolbarRow]); на compact — здесь ([showFound]).
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
              style: context.text.catalogTitle.copyWith(color: c.textPrimary),
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

/// Хлебные крошки SCR-12 (UI-12-001): при глубине ≥ 3 (ADR-114: в дереве из 2 уровней путь видят плитка корня,
/// карточка «Все товары» ленты и заголовок «Каталог» колонки); корень крошек — весь каталог «Все товары».
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

/// Вид, сортировка, «Фильтры». [toolbarStyle] — строка управления SCR-10/11/12 на medium+ (прототип, ADR-114):
/// `ViewModeSegmented` и `SortMenu` в стиле `toolbar`, «Фильтры» — `ToolbarToggleButton` с воронкой прототипа и
/// бейджем (подсвечена при открытой панели или активных фильтрах). SCR-50 и compact — прежний стиль.
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
    this.runAlignEnd = false,
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

  /// Кнопки, перенесённые на вторую строку, — тоже у правого края (SCR-50 «Все товары», 02 SCR-50.2); SCR-10/11/12 —
  /// как прежде, от начала строки.
  final bool runAlignEnd;

  /// Зазор между видом, сортировкой и «Фильтрами» в стиле строки управления (прототип: `gap: 10px`).
  static double gap(BuildContext context) => CatalogToolbarRow.itemGap(context); // money-double: allow — UI lp

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
        runSpacing: CatalogToolbarRow.runGap,
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
              glyph: DsGlyphKind.filter,
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
      alignment: runAlignEnd ? WrapAlignment.end : WrapAlignment.start,
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
    this.glyph,
    this.tooltip,
    this.semanticLabel,
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

  /// Иконка выбранного — для совместимости (`ToolbarToggleButton` прототипа рисует контур в обоих состояниях).
  final IconData? selectedIcon;

  /// Глиф прототипа у кнопки строки управления (часы «Новые», звезда «Избранные»); важнее [icon].
  final DsGlyphKind? glyph;

  /// Подсказка кнопки строки управления («Избранные, 12 товаров» — число, которое прежде показывала плитка колонки;
  /// паритет функций ADR-114); `null` — без подсказки (у кнопки без подписи — подпись).
  final String? tooltip;

  /// Подпись для screen reader у кнопки строки управления; `null` — [label].
  final String? semanticLabel;
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
            // «Сбросить все» — ссылка 14/500 `link` в цели 48, как «Сбросить фильтры» панели (02 П.3 п. 4, ADR-114 п. 5;
            // ревью V-03).
            child: CatalogFilterResetLink(
              key: const ValueKey<String>('active-filters-reset'),
              label: l10n.filters_reset_all,
              onTap: () => onChanged(CatalogFilterCodec.cleared(f)),
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

/// Строка управления над списком (прототип, ADR-112, ADR-114) — один `Wrap` (`spaceBetween`; между группами 16 по
/// горизонтали и 10 по вертикали): слева кнопки-переключатели «Новые», «Избранные», «Недавние» (+ «Очистить») и
/// «Найдено: N» ([found]); справа вид «Сетка / Список / Компакт», сортировка и «Фильтры» ([controls]); внутри групп —
/// зазор 10. Раскладка по ширине, от полной к узкой: все подписи в одну линию; «Недавние»
/// ([CatalogStripChip.collapsible]; подборка приложения, в прототипе её нет) — иконкой с тултипом (окно 1280: линия
/// остаётся одна, как в прототипе); не помещается и так — правая группа переносится на свою линию от левого края с
/// подписями (прототип: ширина контента < 1033, окно 1024); и на своей линии не помещается — вид иконками (без обрезки
/// и горизонтальной прокрутки). Ширина оценивается до раскладки (`estimateWidth` компонентов), без лишнего кадра.
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

  /// Зазор внутри группы (прототип: `gap: 10px`).
  static double itemGap(BuildContext context) => _itemGap; // money-double: allow — геометрия UI (lp)

  static const double _itemGap = 10; // money-double: allow — геометрия UI (lp)

  /// Зазор между группами (прототип: `gap: 10px 16px` — 16 по горизонтали).
  static double groupGap(BuildContext context) => context.space.s4; // money-double: allow — геометрия UI (lp)

  /// Зазор между линиями: прототип `gap: 10px 16px` — 10 по вертикали между видимыми кнопками; у нас кнопки 40 и
  /// сегмент 42 стоят в целях 48 (поля 4 и 3), поэтому между линиями 3 — видимый зазор 10.
  static const double runGap = 3; // money-double: allow — геометрия UI (lp)

  @override
  Widget build(BuildContext context) {
    final CatalogPresetBarData? p = presets;
    final double gap = itemGap(context); // money-double: allow — геометрия UI (lp)
    // «Найдено: N» — `meta 13/400`, поле слева 4 (у [FoundCountText] стиля `toolbar`), по центру линии.
    final Widget? foundText = showFound
        ? ConstrainedBox(
            constraints: const BoxConstraints(minHeight: ToolbarToggleButton.target),
            child: Align(
              widthFactor: 1,
              child: FoundCountText(key: const ValueKey<String>('catalog-found'), text: found, toolbar: true),
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
            runSpacing: runGap,
            children: <Widget>[
              if (p != null)
                for (final CatalogStripChip ch in p.chips)
                  ToolbarToggleButton(
                    key: ValueKey<String>('chip-${ch.key}'),
                    label: ch.label,
                    icon: ch.icon,
                    selectedIcon: ch.selectedIcon,
                    glyph: ch.glyph,
                    tooltip: ch.tooltip,
                    semanticLabel: ch.semanticLabel,
                    selected: ch.selected,
                    enabled: ch.enabled,
                    showLabel: !iconOnly(ch, collapse),
                    onTap: ch.selected && !ch.reselect ? null : ch.onTap,
                  ),
              if (p != null && p.clearRecentLabel != null)
                // «Очистить» — ссылка `link`, как «Сбросить все» (ADR-114 п. 5; ревью V-03).
                CatalogFilterResetLink(
                  key: const ValueKey<String>('catalog-recent-clear'),
                  label: p.clearRecentLabel!,
                  onTap: p.onClearRecent,
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
                    withIcon: ch.icon != null || ch.glyph != null,
                    showLabel: !iconOnly(ch, collapse),
                  ) +
                  gap;
            }
            if (p.clearRecentLabel != null) {
              width += CatalogFilterResetLink.estimateWidth(context, p.clearRecentLabel!) + gap;
            }
          }
          if (showFound) {
            width += _foundWidth(context);
          } else if (width > 0) {
            width -= gap;
          }
          return width;
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
        final double between = groupGap(context); // money-double: allow — геометрия UI (lp)
        final bool collapsible = p?.chips.any((CatalogStripChip ch) => iconOnly(ch, true)) ?? false;
        bool collapse = false;
        final bool showText;
        if (presetsWidth(false) + between + controlsWidth(true) <= width) {
          showText = true;
        } else if (collapsible && presetsWidth(true) + between + controlsWidth(true) <= width) {
          // Окно 1280: «Недавние» — иконкой, подписи вида видны, линия одна (как в прототипе).
          collapse = true;
          showText = true;
        } else {
          // Перенос правой группы на свою линию от левого края (прототип, окно 1024) — с подписями, пока она с ними
          // помещается; левая группа на своей линии — «Недавние» иконкой, только если иначе не помещается.
          collapse = collapsible && presetsWidth(false) > width;
          showText = controlsWidth(true) <= width;
        }
        return Wrap(
          key: const ValueKey<String>('catalog-toolbar'),
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: between,
          runSpacing: runGap,
          children: <Widget>[?presetGroup(collapse), controls(showText)],
        );
      },
    );
  }

  /// Ширина «Найдено: N» с полем слева 4 (до раскладки; без числа — по скелетону 120).
  double _foundWidth(BuildContext context) => // money-double: allow — геометрия UI (lp)
  found == null || found!.isEmpty
      ? 120
      : FoundCountText.toolbarStartPadding + dsTextWidth(context, found!, context.text.meta);
}
