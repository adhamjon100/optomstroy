// Сайдбар SCR-10/12 (зона B, 02 SCR-10.3 B2–B6). Два вида:
// - [CatalogSidebarLayout.list] (SCR-50; `customer` на SCR-11/12 expanded/large — D6): «Категории товаров» → меню
//   категорий-карточек `CategorySidebarItem` со счётчиками (раскрытие 1 уровня), «★ Избранное N», «Недавние товары ·
//   Очистить» (до 5);
// - [CatalogSidebarLayout.tiles] (SCR-10/11/12 на medium и шире, прототип, ADR-114): колонка 144 на фоне страницы —
//   только заголовок «Каталог» 19/700 (нажатие — «Все товары») и вертикальные плитки `CategoryTile.sidebar` (≥ 88)
//   корневых категорий настоящего дерева (картинка категории или иконка по смыслу названия; число товаров — в подсказке
//   и `Semantics`), выбранная — корень пути текущей категории. Подкатегории — лента над списком; «Избранные» и
//   «Недавние» — строка управления, «Избранное N» — меню ☰ (паритет функций ADR-114).
// Оба вида сворачиваются ([CatalogSidebar.onToggleCollapsed], настройка пользователя `sidebarCollapsed`; паритет функций
// ADR-112): у списка — кнопкой внизу колонки, у плиток — значком «‹‹» в строке заголовка «Каталог» (ADR-114; «››» —
// сверху свёрнутой колонки). Свёрнутая колонка 72 — только изображения или иконки с тултипами и подписями `Semantics` по
// названию и числу товаров; у списка «★ Избранное» — иконкой с тултипом, «Недавние» скрыты.
// Плитки разделов роли (B1) — у оболочки `AdaptiveScaffold` (EQ-CAT-08).
import 'dart:async';
import 'dart:math' as math;

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

/// Геометрия UI в lp (не деньги).
typedef _Lp = double; // money-double: allow — геометрия UI (lp)

