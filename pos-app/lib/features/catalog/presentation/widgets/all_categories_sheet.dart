// Лист «Все категории» (02 SCR-12 UI-12-006, UI-12-010; compact/medium): сетка `CategoryTile`
// (3 колонки на compact, 4–5 на medium, зазор 12) с изображением 1С или иконкой и счётчиком.
// Фото товара как изображение категории не используется (CAT-009). Тап — переход, лист закрывается.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/category_tile.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/catalog/domain/entities/category.dart';
import 'package:optomstroy/features/catalog/presentation/providers/category_tree_provider.dart';

/// Показать лист; результат — выбранная категория.
Future<Category?> showAllCategoriesSheet(BuildContext context, {String? selectedId, String? parentId}) {
  final AppLocalizations l10n = AppLocalizations.of(context);
  return AppBottomSheet.show<Category>(
    context,
    title: l10n.category_all_categories,
    variant: AppBottomSheetVariant.fullHeight,
    body: AllCategoriesGrid(selectedId: selectedId, parentId: parentId),
  );
}

class AllCategoriesGrid extends ConsumerWidget {
  const AllCategoriesGrid({super.key, this.selectedId, this.parentId});

  final String? selectedId;

  /// Показать детей этой категории (иначе — корни).
  final String? parentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final CategoryTreeState tree = ref.watch(categoryTreeProvider);
    final int cols = context.windowClass == WindowClass.compact ? 3 : 5;
    final Category? parent = parentId == null ? null : tree.tree?.find(parentId!);
    final List<Category> nodes = parent?.children.isNotEmpty ?? false
        ? parent!.children
        : (tree.tree?.roots ?? const <Category>[]);
    final double gap = context.space.s3; // money-double: allow — геометрия UI (lp)
    if (tree.tree == null && tree.loading) {
      return GridView.count(
        crossAxisCount: cols,
        mainAxisSpacing: gap,
        crossAxisSpacing: gap,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        children: <Widget>[for (int i = 0; i < cols * 2; i++) const SkeletonBox(height: 96)],
      );
    }
    return GridView(
      key: const ValueKey<String>('all-categories-grid'),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        mainAxisSpacing: gap,
        crossAxisSpacing: gap,
        mainAxisExtent: 148,
      ),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: <Widget>[
        for (final Category c in nodes)
          CategoryTile(
            key: ValueKey<String>('category-tile-${c.id}'),
            label: c.name,
            countLabel: '${c.productCount}',
            imageUrl: c.imageUrl,
            iconKey: c.iconKey,
            selected: c.id == selectedId,
            semanticLabel: l10n.category_tile_a11y(c.productCount, c.name),
            onTap: () => Navigator.of(context).pop(c),
          ),
      ],
    );
  }
}
