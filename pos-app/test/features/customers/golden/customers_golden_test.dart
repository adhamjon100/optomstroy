// Golden SCR-31 «Поиск клиентов», SCR-32 «Карточка клиента», SCR-33 «История покупок», SCR-34 «Долги и
// взаиморасчёты», SCR-35 «Скидки и условия», SCR-40 «Избранное» (вкладка «Клиенты») на трёх брейкпоинтах
// compact / medium / expanded (D-18; 13 RM-G-007): роль cashier, палитра B, reduce-motion, синтетические данные
// (деньги — целые тыйыны), «сейчас» зафиксировано (Бишкек). SCR-34 — после step-up (детализация открыта).
// Эталоны: `goldens/ci/` (любая ОС) и `goldens/windows/` (только Windows).
//
// Обновить эталоны: flutter test test/features/customers/golden --update-goldens
import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/repositories/customer_directory_repository.dart';
import 'package:optomstroy/features/customers/presentation/screens/customer_card_screen.dart';
import 'package:optomstroy/features/customers/presentation/screens/customer_discounts_screen.dart';
import 'package:optomstroy/features/customers/presentation/screens/customer_history_screen.dart';
import 'package:optomstroy/features/customers/presentation/screens/customer_receivables_screen.dart';
import 'package:optomstroy/features/customers/presentation/screens/customers_search_screen.dart';
import 'package:optomstroy/features/favorites/presentation/screens/favorites_screen.dart';

import '../support/customers_harness.dart';

CustomersHarness _search() {
  final CustomersHarness h = CustomersHarness();
  h.directory.onList = (CustomersListQuery q) async => Success<PageResult<Customer>>(
    PageResult<Customer>(
      items: <Customer>[
        cashierCustomer(favorite: true),
        cashierCustomer(id: 'c2', name: 'ИП Бакытов Нурлан', favorite: true, overdue: false),
        cashierCustomer(id: 'c3', name: 'Сантехмонтаж ОсОО', favorite: true, hasDebt: false, overdue: false),
        cashierCustomer(
          id: 'c4',
          name: 'Асанова Айгуль',
          favorite: true,
          hasDebt: false,
          overdue: false,
          onecStatus: CustomerOnecStatus.pending,
        ),
      ],
    ),
  );
  return h;
}

CustomersHarness _card() => CustomersHarness();

CustomersHarness _receivables() => CustomersHarness()..grantDetail();

Future<void> _prepare(WidgetTester tester) async {
  for (int i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  setUpAll(() => EditableText.debugDeterministicCursor = true);
  tearDownAll(() => EditableText.debugDeterministicCursor = false);

  final Map<String, (CustomersHarness Function(), Widget)> scenes = <String, (CustomersHarness Function(), Widget)>{
    'scr31_search': (_search, const CustomersSearchScreen()),
    'scr32_card': (_card, const CustomerCardScreen(customerId: 'c1')),
    'scr33_history': (_card, const CustomerHistoryScreen(customerId: 'c1')),
    'scr34_receivables': (_receivables, const CustomerReceivablesScreen(customerId: 'c1')),
    'scr35_discounts': (_card, const CustomerDiscountsScreen(customerId: 'c1')),
    'scr40_favorites_customers': (_card, const FavoritesScreen(tab: 'customers')),
  };

  for (final MapEntry<String, (CustomersHarness Function(), Widget)> scene in scenes.entries) {
    for (final MapEntry<String, Size> w in kWindows.entries) {
      unawaited(
        goldenTest(
          '${scene.key} · ${w.key}',
          fileName: 'customers_${scene.key}_${w.key}',
          constraints: BoxConstraints.tight(w.value),
          pumpBeforeTest: _prepare,
          builder: () => SizedBox(
            width: w.value.width,
            height: w.value.height,
            child: scene.value.$1().app(scene.value.$2, size: w.value),
          ),
        ),
      );
    }
  }
}
