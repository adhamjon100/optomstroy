import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/shells/admin_shell.dart';
import 'package:optomstroy/app/router/shells/app_mode.dart';
import 'package:optomstroy/app/router/shells/cashier_shell.dart';
import 'package:optomstroy/app/router/shells/customer_shell.dart';
import 'package:optomstroy/app/router/shells/owner_shell.dart';
import 'package:optomstroy/app/router/shells/seller_shell.dart';
import 'package:optomstroy/app/router/shells/shell_tab.dart';
import 'package:optomstroy/app/router/shells/staff_nav_drawer.dart';
import 'package:optomstroy/app/router/shells/staff_shell_header.dart';
import 'package:optomstroy/app/router/window_class_scope.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/nav_destination.dart';
import 'package:optomstroy/design_system/layout/adaptive_scaffold.dart';
import 'package:optomstroy/design_system/layout/shell_scope.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_drawer.dart';
import 'package:optomstroy/features/cashier/presentation/cashier_format.dart';
import 'package:optomstroy/features/cashier/presentation/cashier_scan.dart';
import 'package:optomstroy/features/cashier/presentation/providers/cashier_ports.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart' show catalogViewerRoleProvider;
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_header.dart'
    show catalogRoleHasCart, openCatalogNotifications;
import 'package:optomstroy/features/checkout/presentation/widgets/order_submission_overlay.dart';
import 'package:optomstroy/features/notifications/presentation/widgets/notification_announcements.dart';
import 'package:optomstroy/features/scan/domain/scan_lookup.dart';
import 'package:optomstroy/features/scan/presentation/hid_scan_scope.dart';
import 'package:optomstroy/features/scan/presentation/scan_navigation.dart';
import 'package:optomstroy/features/scan/scan_providers.dart'
    show
        HidScanEvent,
        HidScanIgnored,
        HidScanned,
        lookupScannedBarcodeProvider,
        scanCartPortProvider,
        scannerWedgeServiceProvider;
import 'package:optomstroy/features/sync_status/presentation/widgets/sync_connected_widgets.dart';
import 'package:uuid/uuid.dart';

/// Вкладки оболочки для режима [mode].
List<ShellTab> shellTabsFor(AppMode mode) => switch (mode) {
  AppMode.seller => sellerShellTabs,
  AppMode.cashier => cashierShellTabs,
  AppMode.admin => adminShellTabs,
  AppMode.owner => ownerShellTabs,
  AppMode.customer => customerShellTabs,
};

/// HID-сканер в оболочке: только режимы сотрудников (02 §2.2.11; клиенту сканер не положен — 10 CUST-021).
bool hidScannerEnabledFor(AppMode mode) => mode != AppMode.customer;

/// Навигация оболочки сотрудника без rail — drawer по «бургеру» шапки (D3, ADR-112): режим сотрудника на medium+.
bool shellDrawerNavigationFor(AppMode mode, WindowClass windowClass) =>
    mode != AppMode.customer && windowClass != WindowClass.compact;

