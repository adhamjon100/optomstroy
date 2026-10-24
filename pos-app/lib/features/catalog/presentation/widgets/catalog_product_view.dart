// Зона D SCR-10/11/12 (02 SCR-10.3 D1–D5, D′): список товаров в виде сетка/список/компакт
// (виртуализация, колонки сетки — 03 §7.3), подгрузка следующей страницы за 2 ряда до конца
// («Загружаем ещё товары…», ошибка — «Повторить» без потери загруженного), состояния: скелетон,
// пусто, ошибка (полноэкранная / inline над кэшем), нет данных офлайн.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/product_card.dart';
import 'package:optomstroy/design_system/components/view_mode_segmented.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_list_controller.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_card_mapper.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_formats.dart';

/// Действия карточек.
final class CatalogProductCallbacks {
  const CatalogProductCallbacks({required this.onOpen, required this.onFavorite, required this.onAction});

  final ValueChanged<ProductSummary> onOpen;
  final void Function(ProductSummary product, bool favorite) onFavorite;
  final ValueChanged<ProductSummary> onAction;
}

/// Текст ошибки для пользователя (без ПДн; `error_<code>` 03 §16.2 — общий `error_internal`).
String catalogFailureMessage(AppLocalizations l10n, Failure f) => switch (f) {
  ServerFailure(:final String code, :final Duration? retryAfter) when code == 'RATE_LIMITED' => l10n.error_rate_limited(
    retryAfter?.inSeconds ?? 0,
  ),
  _ => l10n.error_internal,
};

class CatalogProductView extends StatelessWidget {
  const CatalogProductView({
    super.key,
    required this.state,
    required this.items,
    required this.view,
    required this.windowClass,
    required this.cardContext,
    required this.callbacks,
    required this.onLoadMore,
    required this.onRetry,
    required this.empty,
    required this.errorTitle,
    this.footer,
    this.padding = EdgeInsets.zero,
    this.scrollController,
    this.headerSlivers = const <Widget>[],
  });

  final CatalogListState state;

  /// Показываемые товары (поиск может фильтровать загруженные по `matchType`).
  final List<ProductSummary> items;
  final ProductViewMode view;
  final WindowClass windowClass;
  final CatalogCardContext cardContext;
  final CatalogProductCallbacks callbacks;
  final VoidCallback onLoadMore;
  final VoidCallback onRetry;

  /// Пустой результат (`EmptyState` с действиями — у экрана).
  final Widget empty;

  /// Заголовок полноэкранной ошибки («Не удалось загрузить каталог»).
  final String errorTitle;

  /// Подвал списка (SCR-11 «Не нашли?»).
  final Widget? footer;
  final EdgeInsets padding;
  final ScrollController? scrollController;

  /// Блоки над списком, прокручиваемые вместе с ним (SCR-50: «Мой кабинет», категории, недавние).
  /// Во всех фазах (скелетон, пусто, ошибка) блоки остаются на месте, меняется только зона товаров.
  final List<Widget> headerSlivers;

  bool get _withHeader => headerSlivers.isNotEmpty;

  bool get _table => windowClass == WindowClass.expanded || windowClass == WindowClass.large;

