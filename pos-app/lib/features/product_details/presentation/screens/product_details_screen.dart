// SCR-14 Карточка товара (`/catalog/p/{productId}?variantId=&qty=`, staff и customer; 02 ч. B SCR-14).
//
// Компоновка по классу окна (02 SCR-14.2): compact — отдельный экран с закреплённой нижней панелью
// «количество + В корзину» (UI-14-027) и вкладками «Описание · Характеристики · Склады»; medium —
// экран в 2 колонки (фото ≈ 40 % / данные ≈ 60 %); expanded/large — панель с шапкой (крошки,
// крестик, `Esc`) и двумя колонками (B над E слева, C над D справа), ширина ≤ 1200.
// Маршрут — app/router/routes.dart (ProductRoute); экран не меняет путь и параметры конструктора.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_tabs.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/layout/content_region.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/catalog/domain/entities/category.dart';
import 'package:optomstroy/features/product_details/presentation/notifiers/product_category_path.dart';
import 'package:optomstroy/features/product_details/presentation/notifiers/product_details_notifier.dart';
import 'package:optomstroy/features/product_details/presentation/widgets/product_favorite_toggle.dart';
import 'package:optomstroy/features/product_details/presentation/widgets/product_sections.dart';
import 'package:optomstroy/features/product_details/presentation/widgets/variant_picker_sheet.dart';

/// SCR-14 — Карточка товара.
class ProductDetailsScreen extends ConsumerWidget {
  const ProductDetailsScreen({required this.productId, this.variantId, this.qty, super.key});

  /// ID экрана по 02 §4.1.
  static const String screenId = 'SCR-14';

  /// Путь каталога (крошка «Каталог», закрытие без истории).
  static const String catalogLocation = '/catalog';

  /// ID товара (uuid).
  final String productId;

  /// Выбранный вариант (по умолчанию — `isDefault`).
  final String? variantId;

  /// Предзаполнение количества из сканера (строка `QuantityValue`, без `double`).
  final String? qty;

