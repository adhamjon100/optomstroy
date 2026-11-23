// T-CAT-042 (unit): иконка у каждой категории и подкатегории (указание владельца 2026-11-07, дословно: «i chtobi u
// vsego kategorii i po kotegorii bila iconka kak na glavnih a to u nekotorih netu» (прочтение — 15 §5.6); 03 §14.4):
// правило `CategoryIcons.resolve` — свой `iconKey` → своё название (корень — начало слова, слова по порядку) → то же у
// ближайшего предка, затем выше → запасной `category`. Покрытие — на настоящих названиях: веб-демо и Windows-демо
// (`demo/catalog/design-catalog.json`), локальный стенд и fake 1С (`SyntheticCatalog`, pos-api), фикстуры тестов
// pos-app. Картинка категории из данных — выше по приоритету (её рисует компонент); здесь — только иконка.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/design_system/components/category_sidebar_item.dart';
import 'package:optomstroy/features/catalog/domain/entities/category.dart';

import '../features/catalog/presentation/support/catalog_fakes.dart' show categoryTree, designCategoryTree;
import '../features/catalog/presentation/support/demo_category_tree.dart';

/// Ожидаемая иконка каждой категории демо (41: 8 корней и 33 подкатегории) по правилу с предками.
const Map<String, IconData> _demoExpected = <String, IconData>{
  'Отопление': Icons.thermostat_rounded,
  'Радиаторы': Icons.thermostat_rounded,
  'Котлы': Icons.local_fire_department_rounded,
  'Тёплый пол': Icons.thermostat_rounded,
  'Трубы отопления': Icons.plumbing_rounded,
  'Сантехника': Icons.bathtub_rounded,
  'Унитазы': Icons.wc_rounded,
  'Раковины': Icons.wash_rounded,
  'Ванны': Icons.bathtub_rounded,
  'Душевые кабины': Icons.shower_rounded,
  'Инсталляции': Icons.wc_rounded,
  'Биде': Icons.wc_rounded,
  'Писсуары': Icons.wc_rounded,
  'Сифоны': Icons.plumbing_rounded,
  'Канализационные трубы и фитинги': Icons.water_damage_rounded,
  'Водоснабжение': Icons.water_drop_rounded,
  'Трубы ППР': Icons.plumbing_rounded,
  'Краны и вентили': Icons.plumbing_rounded,
  'Насосы': Icons.water_drop_rounded,
  'Фильтры': Icons.water_drop_rounded,
  'Электрика': Icons.electrical_services_rounded,
  'Кабель': Icons.cable_rounded,
  'Автоматы': Icons.electrical_services_rounded,
  'Розетки и выключатели': Icons.outlet_rounded,
  'Освещение': Icons.lightbulb_rounded,
  'Вентиляция': Icons.air_rounded,
  'Вентиляторы': Icons.air_rounded,
  'Воздуховоды': Icons.hvac_rounded,
  'Решётки': Icons.air_rounded,
  'Строительные материалы': Icons.foundation_rounded,
  'Сухие смеси': Icons.foundation_rounded,
  'Гипсокартон': Icons.layers_rounded,
  'Утеплитель': Icons.texture_rounded,
  'Инструменты': Icons.handyman_rounded,
  'Электроинструмент': Icons.construction_rounded,
  'Ручной инструмент': Icons.handyman_rounded,
  'Расходники': Icons.handyman_rounded,
  'Крепеж и фурнитура': Icons.hardware_rounded,
  'Саморезы': Icons.hardware_rounded,
  'Дюбели': Icons.hardware_rounded,
  'Анкеры': Icons.hardware_rounded,
};

/// Подкатегории демо, у которых по собственному названию иконки нет (смысл даёт родитель).
const Set<String> _demoByAncestor = <String>{'Фильтры', 'Автоматы', 'Решётки', 'Расходники'};

