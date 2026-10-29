// Сайдбар SCR-10/12 (зона B, 02 SCR-10.3 B2–B6). Два вида:
// - [CatalogSidebarLayout.list] (SCR-50; `customer` на SCR-11/12 expanded/large — D6): «Категории товаров» → меню
//   категорий-карточек `CategorySidebarItem` со счётчиками (раскрытие 1 уровня), «★ Избранное N», «Недавние товары ·
//   Очистить» (до 5);
// - [CatalogSidebarLayout.tiles] (SCR-10/11/12 на medium и шире, прототип 2026-10-29, ADR-112): колонка 132 на фоне
//   страницы — «Каталог» (h3 700) → вертикальные плитки `CategoryTile.sidebar` (≥ 88) корневых категорий настоящего
//   дерева (изображение категории или иконка по смыслу названия) с числом товаров, выбранная — корень пути текущей
//   категории; «★ Избранное N» (SCR-40); «Недавние» — до 5 миниатюр (тап — SCR-14, название в тултипе) и «Очистить».
//   Подкатегории — лента над списком.
// Оба вида сворачиваются кнопкой внизу колонки ([CatalogSidebar.onToggleCollapsed], настройка пользователя
// `sidebarCollapsed`; паритет функций ADR-112): свёрнутая колонка 72 — только изображения или иконки с тултипами и
// подписями `Semantics` по названию и числу товаров, «★ Избранное» — иконкой с тултипом, «Недавние» скрыты.
// Плитки разделов роли (B1) — у оболочки `AdaptiveScaffold` (EQ-CAT-08).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_section_header.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/category_sidebar_item.dart';
import 'package:optomstroy/design_system/components/category_tile.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/product_image.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/catalog/domain/entities/category.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/catalog/presentation/providers/category_tree_provider.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_formats.dart';

/// Недавние товары для блока сайдбара (B5; `GET /catalog/products/recent?limit=5`).
final catalogRecentProductsProvider = FutureProvider.autoDispose<List<RecentProduct>>((ref) async {
  final CatalogShelfPort? port = ref.watch(catalogShelfPortProvider);
  if (port == null) {
    return const <RecentProduct>[];
  }
  try {
    final Result<List<RecentProduct>> r = await port.recentProducts();
    return r.valueOrNull ?? const <RecentProduct>[];
  } on Object {
    return const <RecentProduct>[];
  }
});

/// Вид сайдбара.
enum CatalogSidebarLayout {
  /// Строки-карточки со счётчиками, «Избранное», «Недавние товары» (SCR-50).
  list,

  /// Вертикальные плитки корневых категорий + «Избранное» (экран выбора товаров, expanded).
  tiles,
}

class CatalogSidebar extends ConsumerStatefulWidget {
  const CatalogSidebar({
    super.key,
    required this.selectedCategoryId,
    required this.onCategory,
    required this.onFavorites,
    this.onRecentProduct,
    this.onClearRecent,
    this.collapsed = false,
    this.onToggleCollapsed,
    this.layout = CatalogSidebarLayout.list,
  });

  /// Выбранная категория (SCR-12) и её предки раскрываются.
  final String? selectedCategoryId;
  final ValueChanged<Category> onCategory;
  final VoidCallback onFavorites;

  /// Недавние товары (тап — SCR-14) и «Очистить».
  final ValueChanged<String>? onRecentProduct;
  final Future<void> Function()? onClearRecent;

  /// Свёрнутый сайдбар 72 (только изображения).
  final bool collapsed;

  /// Свернуть / развернуть колонку (кнопка внизу колонки); `null` — кнопки нет.
  final VoidCallback? onToggleCollapsed;

  /// Ключ кнопки «Свернуть / Развернуть» (тесты).
  static const Key toggleKey = ValueKey<String>('catalog-sidebar-toggle');

  /// Вид.
  final CatalogSidebarLayout layout;

