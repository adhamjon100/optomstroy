import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/bottom_nav_bar.dart';
import 'package:optomstroy/design_system/components/nav_destination.dart';
import 'package:optomstroy/design_system/components/navigation_rail_app.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Корневой каркас `AdaptiveScaffold` (03 §9.54, раздел 8; D-18): раскладка по классу окна.
///
/// * compact (< 600): шапка + тело + `CartFab` + `BottomNavBar`;
/// * medium (600–1023): `NavigationRailApp` 72 + шапка + тело (корзина — overlay у фичи);
/// * expanded/large (≥ 1024): шапка + сайдбар 240/292 (или rail 72 при свёрнутом сайдбаре) +
///   тело + `CartPanel` 320/340.
///
/// Смена класса окна не теряет состояние тела и корзины (п. 8.7): они переносятся по `GlobalKey`.
/// Без [destinations] — режим `auth` (одна колонка, фон `surface`, без навигации).
/// Навигацию (`StatefulShellRoute`), горячие клавиши и HID-сканер подключает `app/router/shells`.
class AdaptiveScaffold extends StatefulWidget {
  /// Создаёт каркас.
  const AdaptiveScaffold({
    super.key,
    required this.body,
    this.destinations = const <NavDestination>[],
    this.selectedIndex = 0,
    this.onDestinationSelected,
    this.onReselect,
    this.topBar,
    this.banner,
    this.sidebar,
    this.sidebarCollapsed = false,
    this.cartPanel,
    this.cartFab,
    this.railLeading,
    this.railTrailing,
    this.navigationLabel,
    this.windowClass,
  });

  /// Тело (контент).
  final Widget body;

  /// Пункты навигации режима (ядро §9). Пусто — режим `auth`.
  final List<NavDestination> destinations;

  /// Активный пункт.
  final int selectedIndex;

  /// Переключение ветки.
  final ValueChanged<int>? onDestinationSelected;

  /// Повторный тап по активному пункту.
  final ValueChanged<int>? onReselect;

  /// Шапка по классу окна (`TopAppBarPos.compact` / `.full`).
  final Widget Function(BuildContext context, WindowClass windowClass)? topBar;

  /// Баннер под шапкой (`OfflineBanner`).
  final Widget? banner;

  /// Сайдбар expanded/large (категории или разделы режима).
  final Widget? sidebar;

  /// Сайдбар свёрнут «бургером» до rail 72 (п. 8.4).
  final bool sidebarCollapsed;

  /// Постоянная панель корзины expanded/large.
  final Widget? cartPanel;

  /// `CartFab` (compact, над нижней навигацией).
  final Widget? cartFab;

  /// Логотип rail.
  final Widget? railLeading;

  /// Низ rail (уведомления, аватар, синхронизация).
  final List<Widget>? railTrailing;

  /// Подпись региона навигации («Навигация»).
  final String? navigationLabel;

  /// Класс окна (по умолчанию — по `MediaQuery`); для тестов и витрины.
  final WindowClass? windowClass;

  @override
  State<AdaptiveScaffold> createState() => _AdaptiveScaffoldState();
}

class _AdaptiveScaffoldState extends State<AdaptiveScaffold> {
  final GlobalKey _bodyKey = GlobalKey(debugLabel: 'AdaptiveScaffold.body');
  final GlobalKey _cartKey = GlobalKey(debugLabel: 'AdaptiveScaffold.cart');

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final WindowClass wc = widget.windowClass ?? context.windowClass;
    final double width = MediaQuery.sizeOf(context).width;
    final bool auth = widget.destinations.isEmpty;
    final Widget body = KeyedSubtree(key: _bodyKey, child: widget.body);
    final Widget? top = widget.topBar?.call(context, wc);

    if (auth) {
      return ColoredBox(
        color: c.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ?top,
            ?widget.banner,
            Expanded(child: body),
          ],
        ),
      );
    }

    final Widget content = switch (wc) {
      WindowClass.compact => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ?top,
          ?widget.banner,
          Expanded(
            child: Stack(
              children: <Widget>[
                Positioned.fill(child: body),
                if (widget.cartFab != null) PositionedDirectional(end: 16, bottom: 16, child: widget.cartFab!),
              ],
            ),
          ),
          BottomNavBar(
            destinations: widget.destinations,
            selectedIndex: widget.selectedIndex,
            onSelected: _select,
            onReselect: widget.onReselect,
          ),
        ],
      ),
      WindowClass.medium => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _rail(NavigationRailVariant.rail),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ?top,
                ?widget.banner,
                Expanded(child: body),
              ],
            ),
          ),
        ],
      ),
      WindowClass.expanded || WindowClass.large => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ?top,
          ?widget.banner,
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (widget.sidebar != null && !widget.sidebarCollapsed)
                  _zone(
                    c,
                    width: width >= 1280 ? DsBreakpoints.sidebarWide : DsBreakpoints.sidebarNarrow,
                    border: Border(right: BorderSide(color: c.border)),
                    child: widget.sidebar!,
                  )
                else
                  _rail(NavigationRailVariant.collapsedSidebar),
                Expanded(child: body),
                if (widget.cartPanel != null)
                  _zone(
                    c,
                    width: width >= 1280 ? DsBreakpoints.cartWide : DsBreakpoints.cartNarrow,
                    border: Border(left: BorderSide(color: c.border)),
                    child: KeyedSubtree(key: _cartKey, child: widget.cartPanel!),
                  ),
              ],
            ),
          ),
        ],
      ),
    };

    return ColoredBox(color: c.background, child: content);
  }

  void _select(int i) => widget.onDestinationSelected?.call(i);

  Widget _rail(NavigationRailVariant variant) => NavigationRailApp(
    destinations: widget.destinations,
    selectedIndex: widget.selectedIndex,
    onSelected: _select,
    variant: variant,
    leading: widget.railLeading,
    trailing: widget.railTrailing,
    semanticLabel: widget.navigationLabel,
  );

  Widget _zone(DsColors c, {required double width, required Border border, required Widget child}) => Container(
    width: width,
    decoration: BoxDecoration(color: c.surface, border: border),
    child: child,
  );
}
