// SCR-40 вкладка «Товары» (02 UI-40-002, UI-40-004, UI-40-007; 08 §4.14 `GET/PUT/DELETE /favorites/products`; FAV-001,
// FAV-003): список избранных товаров (название, артикул, цена) со звездой; тап → SCR-14 (`go` в ветку Каталог).
// Снятие звезды — оптимистично + «Отменить» 8 с; ошибка онлайн — возврат и `favorites_remove_error`. Минимальная
// версия (G-fe-customers): «+ Добавить» / степпер, переключатель вида и HID-скан — в каталоге (GQ-FECUST-06).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart' show OnlineStatus;
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_list_tile.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/favorite_toggle.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/favorites/domain/repositories/favorites_repository.dart';
import 'package:optomstroy/features/favorites/favorites_providers.dart';
import 'package:uuid/uuid.dart';

/// Ключи (тесты).
abstract final class FavoriteProductsKeys {
  static const Key empty = ValueKey<String>('favorites-products-empty');
  static Key row(String id) => ValueKey<String>('favorites-product-$id');
  static Key star(String id) => ValueKey<String>('favorites-product-star-$id');
}

/// Вкладка «Товары».
class FavoriteProductsTab extends ConsumerStatefulWidget {
  /// Создаёт вкладку.
  const FavoriteProductsTab({this.onCount, super.key});

  /// Счётчик вкладки (`count` ответа).
  final ValueChanged<int>? onCount;

  @override
  ConsumerState<FavoriteProductsTab> createState() => _FavoriteProductsTabState();
}

enum _Phase { loading, ready, error, offline }

class _FavoriteProductsTabState extends ConsumerState<FavoriteProductsTab> {
  _Phase _phase = _Phase.loading;
  Failure? _failure;
  List<ProductSummary> _items = const <ProductSummary>[];
  int _count = 0;
  int _gen = 0;

  Timer? _firstStatus;

  @override
  void initState() {
    super.initState();
    // Статус сети ещё неизвестен (первое значение потока) — загрузка после него (не дольше 1 с).
    if (ref.read(onlineStatusProvider).hasValue) {
      unawaited(_load());
    } else {
      _firstStatus = Timer(const Duration(seconds: 1), () => unawaited(_load()));
    }
  }

  /// Смена сети: первое значение — загрузка; сеть вернулась — перезагрузка из состояния «офлайн».
  void _onStatus(AsyncValue<OnlineStatus>? prev, AsyncValue<OnlineStatus> next) {
    if (!next.hasValue) return;
    if (_firstStatus != null) {
      _firstStatus!.cancel();
      _firstStatus = null;
      unawaited(_load());
      return;
    }
    if (next.value != OnlineStatus.offline && _phase == _Phase.offline) unawaited(_load());
  }

  @override
  void dispose() {
    _firstStatus?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final int gen = ++_gen;
    if (ref.read(onlineStatusProvider).value == OnlineStatus.offline) {
      setState(() => _phase = _Phase.offline);
      return;
    }
    setState(() => _phase = _Phase.loading);
    Result<FavoriteProductsPage> r;
    try {
      r = await ref.read(favoritesRepositoryProvider).list();
    } on Object catch (e) {
      r = FailureResult<FavoriteProductsPage>(UnknownFailure(cause: e));
    }
    if (!mounted || gen != _gen) return;
    switch (r) {
      case Success<FavoriteProductsPage>(:final FavoriteProductsPage value):
        setState(() {
          _items = value.items;
          _count = value.count;
          _phase = _Phase.ready;
        });
        widget.onCount?.call(value.count);
      case FailureResult<FavoriteProductsPage>(:final Failure failure):
        setState(() {
          _failure = failure;
          _phase = failure is NetworkFailure && failure.kind == NetworkFailureKind.offline
              ? _Phase.offline
              : _Phase.error;
        });
    }
  }

