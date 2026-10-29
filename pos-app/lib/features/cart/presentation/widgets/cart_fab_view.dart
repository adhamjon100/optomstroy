// `CartFab` корзины (02 UI-20-019 / UI-10-040; 03 §9.30; ядро §17.5) для compact SCR-10/11/12 и для `customer` на
// medium (у сотрудника на medium и шире вместо панели-итога — кнопка-итог в шапке, ADR-112): «Корзина», бейдж
// позиций, «5 поз. · 6 шт» (`cart_counter_units`), итог сервера, иконка предупреждения при изменениях цен/остатков.
// compact — переход в `/cart`; medium и шире — drawer корзины 420 справа (`CartDrawer`, 02 SCR-20.2 редакции 1.16).
// Пустая корзина — панель скрыта. Корень подставляет виджет в `catalogCartFabProvider` каталога.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/cart_fab.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/layout/route_activity.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/cart/presentation/providers/cart_controller.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_drawer.dart';

/// `CartFab` на данных корзины.
class CartFabView extends ConsumerStatefulWidget {
  /// Создаёт панель-итог.
  const CartFabView({super.key});

  /// Открыть корзину: compact — экран `/cart`, иначе — drawer корзины 420 ([CartDrawer.open]).
  static Future<void> openCart(BuildContext context) => CartDrawer.open(context);

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

  /// `F4` — корзина (03 A11Y-009, §9.27; 02 §3.8): там, где смонтирована панель-итог (compact, `customer` на
  /// medium), открывает корзину. На expanded/large панели-итога нет — `F4` обрабатывает кнопка-итог шапки.
  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.f4) return false;
    // Над страницей экрана могут лежать записи без содержимого (каталог на medium: категория, поиск) — экран активен.
    if (!mounted || !TickerMode.of(context) || !dsRouteIsCurrent(context)) return false;
    final WindowClass wc = context.windowClass;
    if (wc == WindowClass.expanded || wc == WindowClass.large) return false;
    if (CartDrawer.isOpen) return false;
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
