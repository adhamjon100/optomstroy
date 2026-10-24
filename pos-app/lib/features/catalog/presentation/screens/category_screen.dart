// SCR-12 Категория / подкатегории (`/catalog/c/{categoryId}?view=&sort=&f=`, staff и customer; 02 ч. B).
//
// Имя класса, путь файла и параметры конструктора фиксированы основой маршрутов (routes.dart).
// Реализация — [CatalogWorkspace] в режиме `category`: крошки при глубине ≥ 2, полоса подкатегорий
// только при их наличии (CAT-009), «Категория больше не существует» для удалённой (UI-12-009).
import 'package:flutter/widgets.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_workspace.dart';

/// SCR-12 — Категория / подкатегории.
class CategoryScreen extends StatelessWidget {
  const CategoryScreen({required this.categoryId, this.view, this.sort, this.f, super.key});

  /// ID экрана по 02 §4.1.
  static const String screenId = 'SCR-12';

  /// ID категории (uuid).
  final String categoryId;

  /// Вид: `grid|list|compact`.
  final String? view;

  /// Сортировка — значение API.
  final String? sort;

  /// Сериализованные фильтры (navigation.md §3).
  final String? f;

  @override
  Widget build(BuildContext context) => KeyedSubtree(
    // Новая категория — новое состояние экрана (прокрутка, черновик фильтров).
    key: ValueKey<String>('category-$categoryId'),
    child: CatalogWorkspace(
      key: const ValueKey<String>('stub-$screenId'),
      mode: CatalogScreenMode.category,
      categoryId: categoryId,
      view: view,
      sort: sort,
      f: f,
    ),
  );
}
