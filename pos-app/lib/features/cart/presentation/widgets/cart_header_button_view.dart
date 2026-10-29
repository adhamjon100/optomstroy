// Кнопка-итог корзины в шапке medium+ (02 UI-10-041 редакции 1.16; 03 §9.70 `TopAppBarCartButton`; ADR-112, D5) на
// данных `cartControllerProvider`: бейдж — число позиций, вторая строка — последний итог сервера («≈», пока изменения
// не подтверждены; «N поз.», пока ответа сервера нет — D-23, MNY-001, без локального пересчёта), первая строка —
// «Корзина · 6 шт» (единицы, как прежняя подпись `CartFab`; шапке не хватает места — строка свёрнута, итог одной
// строкой; «5 поз. · 6 шт» — в тултипе, ADR-112 «паритет функций, раунд 2»), иконка предупреждения с тултипом «В корзине есть предупреждения» (и в `Semantics`) —
// изменились цены, не хватает остатка, позиция недоступна или конфликт версий; при неудачном сохранении (записи
// `dead`, строка `failed`) — та же иконка с текстом «Корзина не сохранена» (повтор — в drawer, «Ошибка сохранения ·
// Повторить»). Нажатие — drawer корзины 420 (`CartDrawer`); после закрытия фокус возвращается на кнопку (A11Y-011).
//
// Клавиши при закрытом drawer (02 §3.8, AC-UI-20-020): `F4` — открыть drawer (фокус в корзину), `F8`/`F9` при
// непустой корзине — открыть drawer и сразу «Отложить заказ» / «Создать заказ». `HardwareKeyboard` вызывает все
// обработчики подряд, поэтому кнопка молчит, если drawer уже открыт (клавиши обрабатывает сама корзина), фокус в
// диалоге или листе (`PopupRoute`), маршрут под другим экраном (SCR-21 обрабатывает `F9` сам; панель SCR-14 на
// expanded/large экраном не считается — клавиши работают и при ней) или на экране уже корзина `/cart`. Вокруг кнопки — постоянно смонтированный слушатель фоновых событий корзины
// ([CartEventsListener]). Корень подставляет виджет в порт `catalogCartButtonProvider` (catalog ↛ cart).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/top_app_bar_cart_button.dart';
import 'package:optomstroy/design_system/layout/route_activity.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/presentation/providers/cart_controller.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_drawer.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_events_listener.dart';

/// Данные кнопки (сравнение по значению — кнопка не перестраивается на каждое событие корзины).
typedef CartHeaderData = ({int count, Money? total, bool preliminary, bool warning, bool saveFailed, String units});

/// Выборка данных кнопки из состояния корзины.
CartHeaderData cartHeaderDataOf(CartState s) => (
  count: s.positions,
  total: s.server?.total,
  preliminary: s.preliminary,
  warning: s.hasPriceChanges || s.hasStockShortage || s.hasUnavailable || s.conflict != null,
  // «Не сохранено — повторить» видно и при закрытом drawer (паритет функций ADR-112: прежде — постоянная CP).
  saveFailed: s.syncStatus.dead > 0 || s.lines.any((CartLineView l) => l.failed),
  units: s.unitsText('').trim(),
);

/// Кнопка-итог корзины шапки на данных корзины.
class CartHeaderButtonView extends ConsumerStatefulWidget {
  /// Создаёт кнопку.
  const CartHeaderButtonView({super.key});

  /// Ключ кнопки (тесты).
  static const Key buttonKey = ValueKey<String>('cart-header-button');

  @override
  ConsumerState<CartHeaderButtonView> createState() => _CartHeaderButtonViewState();
}

class _CartHeaderButtonViewState extends ConsumerState<CartHeaderButtonView> {
  final FocusNode _focus = FocusNode(debugLabel: 'cart-header-button');

