import 'package:flutter/material.dart';
import 'package:optomstroy/app/router/shells/shell_tab.dart';

/// Вкладки режима «Продавец (seller, senior_seller)» — R0 §9, 06 §6.4.
// Глифы — карта 03 §7.7 (A11Y-019: один глиф — одно значение): каталог `category` (`grid_view` — вид «Сетка»),
// избранное `star`, клиенты `group`, транзакции `swap_horiz`, заказ `receipt`, профиль `account_circle`.
final List<ShellTab> sellerShellTabs = <ShellTab>[
  ShellTab(
    branch: ShellBranch.catalog,
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
    branch: ShellBranch.customers,
    icon: Icons.group_outlined,
    selectedIcon: Icons.group,
    label: (l10n) => l10n.customers_search_title,
  ),
  ShellTab(
    branch: ShellBranch.profile,
    icon: Icons.account_circle_outlined,
    selectedIcon: Icons.account_circle,
    label: (l10n) => l10n.profile_title,
  ),
];
