import 'package:flutter/widgets.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';

/// Ветки единого `StatefulShellRoute` (app/router/routes.dart).
///
/// Порядок значений = порядок веток в `AppShellRoute`: индекс ветки равен
/// `ShellBranch.index` (сверяет тест `test/widget/router_test.dart`).
enum ShellBranch {
  /// `/catalog` — SCR-10 (staff).
  catalog,

  /// `/home` — SCR-50 (customer).
  home,

  /// `/favorites` — SCR-40.
  favorites,

  /// `/cart` — SCR-20.
  cart,

  /// `/customers` — SCR-31.
  customers,

  /// `/cashier` — SCR-30.
  cashier,

  /// `/transactions` — SCR-36.
  transactions,

  /// `/orders` — SCR-25 («Мои заказы» для customer).
  orders,

  /// `/admin/users` — SCR-45.
  admin,

  /// `/profile` — SCR-41.
  profile,

  /// `/reports` — SCR-48 (owner — главный экран; admin — через меню; navigation.md §2.2).
  reports,
}

/// Вкладка оболочки: ветка, иконка, подпись из ARB.
@immutable
class ShellTab {
  /// Создаёт описание вкладки.
  const ShellTab({required this.branch, required this.icon, required this.selectedIcon, required this.label});

  /// Ветка `StatefulShellRoute`.
  final ShellBranch branch;

  /// Иконка в обычном состоянии.
  final IconData icon;

  /// Иконка выбранной вкладки.
  final IconData selectedIcon;

  /// Подпись (строка ARB).
  final String Function(AppLocalizations l10n) label;
}

/// Ссылка группы «Другие разделы» drawer навигации сотрудника (D3, ADR-112; navigation.md §2.2): путь маршрута
/// (переход `go` — по правилу веток), иконка по карте 03 §7.7 и подпись из ARB. Видимость — по
/// `isPathAllowedForRole` (G-7).
@immutable
class ShellLink {
  /// Создаёт ссылку.
  const ShellLink({required this.path, required this.icon, required this.label, IconData? selectedIcon})
    : selectedIcon = selectedIcon ?? icon;

  /// Путь (`/cart/parked`, `/orders`, `/admin/audit`…).
  final String path;

  /// Иконка в обычном состоянии.
  final IconData icon;

  /// Иконка выбранного пункта.
  final IconData selectedIcon;

  /// Подпись (строка ARB).
  final String Function(AppLocalizations l10n) label;
}