/// Ширина колонки плиток ([CatalogSidebar.widthFor]).
_Lp _tilesWidth(BuildContext context, Iterable<Category> roots, String? selected) {
  _Lp tile = 100;
  for (final Category r in roots) {
    final _Lp need = CategoryTile.sidebarMinWidthFor(context, r.name, selected: r.id == selected);
    tile = math.max(tile, need.ceilToDouble());
  }
  return DsCatalogMetrics.columnPadding.horizontal + tile;
}

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

  /// Заголовок «Каталог» и вертикальные плитки корневых категорий — больше ничего (SCR-10/11/12 на medium и шире,
  /// прототип ADR-114).
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
    this.onAll,
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

  /// Свернуть / развернуть колонку (у списка — кнопка внизу колонки, у плиток — «‹‹» в строке заголовка «Каталог» и
  /// «››» сверху свёрнутой колонки); `null` — кнопки нет.
  final VoidCallback? onToggleCollapsed;

  /// Ключ кнопки «Свернуть / Развернуть» (тесты).
  static const Key toggleKey = ValueKey<String>('catalog-sidebar-toggle');

  /// Нажатие на заголовок «Каталог» колонки плиток — весь каталог «Все товары» (`/catalog?all=1`, ADR-114);
  /// `null` — заголовок не нажимается.
  final VoidCallback? onAll;

  /// Ключ нажимаемого заголовка «Каталог» (тесты).
  static const Key allKey = ValueKey<String>('catalog-sidebar-all');

  /// Вид.
  final CatalogSidebarLayout layout;

  /// Наименьшая ширина колонки плиток (`DsBreakpoints.catalogColumn` 132).
  static const double tilesWidth = DsBreakpoints.catalogColumn; // money-double: allow — геометрия UI (lp)

  /// Ширина колонки плиток (прототип, ADR-114): поле 18 + плитка max(100, ceil(самое длинное слово названий корней
  /// `tileLabel` 12/600, у выбранного корня [selected] — 700, + поля 12 + обводки)) + поле 14 — 144 для демо-каталога по
  /// макету (у макета 143,3 — колонка растёт по min-content; целое — для чётких рамок), 132 без длинных слов. Перенос
  /// подписи — только между словами, слово целиком помещается.
  static double widthFor(BuildContext c, Iterable<Category> roots, {String? selected}) => // money-double: allow — lp UI
      _tilesWidth(c, roots, selected);

  /// Высота строки текста заголовка «Каталог» (`columnTitle 19/700`, прототип: 23).
  static const double headingLine = 23; // money-double: allow — геометрия UI (lp)

  /// Поле заголовка «Каталог» слева от края плиток (прототип: `margin: 0 0 14px 4px`).
  static const double headingStart = 4; // money-double: allow — геометрия UI (lp)

  /// Отступ от строки заголовка «Каталог» до первой плитки (прототип: 14).
  static const double headingGap = 14; // money-double: allow — геометрия UI (lp)

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

  /// Колонка плиток (прототип, ADR-114): только строка заголовка «Каталог» (нажатие — весь каталог «Все товары»,
  /// [CatalogSidebar.onAll]; справа — «‹‹» свернуть) и плитки корней дерева; выбранная — корень пути текущей категории,
  /// повторный тап по ней открывает корень, если показана его подкатегория (экран тот же — `go`, без перезагрузки).
  /// «★ Избранное N» и «Недавние» переехали в строку управления и меню ☰ (паритет функций ADR-114).
  Widget _tiles(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final CategoryTreeState tree = ref.watch(categoryTreeProvider);
    final bool collapsed = widget.collapsed;
    final String? selectedId = widget.selectedCategoryId;
    final List<Category> path = selectedId == null || tree.tree == null
        ? const <Category>[]
        : tree.tree!.pathTo(selectedId);
    final String? selectedRoot = path.isEmpty ? null : path.first.id;
    const double gap = DsCatalogMetrics.tileGap; // money-double: allow — геометрия UI (lp)

    final List<Widget> tiles = <Widget>[];
    if (tree.tree == null && tree.loading) {
      for (int i = 0; i < 6; i++) {
        tiles.add(SkeletonBox(height: collapsed ? 48 : CategoryTile.sidebarMinHeight, radius: context.radii.md));
      }
    } else if (!tree.hasData && tree.failure != null) {
      // Колонка 144: ошибка — столбиком (иконка, текст, «Повторить»), строка `ErrorState.inline` не помещается.
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
            // Число товаров — в подсказке «{название}, N товаров» и `Semantics` (пилюли на плитке нет — ADR-114).
            countLabel: '${root.productCount}',
            semanticLabel: l10n.category_tile_a11y(root.productCount, root.name),
            onTap: () => widget.onCategory(root),
          ),
        );
      }
    }
    final VoidCallback? toggle = widget.onToggleCollapsed;
    final Widget? toggleButton = toggle == null
        ? null
        : _CollapseButton(
            key: CatalogSidebar.toggleKey,
            collapsed: collapsed,
            label: collapsed ? l10n.catalog_sidebar_expand : l10n.catalog_sidebar_collapse,
            onTap: toggle,
          );
    if (collapsed) {
      // Свёрнутая колонка 72: «››» сверху по центру, под ним «Все товары» (значок «четыре квадрата», как у карточки
      // «Все товары» ленты; заголовка «Каталог» в свёрнутой колонке нет — ревью PAR-05), затем плитки-иконки с
      // подсказками; поля 8.
      final VoidCallback? all = widget.onAll;
      return ListView(
        key: const ValueKey<String>('catalog-sidebar'),
        padding: EdgeInsets.fromLTRB(context.space.s2, context.space.s3, context.space.s2, context.space.s6),
        children: <Widget>[
          if (toggleButton != null)
            Padding(
              padding: EdgeInsets.only(bottom: all == null ? context.space.s2 : 0),
              child: Center(child: toggleButton),
            ),
          if (all != null)
            Padding(
              padding: EdgeInsets.only(bottom: context.space.s2),
              child: Center(
                child: _ColumnIconButton(
                  key: CatalogSidebar.allKey,
                  icon: Icons.grid_view_rounded,
                  label: l10n.catalog_sidebar_all_a11y,
                  onTap: all,
                ),
              ),
            ),
          for (int i = 0; i < tiles.length; i++) ...<Widget>[if (i > 0) const SizedBox(height: gap), tiles[i]],
        ],
      );
    }
    // Поля прототипа 18 / 20 / 14 / 24 (слева / сверху / справа / снизу): плитки 112 в колонке 144. Строка заголовка
    // — цель 48 (видимый текст «Каталог» 19/700 — строка 23 на 20 от верха колонки и 22 от её края, как в прототипе:
    // строка 48 начинается на 12,5 выше и кончается на 12,5 ниже текста, поэтому отступ до плиток 14 − 12,5); она
    // идёт до правого края колонки, «‹‹» (цель 48, глиф 20 `textSecondary`) — у этого края, над полем 14. Первая
    // плитка — на 57 от верха колонки (126 от верха окна при шапке 69).
    const EdgeInsets pad = DsCatalogMetrics.columnPadding;
    const double row = 48; // money-double: allow — геометрия UI (lp)
    const double lift = (row - CatalogSidebar.headingLine) / 2; // money-double: allow — геометрия UI (lp)
    final EdgeInsets tilePad = EdgeInsets.only(left: pad.left, right: pad.right);
    return ListView(
      key: const ValueKey<String>('catalog-sidebar'),
      padding: EdgeInsets.only(top: pad.top - lift, bottom: pad.bottom),
      children: <Widget>[
        Padding(
          padding: EdgeInsetsDirectional.only(start: pad.left + CatalogSidebar.headingStart),
          child: SizedBox(
            height: row,
            // «‹‹» — под заголовком: цель нажатия заголовка (ширина текста × 48) лежит поверх цели «‹‹», и нажатие на
            // конец слова «Каталог» открывает «Все товары», а не сворачивает колонку (в колонке 132 цель «‹‹» 48 заходит
            // на текст на ~15 lp, в 144 — на ~3; ревью R2C-06). Вид тот же: заголовок и значок не пересекаются.
            child: Stack(
              children: <Widget>[
                if (toggleButton != null) PositionedDirectional(end: 0, top: 0, bottom: 0, child: toggleButton),
                PositionedDirectional(start: 0, top: 0, bottom: 0, end: 0, child: _Heading(onAll: widget.onAll)),
              ],
            ),
          ),
        ),
        const SizedBox(height: CatalogSidebar.headingGap - lift),
        for (int i = 0; i < tiles.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: gap),
          Padding(padding: tilePad, child: tiles[i]),
        ],
      ],
    );
  }
}

