// Режим клиента: свой долг, история покупок, карточка и скидки — только при подтверждённой привязке (RM-G-014 п. 2;
// 10 CUST-025, ядро §22.12, 11 SEC-030; 02 SCR-32…SCR-35, AC-UI-41-010; 12 T-CUST). Привязка `confirmed` — свои
// экраны открываются, служебных действий нет (оплата долга, «Обновить» 1С, «В заказ», избранное, привязки, вкладка
// операций, лимит ручной скидки); `proposed`/`conflict`/нет привязки — запросов долга/истории/скидок нет, показан
// статус привязки; чужая карточка — «Клиент не найден» без запроса. Синтетические данные (фейки, не интеграция).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/features/customers/presentation/customers_ports.dart';
import 'package:optomstroy/features/customers/presentation/new/new_customer_controller.dart';
import 'package:optomstroy/features/customers/presentation/screens/customer_card_screen.dart';
import 'package:optomstroy/features/customers/presentation/screens/customer_discounts_screen.dart';
import 'package:optomstroy/features/customers/presentation/screens/customer_history_screen.dart';
import 'package:optomstroy/features/customers/presentation/screens/customer_receivables_screen.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_card_view.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_discounts_view.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_history_view.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_self_gate.dart';
import 'package:optomstroy/features/customers/presentation/widgets/debt_summary_panel.dart';
import 'package:optomstroy/features/customers/presentation/widgets/receivables_view.dart';

import 'support/customer_mode_harness.dart';

final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));

const CustomerSelfLink kProposed = CustomerSelfLink(status: CustomerLinkStatus.proposed);
const CustomerSelfLink kConflict = CustomerSelfLink(status: CustomerLinkStatus.conflict);

/// Нет ни одного служебного действия и ни одной служебной вкладки.
void expectNoStaffActions() {
  expect(find.byKey(CustomerCardKeys.acceptDebt), findsNothing, reason: 'оплата долга — не клиенту (D-15)');
  expect(find.byKey(CustomerCardKeys.toCart), findsNothing, reason: '«В заказ» (выбор клиента) — не клиенту');
  expect(find.byKey(CustomerCardKeys.favorite), findsNothing, reason: 'избранные клиенты — FAV-006');
  expect(find.byKey(CustomerCardKeys.links), findsNothing, reason: 'привязки пользователей — admin/owner');
  expect(find.byKey(CustomerCardKeys.tab(CustomerCardTab.orders)), findsNothing, reason: 'журнал операций');
  expect(find.byKey(DebtSummaryKeys.refresh), findsNothing, reason: '«Обновить» из 1С — у customer кнопки нет');
  expect(find.byKey(ReceivablesKeys.acceptPayment), findsNothing);
}

