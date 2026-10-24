// Путь категории товара для шапки SCR-14 (02 SCR-14.2 compact: название категории; SCR-14.3 A2 UI-14-017 expanded:
// крошки «Каталог › Смесители › Для кухни», тап по уровню → `go /catalog/c/{categoryId}`). Дерево — из кэша
// каталога (офлайн тоже), пустой кэш — `GET /catalog/categories`; дерева нет — путь пуст (только «Каталог»).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/domain/entities/category.dart';
import 'package:optomstroy/features/catalog/domain/repositories/catalog_repository.dart';

/// Путь от корня до категории [categoryId]; пусто — категории нет в дереве или дерево недоступно.
final productCategoryPathProvider = FutureProvider.autoDispose.family<List<Category>, String>((
  Ref ref,
  String categoryId,
) async {
  final CatalogRepository repo = ref.read(catalogRepositoryProvider);
  CategoryTree? tree = (await repo.cachedCategories()).valueOrNull;
  if (tree == null || tree.isEmpty) tree = (await repo.categories()).valueOrNull;
  return tree?.pathTo(categoryId) ?? const <Category>[];
});
