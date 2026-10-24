// Widget-тесты экранов клиентов SCR-31…SCR-35 (RM-G-007, RM-G-012; 02 AC-UI-31/32/33/34/35; 12 T-CUST, T-DEBT, T-SEC):
// поля по ролям (seller не видит сумм), step-up детализации и окно 15 мин, «Обновить» снимка долга, офлайн без
// финансов, звезда избранного, пороги поиска по ролям.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/favorite_toggle.dart';
import 'package:optomstroy/design_system/components/receivable_badge.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/entities/customer_contact.dart';
import 'package:optomstroy/features/customers/domain/entities/customer_terms.dart';
import 'package:optomstroy/features/customers/domain/entities/receivable.dart';
import 'package:optomstroy/features/customers/domain/repositories/customer_directory_repository.dart';
import 'package:optomstroy/features/customers/domain/repositories/customers_repository.dart';
import 'package:optomstroy/features/customers/presentation/customers_ports.dart';
import 'package:optomstroy/features/customers/presentation/screens/customer_card_screen.dart';
import 'package:optomstroy/features/customers/presentation/screens/customer_discounts_screen.dart';
import 'package:optomstroy/features/customers/presentation/screens/customer_history_screen.dart';
import 'package:optomstroy/features/customers/presentation/screens/customer_receivables_screen.dart';
import 'package:optomstroy/features/customers/presentation/screens/customers_search_screen.dart';
import 'package:optomstroy/features/customers/presentation/state/customer_history_controller.dart';
import 'package:optomstroy/features/customers/presentation/state/customers_search_controller.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_card_view.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_discounts_view.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_history_view.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_list_row.dart';
import 'package:optomstroy/features/customers/presentation/widgets/debt_summary_panel.dart';
import 'package:optomstroy/features/customers/presentation/widgets/receivables_view.dart';

import '../support/customers_harness.dart';

/// В дереве нет ни одной суммы в сомах.
void expectNoSums() => expect(findTextContaining('сом'), findsNothing);

