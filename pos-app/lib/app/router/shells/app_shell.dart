import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/shells/admin_shell.dart';
import 'package:optomstroy/app/router/shells/app_mode.dart';
import 'package:optomstroy/app/router/shells/cashier_shell.dart';
import 'package:optomstroy/app/router/shells/customer_shell.dart';
import 'package:optomstroy/app/router/shells/owner_shell.dart';
import 'package:optomstroy/app/router/shells/seller_shell.dart';
import 'package:optomstroy/app/router/shells/shell_tab.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/nav_destination.dart';
import 'package:optomstroy/design_system/layout/adaptive_scaffold.dart';
import 'package:optomstroy/features/cashier/presentation/cashier_format.dart';
import 'package:optomstroy/features/cashier/presentation/cashier_scan.dart';
import 'package:optomstroy/features/cashier/presentation/providers/cashier_ports.dart';
import 'package:optomstroy/features/checkout/presentation/widgets/order_submission_overlay.dart';
import 'package:optomstroy/features/notifications/presentation/widgets/notification_announcements.dart';
import 'package:optomstroy/features/scan/presentation/hid_scan_scope.dart';
import 'package:optomstroy/features/scan/scan_providers.dart' show HidScanEvent, HidScanIgnored, HidScanned;
import 'package:optomstroy/features/sync_status/presentation/widgets/sync_connected_widgets.dart';

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

/// Оболочка `StatefulShellRoute` (D-18, 03 §9.54–§9.56; 02 §2 «Оболочка»).
///
/// Раскладка — `AdaptiveScaffold`: compact — `BottomNavBar`, medium — `NavigationRailApp` 72,
/// expanded/large — rail 72 (свёрнутый сайдбар оболочки). Плитки разделов роли над категориями
/// сайдбара SCR-10 (02 UI-10-008, B1) — EQ-FINT-01: до них на expanded разделы роли — rail.
/// Баннер оболочки — индикатор первичной загрузки кэша каталога «Загружаем каталог… N %» (NFR-PERF-006,
/// RM-E-009). Шапку, баннер офлайна и панель корзины рисуют сами экраны веток (SCR-10/50 — `CatalogWorkspace`).
///
/// HID-сканер (`HidScanScope`, RM-E-010) подключён к оболочке режимов сотрудников: скан вне полей
/// ввода на любом экране ветки → поиск по штрихкоду → карточка SCR-14 (или «не найдено» → SCR-11).
/// Касса перехватывает скан ([cashierHidOverride], 02 п. 2.2.11): на SCR-30 — код заказа → SCR-38 (UI-30-019),
/// на SCR-38 — скан игнорируется с подсказкой `payment_scan_disabled` (SCR-38.12).
///
/// Этап F: [OrderSubmissionHost] — неизвестный результат `POST /orders` (после перезапуска — поиск заказа по ключу,
/// переход в SCR-22 / SCR-21; 02 SCR-20.11, ядро §22.6); [NotificationAnnouncements] — снекбар UI-44-011 о новых
/// уведомлениях `severity=error` вне оформления и приёма оплаты (02 SCR-44.4).
class AppShell extends ConsumerWidget {
  /// Создаёт оболочку над [navigationShell].
  const AppShell({required this.navigationShell, super.key});

  /// Состояние веток от go_router.
  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final AppMode mode = ref.watch(appModeProvider);
    final List<ShellTab> tabs = shellTabsFor(mode);
    final int current = tabs.indexWhere((ShellTab tab) => tab.branch.index == navigationShell.currentIndex);
    void select(int index) {
      final int branch = tabs[index].branch.index;
      navigationShell.goBranch(branch, initialLocation: branch == navigationShell.currentIndex);
    }

    final Widget scaffold = Scaffold(
      body: AdaptiveScaffold(
        body: navigationShell,
        destinations: <NavDestination>[
          for (final ShellTab tab in tabs)
            NavDestination(icon: tab.icon, selectedIcon: tab.selectedIcon, label: tab.label(l10n)),
        ],
        selectedIndex: current < 0 ? 0 : current,
        onDestinationSelected: select,
        onReselect: select,
        banner: const CatalogInitialLoadBanner(),
      ),
    );
    return HidScanScope(
      enabled: hidScannerEnabledFor(mode),
      onEvent: (HidScanEvent event) => cashierHidOverride(context, ref, event),
      child: OrderSubmissionHost(child: NotificationAnnouncements(child: scaffold)),
    );
  }
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
