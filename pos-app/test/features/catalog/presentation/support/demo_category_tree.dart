// Дерево категорий веб-демо и Windows-демо (`demo/catalog/design-catalog.json`, ADR-113: 8 корней, 33 подкатегории)
// для проверки иконок категорий (T-CAT-042; указание владельца 2026-11-07 (15 §5.6): иконка у каждой категории и
// подкатегории, как у корневых). Картинок нет (`imageUrl` пуст) — так видна именно иконка; число товаров
// синтетическое (у подкатегории 1 — она входит в ленту). Путь к файлу — от `pos-app`, где идёт `flutter test`.
import 'dart:convert';
import 'dart:io';

import 'package:optomstroy/features/catalog/domain/entities/category.dart';

/// Категория демо: id, название, id родителя (`null` — корень), есть ли картинка в данных демо.
typedef DemoCategory = ({String id, String name, String? parentId, bool hasImage});

/// Категории `design-catalog.json` в порядке файла: корень, затем его подкатегории.
List<DemoCategory> demoCategories() {
  final Map<String, dynamic> json =
      jsonDecode(File('../demo/catalog/design-catalog.json').readAsStringSync()) as Map<String, dynamic>;
  return <DemoCategory>[
    for (final Map<String, dynamic> root in (json['categories'] as List<dynamic>).cast<Map<String, dynamic>>()) ...[
      (id: root['id'] as String, name: root['name'] as String, parentId: null, hasImage: root['image'] != null),
      for (final Map<String, dynamic> sub
          in (root['subs'] as List<dynamic>? ?? const <dynamic>[]).cast<Map<String, dynamic>>())
        (
          id: sub['id'] as String,
          name: sub['name'] as String,
          parentId: root['id'] as String,
          hasImage: sub['image'] != null,
        ),
    ],
  ];
}

/// Дерево демо без картинок (см. заголовок файла).
CategoryTree demoCategoryTree() {
  final List<DemoCategory> all = demoCategories();
  int subsOf(String id) => all.where((DemoCategory c) => c.parentId == id).length;
  return CategoryTree.fromFlat(<Category>[
    for (int i = 0; i < all.length; i++)
      Category(
        id: all[i].id,
        name: all[i].name,
        parentId: all[i].parentId,
        productCount: all[i].parentId == null ? subsOf(all[i].id) : 1,
        sortOrder: i,
        hasChildren: all[i].parentId == null && subsOf(all[i].id) > 0,
      ),
  ]);
}