void main() {
  group('SCR-31 поиск клиентов', () {
    // Трасса T-ID (scripts/trace_test_ids.py): «AC-UI-31-003/004/011/012 seller: имя не ищется».
    testWidgets(
      'AC-UI-31-003, AC-UI-31-004, AC-UI-31-011, AC-UI-31-012 seller: имя не ищется, строка без сумм и полного '
      'телефона, без звезды и чипов долга',
      (WidgetTester tester) async {
        final CustomersHarness h = CustomersHarness(role: RoleCode.seller);
        h.search.onSearch = (CustomerSearchQuery q) async => Success<PageResult<Customer>>(
          PageResult<Customer>(items: <Customer>[sellerCustomer(match: CustomerMatchType.phone)]),
        );
        await h.pump(tester, const CustomersSearchScreen());
        // Idle продавца — подсказка, без запроса.
        expect(findText('Введите полный номер телефона или код клиента'), findsOneWidget);
        expect(h.directory.listCalls, isEmpty);
        // Чипов «С долгом» / «С просрочкой» и «Избранные» нет.
        expect(find.byKey(CustomersSearchKeys.filter(CustomersFilter.debt)), findsNothing);
        expect(find.byKey(CustomersSearchKeys.filter(CustomersFilter.overdue)), findsNothing);
        expect(find.byKey(CustomersSearchKeys.filter(CustomersFilter.favorites)), findsNothing);

        await tester.enterText(find.byType(EditableText), 'Азамат');
        await settle(tester, frames: 10);
        expect(h.search.calls, isEmpty, reason: 'seller: ввод имени запроса не отправляет');
        expect(findText('Введите полный номер телефона или код клиента'), findsOneWidget);

        await tester.enterText(find.byType(EditableText), '0700 123');
        await settle(tester, frames: 10);
        expect(h.search.calls, isEmpty);
        expect(findText('Для поиска по телефону введите номер полностью'), findsOneWidget);

        await tester.enterText(find.byType(EditableText), '0700 123 456');
        await settle(tester, frames: 10);
        expect(h.search.calls.single.q, '+996700123456');
        expect(h.search.calls.single.withReceivable, isFalse, reason: 'AC-UI-31-012: без include=receivable');
        expect(find.byKey(CustomerRowKeys.row('c1')), findsOneWidget);
        expect(findTextContaining('+996 700 *** *56'), findsWidgets);
        expect(findTextContaining('+996 700 123 456'), findsNothing);
        expect(find.byKey(CustomerRowKeys.debt('c1')), findsOneWidget);
        expect(find.byKey(CustomerRowKeys.star('c1')), findsNothing);
        expectNoSums();
      },
    );

    testWidgets(
      'AC-UI-31-001/002/011 cashier: debounce 300 мс, один запрос, подпись «по телефону», индикатор без суммы',
      (WidgetTester tester) async {
        final CustomersHarness h = CustomersHarness();
        await h.pump(tester, const CustomersSearchScreen());
        // Idle кассира — список «Избранные» (`GET /customers?favorite=true`).
        expect(h.directory.listCalls.single.favoriteOnly, isTrue);
        expect(find.byKey(CustomersSearchKeys.filter(CustomersFilter.debt)), findsOneWidget);

        await tester.enterText(find.byType(EditableText), '0700');
        await tester.pump(const Duration(milliseconds: 200));
        expect(h.search.calls, isEmpty, reason: 'не раньше 300 мс после ввода');
        await tester.enterText(find.byType(EditableText), '07001');
        await tester.pump(const Duration(milliseconds: 310));
        await settle(tester);
        expect(h.search.calls, hasLength(1));
        expect(h.search.calls.single.q, '07001');
        expect(find.byKey(CustomersSearchKeys.match), findsOneWidget);
        expect(find.byKey(CustomerRowKeys.debt('c1')), findsOneWidget);
        expectNoSums();
      },
    );

    testWidgets('AC-UI-31-002, AC-UI-31-011 cashier: «Аз» (2 буквы) и «0700» (4 цифры) отправляют поиск; «0700 123» '
        'находит клиента +996700123456 с подписью «по телефону»', (WidgetTester tester) async {
      final CustomersHarness h = CustomersHarness();
      h.search.onSearch = (CustomerSearchQuery q) async => Success<PageResult<Customer>>(
        PageResult<Customer>(items: <Customer>[cashierCustomer(match: CustomerMatchType.phone)]),
      );
      await h.pump(tester, const CustomersSearchScreen());
      for (final String q in <String>['Аз', '0700', '0700 123']) {
        await tester.enterText(find.byType(EditableText), q);
        await tester.pump(const Duration(milliseconds: 310));
        await settle(tester);
        expect(h.search.calls.last.q, q, reason: 'cashier: «$q» отправляет поиск');
      }
      expect(find.byKey(CustomerRowKeys.row('c1')), findsOneWidget);
      expect(findTextContaining('+996 700 123 456'), findsWidgets);
      expect(find.byKey(CustomersSearchKeys.match), findsOneWidget);
    });

    testWidgets('AC-UI-31-006: клиент source=pos_pending — «Код POS: …» и чип «ожидает 1С»', (
      WidgetTester tester,
    ) async {
      final CustomersHarness h = CustomersHarness();
      h.search.onSearch = (CustomerSearchQuery q) async => const Success<PageResult<Customer>>(
        PageResult<Customer>(
          items: <Customer>[
            Customer(
              id: 'p1',
              name: 'Тестов Новый Клиент',
              onecCode: 'POS-000045',
              source: CustomerSource.pos,
              onecStatus: CustomerOnecStatus.pending,
              phones: <CustomerPhone>[CustomerPhone(valueE164: '+996555777002', verified: false)],
            ),
          ],
        ),
      );
      await h.pump(tester, const CustomersSearchScreen());
      await tester.enterText(find.byType(EditableText), 'Тестов');
      await tester.pump(const Duration(milliseconds: 310));
      await settle(tester);
      final Finder row = find.byKey(CustomerRowKeys.row('p1'));
      expect(row, findsOneWidget);
      expect(find.descendant(of: row, matching: findTextContaining('Код POS: POS-000045')), findsOneWidget);
      expect(find.descendant(of: row, matching: findText('ожидает 1С')), findsOneWidget);
    });

    testWidgets('AC-UI-31-007: звезда — оптимистично, PUT через 400 мс, снекбар; ошибка — откат и снекбар', (
      WidgetTester tester,
    ) async {
      final CustomersHarness h = CustomersHarness();
      h.directory.onList = (CustomersListQuery q) async => Success<PageResult<Customer>>(
        PageResult<Customer>(
          items: <Customer>[cashierCustomer(id: 'c9', name: 'ИП Асанов')],
        ),
      );
      await h.pump(tester, const CustomersSearchScreen(withDebtOnly: true));
      expect(h.directory.listCalls.last.hasDebt, isTrue);
      await tapVisible(tester, find.byKey(CustomerRowKeys.star('c9')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.favorites.added, isEmpty, reason: 'debounce 400 мс');
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);
      expect(h.favorites.added, <String>['c9']);
      expect(findText('Клиент добавлен в избранное'), findsOneWidget);

      h.favorites.removeResult = const FailureResult<void>(kOffline);
      await tapVisible(tester, find.byKey(CustomerRowKeys.star('c9')));
      await tester.pump(const Duration(milliseconds: 450));
      await settle(tester);
      expect(h.favorites.removed, <String>['c9']);
      final FavoriteToggle star = tester.widget<FavoriteToggle>(find.byKey(CustomerRowKeys.star('c9')));
      expect(star.selected, isTrue, reason: 'откат к подтверждённому состоянию');
    });

    testWidgets('AC-UI-31-009: без сети — «Поиск клиентов недоступен без сети», запросов нет', (
      WidgetTester tester,
    ) async {
      final CustomersHarness h = CustomersHarness(online: false);
      await h.pump(tester, const CustomersSearchScreen());
      expect(findText('Поиск клиентов недоступен без сети'), findsOneWidget);
      expect(h.directory.listCalls, isEmpty);
      expect(h.search.calls, isEmpty);
    });
  });

  group('SCR-32 карточка клиента', () {
    testWidgets(
      'AC-UI-32-001, AC-UI-32-003, AC-UI-32-015 cashier: телефоны с отметкой, ИНН, сводка с суммами и лимитом '
      '(«Доступно (прогноз)» — серверные limitRemaining и creditLimit), вкладки История/Долги',
      (WidgetTester tester) async {
        final CustomersHarness h = CustomersHarness();
        await h.pump(tester, const CustomerCardScreen(customerId: 'c1'));
        expect(
          h.directory.cardCalls.single.$2,
          containsAll(<CustomerInclude>[
            CustomerInclude.receivable,
            CustomerInclude.discounts,
            CustomerInclude.contacts,
          ]),
        );
        expect(findText('+996 700 123 456'), findsOneWidget);
        expect(findText('подтверждён'), findsOneWidget);
        expect(findText('ИНН: 01234567890123'), findsOneWidget);
        expect(find.byKey(DebtSummaryKeys.balance), findsOneWidget);
        expect(findText('12 000,00 сом'), findsOneWidget);
        expect(findText('Доступно (прогноз) 33 800,00 сом из 50 000,00 сом'), findsOneWidget);
        expect(find.byKey(CustomerCardKeys.tab(CustomerCardTab.history)), findsOneWidget);
        expect(find.byKey(CustomerCardKeys.tab(CustomerCardTab.receivables)), findsOneWidget);
        expect(find.byKey(CustomerCardKeys.favorite), findsOneWidget);
      },
    );

    testWidgets(
      'AC-UI-32-002 seller: маска телефона, «Долг: есть», пояснение; нет сумм, ИНН, вкладок История/Долги, звезды',
      (WidgetTester tester) async {
        final CustomersHarness h = CustomersHarness(role: RoleCode.seller);
        h.directory.onCard = (String id, Set<CustomerInclude> include) async =>
            Success<Customer>(sellerCustomer(id: id));
        await h.pump(tester, const CustomerCardScreen(customerId: 'c1'));
        expect(h.directory.cardCalls.single.$2, <CustomerInclude>{CustomerInclude.discounts});
        expect(findText('+996 700 *** *56'), findsOneWidget);
        expect(find.byKey(CustomerCardKeys.sellerInfo), findsOneWidget);
        expect(findText('Суммы долга и история покупок доступны кассиру'), findsOneWidget);
        expect(find.byType(ReceivableBadge), findsWidgets);
        expect(find.byKey(DebtSummaryKeys.panel), findsNothing);
        expect(find.byKey(CustomerCardKeys.tab(CustomerCardTab.history)), findsNothing);
        expect(find.byKey(CustomerCardKeys.tab(CustomerCardTab.receivables)), findsNothing);
        expect(find.byKey(CustomerCardKeys.favorite), findsNothing);
        expect(findTextContaining('ИНН'), findsNothing);
        expectNoSums();
      },
    );

    // Трасса T-ID (scripts/trace_test_ids.py): «AC-UI-32-003/004: устаревший снимок — предупреждение и «Обновить»».
    testWidgets(
      'AC-UI-32-003, AC-UI-32-004: устаревший снимок — предупреждение и «Обновить» (POST refresh); нет снимка — '
      '«Нет данных из 1С»',
      (WidgetTester tester) async {
        final CustomersHarness h = CustomersHarness();
        h.directory.onCard = (String id, Set<CustomerInclude> include) async => Success<Customer>(
          cashierCustomer(
            receivable: ReceivableSummary(
              balance: som(12000),
              overdueAmount: som(0),
              creditLimit: som(50000),
              limitRemaining: som(38000),
              asOf: kNow.subtract(const Duration(minutes: 90)),
            ),
          ),
        );
        h.receivables.onRefresh = (bool withDocuments) async =>
            Success<Receivable>(receivable(asOf: kNow, balance: som(9000)));
        await h.pump(tester, const CustomerCardScreen(customerId: 'c1'));
        expect(find.byKey(DebtSummaryKeys.stale), findsOneWidget);
        await tapVisible(tester, find.byKey(DebtSummaryKeys.refresh));
        await settle(tester);
        expect(h.receivables.refreshCalls, hasLength(1));
        expect(h.receivables.refreshCalls.single.key, isNotNull, reason: 'Idempotency-Key');
        expect(findText('9 000,00 сом'), findsOneWidget);
        expect(find.byKey(DebtSummaryKeys.stale), findsNothing);

        final CustomersHarness h2 = CustomersHarness();
        h2.directory.onCard = (String id, Set<CustomerInclude> include) async =>
            Success<Customer>(cashierCustomer(withReceivable: false));
        await h2.pump(tester, const CustomerCardScreen(customerId: 'c1'));
        expect(find.byKey(DebtSummaryKeys.noData), findsOneWidget);
        expect(findText('0,00 сом'), findsNothing);
      },
    );

    testWidgets(
      'AC-UI-32-007: «Принять оплату по долгу» — только cashier при debtPaymentsFromPos; owner — без кассовых кнопок',
      (WidgetTester tester) async {
        final CustomersHarness h = CustomersHarness()..debtPayments = true;
        await h.pump(tester, const CustomerCardScreen(customerId: 'c1'));
        expect(find.byKey(CustomerCardKeys.acceptDebt), findsOneWidget);

        final CustomersHarness off = CustomersHarness();
        await off.pump(tester, const CustomerCardScreen(customerId: 'c1'));
        expect(
          find.byKey(CustomerCardKeys.acceptDebt),
          findsNothing,
          reason: 'R1: DEBT_PAYMENTS_FROM_POS=false (Q-152)',
        );

        final CustomersHarness owner = CustomersHarness(role: RoleCode.owner)..debtPayments = true;
        await owner.pump(tester, const CustomerCardScreen(customerId: 'c1'));
        expect(find.byKey(CustomerCardKeys.acceptDebt), findsNothing);
        expect(find.byKey(CustomerCardKeys.favorite), findsNothing, reason: 'FAV-006');
        expect(find.byKey(DebtSummaryKeys.panel), findsOneWidget);
      },
    );

    testWidgets('AC-UI-32-006: звезда добавляет/убирает клиента на сервере; состояние — с сервера (isFavorite); '
        'owner — без звезды', (WidgetTester tester) async {
      final CustomersHarness h = CustomersHarness();
      await h.pump(tester, const CustomerCardScreen(customerId: 'c1'));
      expect(tester.widget<FavoriteToggle>(find.byKey(CustomerCardKeys.favorite)).selected, isFalse);
      await tapVisible(tester, find.byKey(CustomerCardKeys.favorite));
      await tester.pump(const Duration(milliseconds: 450));
      await settle(tester);
      expect(h.favorites.added, <String>['c1'], reason: 'PUT /favorites/customers/{id}');
      await tapVisible(tester, find.byKey(CustomerCardKeys.favorite));
      await tester.pump(const Duration(milliseconds: 450));
      await settle(tester);
      expect(h.favorites.removed, <String>['c1'], reason: 'DELETE /favorites/customers/{id}');

      // «После перезапуска» состояние звезды берётся из ответа сервера (`isFavorite` карточки), не из устройства.
      await tester.pumpWidget(const SizedBox.shrink());
      final CustomersHarness again = CustomersHarness();
      again.directory.onCard = (String id, Set<CustomerInclude> include) async =>
          Success<Customer>(cashierCustomer(id: id, favorite: true));
      await again.pump(tester, const CustomerCardScreen(customerId: 'c1'));
      expect(tester.widget<FavoriteToggle>(find.byKey(CustomerCardKeys.favorite)).selected, isTrue);

      final CustomersHarness owner = CustomersHarness(role: RoleCode.owner);
      await owner.pump(tester, const CustomerCardScreen(customerId: 'c1'));
      expect(find.byKey(CustomerCardKeys.favorite), findsNothing, reason: 'FAV-006');
    });

    testWidgets('AC-UI-32-011: «Розничный покупатель» — без зон долга, истории и контактов', (
      WidgetTester tester,
    ) async {
      final CustomersHarness h = CustomersHarness();
      h.directory.onCard = (String id, Set<CustomerInclude> include) async => Success<Customer>(
        Customer(id: id, name: 'Розничный покупатель', isRetailDefault: true, source: CustomerSource.onec),
      );
      await h.pump(tester, const CustomerCardScreen(customerId: 'retail'));
      expect(find.byKey(CustomerCardKeys.retail), findsOneWidget);
      expect(find.byKey(DebtSummaryKeys.panel), findsNothing);
      expect(find.byKey(CustomerCardKeys.tab(CustomerCardTab.history)), findsNothing);
      expect(find.byKey(CustomerCardKeys.tab(CustomerCardTab.receivables)), findsNothing);
      expect(find.byKey(CustomerCardKeys.contacts), findsNothing);
      expect(find.byKey(CustomerCardKeys.favorite), findsNothing);
    });

    testWidgets(
      'AC-UI-32-014: owner — без кассовых кнопок, Z7 привязок в режиме просмотра (без перехода к разрешению)',
      (WidgetTester tester) async {
        final CustomersHarness owner = CustomersHarness(role: RoleCode.owner)..debtPayments = true;
        owner.directory.onCard = (String id, Set<CustomerInclude> include) async => Success<Customer>(
          Customer(
            id: id,
            name: 'ОсОО «Азамат Строй»',
            onecRef: 'ref-$id',
            source: CustomerSource.onec,
            links: <CustomerLinkRef>[
              CustomerLinkRef(id: 'l1', customerId: id, status: CustomerLinkStatus.confirmed, userId: 'u-7'),
            ],
          ),
        );
        await owner.pump(tester, const CustomerCardScreen(customerId: 'c1'), size: const Size(1366, 900));
        expect(owner.directory.cardCalls.single.$2, contains(CustomerInclude.links));
        expect(find.byKey(CustomerCardKeys.acceptDebt), findsNothing);
        expect(find.byKey(CustomerCardKeys.toCart), findsNothing);
        expect(find.byKey(CustomerCardKeys.links), findsOneWidget);
        expect(find.descendant(of: find.byKey(CustomerCardKeys.links), matching: find.byType(AppButton)), findsNothing);
      },
    );

    testWidgets('AC-UI-32-013: без сети — «Карточка клиента недоступна без сети», запроса нет', (
      WidgetTester tester,
    ) async {
      final CustomersHarness h = CustomersHarness(online: false);
      await h.pump(tester, const CustomerCardScreen(customerId: 'c1'));
      expect(findText('Карточка клиента недоступна без сети'), findsOneWidget);
      expect(h.directory.cardCalls, isEmpty);
      expectNoSums();
    });

    testWidgets('NotFound — «Клиент не найден» + «К списку клиентов»', (WidgetTester tester) async {
      final CustomersHarness h = CustomersHarness();
      h.directory.onCard = (String id, Set<CustomerInclude> include) async =>
          const FailureResult<Customer>(ServerFailure(code: 'NOT_FOUND', status: 404));
      await h.pump(tester, const CustomerCardScreen(customerId: 'zz'));
      expect(findText('Клиент не найден'), findsOneWidget);
      expect(findText('К списку клиентов'), findsOneWidget);
    });
  });

  group('SCR-34 долги и взаиморасчёты', () {
    // Трасса T-ID (scripts/trace_test_ids.py): «AC-UI-34-001/002: сводка без step-up».
    testWidgets(
      'AC-UI-34-001, AC-UI-34-002, AC-UI-34-017: сводка без step-up; детализация до подтверждения не запрашивается; '
      'первый просмотр — StepUpDialog, затем таблица; статус блокировки долга — с причиной, без кнопок действий',
      (WidgetTester tester) async {
        final CustomersHarness h = CustomersHarness();
        // Сервер: без токена детализация → 403 STEP_UP_REQUIRED → StepUpDialog (AuthInterceptor) → токен в кэш → повтор.
        int dialogs = 0;
        h.receivables.onGet = (bool withDocuments, String? token) async {
          if (withDocuments && token == null) {
            dialogs++;
            h.grantDetail();
          }
          return Success<Receivable>(receivable(documents: withDocuments ? documents() : null));
        };
        await h.pump(tester, const CustomerReceivablesScreen(customerId: 'c1'));
        expect(h.receivables.getCalls, hasLength(1));
        expect(h.receivables.getCalls.single.withDocuments, isFalse);
        expect(find.byKey(ReceivablesKeys.locked), findsOneWidget);
        expect(find.byKey(ReceivablesKeys.documents), findsNothing);
        expect(findText('12 000,00 сом'), findsOneWidget);
        expect(findText('Просрочено 4 200,00 сом · 12 дней'), findsOneWidget);
        expect(findText('Продажа в долг недоступна: есть просроченная задолженность'), findsOneWidget);
        // AC-UI-34-017: статус блокировки — чип с причиной; кнопок действий (разрешение долга) у кассира нет.
        expect(find.byKey(DebtSummaryKeys.credit), findsOneWidget);
        final Iterable<AppButton> panelButtons = tester.widgetList<AppButton>(
          find.descendant(of: find.byKey(DebtSummaryKeys.panel), matching: find.byType(AppButton)),
        );
        expect(panelButtons.where((AppButton b) => b.key != DebtSummaryKeys.refresh), isEmpty);

        await tapVisible(tester, find.byKey(ReceivablesKeys.show));
        await settle(tester);
        expect(dialogs, 1);
        expect(h.receivables.getCalls.last.withDocuments, isTrue);
        expect(find.byKey(ReceivablesKeys.documents), findsOneWidget);
        expect(findText('УТ-0001230'), findsOneWidget);
        expect(find.byKey(ReceivablesKeys.openUntil), findsOneWidget);
        expect(findText('Детализация открыта до 10:15 · просмотр записан в аудит'), findsOneWidget);

        // Фильтр «Просроченные» — только строки с overdueDays > 0 (AC-UI-34-016).
        await tapVisible(tester, find.byKey(ReceivablesKeys.filter('overdue')));
        await settle(tester);
        expect(findText('УТ-0001230'), findsOneWidget);
        expect(findText('УТ-0001250'), findsNothing);
      },
    );

    testWidgets('AC-UI-34-011: отмена StepUpDialog — заглушка остаётся, «Детализация не открыта», без ошибки', (
      WidgetTester tester,
    ) async {
      final CustomersHarness h = CustomersHarness();
      h.receivables.onGet = (bool withDocuments, String? token) async =>
          withDocuments ? const FailureResult<Receivable>(kStepUpCancelled) : Success<Receivable>(receivable());
      await h.pump(tester, const CustomerReceivablesScreen(customerId: 'c1'));
      await tapVisible(tester, find.byKey(ReceivablesKeys.show));
      await settle(tester);
      expect(find.byKey(ReceivablesKeys.locked), findsOneWidget);
      expect(find.byKey(ReceivablesKeys.cancelled), findsOneWidget);
      expect(findText('Подтвердите действие'), findsNothing);
      expect(find.byKey(ReceivablesKeys.documents), findsNothing);
    });

    testWidgets(
      'AC-UI-34-003: в течение 15 мин после step-up — без диалога (токен из кэша); через > 15 мин — снова заглушка',
      (WidgetTester tester) async {
        final CustomersHarness h = CustomersHarness();
        h.grantDetail();
        await h.pump(tester, const CustomerReceivablesScreen(customerId: 'c1'));
        expect(h.receivables.getCalls, hasLength(2));
        expect(h.receivables.getCalls.last, (withDocuments: true, token: 'detail_token'));
        expect(find.byKey(ReceivablesKeys.locked), findsNothing);
        expect(find.byKey(ReceivablesKeys.documents), findsOneWidget);

        h.clock.set(kNow.add(const Duration(minutes: 16)));
        await tester.pumpWidget(const SizedBox.shrink());
        expect(h.stepUp.tokenFor(receivablesDetailOperation), isNull, reason: 'токен истёк (15 мин)');
        final int before = h.receivables.getCalls.length;
        await h.pump(tester, const CustomerReceivablesScreen(customerId: 'c1'));
        expect(h.receivables.getCalls, hasLength(before + 1));
        expect(h.receivables.getCalls.last.withDocuments, isFalse);
        expect(find.byKey(ReceivablesKeys.locked), findsOneWidget);
      },
    );

    testWidgets(
      'AC-UI-34-007: «Обновить» → POST refresh; 1С недоступна — снекбар, данные остаются; 429 — снекбар, кнопка недоступна',
      (WidgetTester tester) async {
        final CustomersHarness h = CustomersHarness();
        h.receivables.onRefresh = (bool withDocuments) async => Success<Receivable>(receivable(stale: true));
        await h.pump(tester, const CustomerReceivablesScreen(customerId: 'c1'));
        await tapVisible(tester, find.byKey(DebtSummaryKeys.refresh));
        await settle(tester);
        expect(h.receivables.refreshCalls, hasLength(1));
        expect(findText('1С недоступна, показаны данные от 09:40'), findsOneWidget);
        expect(findText('12 000,00 сом'), findsOneWidget);

        h.receivables.onRefresh = (bool withDocuments) async => const FailureResult<Receivable>(kRateLimited);
        await tapVisible(tester, find.byKey(DebtSummaryKeys.refresh));
        await settle(tester);
        expect(findText('Слишком много запросов, подождите 30 с'), findsOneWidget);
        expect(find.byKey(DebtSummaryKeys.refresh), findsNothing, reason: 'до retryAfter «Обновить» недоступна');
        await tester.pump(const Duration(seconds: 31));
        await settle(tester);
      },
    );

    testWidgets(
      'AC-UI-34-007, AC-FLOW-025-05: «Обновить» → 503 ONEC_UNAVAILABLE (08 §4.11.8) — «1С недоступна, показаны данные '
      'от HH:MM», снимок и пометка остаются (SCR-34 и SCR-32)',
      (WidgetTester tester) async {
        final CustomersHarness h = CustomersHarness();
        h.receivables.onRefresh = (bool withDocuments) async =>
            const FailureResult<Receivable>(OnecUnavailableFailure(retryAfter: Duration(seconds: 30)));
        await h.pump(tester, const CustomerReceivablesScreen(customerId: 'c1'));
        await tapVisible(tester, find.byKey(DebtSummaryKeys.refresh));
        await settle(tester);
        expect(h.receivables.refreshCalls, hasLength(1));
        expect(findText('1С недоступна, показаны данные от 09:40'), findsOneWidget);
        expect(findText('12 000,00 сом'), findsOneWidget);

        final CustomersHarness card = CustomersHarness();
        card.receivables.onRefresh = (bool withDocuments) async =>
            const FailureResult<Receivable>(OnecUnavailableFailure(retryAfter: Duration(seconds: 30)));
        card.directory.onCard = (String id, Set<CustomerInclude> include) async => Success<Customer>(
          cashierCustomer(
            receivable: ReceivableSummary(
              balance: som(12000),
              overdueAmount: som(0),
              creditLimit: som(50000),
              limitRemaining: som(38000),
              asOf: kNow.subtract(const Duration(minutes: 90)),
            ),
          ),
        );
        await card.pump(tester, const CustomerCardScreen(customerId: 'c1'));
        await tapVisible(tester, find.byKey(DebtSummaryKeys.refresh));
        await settle(tester);
        expect(card.receivables.refreshCalls, hasLength(1));
        expect(findTextContaining('1С недоступна, показаны данные от '), findsOneWidget);
        expect(find.byKey(DebtSummaryKeys.stale), findsOneWidget, reason: 'пометка «могут быть неактуальны» остаётся');
      },
    );

    testWidgets(
      'AC-UI-34-014 офлайн: без данных сессии — «Данные о долге недоступны без сети»; из памяти сессии — с пометкой, без детализации',
      (WidgetTester tester) async {
        final CustomersHarness h = CustomersHarness(online: false);
        await h.pump(tester, const CustomerReceivablesScreen(customerId: 'c1'));
        expect(findText('Данные о долге недоступны без сети'), findsOneWidget);
        expect(h.receivables.getCalls, isEmpty);
        expectNoSums();

        final CustomersHarness m = CustomersHarness(online: false);
        m.memory.putReceivable(receivable());
        await m.pump(tester, const CustomerReceivablesScreen(customerId: 'c1'));
        expect(m.receivables.getCalls, isEmpty);
        expect(findText('12 000,00 сом'), findsOneWidget);
        expect(findTextContaining('Нет сети'), findsOneWidget);
        expect(find.byKey(DebtSummaryKeys.refresh), findsNothing);
      },
    );

    // Трасса T-ID (scripts/trace_test_ids.py): «AC-UI-34-008/009: нет снимка — «Нет данных из 1С»».
    testWidgets('AC-UI-34-008: нет снимка — «Нет данных из 1С»; отрицательное сальдо — подпись «Аванс»', (
      WidgetTester tester,
    ) async {
      final CustomersHarness h = CustomersHarness();
      h.receivables.onGet = (bool withDocuments, String? token) async =>
          const Success<Receivable>(Receivable(customerId: 'c1', reason: ReceivableAbsenceReason.notInOnec));
      await h.pump(tester, const CustomerReceivablesScreen(customerId: 'c1'));
      expect(find.byKey(DebtSummaryKeys.noData), findsOneWidget);
      expect(findText('Продажа в долг недоступна: нет данных из 1С о просрочке или лимите'), findsOneWidget);
      expect(find.byKey(ReceivablesKeys.locked), findsNothing);

      final CustomersHarness a = CustomersHarness();
      a.receivables.onGet = (bool withDocuments, String? token) async =>
          Success<Receivable>(receivable(balance: -som(1500)));
      await a.pump(tester, const CustomerReceivablesScreen(customerId: 'c1'));
      expect(findText('Аванс'), findsWidgets);
      expect(findText('−1 500,00 сом'), findsOneWidget);
    });

    testWidgets('AC-UI-34-009: аванс без просрочки — «Аванс», сумма цветом success', (WidgetTester tester) async {
      final CustomersHarness h = CustomersHarness();
      h.receivables.onGet = (bool withDocuments, String? token) async => Success<Receivable>(
        Receivable(
          customerId: 'c1',
          balance: -som(1500),
          overdueAmount: som(0),
          overdueDays: 0,
          creditLimit: som(50000),
          openOrdersAmount: som(0),
          limitRemaining: som(51500),
          creditAllowed: true,
          paymentTermDays: 14,
          asOf: kAsOf,
          staleAfterMinutes: 60,
        ),
      );
      await h.pump(tester, const CustomerReceivablesScreen(customerId: 'c1'));
      expect(findText('Аванс'), findsWidgets);
      final Text amount = tester.widget<Text>(find.byKey(DebtSummaryKeys.balance));
      expect(normSpaces(amount.data!), '−1 500,00 сом');
      expect(amount.style?.color, tester.element(find.byKey(DebtSummaryKeys.balance)).colors.success);
    });

    testWidgets('AC-UI-34-006: снимок старше 60 мин — «Данные могут быть неактуальны (от HH:MM)», «Обновить», '
        'Z4 — блокировка продажи в долг «данные устарели»', (WidgetTester tester) async {
      final CustomersHarness h = CustomersHarness();
      h.receivables.onGet = (bool withDocuments, String? token) async => Success<Receivable>(
        Receivable(
          customerId: 'c1',
          balance: som(12000),
          overdueAmount: som(0),
          overdueDays: 0,
          creditLimit: som(50000),
          openOrdersAmount: som(0),
          limitRemaining: som(38000),
          creditAllowed: true,
          paymentTermDays: 14,
          asOf: kNow.subtract(const Duration(minutes: 61)),
          staleAfterMinutes: 60,
        ),
      );
      await h.pump(tester, const CustomerReceivablesScreen(customerId: 'c1'));
      expect(find.byKey(DebtSummaryKeys.stale), findsOneWidget);
      expect(findTextContaining('Данные могут быть неактуальны (от '), findsOneWidget);
      expect(find.byKey(DebtSummaryKeys.refresh), findsOneWidget);
      expect(findText('Продажа в долг недоступна: данные о долге устарели'), findsOneWidget);
    });

    testWidgets('AC-UI-34-010: «Принять оплату по долгу» — cashier и senior_seller; admin и owner — нет', (
      WidgetTester tester,
    ) async {
      for (final (RoleCode role, bool visible) in <(RoleCode, bool)>[
        (RoleCode.cashier, true),
        (RoleCode.seniorSeller, true),
        (RoleCode.admin, false),
        (RoleCode.owner, false),
      ]) {
        final CustomersHarness h = CustomersHarness(role: role)..debtPayments = true;
        await h.pump(tester, const CustomerReceivablesScreen(customerId: 'c1'));
        expect(find.byKey(ReceivablesKeys.acceptPayment), visible ? findsOneWidget : findsNothing, reason: '$role');
      }
    });

    testWidgets(
      'AC-UI-34-015: после перезапуска приложения детализация снова требует step-up (токен — только память)',
      (WidgetTester tester) async {
        final CustomersHarness before = CustomersHarness()..grantDetail();
        await before.pump(tester, const CustomerReceivablesScreen(customerId: 'c1'));
        expect(find.byKey(ReceivablesKeys.documents), findsOneWidget);

        // Новый процесс: кэш step-up-токенов и память сессии пусты.
        await tester.pumpWidget(const SizedBox.shrink());
        final CustomersHarness after = CustomersHarness();
        await after.pump(tester, const CustomerReceivablesScreen(customerId: 'c1'));
        expect(
          after.receivables.getCalls.single.withDocuments,
          isFalse,
          reason: 'детализация без токена не запрашивается',
        );
        expect(find.byKey(ReceivablesKeys.locked), findsOneWidget);
        expect(find.byKey(ReceivablesKeys.documents), findsNothing);
      },
    );

    testWidgets('AC-UI-34-013 / AC-UI-32-016: seller — «Раздел недоступен для вашей роли», запроса нет', (
      WidgetTester tester,
    ) async {
      final CustomersHarness h = CustomersHarness(role: RoleCode.seller);
      await h.pump(tester, const CustomerReceivablesScreen(customerId: 'c1'));
      expect(findText('Раздел недоступен для вашей роли'), findsOneWidget);
      expect(h.receivables.getCalls, isEmpty);
    });
  });

  group('SCR-33 история покупок', () {
    testWidgets('AC-UI-33-001/004: по умолчанию 90 дней; подпись о долге из 1С; смена источника — новый запрос', (
      WidgetTester tester,
    ) async {
      final CustomersHarness h = CustomersHarness();
      await h.pump(tester, const CustomerHistoryScreen(customerId: 'c1'));
      final CustomerHistoryQuery q = h.directory.historyCalls.single;
      expect(q.to!.difference(q.from!).inDays, inInclusiveRange(90, 91));
      expect(find.byKey(CustomerHistoryKeys.debtNote), findsOneWidget);
      expect(findText('Покупок на сумму: 24 207,50 сом'), findsOneWidget);
      expect(findText('POS-000123'), findsOneWidget);
      await tester.tap(findText('Продажи 1С'));
      await settle(tester);
      expect(h.directory.historyCalls.last.source?.value, 'onec');
      await tapVisible(tester, find.byKey(CustomerHistoryKeys.preset(HistoryPreset.days30)));
      await settle(tester);
      final CustomerHistoryQuery q30 = h.directory.historyCalls.last;
      expect(q30.to!.difference(q30.from!).inDays, inInclusiveRange(30, 31));
    });

    testWidgets('AC-UI-33-005: seller — нет доступа; без сети — «История покупок недоступна без сети»', (
      WidgetTester tester,
    ) async {
      final CustomersHarness h = CustomersHarness(role: RoleCode.seller);
      await h.pump(tester, const CustomerHistoryScreen(customerId: 'c1'));
      expect(findText('Раздел недоступен для вашей роли'), findsOneWidget);
      expect(h.directory.historyCalls, isEmpty);
      final CustomersHarness o = CustomersHarness(online: false);
      await o.pump(tester, const CustomerHistoryScreen(customerId: 'c1'));
      expect(findText('История покупок недоступна без сети'), findsOneWidget);
      expect(o.directory.historyCalls, isEmpty);
    });
  });

  group('SCR-35 скидки и условия', () {
    testWidgets(
      'AC-UI-35-001/002/005/006: пример 5 % от 16 850,00 = 842,50 → 16 007,50; источники; роли сверх лимита из ответа',
      (WidgetTester tester) async {
        final CustomersHarness h = CustomersHarness();
        await h.pump(tester, const CustomerDiscountsScreen(customerId: 'c1'));
        expect(h.directory.discountsCalls, 1);
        expect(h.directory.rulesCalls, 1);
        expect(
          findText(
            'Заказ 16 850,00 сом → скидка 5 % = 842,50 сом → итог 16 007,50 сом (предварительно, итог определяет 1С)',
          ),
          findsOneWidget,
        );
        expect(find.byKey(CustomerDiscountsKeys.creditLimit), findsOneWidget);
        expect(findText('Итог в 1С'), findsOneWidget);
        expect(findText('Действует'), findsOneWidget);
        expect(findText('Сверх лимита подтверждает: Старший продавец — 10 %, Администратор — 15 %'), findsOneWidget);
      },
    );

    testWidgets(
      'AC-UI-35-004/007 seller: сумма лимита отсутствует; ошибка одного блока — второй показан, «Повторить»',
      (WidgetTester tester) async {
        final CustomersHarness h = CustomersHarness(role: RoleCode.seller);
        h.directory.onDiscounts = (String id) async => Success<CustomerDiscounts>(sampleDiscounts(withLimit: false));
        h.directory.onRules = () async => const FailureResult<DiscountRulesInfo>(kOffline);
        await h.pump(tester, const CustomerDiscountsScreen(customerId: 'c1'));
        expect(find.byKey(CustomerDiscountsKeys.creditLimit), findsNothing);
        expect(findText('Продажа в долг: разрешена'), findsOneWidget);
        expect(findText('Оптовая скидка'), findsOneWidget);
      },
    );
  });
}