/// Дерево `SyntheticCatalog` (`pos-api/src/integrations/onec/synthetic-catalog.ts`, `ROOTS`): корень → подкатегории →
/// ожидаемая иконка; у подкатегорий с чётным индексом — вложенные «…: серия N» (там же, `c % 2 === 0`).
const List<(String, IconData, List<(String, IconData)>)> _synthetic = <(String, IconData, List<(String, IconData)>)>[
  (
    'Смесители',
    Icons.plumbing_rounded,
    <(String, IconData)>[
      ('Для кухни', Icons.plumbing_rounded),
      ('Для ванны', Icons.bathtub_rounded),
      ('Для раковины', Icons.wash_rounded),
      ('Душевые системы', Icons.shower_rounded),
      ('Комплектующие', Icons.plumbing_rounded),
    ],
  ),
  (
    'Санфаянс',
    Icons.bathtub_rounded,
    <(String, IconData)>[
      ('Унитазы', Icons.wc_rounded),
      ('Раковины', Icons.wash_rounded),
      ('Биде', Icons.wc_rounded),
      ('Инсталляции', Icons.wc_rounded),
    ],
  ),
  (
    'Трубы и фитинги',
    Icons.plumbing_rounded,
    <(String, IconData)>[
      ('Трубы ППР', Icons.plumbing_rounded),
      ('Фитинги ППР', Icons.plumbing_rounded),
      ('Металлопласт', Icons.plumbing_rounded),
      ('Канализация', Icons.water_damage_rounded),
    ],
  ),
  (
    'Отопление',
    Icons.thermostat_rounded,
    <(String, IconData)>[
      ('Радиаторы', Icons.thermostat_rounded),
      ('Котлы', Icons.local_fire_department_rounded),
      ('Насосы', Icons.water_drop_rounded),
      ('Терморегуляция', Icons.thermostat_rounded),
    ],
  ),
  (
    'Инструмент',
    Icons.handyman_rounded,
    <(String, IconData)>[
      ('Электроинструмент', Icons.construction_rounded),
      ('Ручной инструмент', Icons.handyman_rounded),
      ('Расходники', Icons.handyman_rounded),
    ],
  ),
  (
    'Электрика',
    Icons.electrical_services_rounded,
    <(String, IconData)>[
      ('Кабель', Icons.cable_rounded),
      ('Розетки и выключатели', Icons.outlet_rounded),
      ('Автоматы', Icons.electrical_services_rounded),
    ],
  ),
  (
    'Сухие смеси',
    Icons.foundation_rounded,
    <(String, IconData)>[
      ('Штукатурки', Icons.foundation_rounded),
      ('Плиточный клей', Icons.grid_on_rounded),
      ('Наливные полы', Icons.foundation_rounded),
    ],
  ),
  (
    'Плитка',
    Icons.grid_on_rounded,
    <(String, IconData)>[
      ('Настенная', Icons.grid_on_rounded),
      ('Напольная', Icons.grid_on_rounded),
      ('Керамогранит', Icons.grid_on_rounded),
    ],
  ),
  (
    'Крепёж',
    Icons.hardware_rounded,
    <(String, IconData)>[
      ('Саморезы', Icons.hardware_rounded),
      ('Дюбели', Icons.hardware_rounded),
      ('Анкеры', Icons.hardware_rounded),
    ],
  ),
  (
    'Ванны и душевые',
    Icons.bathtub_rounded,
    <(String, IconData)>[
      ('Ванны акриловые', Icons.bathtub_rounded),
      ('Душевые кабины', Icons.shower_rounded),
      ('Поддоны', Icons.shower_rounded),
    ],
  ),
];

/// Узлы синтетики, у которых по собственному названию иконки нет (смысл даёт предок).
const Set<String> _syntheticByAncestor = <String>{
  'Для кухни',
  'Для кухни: серия 1',
  'Комплектующие',
  'Комплектующие: серия 1',
  'Расходники',
  'Расходники: серия 1',
  'Автоматы',
  'Автоматы: серия 1',
  'Настенная',
  'Настенная: серия 1',
  'Напольная',
};

/// Иконка узла дерева с предками (как `categoryIcon` фичи): [path] — от корня до узла включительно.
IconData _inTree(List<Category> path) => CategoryIcons.resolve(
  key: path.last.iconKey,
  name: path.last.name,
  ancestors: <CategoryIconSource>[for (final Category a in path.reversed.skip(1)) (key: a.iconKey, name: a.name)],
);

