// Drawer корзины SCR-20 на medium и шире (02 SCR-20.2 редакции 1.16; ADR-112, D5; прототип 2026-10-29): модальный
// маршрут корневого навигатора — открывается с любой ветки сотрудника (кнопка-итог шапки UI-10-041, `F4`, пункт
// «Корзина» drawer навигации, `F8`/`F9` при закрытом drawer) поверх текущего экрана: ширина 420
// (`DsBreakpoints.cartDrawer`; в окне уже — во всю ширину), полная высота, затемнение `overlay`, сдвиг справа ANIM-025
// (250 мс `standardDecelerate`; reduce motion — crossfade 80 мс). Закрытие — крестик, тап по затемнению, `Esc`;
// после закрытия фокус возвращается на кнопку-инициатор (A11Y-011).
//
// Внутри — свой `ScaffoldMessenger` и прозрачный `Scaffold` во всё окно с [AppSnackbarRegion]: снекбары корзины
// («Позиция удалена · Отменить», «Заказ отложен · Открыть отложенные», ошибки) видны и нажимаются над затемнением.
// На compact корзина — экран `/cart` (как раньше); маршрут `/cart` остаётся экраном и на широком окне (deep link,
// уведомления, восстановление).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/cart_panel.dart';
import 'package:optomstroy/design_system/motion/ds_animations.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_motion.dart';
import 'package:optomstroy/features/cart/presentation/cart_formats.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_events_listener.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_panel_view.dart';

/// Действие, которое drawer выполняет сразу после открытия (`F8`/`F9` при закрытом drawer, 02 §3.8).
enum CartDrawerIntent {
  /// «Отложить заказ» (UI-20-015) — диалог названия.
  park,

  /// «Создать заказ» (UI-20-016) — переход в SCR-21.
  createOrder,
}

/// Открыт ли drawer корзины: защита от повторного открытия и состояние для кнопки-итога шапки (её клавиши
/// `F4`/`F8`/`F9` при открытом drawer обрабатывает сама корзина).
final cartDrawerOpenProvider = NotifierProvider<CartDrawerOpenNotifier, bool>(CartDrawerOpenNotifier.new);

/// Состояние [cartDrawerOpenProvider].
class CartDrawerOpenNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  /// Drawer открыт / закрыт.
  void set({required bool open}) => state = open;
}

/// Drawer корзины (medium и шире).
abstract final class CartDrawer {
  /// Ключ панели drawer (тесты).
  static const Key key = ValueKey<String>('cart-drawer');

  /// Ключ крестика (тесты).
  static const Key closeKey = CartPanel.closeKey;

  /// Ключ области затемнения слева от drawer (тесты).
  static const Key scrimKey = ValueKey<String>('cart-drawer-scrim');

  static RawDialogRoute<void>? _route;
  static _CartDrawerPageState? _page;

  /// Drawer открыт (маршрут в навигаторе).
  static bool get isOpen => _activeRoute != null;

  /// Drawer открыт и виден: над ним нет другого маршрута — экрана (SCR-26 «Новый клиент» из выбора клиента), диалога
  /// или листа. HID-скан в корзину — только при видимом drawer (снекбар скана — в нём).
  static bool get isCurrent => _activeRoute?.isCurrent ?? false;

  /// Маршрут открытого drawer; маршрут без навигатора (дерево снято — выход, конец теста) забывается.
  static RawDialogRoute<void>? get _activeRoute {
    final RawDialogRoute<void>? route = _route;
    if (route != null && !route.isActive) _route = null;
    return _route;
  }

  /// Фокус клавиатуры — в самом drawer (не в диалоге или листе над ним). HID-сканер считает фокус в `PopupRoute`
  /// «не для скана» (`HidScanIgnored`); для drawer корзины оболочка обрабатывает такой скан сама (02 SCR-20.4).
  static bool get ownsFocus {
    final RawDialogRoute<void>? route = _activeRoute;
    final BuildContext? focus = FocusManager.instance.primaryFocus?.context;
    return route != null && focus != null && focus.mounted && ModalRoute.of(focus) == route;
  }

  /// Контекст `Scaffold` drawer для снекбаров извне (HID-скан при открытом drawer); `null` — drawer закрыт.
  static BuildContext? get snackbarContext => isOpen ? _page?._scaffold.currentContext : null;