/// Оболочка `StatefulShellRoute` (D-18, ADR-112; 03 §9.54–§9.57; 02 §2 «Оболочка», §3.1, §3.2, §3.8).
///
/// Раскладка — `AdaptiveScaffold`: compact — `BottomNavBar` (все режимы); medium и шире — у сотрудника без rail
/// ([DsShellNavigation.none]): разделы — drawer навигации ([StaffNavigationDrawer] на внешнем `Scaffold`, чтобы
/// `AppBar` экранов не показывали свой «бургер») по «бургеру» шапки и меню аватара; у клиента — rail, как раньше
/// (D6). Шапка medium+ у сотрудника: на ветке «Каталог» её рисует `CatalogWorkspace` (ADR-110, одно поле поиска),
/// на остальных ветках — оболочка ([StaffShellHeader], тот же `CatalogHeader`). [DsShellScope] — мост к шапкам
/// экранов: `openNavigation` (drawer навигации).
/// Баннер оболочки — индикатор первичной загрузки кэша каталога «Загружаем каталог… N %» (NFR-PERF-006,
/// RM-E-009). Баннер офлайна и панель корзины рисуют экраны веток.
///
/// Горячие клавиши оболочки (02 §3.8; сочетания экрана имеют приоритет — обработчик оболочки выше по дереву
/// фокуса): Ctrl+1…5 — вкладка режима по порядку, как пункт первой группы drawer навигации (вкладка «Корзина» на
/// medium+ — drawer корзины, [activateShellTab]); в полях ввода не перехватываются (02 §3.8); Ctrl+Shift+N —
/// уведомления (SCR-44); F2 / Ctrl+F на ветках кроме «Каталога» (medium+) — фокус в поле поиска шапки оболочки.
///
/// HID-сканер (`HidScanScope`, RM-E-010) подключён к оболочке режимов сотрудников: скан вне полей
/// ввода на любом экране ветки → поиск по штрихкоду → карточка SCR-14 (или «не найдено» → SCR-11). При открытом и
/// видимом drawer корзины (над ним нет другого экрана, например SCR-26 «Новый клиент»; D5, 02 SCR-20.4 «Клавиатура и
/// сканер») скан добавляет товар в корзину через порт «скан в корзину»
/// (снекбар — в drawer); без порта drawer сначала закрывается, затем — прежнее действие (SCR-14 не окажется под
/// затемнением).
/// Касса перехватывает скан ([cashierHidOverride], 02 п. 2.2.11): на SCR-30 — код заказа → SCR-38 (UI-30-019),
/// на SCR-38 — скан игнорируется с подсказкой `payment_scan_disabled` (SCR-38.12).
///
/// Этап F: [OrderSubmissionHost] — неизвестный результат `POST /orders` (после перезапуска — поиск заказа по ключу,
/// переход в SCR-22 / SCR-21; 02 SCR-20.11, ядро §22.6); [NotificationAnnouncements] — снекбар UI-44-011 о новых
/// уведомлениях `severity=error` вне оформления и приёма оплаты (02 SCR-44.4).
class AppShell extends ConsumerStatefulWidget {
  /// Создаёт оболочку над [navigationShell].
  const AppShell({required this.navigationShell, super.key});

  /// Состояние веток от go_router.
  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>(debugLabel: 'AppShell.scaffold');
  final FocusNode _headerSearchFocus = FocusNode(debugLabel: 'StaffShellHeader.search');
  final TextEditingController _headerSearchText = TextEditingController();

  /// Открыть корзину поверх экрана (drawer 420, D5) — для вкладки «Корзина» drawer навигации и `Ctrl+1…5`; `null` —
  /// роль без корзины (owner, customer) или compact: корзина — маршрут `/cart`.
  Future<void> Function(BuildContext context)? _openCartFor(AppMode mode, WindowClass wc, bool hasCart) =>
      shellDrawerNavigationFor(mode, wc) && hasCart ? _openCartDrawer : null;

  Future<void> _openCartDrawer(BuildContext context) => CartDrawer.open(context);

  /// HID-скан: касса (SCR-30/SCR-38) → видимый drawer корзины → прежнее действие [HidScanScope]. Фокус в drawer
  /// (`PopupRoute`) сервис сканера помечает «не для скана» ([HidScanIgnored]); такой скан — тоже корзине, если над
  /// drawer нет диалога и сканер не приостановлен (нампад, оплата). Drawer под другим экраном (SCR-26 «Новый клиент»
  /// из выбора клиента) скан не получает: его снекбар был бы не виден — действует обычный путь [HidScanScope].
  Future<bool> _onHidEvent(HidScanEvent event) async {
    if (await _shellSearchOrderScan(event)) return true;
    if (!mounted) return false;
    if (await cashierHidOverride(context, ref, event)) return true;
    if (!mounted || !CartDrawer.isCurrent) return false;
    final String? value = switch (event) {
      HidScanned(:final String value) => value,
      HidScanIgnored(:final String value)
          when CartDrawer.ownsFocus && !ref.read(scannerWedgeServiceProvider).isSuspended =>
        value,
      _ => null,
    };
    if (value == null) return false;
    final ScanCartPort? port = ref.read(scanCartPortProvider);
    if (port == null) {
      // Без порта «скан в корзину» — прежнее действие (SCR-14 / SCR-11), но не под затемнением drawer.
      CartDrawer.close();
      await _scanAfterDrawer(value);
      return true;
    }
    await _scanIntoCart(port, value);
    return true;
  }