void main() {
  group('зритель customersViewerProvider в режиме клиента', () {
    ProviderContainer container(RoleCode role, CustomerSelfLink? link) {
      final ProviderContainer c = ProviderContainer(
        overrides: <Override>[
          newCustomerViewerRoleProvider.overrideWithValue(role),
          customerSelfLinkProvider.overrideWith((Ref ref) async => link),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('confirmed: своя карточка — суммы, история, долг; чужая — foreign; служебных прав нет', () async {
      final ProviderContainer c = container(RoleCode.customer, kConfirmed);
      expect(c.read(customersViewerProvider).accessTo(kOwnId), CustomerAccess.loading);
      await c.read(customerSelfLinkProvider.future);
      final CustomersViewer v = c.read(customersViewerProvider);
      expect(v.accessTo(kOwnId), CustomerAccess.own);
      expect(v.accessTo(kForeignId), CustomerAccess.foreign);
      expect(<bool>[v.seesSums, v.canReadHistory, v.canReadReceivables], everyElement(isTrue));
      expect(<bool>[
        v.canRefreshReceivables,
        v.canAcceptDebtPayment,
        v.canAddToCart,
        v.canManageFavorites,
        v.canCreateCustomer,
        v.canReadLinks,
        v.canResolveLinks,
        v.canFilterDebt,
        v.searchesByName,
      ], everyElement(isFalse));
    });

    test('proposed / conflict / нет привязки / ошибка /me — notLinked, без прав на финансы (fail-closed)', () async {
      for (final CustomerSelfLink? link in <CustomerSelfLink?>[kProposed, kConflict, null]) {
        final ProviderContainer c = container(RoleCode.customer, link);
        await c.read(customerSelfLinkProvider.future);
        final CustomersViewer v = c.read(customersViewerProvider);
        expect(v.accessTo(kOwnId), CustomerAccess.notLinked, reason: '$link');
        expect(<bool>[v.seesSums, v.canReadHistory, v.canReadReceivables], everyElement(isFalse));
      }
      final ProviderContainer failed = ProviderContainer(
        overrides: <Override>[
          newCustomerViewerRoleProvider.overrideWithValue(RoleCode.customer),
          customerSelfLinkProvider.overrideWith((Ref ref) async => throw StateError('/me')),
        ],
      );
      addTearDown(failed.dispose);
      await expectLater(failed.read(customerSelfLinkProvider.future), throwsStateError);
      expect(failed.read(customersViewerProvider).accessTo(kOwnId), CustomerAccess.notLinked);
    });

    test('сотрудник — доступ по роли, привязка не читается', () async {
      final ProviderContainer c = container(RoleCode.cashier, null);
      expect(c.read(customersViewerProvider).accessTo('any'), CustomerAccess.staff);
      expect(c.read(customersViewerProvider).seesSums, isTrue);
      final ProviderContainer s = container(RoleCode.seller, null);
      expect(s.read(customersViewerProvider).seesSums, isFalse);
    });
  });

  group('SCR-34 «Мой долг»', () {
    testWidgets('confirmed: сводка своего долга без «Обновить» и без «Принять оплату»; детализация — step-up', (
      WidgetTester tester,
    ) async {
      final CustomerModeHarness h = CustomerModeHarness();
      await h.pump(tester, const CustomerReceivablesScreen(customerId: kOwnId));
      expect(find.byKey(DebtSummaryKeys.panel), findsOneWidget);
      expect(find.byKey(DebtSummaryKeys.balance), findsOneWidget);
      expect(h.receivables.getCalls, isNotEmpty);
      expect(h.receivables.getCalls.every((c) => !c.withDocuments), isTrue, reason: 'детализация без step-up — нет');
      expect(find.byKey(ReceivablesKeys.locked), findsOneWidget, reason: 'документы закрыты до step-up (SEC-037)');
      expect(h.receivables.refreshCalls, isEmpty);
      expect(find.byKey(DebtSummaryKeys.credit), findsNothing, reason: 'продажа в долг — не клиенту (CUST-024)');
      expectNoStaffActions();
    });

    testWidgets('proposed: блока долга нет, запроса нет; статус привязки и «Проверить» → SCR-06', (
      WidgetTester tester,
    ) async {
      final CustomerModeHarness h = CustomerModeHarness(link: kProposed);
      await h.pump(tester, const CustomerReceivablesScreen(customerId: kOwnId));
      expect(find.byKey(CustomerSelfGateKeys.notLinked), findsOneWidget);
      expect(find.text(l10n.home_my_debt_unavailable), findsOneWidget);
      expect(find.text(l10n.link_finance_hidden), findsOneWidget);
      expect(find.text(l10n.status_link_proposed), findsOneWidget);
      expect(find.byKey(CustomerSelfGateKeys.confirmLink), findsOneWidget);
      expect(find.byKey(DebtSummaryKeys.panel), findsNothing);
      expect(h.receivables.getCalls, isEmpty, reason: 'до подтверждения запросов долга нет (сервер → 404)');
    });

    testWidgets('привязка загружается — индикатор, без запросов', (WidgetTester tester) async {
      final Completer<CustomerSelfLink?> pending = Completer<CustomerSelfLink?>();
      final CustomerModeHarness h = CustomerModeHarness(linkCompleter: pending);
      await h.pump(tester, const CustomerReceivablesScreen(customerId: kOwnId));
      expect(find.byKey(CustomerSelfGateKeys.loading), findsOneWidget);
      expect(h.receivables.getCalls, isEmpty);
      pending.complete(kConfirmed);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(DebtSummaryKeys.panel), findsOneWidget);
    });
  });

  group('SCR-33 «История покупок»', () {
    testWidgets('confirmed: своя история', (WidgetTester tester) async {
      final CustomerModeHarness h = CustomerModeHarness();
      await h.pump(tester, const CustomerHistoryScreen(customerId: kOwnId));
      expect(find.byKey(CustomerHistoryKeys.list), findsOneWidget);
      expect(h.directory.historyCalls, isNotEmpty);
    });

    testWidgets('conflict: истории нет, «Ожидает подтверждения администратором»', (WidgetTester tester) async {
      final CustomerModeHarness h = CustomerModeHarness(link: kConflict);
      await h.pump(tester, const CustomerHistoryScreen(customerId: kOwnId));
      expect(find.byKey(CustomerHistoryKeys.list), findsNothing);
      expect(find.text(l10n.status_link_conflict), findsOneWidget);
      expect(find.text(l10n.link_wait_admin), findsOneWidget);
      expect(find.byKey(CustomerSelfGateKeys.confirmLink), findsNothing);
      expect(h.directory.historyCalls, isEmpty);
    });
  });

  group('SCR-32 своя карточка', () {
    testWidgets('confirmed: своя карточка с долгом, вкладки без «Заказы и операции», без служебных действий', (
      WidgetTester tester,
    ) async {
      final CustomerModeHarness h = CustomerModeHarness();
      await h.pump(tester, const CustomerCardScreen(customerId: kOwnId));
      expect(h.directory.cardCalls.single.$1, kOwnId);
      expect(find.byKey(CustomerCardKeys.header), findsOneWidget);
      expect(find.byKey(CustomerCardKeys.tab(CustomerCardTab.history)), findsOneWidget);
      expect(find.byKey(CustomerCardKeys.tab(CustomerCardTab.receivables)), findsOneWidget);
      expect(find.byKey(DebtSummaryKeys.panel), findsOneWidget);
      expectNoStaffActions();
    });

    testWidgets('чужая карточка при confirmed — «Клиент не найден» без запроса', (WidgetTester tester) async {
      final CustomerModeHarness h = CustomerModeHarness();
      await h.pump(tester, const CustomerCardScreen(customerId: kForeignId));
      expect(find.byKey(CustomerSelfGateKeys.foreign), findsOneWidget);
      expect(find.text(l10n.customer_card_not_found), findsOneWidget);
      expect(h.directory.cardCalls, isEmpty);
    });

    testWidgets('без привязки — только статус, карточка не запрашивается', (WidgetTester tester) async {
      final CustomerModeHarness h = CustomerModeHarness(link: null);
      await h.pump(tester, const CustomerCardScreen(customerId: kOwnId));
      expect(find.byKey(CustomerSelfGateKeys.notLinked), findsOneWidget);
      expect(find.byKey(CustomerSelfGateKeys.linkStatus), findsNothing, reason: 'none — статуса нет');
      expect(h.directory.cardCalls, isEmpty);
      expect(find.byKey(CustomerCardKeys.header), findsNothing);
    });
  });

  group('CUSTOMER_SELF_SERVICE=false (10 CASH-006; 02 SCR-35.7)', () {
    testWidgets('свои долг, история, карточка, скидки — «Раздел недоступен», запросов нет даже при confirmed', (
      WidgetTester tester,
    ) async {
      for (final Widget screen in <Widget>[
        const CustomerReceivablesScreen(customerId: kOwnId),
        const CustomerHistoryScreen(customerId: kOwnId),
        const CustomerCardScreen(customerId: kOwnId),
        const CustomerDiscountsScreen(customerId: kOwnId),
      ]) {
        final CustomerModeHarness h = CustomerModeHarness(selfService: false);
        await h.pump(tester, screen);
        expect(find.byKey(const ValueKey<String>('customers-forbidden')), findsOneWidget, reason: '$screen');
        expect(h.receivables.getCalls, isEmpty);
        expect(h.directory.historyCalls, isEmpty);
        expect(h.directory.cardCalls, isEmpty);
        expect(h.directory.discountsCalls, 0);
        expect(h.linkLoads, 0, reason: '/me не читается');
      }
    });
  });

  group('SCR-35 свои скидки', () {
    testWidgets('confirmed: правила карточки 1С, без лимита ручной скидки и без GET /discounts/rules', (
      WidgetTester tester,
    ) async {
      final CustomerModeHarness h = CustomerModeHarness();
      await h.pump(tester, const CustomerDiscountsScreen(customerId: kOwnId), size: const Size(1366, 900));
      expect(h.directory.discountsCalls, 1);
      expect(h.directory.rulesCalls, 0);
      expect(find.byKey(CustomerDiscountsKeys.rule('r1')), findsOneWidget);
      expect(find.byKey(CustomerDiscountsKeys.roleLimit), findsNothing);
    });

    testWidgets('proposed: скидки не запрашиваются', (WidgetTester tester) async {
      final CustomerModeHarness h = CustomerModeHarness(link: kProposed);
      await h.pump(tester, const CustomerDiscountsScreen(customerId: kOwnId));
      expect(h.directory.discountsCalls, 0);
      expect(find.byKey(CustomerSelfGateKeys.notLinked), findsOneWidget);
    });
  });
}