  /// Открыть корзину: compact — экран `/cart`; иначе — drawer 420 справа. [intent] выполняется после первого кадра;
  /// [returnFocus] — узел, на который вернётся фокус после закрытия (по умолчанию — фокус до открытия). Повторное
  /// открытие при открытом drawer ничего не делает; если на экране уже корзина `/cart` — фокус в неё.
  static Future<void> open(BuildContext context, {CartDrawerIntent? intent, FocusNode? returnFocus}) async {
    if (context.windowClass == WindowClass.compact) {
      GoRouter.of(context).go(CartPaths.cart);
      return;
    }
    if (isOpen) return;
    final CartSurface? screen = CartSurfaces.shownScreen;
    if (screen != null) {
      screen.focusCart();
      return;
    }
    final ProviderContainer container = ProviderScope.containerOf(context, listen: false);
    final FocusNode? back = returnFocus ?? FocusManager.instance.primaryFocus;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsMotion motion = context.motion;
    final bool reduce = motion.reduceMotion;
    final RawDialogRoute<void> route = RawDialogRoute<void>(
      barrierDismissible: true,
      barrierLabel: l10n.cart_drawer_close_a11y,
      barrierColor: context.colors.overlay,
      transitionDuration: reduce ? motion.reducedCrossfade : DsAnimations.bottomSheet.duration,
      pageBuilder:
          (
            BuildContext ctx,
            Animation<double> animation, // money-double: allow — анимация перехода, не деньги
            Animation<double> secondary, // money-double: allow — анимация перехода, не деньги
          ) => _CartDrawerPage(animation: animation, reduceMotion: reduce, intent: intent),
      transitionBuilder:
          (
            BuildContext ctx,
            Animation<double> animation, // money-double: allow — анимация перехода, не деньги
            Animation<double> secondary, // money-double: allow — анимация перехода, не деньги
            Widget child,
          ) => child,
    );
    _route = route;
    container.read(cartDrawerOpenProvider.notifier).set(open: true);
    try {
      await Navigator.of(context, rootNavigator: true).push<void>(route);
    } finally {
      if (identical(_route, route)) _route = null;
      try {
        container.read(cartDrawerOpenProvider.notifier).set(open: false);
      } on Object {
        // Контейнер уже уничтожен (выход из приложения, конец теста) — состояние больше никому не нужно.
      }
      if (back != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (back.context != null && back.canRequestFocus) back.requestFocus();
        });
      }
    }
  }

  /// Закрыть drawer, если он открыт (HID-скан без порта «скан в корзину», переход в маршрут ветки).
  static void close() {
    final RawDialogRoute<void>? route = _activeRoute;
    final NavigatorState? navigator = route?.navigator;
    if (route == null || navigator == null) return;
    if (route.isCurrent) {
      navigator.pop();
    } else if (route.isActive) {
      navigator.removeRoute(route);
    }
  }
}

/// Страница маршрута drawer: затемнение слева закрывает, панель 420 справа.
class _CartDrawerPage extends StatefulWidget {
  const _CartDrawerPage({required this.animation, required this.reduceMotion, this.intent});

  final Animation<double> animation; // money-double: allow — анимация перехода, не деньги
  final bool reduceMotion;
  final CartDrawerIntent? intent;

  @override
  State<_CartDrawerPage> createState() => _CartDrawerPageState();
}

class _CartDrawerPageState extends State<_CartDrawerPage> {
  final GlobalKey<ScaffoldState> _scaffold = GlobalKey<ScaffoldState>(debugLabel: 'CartDrawer.scaffold');

  /// Высота закреплённого низа (итоги и кнопки) — для снекбара узкого окна.
  final ValueNotifier<double> _bottom = ValueNotifier<double>(0); // money-double: allow — высота раскладки (lp)
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(1, 0),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: widget.animation, curve: DsAnimations.bottomSheet.curve));

  @override
  void initState() {
    super.initState();
    CartDrawer._page = this;
  }

  @override
  void dispose() {
    if (identical(CartDrawer._page, this)) CartDrawer._page = null;
    _bottom.dispose();
    super.dispose();
  }

  void _close() => unawaited(Navigator.of(context).maybePop());

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final double window = MediaQuery.sizeOf(context).width; // money-double: allow — ширина окна (lp), не деньги
    final double width = math.min(DsBreakpoints.cartDrawer, window); // money-double: allow — ширина drawer (lp)
    final Widget panel = SizedBox(
      key: CartDrawer.key,
      width: width,
      height: double.infinity, // money-double: allow — высота drawer (lp), не деньги
      child: Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: l10n.cart_title,
        child: Material(
          type: MaterialType.transparency,
          child: CartPanelView(variant: CartPanelVariant.overlay, onClose: _close, intent: widget.intent),
        ),
      ),
    );
    return ScaffoldMessenger(
      child: AppSnackbarRegion(
        endInset: width,
        bottomInset: _bottom,
        child: Scaffold(
          key: _scaffold,
          backgroundColor: Colors.transparent,
          resizeToAvoidBottomInset: false,
          // `Esc` (DismissIntent): ближайшее действие — у самого `Scaffold` (закрыть его drawer) и при закрытом drawer
          // оно выключено; `Shortcuts` до действия маршрута не доходит — закрытие корзины задано здесь.
          body: Actions(
            actions: <Type, Action<Intent>>{
              DismissIntent: CallbackAction<DismissIntent>(onInvoke: (DismissIntent _) => _close()),
            },
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                // `Scaffold` во всё окно перехватывает касания: затемнение слева закрывает drawer само (подпись для
                // диктора — у барьера маршрута, `barrierLabel`).
                GestureDetector(
                  key: CartDrawer.scrimKey,
                  behavior: HitTestBehavior.opaque,
                  excludeFromSemantics: true,
                  onTap: _close,
                ),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: widget.reduceMotion
                      ? FadeTransition(opacity: widget.animation, child: panel)
                      : SlideTransition(position: _slide, child: panel),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