  /// Ширина колонки плиток (medium и шире; прототип 2026-10-29 — `DsBreakpoints.catalogColumn` 132).
  static const double tilesWidth = DsBreakpoints.catalogColumn; // money-double: allow — геометрия UI (lp)

  /// Ширина свёрнутой колонки (`DsBreakpoints.sidebarCollapsed` 72).
  static const double collapsedWidth = DsBreakpoints.sidebarCollapsed; // money-double: allow — геометрия UI (lp)

  @override
  ConsumerState<CatalogSidebar> createState() => _CatalogSidebarState();
}

class _CatalogSidebarState extends ConsumerState<CatalogSidebar> {
  final Set<String> _expanded = <String>{};
  final Set<String> _collapsedByUser = <String>{};

  bool _isExpanded(Category c, List<Category> path) {
    if (_expanded.contains(c.id)) {
      return true;
    }
    return !_collapsedByUser.contains(c.id) && path.any((Category p) => p.id == c.id);
  }

  void _toggle(Category c, bool expanded) => setState(() {
    if (expanded) {
      _expanded.remove(c.id);
      _collapsedByUser.add(c.id);
    } else {
      _expanded.add(c.id);
      _collapsedByUser.remove(c.id);
    }
  });

  @override
  Widget build(BuildContext context) {
    if (widget.layout == CatalogSidebarLayout.tiles) {
      return _tiles(context);
    }
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final CategoryTreeState tree = ref.watch(categoryTreeProvider);
    final CatalogShelfPort? port = ref.watch(catalogShelfPortProvider);
    final List<Category> path = widget.selectedCategoryId == null || tree.tree == null
        ? const <Category>[]
        : tree.tree!.pathTo(widget.selectedCategoryId!);
    final bool collapsed = widget.collapsed;

    Widget item(Category cat, {required bool child}) {
      final bool expanded = _isExpanded(cat, path);
      return CategorySidebarItem(
        key: ValueKey<String>('sidebar-category-${cat.id}'),
        label: cat.name,
        count: cat.productCount,
        variant: child ? CategorySidebarItemVariant.child : CategorySidebarItemVariant.root,
        imageUrl: cat.imageUrl,
        iconKey: cat.iconKey,
        selected: cat.id == widget.selectedCategoryId,
        hasChildren: !collapsed && cat.hasChildren && cat.children.isNotEmpty,
        expanded: expanded,
        collapsed: collapsed,
        onTap: () => widget.onCategory(cat),
        onToggleExpanded: () => _toggle(cat, expanded),
        semanticLabel: l10n.category_tile_a11y(cat.productCount, cat.name),
      );
    }

    final List<Widget> categories = <Widget>[];
    if (tree.tree == null && tree.loading) {
      for (int i = 0; i < 6; i++) {
        categories.add(CategorySidebarItem.skeleton(context));
      }
    } else if (!tree.hasData && tree.failure != null) {
      final (String msg, String? _) = CatalogFormats.splitAction(l10n.category_error_title);
      categories.add(
        ErrorState.inline(message: msg, onRetry: () => unawaited(ref.read(categoryTreeProvider.notifier).refresh())),
      );
    } else {
      for (final Category root in tree.tree?.roots ?? const <Category>[]) {
        categories.add(item(root, child: false));
        if (!collapsed && _isExpanded(root, path)) {
          for (final Category ch in root.children) {
            categories.add(item(ch, child: true));
          }
        }
      }
    }

    final Widget menu = Container(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.all(context.radii.md),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < categories.length; i++) ...<Widget>[
            if (i > 0) Divider(height: 1, thickness: 1, color: c.border),
            categories[i],
          ],
        ],
      ),
    );

    return _withToggle(
      context,
      ListView(
        key: const ValueKey<String>('catalog-sidebar'),
        padding: EdgeInsets.all(collapsed ? context.space.s2 : context.space.s4),
        children: <Widget>[
          if (!collapsed) AppSectionHeader(title: l10n.catalog_sidebar_categories_title, padding: EdgeInsets.zero),
          menu,
          if (port != null) ...<Widget>[
            SizedBox(height: context.space.s4),
            _FavoritesCard(collapsed: collapsed, onTap: widget.onFavorites),
            if (!collapsed && widget.onRecentProduct != null && widget.onClearRecent != null) ...<Widget>[
              SizedBox(height: context.space.s4),
              _RecentBlock(onProduct: widget.onRecentProduct!, onClear: widget.onClearRecent!),
            ],
          ],
        ],
      ),
    );
  }

  /// Колонка с кнопкой «Свернуть / Развернуть» внизу (вне прокрутки — всегда видна).
  Widget _withToggle(BuildContext context, Widget list) {
    final VoidCallback? toggle = widget.onToggleCollapsed;
    if (toggle == null) {
      return list;
    }
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool collapsed = widget.collapsed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(child: list),
        Padding(
          padding: EdgeInsets.fromLTRB(
            collapsed ? context.space.s1 : context.space.s3,
            context.space.s1,
            context.space.s1,
            context.space.s2,
          ),
          child: Align(
            alignment: collapsed ? Alignment.center : AlignmentDirectional.centerStart,
            child: AppIconButton(
              key: CatalogSidebar.toggleKey,
              icon: collapsed ? Icons.keyboard_double_arrow_right_rounded : Icons.keyboard_double_arrow_left_rounded,
              semanticLabel: collapsed ? l10n.catalog_sidebar_expand : l10n.catalog_sidebar_collapse,
              onPressed: toggle,
            ),
          ),
        ),
      ],
    );
  }

  /// Колонка плиток (макет заказчика): корни дерева, выбранный — корень пути текущей категории; повторный тап
  /// по нему открывает корень, если показана его подкатегория (экран тот же — `go`, без перезагрузки).
  Widget _tiles(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final CategoryTreeState tree = ref.watch(categoryTreeProvider);
    final CatalogShelfPort? port = ref.watch(catalogShelfPortProvider);
    final bool collapsed = widget.collapsed;
    final String? selectedId = widget.selectedCategoryId;
    final List<Category> path = selectedId == null || tree.tree == null
        ? const <Category>[]
        : tree.tree!.pathTo(selectedId);
    final String? selectedRoot = path.isEmpty ? null : path.first.id;
    final double gap = context.space.s3; // money-double: allow — геометрия UI (lp)

    final List<Widget> tiles = <Widget>[];
    if (tree.tree == null && tree.loading) {
      for (int i = 0; i < 6; i++) {
        tiles.add(SkeletonBox(height: collapsed ? 48 : CategoryTile.sidebarMinHeight, radius: context.radii.md));
      }
    } else if (!tree.hasData && tree.failure != null) {
      // Колонка 132: ошибка — столбиком (иконка, текст, «Повторить»), строка `ErrorState.inline` не помещается.
      final (String msg, String? _) = CatalogFormats.splitAction(l10n.category_error_title);
      tiles.add(
        Column(
          key: const ValueKey<String>('sidebar-error'),
          children: <Widget>[
            Icon(Icons.error_outline_rounded, size: 24, color: c.error),
            SizedBox(height: context.space.s1),
            Text(
              msg,
              textAlign: TextAlign.center,
              style: context.text.caption.copyWith(color: c.textSecondary),
            ),
            AppButton(
              label: l10n.ds_button_retry,
              onPressed: () => unawaited(ref.read(categoryTreeProvider.notifier).refresh()),
              variant: AppButtonVariant.text,
              size: AppButtonSize.s,
            ),
          ],
        ),
      );
    } else {
      for (final Category root in tree.tree?.roots ?? const <Category>[]) {
        tiles.add(
          CategoryTile(
            key: ValueKey<String>('sidebar-category-${root.id}'),
            variant: CategoryTileVariant.sidebar,
            label: root.name,
            imageUrl: root.imageUrl,
            iconKey: root.iconKey,
            selected: root.id == selectedRoot,
            showLabel: !collapsed,
            // Число товаров — видимой пилюлей (паритет функций ADR-112; данные дерева категорий, без выдумок).
            countLabel: '${root.productCount}',
            semanticLabel: l10n.category_tile_a11y(root.productCount, root.name),
            onTap: () => widget.onCategory(root),
          ),
        );
      }
    }
    if (port != null) {
      final int favorites = ref.watch(catalogFavoriteIdsProvider).value?.length ?? 0;
      tiles
        ..add(Divider(height: gap, thickness: 1, color: c.border))
        ..add(
          CategoryTile(
            key: const ValueKey<String>('sidebar-favorites'),
            variant: CategoryTileVariant.sidebar,
            label: l10n.catalog_sidebar_favorites,
            icon: Icons.star_rounded,
            showLabel: !collapsed,
            // «★ Избранное N» — число избранных товаров пользователя (`catalogFavoriteIdsProvider`).
            countLabel: '$favorites',
            semanticLabel: '${l10n.catalog_sidebar_favorites}, $favorites',
            onTap: widget.onFavorites,
          ),
        );
      if (!collapsed && widget.onRecentProduct != null && widget.onClearRecent != null) {
        tiles.add(_RecentTiles(onProduct: widget.onRecentProduct!, onClear: widget.onClearRecent!));
      }
    }
    // Поля 16 / 20 / 16 / 24 (слева / сверху / справа / снизу): прототип 18 / 20 / 14 / 24 — сумма боковых 32
    // сохранена, плитка 100 lp, как в прототипе (колонка 132); свёрнутая — 8.
    return _withToggle(
      context,
      ListView(
        key: const ValueKey<String>('catalog-sidebar'),
        padding: collapsed
            ? EdgeInsets.all(context.space.s2)
            : EdgeInsets.fromLTRB(context.space.s4, context.space.s5, context.space.s4, context.space.s6),
        children: <Widget>[
          // «Каталог»: прототип 19/700 с обычным интервалом (строка 23) и отступом 14 — по шкале `h3` 20/700 в строку
          // 23 и отступ 14: первая плитка на 57 от верха колонки, как в прототипе (02 П.5).
          if (!collapsed)
            Padding(
              padding: EdgeInsetsDirectional.only(start: context.space.s1, bottom: context.space.s3 + 2),
              child: Semantics(
                header: true,
                child: Text(
                  l10n.category_breadcrumb_root,
                  key: const ValueKey<String>('sidebar-title'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.h3.copyWith(fontWeight: FontWeight.w700, height: 23 / 20, color: c.textPrimary),
                ),
              ),
            ),
          for (int i = 0; i < tiles.length; i++) ...<Widget>[if (i > 0) SizedBox(height: gap), tiles[i]],
        ],
      ),
    );
  }
}

