import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/bottom_nav_bar.dart';
import 'package:optomstroy/design_system/components/nav_destination.dart';
import 'package:optomstroy/design_system/components/navigation_rail_app.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Навигация каркаса на medium и шире (03 §9.54; ADR-112).
enum DsShellNavigation {
  /// `NavigationRailApp` 72 на medium, rail / сайдбар на expanded/large (D-18) — режим клиента, витрина.
  rail,

  /// Без rail и сайдбара навигации: разделы — drawer по «бургеру» шапки (`NavigationDrawerApp`) и меню
  /// аватара; оболочка сотрудника на medium+ (D3, ADR-112). compact не меняется (`BottomNavBar`).
  none,
}

/// Корневой каркас `AdaptiveScaffold` (03 §9.54, раздел 8; D-18, ADR-112): раскладка по классу окна.
///
/// * compact (< 600): шапка + тело + `CartFab` + `BottomNavBar`;
/// * medium (600–1023): [DsShellNavigation.rail] — `NavigationRailApp` 72 + шапка + тело;
///   [DsShellNavigation.none] — шапка + тело (навигация — drawer оболочки);
/// * expanded/large (≥ 1024): шапка + сайдбар 240/292 (или rail 72 при свёрнутом сайдбаре; при
///   [DsShellNavigation.none] — без rail) + тело + `CartPanel` 320/340 (если переданы).
///
/// Смена класса окна не теряет состояние тела и корзины (п. 8.7): они переносятся по `GlobalKey`.
/// Без [destinations] — режим `auth` (одна колонка, фон `surface`, без навигации).
/// Навигацию (`StatefulShellRoute`), drawer, горячие клавиши и HID-сканер подключает `app/router/shells`.
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
    this.navigation = DsShellNavigation.rail,
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

  /// Навигация на medium и шире: rail (по умолчанию) или без неё (drawer оболочки, ADR-112).
  final DsShellNavigation navigation;

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
    // Тело — отдельный узел семантики: `ModalBarrier` страниц вложенного навигатора ветки (`BlockSemantics`) иначе
    // скрывал бы от диктора всё, что нарисовано раньше в том же узле, — шапку оболочки, rail (A11Y, WCAG 4.1.2).
    final Widget body = Semantics(
      container: true,
      explicitChildNodes: true,
      child: KeyedSubtree(key: _bodyKey, child: widget.body),
    );
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
      WindowClass.medium when widget.navigation == DsShellNavigation.none => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ?top,
          ?widget.banner,
          Expanded(child: body),
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
                else if (widget.navigation == DsShellNavigation.rail)
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
