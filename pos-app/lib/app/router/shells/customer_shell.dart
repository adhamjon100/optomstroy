import 'package:flutter/material.dart';
import 'package:optomstroy/app/router/shells/shell_tab.dart';

/// Вкладки режима «Клиент-покупатель (customer, R1 — ядро v1.9 §24.2)» — R0 §9, 06 §6.4.
// Глифы — карта 03 §7.7 (A11Y-019: один глиф — одно значение): каталог `category` (`grid_view` — вид «Сетка»),
// избранное `star`, клиенты `group`, транзакции `swap_horiz`, заказ `receipt`, профиль `account_circle`.
final List<ShellTab> customerShellTabs = <ShellTab>[
  ShellTab(
    branch: ShellBranch.home,
    icon: Icons.category_outlined,
    selectedIcon: Icons.category,
    label: (l10n) => l10n.category_breadcrumb_root,
  ),
  ShellTab(
    branch: ShellBranch.favorites,
    icon: Icons.star_border,
    selectedIcon: Icons.star,
    label: (l10n) => l10n.favorites_title,
  ),
  ShellTab(
    branch: ShellBranch.cart,
    icon: Icons.shopping_cart_outlined,
    selectedIcon: Icons.shopping_cart,
    label: (l10n) => l10n.cart_title,
  ),
  ShellTab(
    branch: ShellBranch.orders,
    icon: Icons.receipt_outlined,
    selectedIcon: Icons.receipt,
    label: (l10n) => l10n.orders_title_mine,
  ),
  ShellTab(
    branch: ShellBranch.profile,
    icon: Icons.account_circle_outlined,
    selectedIcon: Icons.account_circle,
    label: (l10n) => l10n.profile_title,
  ),
];
