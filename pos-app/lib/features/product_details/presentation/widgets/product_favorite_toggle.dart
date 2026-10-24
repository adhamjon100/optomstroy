// Звезда избранного SCR-14 (02 SCR-14 A3, UI-14-001; 03 §9.23; FAV-002) через порт `productFavoritePortProvider`
// (06 §6.1, EQ-PD-03): optimistic-переключение, снекбары «Добавлено в избранное · Отменить» /
// «Удалено из избранного · Отменить», при ошибке — откат и «Не удалось сохранить избранное · Повторить».
// Без порта звезда не показывается.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/favorite_toggle.dart';
import 'package:optomstroy/features/product_details/product_details_providers.dart';

/// Избранное (id) из порта SCR-14; без порта — пусто.
final productFavoriteIdsProvider = StreamProvider.autoDispose<Set<String>>((ref) {
  final ProductFavoritePort? port = ref.watch(productFavoritePortProvider);
  return port == null ? Stream<Set<String>>.value(const <String>{}) : port.watchFavoriteIds();
});

/// `FavoriteToggle` шапки SCR-14 для товара [productId].
class ProductFavoriteToggle extends ConsumerStatefulWidget {
  const ProductFavoriteToggle({super.key, required this.productId});

  final String productId;

  @override
  ConsumerState<ProductFavoriteToggle> createState() => _ProductFavoriteToggleState();
}

class _ProductFavoriteToggleState extends ConsumerState<ProductFavoriteToggle> {
  /// Оптимистичное значение до подтверждения кэшем избранного.
  bool? _override;

  /// «Текст · Действие» строки ARB → (текст, действие).
  static (String, String?) _splitAction(String text) {
    final int i = text.lastIndexOf(' · ');
    return i <= 0 ? (text, null) : (text.substring(0, i), text.substring(i + 3));
  }

  Future<void> _set(bool value) async {
    final ProductFavoritePort? port = ref.read(productFavoritePortProvider);
    if (port == null) return;
    final AppLocalizations l10n = AppLocalizations.of(context);
    setState(() => _override = value);
    final Result<void> r = await port.setFavorite(widget.productId, favorite: value);
    if (!mounted) return;
    if (r is FailureResult<void>) {
      setState(() => _override = !value);
      final (String msg, String? action) = _splitAction(l10n.catalog_favorite_error);
      AppSnackbar.show(
        context,
        message: msg,
        variant: AppSnackbarVariant.error,
        actionLabel: action,
        onAction: () => unawaited(_set(value)),
      );
      return;
    }
    final (String msg, String? action) = _splitAction(
      value ? l10n.catalog_favorite_added : l10n.catalog_favorite_removed,
    );
    AppSnackbar.show(context, message: msg, actionLabel: action, onAction: () => unawaited(_set(!value)));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<Set<String>>>(productFavoriteIdsProvider, (_, AsyncValue<Set<String>> next) {
      // Кэш избранного подтвердил оптимистичное значение — дальше источник истины он.
      if (_override != null && next.value?.contains(widget.productId) == _override) {
        setState(() => _override = null);
      }
    });
    if (ref.watch(productFavoritePortProvider) == null) return const SizedBox.shrink();
    final AppLocalizations l10n = AppLocalizations.of(context);
    final Set<String> ids = ref.watch(productFavoriteIdsProvider).value ?? const <String>{};
    final bool selected = _override ?? ids.contains(widget.productId);
    return FavoriteToggle(
      key: const ValueKey<String>('product-favorite'),
      selected: selected,
      semanticLabel: selected ? l10n.ds_favorite_on_a11y : l10n.ds_favorite_add_a11y,
      onChanged: (bool v) => unawaited(_set(v)),
    );
  }
}
