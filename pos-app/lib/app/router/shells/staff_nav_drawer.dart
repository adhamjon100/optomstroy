// Drawer навигации оболочки сотрудника на medium и шире (D3, ADR-112; 02 §3.1 п. 1, §3.2; navigation.md §2.1,
// §2.2): вместо rail и сайдбара разделы открываются «бургером» шапки. Сверху — 5 вкладок режима (`shellTabsFor`,
// выделена активная ветка, переход `goBranch`), ниже — «Другие разделы» (ссылки режима, фильтр
// `isPathAllowedForRole`, переход `go`). Пункт «Корзина» на medium+ открывает drawer корзины (D5), если оболочка
// его подключила, иначе — экран `/cart`. Esc и тап по затемнению закрывают drawer.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/guards/role_guard.dart';
import 'package:optomstroy/app/router/shells/app_mode.dart';
import 'package:optomstroy/app/router/shells/app_shell.dart' show activateShellTab, shellTabsFor;
import 'package:optomstroy/app/router/shells/shell_tab.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/navigation_drawer_app.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart' show catalogViewerRoleProvider;
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_logo.dart';

/// Путь корзины: ссылка «Корзина» открывает drawer корзины (D5), а не экран, если оболочка его подключила.
const String kShellCartPath = '/cart';

const ShellLink _parked = ShellLink(
  path: '/cart/parked',
  icon: Icons.bookmark_border_rounded,
  selectedIcon: Icons.bookmark_rounded,
  label: _parkedLabel,
);
const ShellLink _orders = ShellLink(path: '/orders', icon: Icons.receipt_outlined, label: _ordersLabel);
const ShellLink _transactions = ShellLink(path: '/transactions', icon: Icons.swap_horiz, label: _transactionsLabel);
const ShellLink _favorites = ShellLink(
  path: '/favorites',
  icon: Icons.star_border_rounded,
  selectedIcon: Icons.star_rounded,
  label: _favoritesLabel,
);
const ShellLink _cart = ShellLink(
  path: kShellCartPath,
  icon: Icons.shopping_cart_outlined,
  selectedIcon: Icons.shopping_cart,
  label: _cartLabel,
);
const ShellLink _reports = ShellLink(
  path: '/reports',
  icon: Icons.bar_chart_outlined,
  selectedIcon: Icons.bar_chart,
  label: _reportsLabel,
);
const ShellLink _cashier = ShellLink(
  path: '/cashier',
  icon: Icons.point_of_sale_outlined,
  selectedIcon: Icons.point_of_sale,
  label: _cashierLabel,
);
const ShellLink _audit = ShellLink(path: '/admin/audit', icon: Icons.fact_check_outlined, label: _auditLabel);
const ShellLink _systemSettings = ShellLink(
  path: '/admin/settings',
  icon: Icons.settings_outlined,
  selectedIcon: Icons.settings,
  label: _systemSettingsLabel,
);
const ShellLink _users = ShellLink(
  path: '/admin/users',
  icon: Icons.admin_panel_settings_outlined,
  selectedIcon: Icons.admin_panel_settings,
  label: _usersLabel,
);

String _parkedLabel(AppLocalizations l10n) => l10n.parked_title;
String _ordersLabel(AppLocalizations l10n) => l10n.orders_title;
String _transactionsLabel(AppLocalizations l10n) => l10n.transactions_title;
String _favoritesLabel(AppLocalizations l10n) => l10n.favorites_title;
String _cartLabel(AppLocalizations l10n) => l10n.cart_title;
String _reportsLabel(AppLocalizations l10n) => l10n.reports_title;
String _cashierLabel(AppLocalizations l10n) => l10n.cashier_title;
String _auditLabel(AppLocalizations l10n) => l10n.audit_title;
String _systemSettingsLabel(AppLocalizations l10n) => l10n.admin_settings_title;
String _usersLabel(AppLocalizations l10n) => l10n.admin_users_title;