  Future<void> _remove(ProductSummary p) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final int index = _items.indexWhere((ProductSummary x) => x.id == p.id);
    setState(() {
      _items = <ProductSummary>[
        for (final ProductSummary x in _items)
          if (x.id != p.id) x,
      ];
      _count = _count > 0 ? _count - 1 : 0;
    });
    widget.onCount?.call(_count);
    AppSnackbar.show(
      context,
      message: l10n.favorites_removed_snackbar,
      actionLabel: l10n.ds_button_undo,
      onAction: () => unawaited(_undo(p, index)),
    );
    final Result<void> r = await ref.read(favoritesRepositoryProvider).remove(p.id);
    if (!mounted) return;
    if (r is FailureResult<void>) {
      _restore(p, index);
      AppSnackbar.show(context, message: l10n.favorites_remove_error, variant: AppSnackbarVariant.error);
    }
  }

  void _restore(ProductSummary p, int index) {
    if (_items.any((ProductSummary x) => x.id == p.id)) return;
    setState(() {
      _items = <ProductSummary>[..._items]..insert(index.clamp(0, _items.length), p);
      _count++;
    });
    widget.onCount?.call(_count);
  }

  Future<void> _undo(ProductSummary p, int index) async {
    _restore(p, index);
    final Result<void> r = await ref.read(favoritesRepositoryProvider).add(p.id, idempotencyKey: const Uuid().v4());
    if (!mounted || r is! FailureResult<void>) return;
    AppSnackbar.show(
      context,
      message: AppLocalizations.of(context).catalog_favorite_error,
      variant: AppSnackbarVariant.error,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<OnlineStatus>>(onlineStatusProvider, _onStatus);
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool online = ref.watch(onlineStatusProvider).value != OnlineStatus.offline;
    switch (_phase) {
      case _Phase.loading:
        return ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            for (int i = 0; i < 6; i++)
              const Padding(padding: EdgeInsets.only(bottom: 8), child: SkeletonBox(height: 56)),
          ],
        );
      case _Phase.offline:
        return EmptyState(
          variant: EmptyStateVariant.offlineNoCache,
          title: l10n.ds_empty_offline_no_cache_title,
          body: l10n.ds_empty_offline_no_cache_body,
        );
      case _Phase.error:
        return ErrorState.fullScreen(
          title: l10n.error_internal,
          message: l10n.error_internal,
          requestId: _failure?.requestId,
          onRetry: () => unawaited(_load()),
        );
      case _Phase.ready:
        break;
    }
    if (_items.isEmpty) {
      return EmptyState(
        key: FavoriteProductsKeys.empty,
        variant: EmptyStateVariant.favorites,
        title: l10n.favorites_title,
        actionLabel: l10n.cart_empty_to_catalog,
        onAction: () => GoRouter.maybeOf(context)?.go('/catalog'),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        children: <Widget>[
          Padding(
            padding: EdgeInsets.fromLTRB(context.space.s4, context.space.s3, context.space.s4, context.space.s2),
            child: Text(
              l10n.favorites_products_found(_count),
              style: context.text.label.copyWith(color: context.colors.textSecondary),
            ),
          ),
          for (final ProductSummary p in _items)
            AppListTile(
              key: FavoriteProductsKeys.row(p.id),
              title: p.name,
              subtitle: <String>[
                ?p.sku,
                p.price == null ? l10n.ds_price_missing : PriceText.format(p.price!.amount),
              ].join(' · '),
              onTap: () => GoRouter.maybeOf(context)?.go('/catalog/p/${Uri.encodeComponent(p.id)}'),
              trailing: Tooltip(
                message: l10n.favorites_star_remove_tooltip,
                child: FavoriteToggle(
                  key: FavoriteProductsKeys.star(p.id),
                  selected: true,
                  semanticLabel: l10n.favorites_star_remove_tooltip,
                  onChanged: online ? (bool _) => unawaited(_remove(p)) : null,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