void main() {
  group('T-CAT-042 иконка у каждой категории', () {
    test('веб-демо: все 41 категория `design-catalog.json` — ожидаемая иконка, ни одной `category`', () {
      final List<DemoCategory> all = demoCategories();
      expect(all.map((DemoCategory c) => c.name).toSet(), _demoExpected.keys.toSet(), reason: 'данные демо = таблица');
      expect(all.length, 41);
      final Map<String, String> nameOf = <String, String>{for (final DemoCategory c in all) c.id: c.name};
      int byOwnName = 0;
      for (final DemoCategory c in all) {
        final String? parent = c.parentId == null ? null : nameOf[c.parentId];
        final IconData icon = CategoryIcons.resolve(
          name: c.name,
          ancestors: <CategoryIconSource>[if (parent != null) (key: null, name: parent)],
        );
        expect(icon, _demoExpected[c.name], reason: c.name);
        expect(icon, isNot(Icons.category_rounded), reason: c.name);
        final IconData? own = CategoryIcons.match(name: c.name);
        if (own != null) {
          byOwnName++;
        }
        expect(own == null, _demoByAncestor.contains(c.name), reason: '${c.name}: по своему названию');
      }
      expect(byOwnName, 37, reason: 'по своему названию 37 из 41, остальные 4 — по родителю');
    });

    test('локальный стенд и fake 1С (`SyntheticCatalog`): 66 узлов с «…: серия 1» — без `category`', () {
      final String source = File('../pos-api/src/integrations/onec/synthetic-catalog.ts').readAsStringSync();
      int nodes = 0;
      int byOwnName = 0;
      // [path] — названия от корня до узла включительно.
      void check(List<String> path, IconData expected) {
        final String name = path.last;
        nodes++;
        final IconData icon = CategoryIcons.resolve(
          name: name,
          ancestors: <CategoryIconSource>[for (final String n in path.reversed.skip(1)) (key: null, name: n)],
        );
        expect(icon, expected, reason: name);
        expect(icon, isNot(Icons.category_rounded), reason: name);
        final bool own = CategoryIcons.match(name: name) != null;
        if (own) {
          byOwnName++;
        }
        expect(own, !_syntheticByAncestor.contains(name), reason: '$name: по своему названию');
      }

      for (final (String root, IconData rootIcon, List<(String, IconData)> children) in _synthetic) {
        expect(source, contains("'$root'"), reason: 'корень есть в синтетике');
        check(<String>[root], rootIcon);
        for (int c = 0; c < children.length; c++) {
          final (String child, IconData childIcon) = children[c];
          expect(source, contains("'$child'"), reason: 'подкатегория есть в синтетике');
          check(<String>[root, child], childIcon);
          if (c.isEven) {
            check(<String>[root, child, '$child: серия 1'], childIcon);
          }
        }
      }
      expect(nodes, 66);
      expect(byOwnName, 55, reason: 'по своему названию 55 из 66, остальные 11 — по предку');
    });

    test('фикстуры pos-app (categoryTree, designCategoryTree): у каждого узла — иконка, не `category`', () {
      for (final CategoryTree tree in <CategoryTree>[categoryTree(), designCategoryTree()]) {
        for (final Category c in tree.all) {
          final IconData icon = _inTree(tree.pathTo(c.id));
          expect(icon, isNot(Icons.category_rounded), reason: c.name);
        }
      }
      final CategoryTree t = categoryTree();
      expect(_inTree(t.pathTo('c-mix-kitchen')), Icons.plumbing_rounded, reason: '«Для кухни» — ключ предка');
      expect(_inTree(t.pathTo('c-mix-bath')), Icons.bathtub_rounded, reason: '«Для ванной» — своё название');
      expect(_inTree(t.pathTo('c-pipes')), Icons.plumbing_rounded, reason: 'ключ `valve`');
    });

    test('порядок ступеней: свой ключ > своё название > ключ предка > название предка; ближний предок раньше', () {
      expect(
        CategoryIcons.resolve(key: 'bathtub', name: 'Котлы'),
        Icons.bathtub_rounded,
        reason: 'ключ важнее',
      );
      expect(
        CategoryIcons.resolve(
          name: 'Котлы',
          ancestors: const <CategoryIconSource>[(key: 'plumbing', name: 'Сантехника')],
        ),
        Icons.local_fire_department_rounded,
        reason: 'своё название важнее предка',
      );
      expect(
        CategoryIcons.resolve(
          name: 'Однорычажные',
          ancestors: const <CategoryIconSource>[(key: 'hardware', name: 'Отопление')],
        ),
        Icons.hardware_rounded,
        reason: 'у предка ключ важнее названия',
      );
      expect(
        CategoryIcons.resolve(
          name: 'Серия 1',
          ancestors: const <CategoryIconSource>[(key: null, name: 'Для ванной'), (key: 'plumbing', name: 'Смесители')],
        ),
        Icons.bathtub_rounded,
        reason: 'ближний предок раньше дальнего',
      );
      expect(
        CategoryIcons.resolve(
          name: 'Однорычажные',
          ancestors: const <CategoryIconSource>[(key: null, name: 'Для кухни'), (key: 'plumbing', name: 'Смесители')],
        ),
        Icons.plumbing_rounded,
        reason: 'предок без совпадения пропускается — до корня',
      );
    });

    test('совпадение — начало слова, слова по порядку (промахи подстроки устранены)', () {
      const Map<String, IconData> cases = <String, IconData>{
        'Утеплитель': Icons.texture_rounded,
        'Вентиляторы': Icons.air_rounded,
        'Электроинструмент': Icons.construction_rounded,
        'Воздуховоды': Icons.hvac_rounded,
        'Воздушные фильтры': Icons.air_rounded,
        'Экраны для ванн': Icons.bathtub_rounded,
        'Трубы отопления': Icons.plumbing_rounded,
        'Канализационные трубы и фитинги': Icons.water_damage_rounded,
        'Смесители': Icons.plumbing_rounded,
        'Сухие смеси': Icons.foundation_rounded,
        'Унитаз-компакт': Icons.wc_rounded,
        'Лакокрасочные материалы': Icons.format_paint_rounded,
        'Окна и подоконники': Icons.window_rounded,
        'Тротуарная плитка и брусчатка': Icons.grid_on_rounded,
        'Пиломатериалы': Icons.carpenter_rounded,
      };
      for (final MapEntry<String, IconData> e in cases.entries) {
        expect(CategoryIcons.resolve(name: e.key), e.value, reason: e.key);
      }
    });

    test('типовые названия магазина вне демо (доработка 2026-11-08) — не общий `category`', () {
      const Map<String, IconData> cases = <String, IconData>{
        'Герметики и пена': Icons.format_color_fill_rounded,
        'Пена монтажная': Icons.format_color_fill_rounded,
        'Силиконовые герметики': Icons.format_color_fill_rounded,
        'Ламинат': Icons.table_rows_rounded,
        'Линолеум': Icons.table_rows_rounded,
        'Плинтус напольный': Icons.table_rows_rounded,
        'Хозтовары': Icons.cleaning_services_rounded,
        'Хозяйственные товары': Icons.cleaning_services_rounded,
        'Счётчики воды': Icons.speed_rounded,
        'Сварка': Icons.bolt_rounded,
        'Сварочные аппараты': Icons.bolt_rounded,
        'Электроды': Icons.bolt_rounded,
        'Электроды сварочные': Icons.bolt_rounded,
        'Электрододержатели': Icons.bolt_rounded,
        // «Электроды» стоят раньше «электр», но не задевают другие слова на «электрод…».
        'Электродвигатели': Icons.electrical_services_rounded,
        'Электродрели': Icons.electrical_services_rounded,
        'Электрика': Icons.electrical_services_rounded,
        // Прежние правила раньше новых: «пенопласт» — утеплитель, «клей-герметик» — по первому слову.
        'Пенопласт': Icons.texture_rounded,
        'Клей-герметик': Icons.foundation_rounded,
      };
      for (final MapEntry<String, IconData> e in cases.entries) {
        expect(CategoryIcons.resolve(name: e.key), e.value, reason: e.key);
      }
    });

    test('регистр, «Ё»/«ё», кыргызские названия [ТИПОВО]', () {
      expect(CategoryIcons.resolve(name: 'КРЕПЁЖ'), Icons.hardware_rounded);
      expect(CategoryIcons.resolve(name: 'Крепеж и фурнитура'), Icons.hardware_rounded);
      expect(CategoryIcons.resolve(name: 'Тёплый пол'), Icons.thermostat_rounded);
      expect(CategoryIcons.resolve(name: 'Жылытуу'), Icons.thermostat_rounded);
      expect(CategoryIcons.resolve(name: 'Суу түтүктөрү'), Icons.water_drop_rounded);
      expect(CategoryIcons.resolve(name: 'Жылуулоочу материалдар'), Icons.texture_rounded);
      expect(CategoryIcons.resolve(name: 'Курулуш материалдары'), Icons.foundation_rounded);
      expect(CategoryIcons.resolve(name: 'Даараткандар'), Icons.wc_rounded);
    });

    test(
      'запасной `category` — только без совпадения у себя и у предков; ключ `category` и неизвестный — как «нет»',
      () {
        for (final String name in <String>['Прочее', 'X', 'Старое', '']) {
          expect(CategoryIcons.match(name: name), isNull, reason: name);
          expect(CategoryIcons.resolve(name: name), Icons.category_rounded, reason: name);
        }
        expect(CategoryIcons.resolve(), Icons.category_rounded);
        expect(CategoryIcons.resolve(key: 'category', name: 'Котлы'), Icons.local_fire_department_rounded);
        expect(CategoryIcons.resolve(key: 'heating', name: 'Отопление'), Icons.thermostat_rounded);
        expect(CategoryIcons.of('нет такого'), Icons.category_rounded);
        expect(
          CategoryIcons.resolve(name: 'Прочее', ancestors: const <CategoryIconSource>[(key: null, name: 'Y')]),
          Icons.category_rounded,
        );
      },
    );
  });
}
