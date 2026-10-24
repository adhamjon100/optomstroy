import 'package:flutter/material.dart';
import 'package:optomstroy/app/router/shells/shell_tab.dart';

/// Вкладки режима «Руководитель» (owner) — navigation.md §2.1, §14.7 (R0 §3.2, §17.2 D-15).
///
/// Каталог (просмотр, без корзины) · Клиенты · Транзакции · Отчёты (главный экран SCR-48; внутри — Аудит
/// `/admin/audit`, Пользователи `/admin/users` и Настройки `/admin/settings` в ограниченном режиме, ядро §21 п. 3)
/// · Профиль. Касса `/cashier` — только просмотр через меню.
// Глифы — карта 03 §7.7 (A11Y-019: один глиф — одно значение): каталог `category`, клиенты `group`,
// транзакции `swap_horiz`, отчёты `bar_chart`, профиль `account_circle`.
final List<ShellTab> ownerShellTabs = <ShellTab>[
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
    branch: ShellBranch.reports,
    icon: Icons.bar_chart_outlined,
    selectedIcon: Icons.bar_chart,
    label: (l10n) => l10n.reports_title,
  ),
  ShellTab(
    branch: ShellBranch.profile,
    icon: Icons.account_circle_outlined,
    selectedIcon: Icons.account_circle,
    label: (l10n) => l10n.profile_title,
  ),
];