/// Ссылки группы «Другие разделы» режима [mode] (порядок — как в drawer; состав по роли — фильтр
/// `isPathAllowedForRole`, guard G-7). У продавца «Корзина» — вкладка режима (на medium+ она открывает drawer
/// корзины), поэтому отдельной ссылкой не повторяется; «Касса» в режиме продавца видна только `senior_seller`
/// (navigation.md §2.2: ветка cashier у старшего продавца — через меню). Клиенту drawer не положен.
List<ShellLink> shellLinksFor(AppMode mode) => switch (mode) {
  AppMode.seller => const <ShellLink>[_cashier, _parked, _orders, _transactions],
  AppMode.cashier => const <ShellLink>[_orders, _parked, _favorites, _cart],
  AppMode.admin => const <ShellLink>[_reports, _cashier, _audit, _systemSettings, _orders, _parked, _favorites, _cart],
  AppMode.owner => const <ShellLink>[_cashier, _users, _audit, _systemSettings, _orders],
  AppMode.customer => const <ShellLink>[],
};

/// Ссылка, которой соответствует [path] (самая длинная по префиксу пути), или `null`.
ShellLink? shellLinkForPath(Iterable<ShellLink> links, String path) {
  ShellLink? best;
  for (final ShellLink l in links) {
    if ((path == l.path || path.startsWith('${l.path}/')) && (best == null || l.path.length > best.path.length)) {
      best = l;
    }
  }
  return best;
}

/// Drawer навигации оболочки сотрудника (`NavigationDrawerApp`).
class StaffNavigationDrawer extends ConsumerWidget {
  /// Создаёт drawer.
  const StaffNavigationDrawer({
    super.key,
    required this.mode,
    required this.currentBranch,
    required this.onSelectTab,
    required this.onClose,
    this.onOpenCart,
  });

  /// Режим оболочки.
  final AppMode mode;

  /// Индекс активной ветки (`StatefulNavigationShell.currentIndex`).
  final int currentBranch;

  /// Переключить вкладку режима (индекс в `shellTabsFor(mode)`).
  final ValueChanged<int> onSelectTab;

  /// Закрыть drawer.
  final VoidCallback onClose;

  /// Открыть drawer корзины (D5); `null` — пункт «Корзина» открывает экран `/cart`.
  final VoidCallback? onOpenCart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final RoleCode? role = ref.watch(catalogViewerRoleProvider);
    final List<ShellTab> tabs = shellTabsFor(mode);
    final List<ShellLink> links = <ShellLink>[
      for (final ShellLink l in shellLinksFor(mode))
        if (isPathAllowedForRole(role, l.path)) l,
    ];
    final GoRouter? router = GoRouter.maybeOf(context);
    final String path = router?.routerDelegate.currentConfiguration.uri.path ?? '';
    final ShellLink? current = shellLinkForPath(links, path);

    void openLink(ShellLink link) {
      onClose();
      if (link.path == kShellCartPath && onOpenCart != null) {
        onOpenCart!();
      } else {
        router?.go(link.path);
      }
    }

    return NavigationDrawerApp(
      key: const ValueKey<String>('shell-nav-drawer'),
      semanticLabel: l10n.shell_nav_a11y,
      header: const CatalogLogo.header(),
      onClose: onClose,
      groups: <NavigationDrawerGroup>[
        NavigationDrawerGroup(
          items: <NavigationDrawerItem>[
            for (int i = 0; i < tabs.length; i++)
              NavigationDrawerItem(
                key: ValueKey<String>('shell-nav-tab-${tabs[i].branch.name}'),
                icon: tabs[i].icon,
                selectedIcon: tabs[i].selectedIcon,
                label: tabs[i].label(l10n),
                // Ссылка «Другие разделы» на ту же ветку (Журнал аудита в ветке «Админ») выделяется вместо вкладки.
                selected: current == null && tabs[i].branch.index == currentBranch,
                onTap: () {
                  onClose();
                  activateShellTab(tabs, i, onSelectTab: onSelectTab, onOpenCart: onOpenCart);
                },
              ),
          ],
        ),
        NavigationDrawerGroup(
          title: l10n.shell_nav_more,
          items: <NavigationDrawerItem>[
            for (final ShellLink l in links)
              NavigationDrawerItem(
                key: ValueKey<String>('shell-nav-link-${l.path}'),
                icon: l.icon,
                selectedIcon: l.selectedIcon,
                label: l.label(l10n),
                selected: identical(l, current),
                onTap: () => openLink(l),
              ),
          ],
        ),
      ],
    );
  }
}