  ProductDetailsArgs get _args => (productId: productId, variantId: variantId, qty: qty);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ProductDetailsArgs args = _args;
    final ProductDetailsState s = ref.watch(productDetailsProvider(args));
    final ProductDetailsNotifier notifier = ref.read(productDetailsProvider(args).notifier);
    final WindowClass wc = context.windowClass;
    ref.listen<int>(productDetailsProvider(args).select((ProductDetailsState x) => x.addedCount), (
      int? prev,
      int next,
    ) {
      if (prev != null && next > prev && wc == WindowClass.compact) {
        showAddedSnackbar(context, ref.read(productDetailsProvider(args)));
      }
    });
    final bool wide = wc == WindowClass.expanded || wc == WindowClass.large;
    // expanded/large: маршрут — прозрачная страница поверх SCR-10/11/12 (app/router ProductRoute); панель
    // занимает контент-колонку списка, SB и CP остаются видимыми (02 SCR-14.2, EQ-PD-05). Без колонки под
    // маршрутом (deep link с другого экрана, отдельный тест) — полноэкранная раскладка.
    Widget bodyFor({required bool embedded}) => switch (s.status) {
      ProductLoadStatus.loading => Padding(
        padding: EdgeInsets.all(wide ? 24 : 16),
        child: SingleChildScrollView(child: ProductDetailsSkeleton(wide: wc != WindowClass.compact)),
      ),
      ProductLoadStatus.notFound => Center(
        child: EmptyState(
          variant: EmptyStateVariant.search,
          title: AppLocalizations.of(context).product_not_found_title,
          actionLabel: AppLocalizations.of(context).category_breadcrumb_root,
          onAction: () => GoRouter.of(context).go(catalogLocation),
        ),
      ),
      ProductLoadStatus.error => Center(
        child: ErrorState.fullScreen(
          title: s.failure is NetworkFailure
              ? AppLocalizations.of(context).global_offline_title
              : AppLocalizations.of(context).ds_server_down,
          message: AppLocalizations.of(context).error_internal,
          onRetry: notifier.retry,
          requestId: s.failure?.requestId,
        ),
      ),
      ProductLoadStatus.ready => switch (wc) {
        WindowClass.compact => _CompactBody(state: s, notifier: notifier),
        WindowClass.medium => _MediumBody(state: s, notifier: notifier),
        WindowClass.expanded || WindowClass.large => _PanelBody(state: s, notifier: notifier, embedded: embedded),
      },
    };
    final DsColors c = context.colors;
    void close() => _close(context);
    final Widget header = _Header(
      wide: wide,
      onClose: close,
      categoryId: s.product?.summary.categoryId,
      favoriteProductId: s.status == ProductLoadStatus.ready ? productId : null,
    );
    Widget shortcuts(Widget child) => CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): close,
        if (s.status == ProductLoadStatus.ready) ...<ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.enter): notifier.add,
          const SingleActivator(LogicalKeyboardKey.numpadAdd): notifier.increment,
          const SingleActivator(LogicalKeyboardKey.numpadSubtract): notifier.decrement,
        },
      },
      child: Focus(autofocus: true, child: child),
    );
    if (wide && ModalRoute.of(context)?.opaque == false) {
      // Геометрия колонки меняется со сменой окна и свёрнутым сайдбаром — панель следует за ней.
      return ValueListenableBuilder<int>(
        valueListenable: DsContentRegion.changes,
        builder: (BuildContext context, int _, Widget? _) {
          final Rect? region = DsContentRegion.rectIn(context);
          if (region == null) {
            return shortcuts(_page(c, header, bodyFor(embedded: false), wc, s, notifier, wide: true));
          }
          final width = math.min(region.width, DsBreakpoints.contentMaxLarge);
          final Rect panel = Rect.fromLTWH(region.left + (region.width - width) / 2, region.top, width, region.height);
          return shortcuts(
            Stack(
              children: <Widget>[
                // Клик вне панели: SB, пустая область шапки — `pop`; CP и SearchBar — насквозь
                // (02 SCR-14.2, navigation.md §5; маршрут без барьера — app/router PanelPage).
                Positioned.fill(child: DsPanelDismissLayer(onDismiss: close)),
                Positioned.fromRect(
                  rect: panel,
                  // Корень SCR-14 в обеих раскладках — ключ `scr-14` (интеграционные тесты, 12 T-CAT).
                  child: DecoratedBox(
                    key: const ValueKey<String>('scr-14'),
                    decoration: BoxDecoration(color: c.surface, boxShadow: context.elevation.e3),
                    child: Material(
                      key: const ValueKey<String>('product-panel-overlay'),
                      type: MaterialType.transparency,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          header,
                          Expanded(child: bodyFor(embedded: true)),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );
    }
    return shortcuts(_page(c, header, bodyFor(embedded: false), wc, s, notifier, wide: wide));
  }

  Widget _page(
    DsColors c,
    Widget header,
    Widget body,
    WindowClass wc,
    ProductDetailsState s,
    ProductDetailsNotifier notifier, {
    required bool wide,
  }) => Scaffold(
    key: const ValueKey<String>('scr-14'),
    backgroundColor: wide ? c.background : c.surface,
    body: SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          header,
          Expanded(child: body),
        ],
      ),
    ),
    bottomNavigationBar: wc == WindowClass.compact && s.status == ProductLoadStatus.ready
        ? ProductBottomBar(state: s, notifier: notifier)
        : null,
  );

  static void _close(BuildContext context) {
    final GoRouter router = GoRouter.of(context);
    if (router.canPop()) {
      router.pop();
    } else {
      router.go(catalogLocation);
    }
  }
}

/// Зона A (UI-14-001/017): compact/medium — «Назад», название категории, кнопка поиска (→ SCR-11);
/// expanded — крошки «Каталог › … › категория» (тап по уровню → SCR-12) и крестик.
/// `FavoriteToggle` (A3) — через порт избранного SCR-14 (EQ-PD-03): compact/medium — перед поиском,
/// expanded — перед крестиком.
class _Header extends ConsumerWidget {
  const _Header({required this.wide, required this.onClose, this.categoryId, this.favoriteProductId});

  final bool wide;
  final VoidCallback onClose;
  final String? categoryId;

  /// Товар для звезды избранного; `null` — звезда скрыта (загрузка, «не найден», ошибка).
  final String? favoriteProductId;

  static const String _searchLocation = '/catalog/search';

  static String _categoryLocation(String id) => '/catalog/c/${Uri.encodeComponent(id)}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DsColors c = context.colors;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String? id = categoryId;
    final List<Category> path = id == null
        ? const <Category>[]
        : ref.watch(productCategoryPathProvider(id)).value ?? const <Category>[];
    final Widget sep = Icon(Icons.chevron_right_rounded, size: 16, color: c.textSecondary);
    return Container(
      height: 56,
      padding: EdgeInsets.symmetric(horizontal: wide ? 16 : 4),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: <Widget>[
          if (!wide)
            AppIconButton(
              key: const ValueKey<String>('product-back'),
              icon: Icons.arrow_back_rounded,
              semanticLabel: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: onClose,
            ),
          if (!wide)
            Expanded(
              child: Text(
                path.isEmpty ? '' : path.last.name,
                key: const ValueKey<String>('product-header-category'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text.title.copyWith(color: c.textPrimary),
              ),
            ),
          if (favoriteProductId != null && !wide) ProductFavoriteToggle(productId: favoriteProductId!),
          if (!wide)
            AppIconButton(
              key: const ValueKey<String>('product-search'),
              icon: Icons.search_rounded,
              semanticLabel: l10n.search_title,
              tooltip: l10n.search_title,
              onPressed: () => GoRouter.of(context).push<void>(_searchLocation),
            ),
          if (wide)
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: <Widget>[
                    AppButton(
                      key: const ValueKey<String>('product-breadcrumb-root'),
                      label: l10n.category_breadcrumb_root,
                      onPressed: () => GoRouter.of(context).go(ProductDetailsScreen.catalogLocation),
                      variant: AppButtonVariant.text,
                      size: AppButtonSize.s,
                    ),
                    for (final Category cat in path) ...<Widget>[
                      sep,
                      AppButton(
                        key: ValueKey<String>('product-breadcrumb-${cat.id}'),
                        label: cat.name,
                        onPressed: () => GoRouter.of(context).go(_categoryLocation(cat.id)),
                        variant: AppButtonVariant.text,
                        size: AppButtonSize.s,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          if (favoriteProductId != null && wide) ProductFavoriteToggle(productId: favoriteProductId!),
          if (wide)
            AppIconButton(
              key: const ValueKey<String>('product-close'),
              icon: Icons.close_rounded,
              semanticLabel: l10n.ds_button_close,
              onPressed: onClose,
            ),
        ],
      ),
    );
  }
}

/// Ошибка обновления при показанном кэше (`ErrorState.inline` над данными, SCR-14.7).
Widget? _refreshError(BuildContext context, ProductDetailsState s, ProductDetailsNotifier n) {
  if (s.failure == null || s.status != ProductLoadStatus.ready) return null;
  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: ErrorState.inline(message: AppLocalizations.of(context).error_internal, onRetry: n.retry),
  );
}

Future<void> _showWarehouses(BuildContext context, ProductDetailsState s, ProductDetailsNotifier n) =>
    AppBottomSheet.show<void>(
      context,
      title: AppLocalizations.of(context).product_stock_title,
      body: ProductStockSection(state: s, showTitle: false, onRetry: n.retry),
    );

class _CompactBody extends StatelessWidget {
  const _CompactBody({required this.state, required this.notifier});

  final ProductDetailsState state;
  final ProductDetailsNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final Widget? err = _refreshError(context, state, notifier);
    return ListView(
      key: const ValueKey<String>('product-compact'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: <Widget>[
        ?err,
        ProductGallerySection(state: state),
        const SizedBox(height: 16),
        ProductMainInfo(
          state: state,
          notifier: notifier,
          onShowWarehouses: () => _showWarehouses(context, state, notifier),
          onOpenVariantList: () => showVariantPickerSheet(context, state: state, notifier: notifier),
        ),
        const SizedBox(height: 12),
        ProductQuantityRules(state: state),
        const SizedBox(height: 16),
        _InfoTabs(state: state, notifier: notifier),
      ],
    );
  }
}

class _MediumBody extends StatelessWidget {
  const _MediumBody({required this.state, required this.notifier});

  final ProductDetailsState state;
  final ProductDetailsNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final Widget? err = _refreshError(context, state, notifier);
    return SingleChildScrollView(
      key: const ValueKey<String>('product-medium'),
      padding: const EdgeInsets.all(24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(flex: 2, child: ProductGallerySection(state: state)),
          const SizedBox(width: 24),
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ?err,
                ProductMainInfo(
                  state: state,
                  notifier: notifier,
                  onOpenVariantList: () => showVariantPickerSheet(context, state: state, notifier: notifier),
                ),
                const SizedBox(height: 16),
                ProductQuantityBar(state: state, notifier: notifier),
                const SizedBox(height: 16),
                _InfoTabs(state: state, notifier: notifier),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PanelBody extends StatelessWidget {
  const _PanelBody({required this.state, required this.notifier, this.embedded = false});

  final ProductDetailsState state;
  final ProductDetailsNotifier notifier;

  /// Содержимое панели поверх контент-колонки SCR-10 (фон и тень рисует панель, EQ-PD-05).
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final Widget? err = _refreshError(context, state, notifier);
    if (embedded) {
      return SingleChildScrollView(
        key: const ValueKey<String>('product-panel'),
        padding: const EdgeInsets.all(24),
        child: _columns(err),
      );
    }
    return SingleChildScrollView(
      key: const ValueKey<String>('product-panel'),
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: DsBreakpoints.contentMaxLarge),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.all(context.radii.lg),
              boxShadow: context.elevation.e3,
            ),
            child: _columns(err),
          ),
        ),
      ),
    );
  }

  /// Две колонки панели: B над E (40 %), C над D (60 %), зазор 24 (02 SCR-14.2).
  Widget _columns(Widget? err) => Builder(
    builder: (BuildContext context) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          flex: 2,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ProductGallerySection(state: state, vertical: true),
              const SizedBox(height: 24),
              ProductSpecsSection(state: state),
              const SizedBox(height: 16),
              ProductDescriptionSection(state: state),
            ],
          ),
        ),
        const SizedBox(width: 24),
        Expanded(
          flex: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ?err,
              ProductMainInfo(
                state: state,
                notifier: notifier,
                large: true,
                onOpenVariantList: () => showVariantPickerSheet(context, state: state, notifier: notifier),
              ),
              const SizedBox(height: 16),
              ProductQuantityBar(state: state, notifier: notifier),
              const SizedBox(height: 24),
              ProductStockSection(state: state, onRetry: notifier.retry),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Вкладки «Описание · Характеристики · Склады» (UI-14-015; «Склады» — только staff); пустые
/// блоки не показываются (INV-052).
class _InfoTabs extends StatefulWidget {
  const _InfoTabs({required this.state, required this.notifier});

  final ProductDetailsState state;
  final ProductDetailsNotifier notifier;

  @override
  State<_InfoTabs> createState() => _InfoTabsState();
}

enum _Tab { description, specs, warehouses }

class _InfoTabsState extends State<_InfoTabs> {
  _Tab? _selected;

  List<_Tab> _tabs() {
    final ProductDetailsState s = widget.state;
    final String? d = s.product?.description?.trim();
    final bool hasSpecs = (s.product?.attributes.isNotEmpty ?? false) || (s.variant?.attributes.isNotEmpty ?? false);
    return <_Tab>[
      if (d != null && d.isNotEmpty) _Tab.description,
      if (hasSpecs) _Tab.specs,
      if (!s.isCustomer) _Tab.warehouses,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final List<_Tab> tabs = _tabs();
    if (tabs.isEmpty) return const SizedBox.shrink();
    final _Tab current = tabs.contains(_selected) ? _selected! : tabs.first;
    String title(_Tab t) => switch (t) {
      _Tab.description => l10n.product_description_title,
      _Tab.specs => l10n.product_specs_title,
      _Tab.warehouses => l10n.product_warehouses_tab,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // UI-14-015: `AppTabs` `fixed` (03 §9.49).
        AppTabs<_Tab>(
          key: const ValueKey<String>('product-tabs'),
          value: current,
          tabs: <AppTab<_Tab>>[
            for (final _Tab t in tabs)
              AppTab<_Tab>(key: ValueKey<String>('product-tab-${t.name}'), value: t, label: title(t)),
          ],
          onChanged: (_Tab t) => setState(() => _selected = t),
        ),
        const SizedBox(height: 12),
        switch (current) {
          _Tab.description => ProductDescriptionSection(state: widget.state, showTitle: false),
          _Tab.specs => ProductSpecsSection(state: widget.state, showTitle: false),
          _Tab.warehouses => ProductStockSection(state: widget.state, showTitle: false, onRetry: widget.notifier.retry),
        },
      ],
    );
  }
}
