// Иконка категории без картинки (указание владельца 2026-11-07 (15 §5.6): иконка у каждой категории и подкатегории,
// как у корневых; 03 §14.4): одно правило для колонки, ленты, «Все категории», главной клиента, списка SB и киоска —
// свой `iconKey` → своё название → то же у ближайшего предка, затем у следующего до корня → `category`. Картинка
// категории из данных — выше по приоритету (её рисует компонент DS); картинка родителя не подставляется. Дерева
// категорий дизайн-система не знает — предков даёт фича.
import 'package:flutter/widgets.dart';
import 'package:optomstroy/design_system/components/category_sidebar_item.dart';
import 'package:optomstroy/features/catalog/domain/entities/category.dart';

/// Иконка категории [c] с учётом предков. [path] — путь от корня до родителя [c] (`CategoryTree.pathTo(parent.id)`;
/// у корня — пусто); его считают один раз на набор (лента, раскрытый корень списка, лист), а не на каждую карточку.
/// Сама [c] в [path] не учитывается, если попала туда.
IconData categoryIcon(Category c, {List<Category> path = const <Category>[]}) => CategoryIcons.resolve(
  key: c.iconKey,
  name: c.name,
  ancestors: <CategoryIconSource>[
    for (final Category a in path.reversed)
      if (a.id != c.id) (key: a.iconKey, name: a.name),
  ],
);
