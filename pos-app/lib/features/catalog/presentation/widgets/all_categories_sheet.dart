// Лист «Все категории» (02 SCR-12 UI-12-006, UI-12-010; compact/medium): сетка `CategoryTile`
// (3 колонки на compact, 4–5 на medium, зазор 12) с изображением 1С или иконкой и счётчиком (иконка — своя по
// `iconKey`/названию, у подкатегории без совпадения — ближайшего предка). Фото товара как изображение категории не
// используется (CAT-009). Тап — переход, лист закрывается.
// Колонок меньше (не меньше 2), если самое длинное слово подписи иначе не помещается в плитку
// (`CategoryTile.gridColumnsFor`), высота плитки растёт с масштабом текста, как на SCR-50 (03 §9.10; указание владельца
// 2026-11-18, 15 §5.8 — [ВЫВОД исполнителя]).
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
import 'package:optomstroy/features/catalog/presentation/widgets/category_icon.dart';

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
    final int maxCols = context.windowClass == WindowClass.compact ? 3 : 5;
    final Category? parent = parentId == null ? null : tree.tree?.find(parentId!);
    final bool showChildren = parent?.children.isNotEmpty ?? false;
    final List<Category> nodes = showChildren ? parent!.children : (tree.tree?.roots ?? const <Category>[]);
    // Предки детей [parent] — для иконки подкатегории без своей (путь считается один раз на лист).
    final List<Category> ancestors = showChildren ? tree.tree!.pathTo(parent!.id) : const <Category>[];
    final double gap = context.space.s3; // money-double: allow — геометрия UI (lp)
    // Высота плитки — как на SCR-50: 148 при обычном размере текста, крупный текст — выше на прирост подписи в 2 строки
    // и числа (56 lp при 1).
    final double /* money-double: allow — высота (lp) */ extent = 148 + MediaQuery.textScalerOf(context).scale(56) - 56;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        // Колонок меньше, если самое длинное слово иначе не помещается в плитку (CategoryTile.gridColumnsFor).
        final int cols = CategoryTile.gridColumnsFor(
          context,
          <String>[for (final Category c in nodes) c.name],
          width: box.maxWidth,
          gap: gap,
          maxColumns: maxCols,
        );
        final SliverGridDelegate grid = SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          mainAxisSpacing: gap,
          crossAxisSpacing: gap,
          mainAxisExtent: extent,
        );
        if (tree.tree == null && tree.loading) {
          return GridView(
            gridDelegate: grid,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: <Widget>[for (int i = 0; i < cols * 2; i++) SkeletonBox(height: extent)],
          );
        }
        return _grid(context, l10n, grid, nodes, ancestors);
      },
    );
  }

  Widget _grid(
    BuildContext context,
    AppLocalizations l10n,
    SliverGridDelegate grid,
    List<Category> nodes,
    List<Category> ancestors,
  ) {
    return GridView(
      key: const ValueKey<String>('all-categories-grid'),
      gridDelegate: grid,
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
            icon: categoryIcon(c, path: ancestors),
            selected: c.id == selectedId,
            semanticLabel: l10n.category_tile_a11y(c.productCount, c.name),
            onTap: () => Navigator.of(context).pop(c),
          ),
      ],
    );
  }
}
