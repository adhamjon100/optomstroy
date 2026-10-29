// Фоновые события корзины без открытой панели (02 SCR-20.8, SCR-20.9; ADR-112, D5). До редакции 1.16 постоянная CP
// на expanded была смонтирована всегда и сразу показывала диалог конфликта версий (UI-20-027), снекбары «Корзина
// обновлена с сервера», «Слишком много позиций» и отказы синхронизации. Корзина на medium и шире — drawer по кнопке,
// поэтому эти события слушает постоянно смонтированный [CartEventsListener] у кнопки-итога шапки.
//
// Одна поверхность на событие: пока на экране есть корзина SCR-20 (drawer или экран `/cart`, реестр
// [CartSurfaces]), снекбары показывает она, а слушатель молчит; диалог конфликта — один на приложение
// ([CartConflictPrompt]).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/error_texts.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/domain/sync/cart_sync.dart';
import 'package:optomstroy/features/cart/presentation/providers/cart_controller.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_dialogs.dart';

/// Корзина SCR-20 на экране (`CartPanelView`): drawer или экран `/cart`.
abstract interface class CartSurface {
  /// Видна пользователю: смонтирована, ветка на экране (`TickerMode`), маршрут верхний (для экрана).
  bool get cartShown;

  /// Drawer корзины (а не экран `/cart`).
  bool get cartIsDrawer;

  /// Поставить фокус в корзину (`F4`).
  void focusCart();
}

/// Реестр корзин SCR-20 на экране: кнопка шапки и слушатель фоновых событий уступают видимой корзине.
abstract final class CartSurfaces {
  static final Set<CartSurface> _all = <CartSurface>{};

  /// Корзина смонтирована.
  static void register(CartSurface surface) => _all.add(surface);

  /// Корзина размонтирована.
  static void unregister(CartSurface surface) => _all.remove(surface);

  /// Хоть одна корзина видна.
  static bool get anyShown => _all.any((CartSurface s) => s.cartShown);

  /// Видимый экран `/cart` (не drawer) или `null`.
  static CartSurface? get shownScreen {
    for (final CartSurface s in _all) {
      if (s.cartShown && !s.cartIsDrawer) return s;
    }
    return null;
  }
}

/// Диалог конфликта версий (UI-20-027) — один на приложение, кто бы его ни открыл (панель или слушатель).
abstract final class CartConflictPrompt {
  static bool _open = false;

  /// Диалог открыт.
  static bool get isOpen => _open;

  /// Показать диалог [conflict] (если ещё не показан) и применить выбор; отказ — [onFailure].
  static Future<void> show(
    BuildContext context,
    CartController cart,
    CartVersionConflict conflict, {
    required void Function(Failure failure) onFailure,
  }) async {
    if (_open) return;
    _open = true;
    try {
      final bool? mine = await showVersionConflictDialog(context, conflict);
      if (mine == null || !context.mounted) return;
      final Failure? f = await cart.resolveConflict(applyMine: mine);
      if (f != null) onFailure(f);
    } finally {
      _open = false;
    }
  }
}

/// Слушатель фоновых событий корзины вокруг [child] (кнопка-итог шапки medium+). Действует, только пока виден
/// (`TickerMode`) и на экране нет корзины SCR-20 ([CartSurfaces.anyShown]).
class CartEventsListener extends ConsumerStatefulWidget {
  /// Создаёт слушатель.
  const CartEventsListener({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<CartEventsListener> createState() => _CartEventsListenerState();
}

class _CartEventsListenerState extends ConsumerState<CartEventsListener> {
  StreamSubscription<CartSyncEvent>? _events;
  StreamSubscription<CartNotice>? _notices;

  /// Ветка на экране (`TickerMode`, из [build]) и элемент в дереве — обработчики потоков не обращаются к предкам
  /// деактивированного элемента.
  bool _tickerOn = true;
  bool _inTree = true;

  @override
  void initState() {
    super.initState();
    _events = ref.read(cartSyncProvider).events.listen(_onSyncEvent, onError: (Object _) {});
    _notices = ref.read(cartControllerProvider.notifier).watchNotices().listen(_onNotice);
    // Конфликт, найденный до появления кнопки (в том числе восстановленный после перезапуска), — диалог сразу.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final CartVersionConflict? c = ref.read(cartControllerProvider).conflict;
      if (c != null) _showConflict(c);
    });
  }

  @override
  void deactivate() {
    _inTree = false;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _inTree = true;
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    unawaited(_notices?.cancel());
    super.dispose();
  }

  /// Слушатель действует: виден и корзины SCR-20 на экране нет.
  bool get _active => mounted && _inTree && _tickerOn && !CartSurfaces.anyShown;

  void _onNotice(CartNotice n) {
    if (!_active) return;
    final AppLocalizations l10n = AppLocalizations.of(context);
    switch (n.kind) {
      case CartNoticeKind.updatedFromServer:
        AppSnackbar.show(context, message: l10n.cart_updated_from_server(n.count));
      case CartNoticeKind.maxItems:
        AppSnackbar.show(context, message: l10n.cart_max_items('${n.count}'), variant: AppSnackbarVariant.error);
    }
  }

  void _onSyncEvent(CartSyncEvent e) {
    if (e is! CartSyncRejected || !_active) return;
    _snackError(e.failure);
  }

  void _snackError(Failure f) {
    if (!mounted) return;
    final AppLocalizations l10n = AppLocalizations.of(context);
    AppSnackbar.show(
      context,
      message: ErrorTexts.message(l10n, UiErrorMapper.fromFailure(f)),
      variant: AppSnackbarVariant.error,
    );
  }

  void _showConflict(CartVersionConflict c) {
    if (!mounted || !_inTree || !_tickerOn) return;
    unawaited(CartConflictPrompt.show(context, ref.read(cartControllerProvider.notifier), c, onFailure: _snackError));
  }

  @override
  Widget build(BuildContext context) {
    _tickerOn = TickerMode.of(context);
    ref.listen<CartVersionConflict?>(cartControllerProvider.select((CartState v) => v.conflict), (
      CartVersionConflict? previous,
      CartVersionConflict? next,
    ) {
      if (next != null && !identical(previous, next)) _showConflict(next);
    });
    return widget.child;
  }
}
