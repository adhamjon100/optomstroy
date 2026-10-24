// Категория и дерево категорий (`Category`, `CatalogCategoryNode`; SCR-10 сайдбар, SCR-12). Чистый Dart.

/// Категория со счётчиком товаров (`productCount` — значение сервера, Q-022).
final class Category {
  const Category({
    required this.id,
    required this.name,
    this.parentId,
    this.code,
    this.productCount = 0,
    this.sortOrder = 0,
    this.iconKey,
    this.imageUrl,
    this.hasChildren = false,
    this.children = const <Category>[],
    this.depth = 0,
  });

  final String id;
  final String? parentId;
  final String name;
  final String? code;
  final int productCount;
  final int sortOrder;

  /// Ключ иконки категории (03 §9, `CategorySidebarItem`).
  final String? iconKey;
  final String? imageUrl;
  final bool hasChildren;

  /// Подкатегории в порядке `sortOrder`, затем имени.
  final List<Category> children;

  /// Глубина узла (корень — 0).
  final int depth;

  bool get isRoot => parentId == null;

  Category copyWith({List<Category>? children, int? depth, bool? hasChildren}) => Category(
    id: id,
    name: name,
    parentId: parentId,
    code: code,
    productCount: productCount,
    sortOrder: sortOrder,
    iconKey: iconKey,
    imageUrl: imageUrl,
    hasChildren: hasChildren ?? this.hasChildren,
    children: children ?? this.children,
    depth: depth ?? this.depth,
  );
}

/// Дерево категорий с меткой данных (`asOf`, `snapshotVersion`).
final class CategoryTree {
  const CategoryTree({required this.roots, this.asOf, this.snapshotVersion});

  /// Строит дерево из плоского списка (по `parentId`); узел с неизвестным родителем — корень.
  factory CategoryTree.fromFlat(List<Category> flat, {DateTime? asOf, String? snapshotVersion}) {
    final byParent = <String?, List<Category>>{};
    final ids = {for (final c in flat) c.id};
    for (final c in flat) {
      final parent = c.parentId != null && ids.contains(c.parentId) ? c.parentId : null;
      (byParent[parent] ??= <Category>[]).add(c);
    }
    List<Category> build(String? parent, int depth, Set<String> seen) {
      final nodes = [...?byParent[parent]]
        ..sort((a, b) {
          final bySort = a.sortOrder.compareTo(b.sortOrder);
          return bySort != 0 ? bySort : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
      return [
        for (final n in nodes)
          if (!seen.contains(n.id))
            n.copyWith(
              depth: depth,
              children: build(n.id, depth + 1, {...seen, n.id}),
              hasChildren: n.hasChildren || (byParent[n.id]?.isNotEmpty ?? false),
            ),
      ];
    }

    return CategoryTree(roots: build(null, 0, <String>{}), asOf: asOf, snapshotVersion: snapshotVersion);
  }

  final List<Category> roots;
  final DateTime? asOf;
  final String? snapshotVersion;

  /// Все узлы в порядке обхода в глубину.
  Iterable<Category> get all sync* {
    Iterable<Category> walk(List<Category> nodes) sync* {
      for (final n in nodes) {
        yield n;
        yield* walk(n.children);
      }
    }

    yield* walk(roots);
  }

  /// Узел по id или `null`.
  Category? find(String id) {
    for (final c in all) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Путь от корня до узла (хлебные крошки SCR-12/SCR-14); пусто — узла нет.
  List<Category> pathTo(String id) {
    List<Category>? search(List<Category> nodes, List<Category> prefix) {
      for (final n in nodes) {
        final path = [...prefix, n];
        if (n.id == id) return path;
        final found = search(n.children, path);
        if (found != null) return found;
      }
      return null;
    }

    return search(roots, const <Category>[]) ?? const <Category>[];
  }

  bool get isEmpty => roots.isEmpty;
}