/// «‹‹» / «››» колонки плиток (02 П.3, ADR-114; в прототипе значка нет — паритет функций ADR-112): глиф 20
/// `textSecondary` в квадрате 32 радиуса `sm` (фон только при наведении и нажатии), цель 48; подпись — в подсказке и
/// `Semantics`.
class _CollapseButton extends StatelessWidget {
  const _CollapseButton({super.key, required this.collapsed, required this.label, required this.onTap});

  final bool collapsed;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => _ColumnIconButton(
    icon: collapsed ? Icons.keyboard_double_arrow_right_rounded : Icons.keyboard_double_arrow_left_rounded,
    label: label,
    onTap: onTap,
  );
}

/// Значок колонки плиток («‹‹» / «››», «Все товары» свёрнутой колонки): глиф 20 `textSecondary` в квадрате 32
/// радиуса `sm` (фон только при наведении и нажатии), цель 48; подпись — в подсказке и `Semantics`.
class _ColumnIconButton extends StatelessWidget {
  const _ColumnIconButton({super.key, required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final BorderRadius radius = BorderRadius.all(context.radii.sm);
    return AppTooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        onTap: onTap,
        child: DsInteractive(
          onTap: onTap,
          builder: (BuildContext context, DsInteractionState s) => SizedBox.square(
            dimension: 48,
            child: Center(
              child: DsFocusRing(
                visible: s.focused,
                borderRadius: radius,
                child: AnimatedContainer(
                  duration: context.motion.of(context.motion.fast),
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: s.pressed ? c.iconButtonPressed : (s.hovered ? c.surfaceVariant : null),
                    borderRadius: radius,
                  ),
                  child: Icon(icon, size: 20, color: c.textSecondary),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Заголовок «Каталог» колонки плиток (19/700 `columnTitle`): нажатие — весь каталог «Все товары» (`/catalog?all=1`,
/// ADR-114); внешне — текст без подчёркивания (как в прототипе), при фокусе — кольцо; цель нажатия — вся высота
/// строки 48 по ширине текста. `onAll == null` — просто заголовок.
class _Heading extends StatelessWidget {
  const _Heading({required this.onAll});

  final VoidCallback? onAll;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final Widget text = Text(
      l10n.category_breadcrumb_root,
      key: const ValueKey<String>('sidebar-title'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: context.text.columnTitle.copyWith(color: c.textPrimary),
    );
    final VoidCallback? tap = onAll;
    if (tap == null) {
      return Semantics(
        header: true,
        child: Align(alignment: AlignmentDirectional.centerStart, child: text),
      );
    }
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Semantics(
        header: true,
        button: true,
        label: l10n.catalog_sidebar_all_a11y,
        excludeSemantics: true,
        onTap: tap,
        child: DsInteractive(
          key: CatalogSidebar.allKey,
          onTap: tap,
          builder: (BuildContext context, DsInteractionState s) => SizedBox(
            height: double.infinity, // money-double: allow — геометрия UI (lp)
            child: Center(
              widthFactor: 1,
              child: DsFocusRing(visible: s.focused, borderRadius: BorderRadius.all(context.radii.sm), child: text),
            ),
          ),
        ),
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
