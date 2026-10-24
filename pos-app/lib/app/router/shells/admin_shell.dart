import 'package:flutter/material.dart';
import 'package:optomstroy/app/router/shells/shell_tab.dart';

/// Вкладки режима «Администратор» — R0 §9, 06 §6.4.
// Глифы — карта 03 §7.7 (A11Y-019: один глиф — одно значение): каталог `category` (`grid_view` — вид «Сетка»),
// избранное `star`, клиенты `group`, транзакции `swap_horiz`, заказ `receipt`, профиль `account_circle`.
final List<ShellTab> adminShellTabs = <ShellTab>[
  ShellTab(
    branch: ShellBranch.catalog,
    icon: Icons.category_outlined,
    selectedIcon: Icons.category,
    label: (l10n) => l10n.category_breadcrumb_root,
  ),
  ShellTab(
    branch: ShellBranch.customers,
    icon: Icons.group_outlined,
    selectedIcon: Icons.group,
    label: (l10n) => l10n.customers_search_title,
  ),
  ShellTab(
    branch: ShellBranch.transactions,
    icon: Icons.swap_horiz,
    selectedIcon: Icons.swap_horiz,
    label: (l10n) => l10n.transactions_title,
  ),
  ShellTab(
    branch: ShellBranch.admin,
    icon: Icons.admin_panel_settings_outlined,
    selectedIcon: Icons.admin_panel_settings,
    label: (l10n) => l10n.role_admin,
  ),
  ShellTab(
    branch: ShellBranch.profile,
    icon: Icons.account_circle_outlined,
    selectedIcon: Icons.account_circle,
    label: (l10n) => l10n.profile_title,
  ),
];