  double _gap() => // money-double: allow — геометрия UI (lp)
      windowClass == WindowClass.compact || windowClass == WindowClass.medium ? 16 : 12;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    if (_withHeader && state.phase != CatalogListPhase.ready) {
      return CustomScrollView(
        key: const ValueKey<String>('catalog-products'),
        controller: scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: <Widget>[
          ...headerSlivers,
          SliverToBoxAdapter(child: _phaseBody(context, l10n)),
        ],
      );
    }
    return _phaseBody(context, l10n);
  }

  Widget _phaseBody(BuildContext context, AppLocalizations l10n) {
    switch (state.phase) {
      case CatalogListPhase.loading:
        return _skeleton(context);
      case CatalogListPhase.empty:
        return _centered(empty);
      case CatalogListPhase.error:
        return _centered(
          ErrorState.fullScreen(
            key: const ValueKey<String>('catalog-error'),
            title: errorTitle,
            message: catalogFailureMessage(l10n, state.failure!),
            requestId: state.failure!.requestId,
            onRetry: onRetry,
          ),
        );
      case CatalogListPhase.offlineNoCache:
        return _centered(
          EmptyState(
            key: const ValueKey<String>('catalog-offline-no-cache'),
            variant: EmptyStateVariant.offlineNoCache,
            title: l10n.ds_empty_offline_no_cache_title,
            body: l10n.ds_empty_offline_no_cache_body,
            actionLabel: l10n.ds_button_retry,
            onAction: onRetry,
          ),
        );
      case CatalogListPhase.ready:
        return _list(context, l10n);
    }
  }

  /// Состояние без товаров: по центру области (с блоками над списком — сразу под ними).
  Widget _centered(Widget child) =>
      _withHeader ? Padding(padding: padding, child: child) : Center(child: SingleChildScrollView(child: child));

  Widget _skeleton(BuildContext context) {
    final Widget body = switch (view) {
      ProductViewMode.grid => LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final double gap = _gap(); // money-double: allow — геометрия UI (lp)
          final double width = box.maxWidth - padding.horizontal; // money-double: allow — геометрия UI (lp)
          final int cols = DsBreakpoints.gridColumns(width, gap);
          final double cell = (width - gap * (cols - 1)) / cols; // money-double: allow — геометрия UI (lp)
          return GridView.builder(
            padding: padding,
            shrinkWrap: _withHeader,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisSpacing: gap,
              crossAxisSpacing: gap,
              mainAxisExtent: cell + kProductCardGridBodyHeight,
            ),
            itemCount: cols * 2,
            itemBuilder: (BuildContext context, int i) => const ProductCardSkeleton.grid(),
          );
        },
      ),
      ProductViewMode.list => ListView.builder(
        padding: padding,
        shrinkWrap: _withHeader,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 10,
        itemBuilder: (BuildContext context, int i) => const ProductCardSkeleton.list(),
      ),
      ProductViewMode.compact => ListView.builder(
        padding: padding,
        shrinkWrap: _withHeader,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 14,
        itemBuilder: (BuildContext context, int i) => const ProductCardSkeleton.compact(),
      ),
    };
    return KeyedSubtree(key: const ValueKey<String>('catalog-skeleton'), child: body);
  }

  void _maybeLoadMore(int index, int threshold) {
    if (index >= items.length - threshold && state.hasMore && !state.loadingMore && state.moreFailure == null) {
      scheduleMicrotask(onLoadMore);
    }
  }

  Widget _card(BuildContext context, ProductSummary p, {required ProductCardCompactVariant compactVariant}) {
    final ProductCardData data = CatalogCardMapper.map(cardContext, p);
    final ProductCardCallbacks cb = ProductCardCallbacks(
      onOpen: () => callbacks.onOpen(p),
      onFavorite: cardContext.favoritesEnabled ? (bool v) => callbacks.onFavorite(p, v) : null,
      onAction: () => callbacks.onAction(p),
    );
    return KeyedSubtree(
      key: ValueKey<String>('product-${p.id}'),
      child: switch (view) {
        ProductViewMode.grid => ProductCardGrid(data: data, callbacks: cb),
        ProductViewMode.list => ProductCardList(data: data, callbacks: cb),
        ProductViewMode.compact => ProductCardCompact(data: data, callbacks: cb, variant: compactVariant),
      },
    );
  }

  Widget _list(BuildContext context, AppLocalizations l10n) {
    final DsColors c = context.colors;
    final double width = MediaQuery.sizeOf(context).width; // money-double: allow — геометрия UI (lp)
    final bool table = _table || (windowClass == WindowClass.medium && width >= 840);
    final ProductCardCompactVariant compactVariant = table
        ? ProductCardCompactVariant.table
        : ProductCardCompactVariant.row;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final double gap = _gap(); // money-double: allow — геометрия UI (lp)
        final double contentWidth = box.maxWidth - padding.horizontal; // money-double: allow — геометрия UI (lp)
        final int cols = DsBreakpoints.gridColumns(contentWidth, gap);
        final double cell = (contentWidth - gap * (cols - 1)) / cols; // money-double: allow — геометрия UI (lp)
        final List<Widget> slivers = <Widget>[
          ...headerSlivers,
          if (state.failure != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(padding.left, 0, padding.right, context.space.s2),
                child: ErrorState.inline(
                  key: const ValueKey<String>('catalog-error-inline'),
                  message: errorTitle,
                  onRetry: onRetry,
                ),
              ),
            ),
          if (view == ProductViewMode.compact && table)
            SliverPersistentHeader(
              pinned: true,
              delegate: _CompactHeaderDelegate(
                ProductCompactHeaderLabels(
                  photo: l10n.catalog_compact_col_photo_a11y,
                  sku: l10n.catalog_compact_col_sku,
                  name: l10n.catalog_compact_col_name,
                  variants: l10n.catalog_compact_col_variants,
                  stock: l10n.catalog_compact_col_available,
                  unit: l10n.catalog_compact_col_unit,
                  price: l10n.catalog_compact_col_price,
                  qty: l10n.catalog_compact_col_qty,
                  favorite: l10n.catalog_sidebar_favorites,
                ),
                padding: EdgeInsets.symmetric(horizontal: padding.left),
              ),
            ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              padding.left,
              view == ProductViewMode.grid ? padding.top : 0,
              padding.right,
              0,
            ),
            sliver: view == ProductViewMode.grid
                ? SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: cols,
                      mainAxisSpacing: gap,
                      crossAxisSpacing: gap,
                      mainAxisExtent: cell + kProductCardGridBodyHeight,
                    ),
                    delegate: SliverChildBuilderDelegate((BuildContext context, int i) {
                      _maybeLoadMore(i, cols * 2);
                      return _card(context, items[i], compactVariant: compactVariant);
                    }, childCount: items.length),
                  )
                : SliverList(
                    delegate: SliverChildBuilderDelegate((BuildContext context, int i) {
                      _maybeLoadMore(i, 2);
                      return _card(context, items[i], compactVariant: compactVariant);
                    }, childCount: items.length),
                  ),
          ),
          SliverToBoxAdapter(child: _loadMoreRow(context, l10n, c)),
          if (footer != null) SliverToBoxAdapter(child: footer),
          SliverToBoxAdapter(child: SizedBox(height: padding.bottom)),
        ];
        if (items.isEmpty && state.hasMore && !state.loadingMore && state.moreFailure == null) {
          scheduleMicrotask(onLoadMore);
        }
        return CustomScrollView(
          key: const ValueKey<String>('catalog-products'),
          controller: scrollController,
          physics: _withHeader ? const AlwaysScrollableScrollPhysics() : null,
          cacheExtent: 600,
          slivers: slivers,
        );
      },
    );
  }

  Widget _loadMoreRow(BuildContext context, AppLocalizations l10n, DsColors c) {
    if (state.moreFailure != null) {
      final (String msg, String? action) = CatalogFormats.splitAction(l10n.catalog_loading_more_error);
      return DsInteractive(
        key: const ValueKey<String>('catalog-load-more-error'),
        onTap: onLoadMore,
        builder: (BuildContext context, DsInteractionState s) => SizedBox(
          height: 48,
          child: Center(
            child: Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  TextSpan(
                    text: msg,
                    style: context.text.caption.copyWith(color: c.error),
                  ),
                  if (action != null) ...<InlineSpan>[
                    TextSpan(
                      text: ' · ',
                      style: context.text.caption.copyWith(color: c.textSecondary),
                    ),
                    TextSpan(
                      text: action,
                      style: context.text.label.copyWith(fontWeight: FontWeight.w600, color: c.primaryText),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }
    if (state.loadingMore || state.hasMore) {
      return SizedBox(
        key: const ValueKey<String>('catalog-loading-more'),
        height: 48,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const AppProgress.circular(size: 16),
            SizedBox(width: context.space.s2),
            Text(l10n.catalog_loading_more, style: context.text.caption.copyWith(color: c.textSecondary)),
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

class _CompactHeaderDelegate extends SliverPersistentHeaderDelegate {
  _CompactHeaderDelegate(this.labels, {required this.padding});

  final ProductCompactHeaderLabels labels;
  final EdgeInsets padding;

  @override
  double get minExtent => 40; // money-double: allow — геометрия UI (lp)

  @override
  double get maxExtent => 40; // money-double: allow — геометрия UI (lp)

  @override
  Widget build(
    BuildContext context,
    double /* money-double: allow — геометрия UI */ shrinkOffset,
    bool overlapsContent,
  ) => Padding(
    padding: padding,
    child: ProductCardCompactHeader(labels: labels),
  );

  @override
  bool shouldRebuild(_CompactHeaderDelegate oldDelegate) =>
      oldDelegate.labels != labels || oldDelegate.padding != padding;
}