  /// SCR-30 (medium+): скан в поле поиска товара шапки оболочки — номер заказа (UI-30-019), а не запрос поиска
  /// товара: поле очищается (его отложенный поиск SCR-11 не выполняется), заказ открывается как при скане вне полей.
  /// Поле поиска клиента дашборда (UI-30-002) по-прежнему получает скан как текст запроса ([cashierHidOverride]).
  Future<bool> _shellSearchOrderScan(HidScanEvent event) async {
    if (event is! HidScanned || !event.fromSearchField || !_headerSearchFocus.hasPrimaryFocus) return false;
    final GoRouter? router = GoRouter.maybeOf(context);
    if (router == null || router.state.uri.path != CashierLocations.dashboard) return false;
    _headerSearchText.clear();
    return openOrderByScan(context, ref, event.value);
  }

  /// Прежнее действие скана после закрытия drawer (как [HidScanScope]): найден — SCR-14, не найден — SCR-11.
  Future<void> _scanAfterDrawer(String value) async {
    final ScanLookupOutcome outcome = await ref.read(lookupScannedBarcodeProvider)(value);
    if (!mounted) return;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final GoRouter? router = GoRouter.maybeOf(context);
    switch (outcome) {
      case ScanFound(:final ScanLookupResult result):
        unawaited(router?.push<void>(ScanLocations.product(result)));
        if (result.ambiguous) AppSnackbar.show(context, message: l10n.scan_ambiguous);
      case ScanNotFound():
        AppSnackbar.show(context, message: l10n.scan_not_found(value));
        router?.go(ScanLocations.search(value));
      case ScanLookupFailed():
        AppSnackbar.show(context, message: l10n.scan_lookup_error, variant: AppSnackbarVariant.error);
    }
  }

  /// Скан при открытом drawer: найденный товар — +шаг в корзину («Отсканировано … · Отменить»); не найден или ошибка
  /// поиска — снекбар; снекбары — в drawer (над затемнением).
  Future<void> _scanIntoCart(ScanCartPort port, String value) async {
    final ScanLookupOutcome outcome = await ref.read(lookupScannedBarcodeProvider)(value);
    switch (outcome) {
      case ScanFound(:final ScanLookupResult result):
        // Ключ идемпотентности — на каждый скан (02 SCR-17.11).
        final Result<ScanAddReceipt> added = await port.addStep(result, idempotencyKey: const Uuid().v4());
        final BuildContext? shown = _drawerSnackContext();
        if (shown == null || !shown.mounted) return;
        final AppLocalizations l10n = AppLocalizations.of(shown);
        added.fold(
          (ScanAddReceipt receipt) => AppSnackbar.show(
            shown,
            message: l10n.scan_hid_result(result.productName, receipt.quantityLabel, receipt.unitLabel ?? '', value),
            variant: AppSnackbarVariant.success,
            actionLabel: l10n.ds_button_undo,
            onAction: () => unawaited(port.undo(receipt)),
          ),
          (_) => AppSnackbar.show(shown, message: l10n.scan_lookup_error, variant: AppSnackbarVariant.error),
        );
      case ScanNotFound():
        final BuildContext? shown = _drawerSnackContext();
        if (shown == null || !shown.mounted) return;
        AppSnackbar.show(shown, message: AppLocalizations.of(shown).scan_not_found(value));
      case ScanLookupFailed():
        final BuildContext? shown = _drawerSnackContext();
        if (shown == null || !shown.mounted) return;
        AppSnackbar.show(
          shown,
          message: AppLocalizations.of(shown).scan_lookup_error,
          variant: AppSnackbarVariant.error,
        );
    }
  }