class _FavoritesCard extends ConsumerWidget {
  const _FavoritesCard({required this.collapsed, required this.onTap});

  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final int count = ref.watch(catalogFavoriteIdsProvider).value?.length ?? 0;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.all(context.radii.md),
      ),
      clipBehavior: Clip.antiAlias,
      child: CategorySidebarItem(
        key: const ValueKey<String>('sidebar-favorites'),
        label: l10n.catalog_sidebar_favorites,
        count: count,
        variant: CategorySidebarItemVariant.favorites,
        collapsed: collapsed,
        onTap: onTap,
      ),
    );
  }
}

/// «Недавние» колонки плиток (паритет функций ADR-112: прежний блок «Недавние товары» сайдбара): до 5 последних
/// просмотренных товаров (`GET /catalog/products/recent?limit=5`) миниатюрами 48 по две в ряд, тап — SCR-14, название —
/// в тултипе и `Semantics`; «Очистить» — с подтверждением у вызывающего. Пусто — блока нет.
class _RecentTiles extends ConsumerWidget {
  const _RecentTiles({required this.onProduct, required this.onClear});

  final ValueChanged<String> onProduct;
  final Future<void> Function() onClear;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final AsyncValue<List<RecentProduct>> recent = ref.watch(catalogRecentProductsProvider);
    final List<RecentProduct> items = recent.value ?? const <RecentProduct>[];
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }
    final BorderRadius radius = BorderRadius.all(context.radii.sm);
    return Column(
      key: const ValueKey<String>('sidebar-recent'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Divider(height: context.space.s3, thickness: 1, color: c.border),
        Padding(
          padding: EdgeInsetsDirectional.only(start: context.space.s1, top: context.space.s1, bottom: context.space.s2),
          child: Semantics(
            header: true,
            child: Text(
              l10n.catalog_preset_recent,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.text.label.copyWith(fontWeight: FontWeight.w600, color: c.textPrimary),
            ),
          ),
        ),
        Wrap(
          spacing: context.space.s1,
          runSpacing: context.space.s1,
          children: <Widget>[
            for (final RecentProduct r in items.take(5))
              AppTooltip(
                message: r.product.name,
                child: Semantics(
                  button: true,
                  label: r.product.name,
                  excludeSemantics: true,
                  onTap: () => onProduct(r.product.id),
                  child: DsInteractive(
                    key: ValueKey<String>('sidebar-recent-${r.product.id}'),
                    onTap: () => onProduct(r.product.id),
                    builder: (BuildContext context, DsInteractionState s) => DsFocusRing(
                      visible: s.focused,
                      borderRadius: radius,
                      child: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: c.surface,
                          borderRadius: radius,
                          border: Border.all(color: s.hovered ? c.primaryContainerBorder : c.border),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: ProductImage(
                          url: r.product.primaryImage?.thumbUrl,
                          size: ProductImageSize.thumb,
                          dimension: 46,
                          fit: BoxFit.contain,
                          background: c.surface,
                          showPlaceholderLabel: false,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: AppButton(
            key: const ValueKey<String>('sidebar-recent-clear'),
            label: l10n.catalog_recent_clear,
            onPressed: () => unawaited(onClear()),
            variant: AppButtonVariant.text,
            size: AppButtonSize.s,
          ),
        ),
      ],
    );
  }
}

class _RecentBlock extends ConsumerWidget {
  const _RecentBlock({required this.onProduct, required this.onClear});

  final ValueChanged<String> onProduct;
  final Future<void> Function() onClear;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final AsyncValue<List<RecentProduct>> recent = ref.watch(catalogRecentProductsProvider);
    final List<RecentProduct> items = recent.value ?? const <RecentProduct>[];
    if (!recent.isLoading && items.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      key: const ValueKey<String>('sidebar-recent'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppSectionHeader(
          title: l10n.catalog_recent_title,
          actionLabel: l10n.catalog_recent_clear,
          onAction: items.isEmpty ? null : () => unawaited(onClear()),
          padding: EdgeInsets.zero,
        ),
        if (recent.isLoading && items.isEmpty)
          for (int i = 0; i < 3; i++)
            Padding(
              padding: EdgeInsets.symmetric(vertical: context.space.s1),
              child: const SkeletonBox(height: 32),
            )
        else
          for (final RecentProduct r in items.take(5))
            DsInteractive(
              key: ValueKey<String>('sidebar-recent-${r.product.id}'),
              onTap: () => onProduct(r.product.id),
              builder: (BuildContext context, DsInteractionState s) => Container(
                height: 40,
                color: s.hovered ? c.surfaceHover : Colors.transparent,
                child: Row(
                  children: <Widget>[
                    ProductImage(
                      url: r.product.primaryImage?.thumbUrl,
                      size: ProductImageSize.thumb,
                      dimension: 32,
                      fit: BoxFit.cover,
                      showPlaceholderLabel: false,
                      borderRadius: BorderRadius.all(context.radii.sm),
                    ),
                    SizedBox(width: context.space.s2),
                    Expanded(
                      child: Text(
                        r.product.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.label.copyWith(fontWeight: FontWeight.w500, color: c.textPrimary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}
