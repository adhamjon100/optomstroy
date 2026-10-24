// Widget-тесты: SCR-40 вкладка «Клиенты» (избранные клиенты: вкладки по праву, звезда — DELETE и «Отменить»),
// SCR-26 на реальном API (предзаполнение номера из поиска SCR-31 только из памяти; `409 CUSTOMER_DUPLICATE_SUSPECTED`
// → кандидаты и «Всё равно создать» по праву cashier+).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/customers/domain/repositories/customers_repository.dart';
import 'package:optomstroy/features/customers/presentation/customers_ports.dart';
import 'package:optomstroy/features/customers/presentation/new/new_customer_screen.dart';
import 'package:optomstroy/features/favorites/presentation/screens/favorites_screen.dart';
import 'package:optomstroy/features/favorites/presentation/widgets/favorite_customers_tab.dart';

import '../support/customers_harness.dart';

void main() {
  group('SCR-40 избранные клиенты', () {
    testWidgets('AC-UI-40-001/002: cashier — вкладки «Товары · N» / «Клиенты · M» по count; seller — без вкладок', (
      WidgetTester tester,
    ) async {
      final CustomersHarness h = CustomersHarness();
      await h.pump(tester, const FavoritesScreen(tab: 'customers'));
      expect(findText('Клиенты · 2'), findsOneWidget);
      expect(findText('Товары · 1'), findsOneWidget);
      expect(find.byKey(FavoriteCustomersKeys.row('c1')), findsOneWidget);
      expect(find.byKey(FavoriteCustomersKeys.row('c2')), findsOneWidget);
      expectNoSumsInRows();

      final CustomersHarness s = CustomersHarness(role: RoleCode.seller);
      await s.pump(tester, const FavoritesScreen(tab: 'customers'));
      expect(find.byKey(const ValueKey<String>('favorites-tabs')), findsNothing);
      expect(find.byKey(FavoriteCustomersKeys.row('c1')), findsNothing);
      expect(findText('Смеситель Grohe Eurosmart'), findsOneWidget);
    });

    testWidgets(
      'AC-UI-40-003/005: снятие звезды — строка убрана, DELETE, «Отменить» возвращает (PUT); ошибка — возврат и текст',
      (WidgetTester tester) async {
        final CustomersHarness h = CustomersHarness();
        await h.pump(tester, const FavoritesScreen(tab: 'customers'));
        await tapVisible(tester, find.byKey(FavoriteCustomersKeys.star('c2')));
        await settle(tester);
        expect(h.favorites.removed, <String>['c2']);
        expect(find.byKey(FavoriteCustomersKeys.row('c2')), findsNothing);
        expect(findText('Клиенты · 1'), findsOneWidget);
        expect(findText('Клиент убран из избранного'), findsOneWidget);
        await tester.tap(find.text('Отменить'));
        await settle(tester);
        expect(h.favorites.added, <String>['c2']);
        expect(find.byKey(FavoriteCustomersKeys.row('c2')), findsOneWidget);

        h.favorites.removeResult = const FailureResult<void>(kOffline);
        await tapVisible(tester, find.byKey(FavoriteCustomersKeys.star('c1')));
        await settle(tester, frames: 12);
        expect(find.byKey(FavoriteCustomersKeys.row('c1')), findsOneWidget);
        expect(findText('Не удалось убрать из избранного. Повторите'), findsOneWidget);
      },
    );

    testWidgets('Фильтр избранных клиентов — локально по имени (без запроса)', (WidgetTester tester) async {
      final CustomersHarness h = CustomersHarness();
      await h.pump(tester, const FavoritesScreen(tab: 'customers'));
      await tester.enterText(
        find.descendant(of: find.byKey(FavoriteCustomersKeys.filter), matching: find.byType(EditableText)),
        'бакыт',
      );
      await tester.pump(const Duration(milliseconds: 350));
      await settle(tester);
      expect(find.byKey(FavoriteCustomersKeys.row('c2')), findsOneWidget);
      expect(find.byKey(FavoriteCustomersKeys.row('c1')), findsNothing);
    });

    testWidgets('Без сети — вкладка клиентов «Поиск клиентов недоступен без сети»', (WidgetTester tester) async {
      final CustomersHarness h = CustomersHarness(online: false);
      await h.pump(tester, const FavoritesScreen(tab: 'customers'));
      expect(findText('Поиск клиентов недоступен без сети'), findsOneWidget);
    });
  });

  group('SCR-26 (UI-31-005, N-3)', () {
    testWidgets('Предзаполнение SCR-26: поле телефона и проверка дублей по E.164; повторно номер не подставляется', (
      WidgetTester tester,
    ) async {
      final CustomersHarness h = CustomersHarness();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      final ProviderContainer container = ProviderContainer(overrides: h.overrides);
      addTearDown(container.dispose);
      container.read(customerNewPrefillProvider).put('+996700123456');
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: h.materialApp(const NewCustomerScreen())),
      );
      await settle(tester);
      expect(
        tester
            .widgetList<EditableText>(find.byType(EditableText))
            .map((EditableText e) => normSpaces(e.controller.text)),
        contains('700 123 456'),
      );
      expect(h.search.calls.map((CustomerSearchQuery q) => q.q), contains('+996700123456'));
      expect(container.read(customerNewPrefillProvider).take(), isNull);
    });
  });
}

/// В строках избранных клиентов нет сумм долга.
void expectNoSumsInRows() => expect(findTextContaining('сом'), findsNothing);