  /// Куда показать снекбар скана: `Scaffold` открытого drawer корзины, иначе — оболочка; `null` — некуда.
  BuildContext? _drawerSnackContext() {
    final BuildContext? drawer = CartDrawer.snackbarContext;
    if (drawer != null && drawer.mounted) return drawer;
    return mounted ? context : null;
  }

  @override
  void dispose() {
    _headerSearchFocus.dispose();
    _headerSearchText.dispose();
    super.dispose();
  }

  void _openNavigation() => _scaffoldKey.currentState?.openDrawer();

  void _closeNavigation() => _scaffoldKey.currentState?.closeDrawer();

  void _selectTab(List<ShellTab> tabs, int index) {
    if (index < 0 || index >= tabs.length) {
      return;
    }
    final int branch = tabs[index].branch.index;
    widget.navigationShell.goBranch(branch, initialLocation: branch == widget.navigationShell.currentIndex);
  }

  /// `Ctrl+1…5`: как пункт первой группы drawer навигации ([activateShellTab]); в поле ввода сочетание не
  /// перехватывается (02 §3.8) — вкладка не меняется.
  void _tabKey(List<ShellTab> tabs, int index, Future<void> Function(BuildContext context)? openCart) {
    if (shellFocusInTextField()) return;
    activateShellTab(
      tabs,
      index,
      onSelectTab: (int i) => _selectTab(tabs, i),
      onOpenCart: openCart == null ? null : () => unawaited(openCart(context)),
    );
  }

  /// Ctrl+Shift+N — центр уведомлений (02 §3.8, SCR-44): на expanded/large — popover, иначе экран.
  void _openNotifications(WindowClass wc) => openCatalogNotifications(context, ref, wc);

  void _focusHeaderSearch() {
    _headerSearchFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final AppMode mode = ref.watch(appModeProvider);
    final List<ShellTab> tabs = shellTabsFor(mode);
    final StatefulNavigationShell shell = widget.navigationShell;
    final int current = tabs.indexWhere((ShellTab tab) => tab.branch.index == shell.currentIndex);
    final WindowClass wc = context.windowClass;
    final bool staff = mode != AppMode.customer;
    final bool drawerNav = shellDrawerNavigationFor(mode, wc);
    // На ветке «Каталог» шапку рисует `CatalogWorkspace` (ADR-110): вторая шапка дала бы два поля поиска.
    final bool shellHeader = drawerNav && shell.currentIndex != ShellBranch.catalog.index;
    void select(int index) => _selectTab(tabs, index);
    final Future<void> Function(BuildContext context)? openCart = _openCartFor(
      mode,
      wc,
      catalogRoleHasCart(ref.watch(catalogViewerRoleProvider)),
    );

    final Widget scaffold = Scaffold(
      key: _scaffoldKey,
      drawer: drawerNav
          ? StaffNavigationDrawer(
              mode: mode,
              currentBranch: shell.currentIndex,
              onSelectTab: select,
              onClose: _closeNavigation,
              onOpenCart: openCart == null ? null : () => unawaited(openCart(context)),
            )
          : null,
      drawerScrimColor: context.colors.overlay,
      drawerEnableOpenDragGesture: false,
      body: AdaptiveScaffold(
        // Построители страниц веток зависят только от класса окна (не от каждого пикселя размера).
        body: WindowClassScope(windowClass: wc, child: shell),
        destinations: <NavDestination>[
          for (final ShellTab tab in tabs)
            NavDestination(icon: tab.icon, selectedIcon: tab.selectedIcon, label: tab.label(l10n)),
        ],
        selectedIndex: current < 0 ? 0 : current,
        onDestinationSelected: select,
        onReselect: select,
        navigation: drawerNav ? DsShellNavigation.none : DsShellNavigation.rail,
        topBar: shellHeader
            ? (BuildContext context, WindowClass windowClass) => StaffShellHeader(
                mode: mode,
                windowClass: windowClass,
                focusNode: _headerSearchFocus,
                controller: _headerSearchText,
                // Часы шапки на ветке «Касса» — с полной датой (UI-30-013, AC-UI-30-020).
                clockLongDate: shell.currentIndex == ShellBranch.cashier.index,
              )
            : null,
        banner: const CatalogInitialLoadBanner(),
      ),
    );
    final Widget scoped = DsShellScope(openNavigation: drawerNav ? _openNavigation : null, child: scaffold);
    final Widget withKeys = staff
        ? CallbackShortcuts(
            bindings: <ShortcutActivator, VoidCallback>{
              for (int i = 0; i < tabs.length && i < 9; i++)
                SingleActivator(LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + i), control: true): () =>
                    _tabKey(tabs, i, openCart),
              const SingleActivator(LogicalKeyboardKey.keyN, control: true, shift: true): () => _openNotifications(wc),
              if (shellHeader) ...<ShortcutActivator, VoidCallback>{
                const SingleActivator(LogicalKeyboardKey.f2): _focusHeaderSearch,
                const SingleActivator(LogicalKeyboardKey.keyF, control: true): _focusHeaderSearch,
              },
            },
            // Узел без остановки Tab: принимает клавиши, пока фокус не стоит ни на одном элементе экрана.
            child: Focus(autofocus: true, skipTraversal: true, child: scoped),
          )
        : scoped;
    return HidScanScope(
      enabled: hidScannerEnabledFor(mode),
      onEvent: _onHidEvent,
      child: OrderSubmissionHost(child: NotificationAnnouncements(child: withKeys)),
    );
  }
}

