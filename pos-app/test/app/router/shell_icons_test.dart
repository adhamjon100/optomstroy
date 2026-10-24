// A11Y-019 / 03 §7.7: глифы вкладок оболочки берутся из карты обязательных иконок, значение глифа не меняется
// между экранами — избранное `star` (не сердце), транзакции `swap_horiz` (`receipt_long` — «долг без оплаты»),
// заказ `receipt` (`inventory_2` — «пустая категория»), каталог не совпадает с видом «Сетка» `grid_view`.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/app/router/shells/admin_shell.dart';
import 'package:optomstroy/app/router/shells/cashier_shell.dart';
import 'package:optomstroy/app/router/shells/customer_shell.dart';
import 'package:optomstroy/app/router/shells/owner_shell.dart';
import 'package:optomstroy/app/router/shells/seller_shell.dart';
import 'package:optomstroy/app/router/shells/shell_tab.dart';

void main() {
  final Map<String, List<ShellTab>> modes = <String, List<ShellTab>>{
    'seller': sellerShellTabs,
    'cashier': cashierShellTabs,
    'admin': adminShellTabs,
    'customer': customerShellTabs,
    'owner': ownerShellTabs,
  };

  test('вкладки: глифы карты 03 §7.7, запрещённые значения не используются', () {
    final Set<IconData> forbidden = <IconData>{
      Icons.favorite,
      Icons.favorite_border,
      Icons.inventory_2,
      Icons.inventory_2_outlined,
      Icons.receipt_long,
      Icons.receipt_long_outlined,
      Icons.grid_view,
      Icons.grid_view_outlined,
    };
    for (final MapEntry<String, List<ShellTab>> m in modes.entries) {
      for (final ShellTab t in m.value) {
        expect(
          forbidden.contains(t.icon) || forbidden.contains(t.selectedIcon),
          isFalse,
          reason: '${m.key} ${t.branch}',
        );
      }
    }
  });

  test('одна ветка — один глиф во всех режимах; избранное — звезда, транзакции — swap_horiz, заказы — receipt', () {
    final Map<ShellBranch, Set<IconData>> byBranch = <ShellBranch, Set<IconData>>{};
    for (final List<ShellTab> tabs in modes.values) {
      for (final ShellTab t in tabs) {
        (byBranch[t.branch] ??= <IconData>{}).add(t.selectedIcon);
      }
    }
    for (final MapEntry<ShellBranch, Set<IconData>> e in byBranch.entries) {
      if (e.key == ShellBranch.home) continue; // корень каталога клиента — тот же глиф, что «Каталог»
      expect(e.value, hasLength(1), reason: '${e.key}');
    }
    expect(byBranch[ShellBranch.favorites], <IconData>{Icons.star});
    expect(byBranch[ShellBranch.transactions], <IconData>{Icons.swap_horiz});
    expect(byBranch[ShellBranch.orders], <IconData>{Icons.receipt});
    expect(byBranch[ShellBranch.reports], <IconData>{Icons.bar_chart}, reason: '03 §7.7: отчёты — bar_chart');
    expect(byBranch[ShellBranch.home], byBranch[ShellBranch.catalog]);
  });
}
