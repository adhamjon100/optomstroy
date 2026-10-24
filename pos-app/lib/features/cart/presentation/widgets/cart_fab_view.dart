// `CartFab` корзины (02 UI-20-019 / UI-10-040; 03 §9.30; ядро §17.5) для compact/medium SCR-10/11/12: «Корзина»,
// бейдж позиций, «5 поз. · 6 шт» (`cart_counter_units`), итог сервера, иконка предупреждения при изменениях цен/
// остатков. compact — переход в `/cart`; medium — `CartPanel.overlay` 320 справа (02 SCR-20.2). Пустая корзина —
// панель скрыта. Корень подставляет виджет в `catalogCartFabProvider` каталога.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/cart_fab.dart';
import 'package:optomstroy/design_system/components/cart_panel.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/motion/ds_animations.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/cart/presentation/cart_formats.dart';
import 'package:optomstroy/features/cart/presentation/providers/cart_controller.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_panel_view.dart';

/// `CartFab` на данных корзины.
class CartFabView extends ConsumerStatefulWidget {
  /// Создаёт панель-итог.
  const CartFabView({super.key});

  /// Открыть корзину: compact — экран `/cart`, иначе — side sheet `CartPanel.overlay`.
  static Future<void> openCart(BuildContext context) async {
    if (context.windowClass == WindowClass.compact) {
      GoRouter.of(context).go(CartPaths.cart);
      return;
    }
    // `CartPanel.overlay` 320 справа (02 SCR-20.2): своя высота окна — тело `AppBottomSheet` прокручивается и не даёт
    // панели (закреплённые итоги и кнопки) ограниченной высоты.
    final AppLocalizations l10n = AppLocalizations.of(context);
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: l10n.ds_button_close,
      barrierColor: context.colors.overlay,
      transitionDuration: context.motion.of(DsAnimations.bottomSheet.duration),
      pageBuilder:
          (
            BuildContext ctx,
            Animation<double> a, // money-double: allow — анимация перехода, не деньги
            Animation<double> b, // money-double: allow — анимация перехода, не деньги
          ) => Align(
            alignment: AlignmentDirectional.centerEnd,
            child: SizedBox(
              width: cartOverlayWidth,
              child: Material(
                type: MaterialType.transparency,
                child: CartPanelView(variant: CartPanelVariant.overlay, onClose: () => Navigator.of(ctx).maybePop()),
              ),
            ),
          ),
      transitionBuilder:
          (
            BuildContext ctx,
            Animation<double> a, // money-double: allow — анимация перехода, не деньги
            Animation<double> b, // money-double: allow — анимация перехода, не деньги
            Widget child,
          ) => SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(1, 0),
              end: Offset.zero,
            ).animate(CurvedAnimation(parent: a, curve: DsAnimations.bottomSheet.curve)),
            child: child,
          ),
    );
  }

  @override
  ConsumerState<CartFabView> createState() => _CartFabViewState();
}

class _CartFabViewState extends ConsumerState<CartFabView> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  /// `F4` — корзина (03 A11Y-009, §9.27; 02 SCR-20.2 medium: «открытие — кнопка-итог в шапке или F4»): на
  /// compact/medium открывает корзину (на expanded корзина — постоянная панель, фокус в неё ставит `CartPanelView`).
  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.f4) return false;
    if (!mounted || !TickerMode.of(context) || !(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    final WindowClass wc = context.windowClass;
    if (wc == WindowClass.expanded || wc == WindowClass.large) return false;
    final BuildContext? fc = FocusManager.instance.primaryFocus?.context;
    if (fc != null && ModalRoute.of(fc) is PopupRoute) return false;
    unawaited(CartFabView.openCart(context));
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final CartState s = ref.watch(cartControllerProvider);
    final int count = s.positions;
    if (count == 0) return const SizedBox.shrink();
    final Money? total = s.server?.total;
    final String units = s.unitsText('').trim();
    return Padding(
      padding: EdgeInsets.fromLTRB(context.space.s4, context.space.s2, context.space.s4, context.space.s2),
      child: CartFab(
        label: l10n.cart_title,
        count: count,
        caption: units.isEmpty
            ? l10n.cart_positions_short(count)
            : l10n.cart_counter_units(l10n.cart_positions_short(count), units),
        total: total,
        warning: s.hasPriceChanges || s.hasStockShortage || s.hasUnavailable,
        // AC-UI-20-002: «Открыть корзину, 5 позиций, 6 шт, 16 007 сом 50 тыйын» — единицы и сумма словами.
        semanticLabel: total == null
            ? l10n.cart_fab_a11y_nototal(count)
            : l10n.cart_fab_a11y(count, units.isEmpty ? PriceText.spoken(total) : '$units, ${PriceText.spoken(total)}'),
        onTap: () => unawaited(CartFabView.openCart(context)),
      ),
    );
  }
}