/// Вкладка [index] режима — общее действие пункта первой группы drawer навигации и `Ctrl+1…5` (02 §3.8): вкладка
/// «Корзина» при [onOpenCart] (medium+, роль с корзиной) открывает drawer корзины (D5), остальные —
/// [onSelectTab] (`goBranch`).
void activateShellTab(
  List<ShellTab> tabs,
  int index, {
  required ValueChanged<int> onSelectTab,
  VoidCallback? onOpenCart,
}) {
  if (index < 0 || index >= tabs.length) return;
  if (tabs[index].branch == ShellBranch.cart && onOpenCart != null) {
    onOpenCart();
  } else {
    onSelectTab(index);
  }
}

/// Фокус клавиатуры — в поле ввода (`EditableText`): сочетания оболочки, которые 02 §3.8 «в полях ввода не
/// перехватывает», молчат.
bool shellFocusInTextField() {
  final BuildContext? focus = FocusManager.instance.primaryFocus?.context;
  if (focus == null || !focus.mounted) return false;
  return focus.widget is EditableText || focus.findAncestorStateOfType<EditableTextState>() != null;
}

/// Перехват HID-скана кассой поверх поиска товара по штрихкоду (02 п. 2.2.11): `true` — скан обработан.
/// Адрес — верхний маршрут стека (SCR-38 — root-маршрут над оболочкой).
Future<bool> cashierHidOverride(BuildContext context, WidgetRef ref, HidScanEvent event) async {
  final GoRouter? router = GoRouter.maybeOf(context);
  if (router == null || !context.mounted) return false;
  // Верхний маршрут стека, в том числе открытый `push` (`currentConfiguration.uri` — адрес без imperative-маршрутов).
  final String path = router.state.uri.path;
  if (isPaymentLocation(path)) {
    // SCR-38 и финансовые формы: скан игнорируется (SCR-38.12).
    if (event is HidScanned || event is HidScanIgnored) showPaymentScanDisabled(context);
    return true;
  }
  if (path == CashierLocations.dashboard && event is HidScanned) {
    // Скан в поле поиска клиента SCR-30 — уже текст запроса (UI-30-002): поиск товара не запускается.
    if (event.fromSearchField) return CashierRoles.canAcceptPayment(ref.read(cashierViewerRoleProvider));
    return openOrderByScan(context, ref, event.value);
  }
  return false;
}
