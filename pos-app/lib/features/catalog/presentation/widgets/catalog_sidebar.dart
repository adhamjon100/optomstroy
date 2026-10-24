// Сайдбар SCR-10/12 (зона B, 02 SCR-10.3 B2–B6): «Категории товаров» → меню категорий-карточек
// `CategorySidebarItem` со счётчиками (раскрытие 1 уровня), «★ Избранное N», «Недавние товары ·
// Очистить» (до 5). Плитки разделов роли (B1) — у оболочки `AdaptiveScaffold` (EQ-CAT-08).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_section_header.dart';
import 'package:optomstroy/design_system/components/category_sidebar_item.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/product_image.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
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

class CatalogSidebar extends ConsumerStatefulWidget {
  const CatalogSidebar({
    super.key,
    required this.selectedCategoryId,
    required this.onCategory,
    required this.onFavorites,
    required this.onRecentProduct,
    required this.onClearRecent,
    this.collapsed = false,
  });

  /// Выбранная категория (SCR-12) и её предки раскрываются.
  final String? selectedCategoryId;
  final ValueChanged<Category> onCategory;
  final VoidCallback onFavorites;
  final ValueChanged<String> onRecentProduct;
  final Future<void> Function() onClearRecent;

  /// Свёрнутый сайдбар 72 (только изображения).
  final bool collapsed;

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

    return ListView(
      key: const ValueKey<String>('catalog-sidebar'),
      padding: EdgeInsets.all(collapsed ? context.space.s2 : context.space.s4),
      children: <Widget>[
        if (!collapsed) AppSectionHeader(title: l10n.catalog_sidebar_categories_title, padding: EdgeInsets.zero),
        menu,
        if (port != null) ...<Widget>[
          SizedBox(height: context.space.s4),
          _FavoritesCard(collapsed: collapsed, onTap: widget.onFavorites),
          if (!collapsed) ...<Widget>[
            SizedBox(height: context.space.s4),
            _RecentBlock(onProduct: widget.onRecentProduct, onClear: widget.onClearRecent),
          ],
        ],
      ],
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