  /// Ветка на экране (`TickerMode`, из [build]) и элемент в дереве.
  bool _tickerOn = true;
  bool _inTree = true;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
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
    HardwareKeyboard.instance.removeHandler(_onKey);
    _focus.dispose();
    super.dispose();
  }

  void _open({CartDrawerIntent? intent}) => unawaited(CartDrawer.open(context, intent: intent, returnFocus: _focus));

  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent) return false;
    final LogicalKeyboardKey k = e.logicalKey;
    if (k != LogicalKeyboardKey.f4 && k != LogicalKeyboardKey.f8 && k != LogicalKeyboardKey.f9) return false;
    // Панель SCR-14 (expanded/large) над страницей шапки — экран остаётся активным: F4/F8/F9 на SCR-10…SCR-14
    // (02 §3.8; у SCR-14 своих F4/F8/F9 нет).
    if (!mounted || !_inTree || !_tickerOn || !dsRouteIsCurrent(context, allowPanels: true)) return false;
    if (context.windowClass == WindowClass.compact) return false;
    // Drawer открыт (или ещё закрывается) либо на экране экран `/cart` — клавиши у самой корзины.
    if (ref.read(cartDrawerOpenProvider) || CartDrawer.isOpen || CartSurfaces.anyShown) return false;
    final BuildContext? fc = FocusManager.instance.primaryFocus?.context;
    if (fc != null && ModalRoute.of(fc) is PopupRoute) return false;
    if (k == LogicalKeyboardKey.f4) {
      _open();
      return true;
    }
    final CartState s = ref.read(cartControllerProvider);
    if (s.lines.isEmpty) return false;
    if (k == LogicalKeyboardKey.f8) {
      if (!cartPermissionsFor(ref.read(cartViewerRoleProvider)).canPark) return false;
      _open(intent: CartDrawerIntent.park);
      return true;
    }
    _open(intent: CartDrawerIntent.createOrder);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    _tickerOn = TickerMode.of(context);
    final AppLocalizations l10n = AppLocalizations.of(context);
    final CartHeaderData d = ref.watch(cartControllerProvider.select(cartHeaderDataOf));
    final Money? total = d.total;
    final String totalText = total == null
        ? l10n.cart_positions_short(d.count)
        : '${d.preliminary ? '≈ ' : ''}${PriceText.format(total, fixed2: true)}';
    // AC-UI-20-002: «Открыть корзину, 5 позиций, 6 шт, 16 007 сом 50 тыйын» — единицы и сумма словами; при
    // предупреждении — «…, В корзине есть предупреждения» (warning — иконка и текст, ядро §24.1).
    final String base = total == null
        ? l10n.cart_fab_a11y_nototal(d.count)
        : l10n.cart_fab_a11y(
            d.count,
            d.units.isEmpty ? PriceText.spoken(total) : '${d.units}, ${PriceText.spoken(total)}',
          );
    final List<String> warnings = <String>[
      if (d.saveFailed) l10n.cart_header_save_failed,
      if (d.warning) l10n.cart_header_warning,
    ];
    final String warningText = warnings.join('\n');
    final String semantic = warnings.isEmpty ? base : '$base, ${warnings.join(', ')}';
    // Строку «Корзина · 6 шт» шапка сворачивает по своей ширине (`TopAppBarFit`, 02 §3.1 п. 7, ADR-112): итог
    // сервера виден всегда (02 UI-10-041), число позиций и единиц («5 поз. · 6 шт») — в тултипе и `Semantics`.
    final String? counter = d.count == 0 || d.units.isEmpty
        ? null
        : l10n.cart_counter_units(l10n.cart_positions_short(d.count), d.units);
    return CartEventsListener(
      child: TopAppBarCartButton(
        key: CartHeaderButtonView.buttonKey,
        label: d.count == 0 || d.units.isEmpty ? l10n.cart_title : l10n.cart_header_label_units(d.units),
        count: d.count,
        totalText: totalText,
        warning: warnings.isNotEmpty,
        warningText: warningText,
        countTooltip: counter,
        semanticLabel: semantic,
        focusNode: _focus,
        onTap: _open,
      ),
    );
  }
}
