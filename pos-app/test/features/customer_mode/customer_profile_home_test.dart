// Режим клиента: профиль SCR-41 (блок «Клиент 1С», пункты клиента), «Мой кабинет» SCR-50 (заказы в работе и свой
// долг только при `confirmed`), своя привязка из `GET /me` для экранов клиента, уведомления `order_status` (RM-G-014;
// 02 UI-41-011, UI-41-016, AC-UI-41-010, UI-50-004, UI-50-005; 10 CUST-025, DEBT-009; 02 SCR-44.3). Синтетические
// данные (фейки, не реальная интеграция), деньги — целые тыйыны.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/app/router/shells/customer_mode_bindings.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart' show catalogViewerRoleProvider;
import 'package:optomstroy/features/catalog/presentation/providers/customer_mode_ports.dart';
import 'package:optomstroy/features/customers/domain/entities/receivable.dart';
import 'package:optomstroy/features/customers/domain/repositories/receivables_repository.dart';
import 'package:optomstroy/features/customers/presentation/customers_ports.dart';
import 'package:optomstroy/features/notifications/domain/entities/app_notification.dart';
import 'package:optomstroy/features/notifications/presentation/notification_targets.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/profile/presentation/screens/profile_screen.dart';
import 'package:optomstroy/features/profile/profile_providers.dart';

import '../../support/f_fakes.dart';
import '../customers/support/customers_harness.dart' as cu;
import '../orders/support/orders_harness.dart' as oh;
import 'support/customer_profile_fakes.dart';

final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));

Future<void> pumpProfile(
  WidgetTester tester,
  FakeCustomerProfileRepository repo, {
  Size size = const Size(390, 844),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        profileRepositoryProvider.overrideWithValue(repo),
        clockProvider.overrideWithValue(FixedClock(DateTime.utc(2026, 10, 22, 9))),
        onlineStatusProvider.overrideWith((Ref ref) => Stream<OnlineStatus>.value(OnlineStatus.online)),
        sessionControllerProvider.overrideWith(CustomerTestSession.new),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        debugShowCheckedModeBanner: false,
        builder: (BuildContext context, Widget? app) =>
            MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: app!),
        home: const ProfileScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pumpAndSettle();
}

AppNotification notification(String kind, {String? orderId, NotificationTarget? target, Map<String, Object?>? p}) =>
    AppNotification(
      id: 'n-$kind',
      rawKind: kind,
      title: 'Заказ согласован',
      createdAt: DateTime.utc(2026, 10, 24, 4),
      severity: NotificationSeverity.info,
      orderId: orderId,
      target: target,
      rawTarget: target?.value,
      payload: p ?? const <String, Object?>{},
    );

void main() {
  group('SCR-41 профиль клиента', () {
    testWidgets('confirmed: «Клиент 1С» — полное наименование и «Подтверждена»; пункты клиента без служебных', (
      WidgetTester tester,
    ) async {
      await pumpProfile(tester, FakeCustomerProfileRepository(customerMe(link: confirmedLink)));
      expect(find.byKey(ProfileScreen.customerLinkKey), findsOneWidget);
      expect(find.text('ОсОО «Азамат Строй»'), findsOneWidget);
      expect(find.text(l10n.status_link_confirmed), findsOneWidget);
      expect(find.byKey(ProfileScreen.ordersKey), findsOneWidget);
      expect(find.byKey(ProfileScreen.settingsKey), findsOneWidget);
      expect(find.byKey(ProfileScreen.notificationsKey), findsOneWidget);
      for (final Key k in <Key>[ProfileScreen.transactionsKey, ProfileScreen.syncKey, ProfileScreen.lockKey]) {
        expect(find.byKey(k), findsNothing, reason: '$k');
      }
      // «Мои заказы» — первым пунктом меню (UI-41-016).
      final double orders = tester.getTopLeft(find.byKey(ProfileScreen.ordersKey)).dy;
      expect(orders, lessThan(tester.getTopLeft(find.byKey(ProfileScreen.notificationsKey)).dy));
    });

    testWidgets('proposed: маскированное наименование, «Ожидает подтверждения»; долга и истории нет (AC-UI-41-010)', (
      WidgetTester tester,
    ) async {
      await pumpProfile(tester, FakeCustomerProfileRepository(customerMe(link: proposedLink)));
      expect(find.text('ОсОО «Аза***»'), findsOneWidget);
      expect(find.text('ОсОО «Азамат Строй»'), findsNothing);
      expect(find.text(l10n.status_link_proposed), findsOneWidget);
      expect(find.text(l10n.home_my_debt), findsNothing);
      expect(find.text(l10n.customer_history_title), findsNothing);
    });

    testWidgets('conflict: «Ожидает подтверждения администратором»', (WidgetTester tester) async {
      await pumpProfile(tester, FakeCustomerProfileRepository(customerMe(link: conflictLink)));
      expect(find.text(l10n.profile_customer_link_waiting), findsOneWidget);
      expect(find.text(l10n.status_link_conflict), findsOneWidget);
    });

    testWidgets('нет привязки — блок «Клиент 1С» скрыт', (WidgetTester tester) async {
      await pumpProfile(tester, FakeCustomerProfileRepository(customerMe()));
      expect(find.byKey(ProfileScreen.customerLinkKey), findsNothing);
    });
  });

  group('своя привязка (корень customer_mode_bindings)', () {
    ProviderContainer container(RoleCode? role, FakeCustomerProfileRepository repo) {
      final ProviderContainer c = ProviderContainer(
        overrides: <Override>[
          ...customerModeOverrides,
          catalogViewerRoleProvider.overrideWithValue(role),
          profileRepositoryProvider.overrideWithValue(repo),
          sessionControllerProvider.overrideWith(CustomerTestSession.new),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test(
      'customer confirmed → customerId; proposed → без customerId; ошибка /me → null; staff → /me не читается',
      () async {
        final FakeCustomerProfileRepository confirmed = FakeCustomerProfileRepository(customerMe(link: confirmedLink));
        expect(
          await container(RoleCode.customer, confirmed).read(customerSelfLinkProvider.future),
          const CustomerSelfLink(status: CustomerLinkStatus.confirmed, customerId: 'c-own'),
        );
        expect(
          await container(
            RoleCode.customer,
            FakeCustomerProfileRepository(customerMe(link: proposedLink)),
          ).read(customerSelfLinkProvider.future),
          const CustomerSelfLink(status: CustomerLinkStatus.proposed),
        );
        final FakeCustomerProfileRepository failing = FakeCustomerProfileRepository(customerMe())
          ..failure = const NetworkFailure(NetworkFailureKind.offline);
        expect(await container(RoleCode.customer, failing).read(customerSelfLinkProvider.future), isNull);
        final FakeCustomerProfileRepository staff = FakeCustomerProfileRepository(customerMe(link: confirmedLink));
        expect(await container(RoleCode.cashier, staff).read(customerSelfLinkProvider.future), isNull);
        expect(staff.meCalls, 0);
        expect(container(RoleCode.customer, confirmed).read(notificationsCustomerModeProvider), isTrue);
        expect(container(RoleCode.cashier, staff).read(notificationsCustomerModeProvider), isFalse);
      },
    );
  });

  group('SCR-50 «Мой кабинет»', () {
    FakeOrdersRepository orders({int? total = 2, bool items = true}) =>
        FakeOrdersRepository()
          ..onList = (OrdersQuery q) async {
            expect(q.statuses, customerActiveOrderStatuses);
            expect(q.limit, 1);
            expect(q.createdBy, isNull);
            return Success<OrdersPage>(oh.ordersPage(<OrderSummary>[if (items) oh.summary(1)], total: total));
          };

    test('confirmed: заказы в работе (totalEstimate) и свой долг из 1С с временем снимка', () async {
      final cu.FakeReceivables debt = cu.FakeReceivables(InMemoryCustomerFinanceMemory());
      final CustomerHomeSummary s = await MeCustomerHomePort.withOrdersAndDebt(
        const CustomerHomeSummary(linkStatus: CustomerLinkStatus.confirmed, customerId: 'c-own'),
        receivables: () => debt,
        orders: orders,
      );
      expect(s.activeOrders, 2);
      expect(s.debt, Money.som(12000));
      expect(s.debtAsOf, cu.kAsOf);
      expect(debt.getCalls.single.withDocuments, isFalse, reason: 'сводка без step-up; детализация — на SCR-34');
    });

    test('proposed: долг не запрашивается; без totalEstimate — «Есть заказы в работе»', () async {
      final cu.FakeReceivables debt = cu.FakeReceivables(InMemoryCustomerFinanceMemory());
      final CustomerHomeSummary s = await MeCustomerHomePort.withOrdersAndDebt(
        const CustomerHomeSummary(linkStatus: CustomerLinkStatus.proposed, linkName: 'ОсОО «Аза***»'),
        receivables: () => debt,
        orders: () => orders(total: null),
      );
      expect(debt.getCalls, isEmpty);
      expect(s.debt, isNull);
      expect(s.activeOrders, isNull);
      expect(s.hasActiveOrders, isTrue);
      expect(s.linkName, 'ОсОО «Аза***»');
    });

    test('ошибка 1С — «Нет данных из 1С» (null, не 0 сом — DEBT-009); порты не подключены — без чисел', () async {
      final cu.FakeReceivables debt = cu.FakeReceivables(InMemoryCustomerFinanceMemory())
        ..onGet = (bool withDocuments, String? token) async =>
            const FailureResult<Receivable>(ServerFailure(code: 'ONEC_UNAVAILABLE', status: 503));
      final CustomerHomeSummary s = await MeCustomerHomePort.withOrdersAndDebt(
        const CustomerHomeSummary(linkStatus: CustomerLinkStatus.confirmed, customerId: 'c-own'),
        receivables: () => debt,
        orders: () => throw UnimplementedError('ordersRepositoryProvider не подключён'),
      );
      expect(s.debt, isNull);
      expect(s.debtAsOf, isNull);
      expect(s.activeOrders, isNull);
      expect(s.hasActiveOrders, isFalse);
      expect(s.linked, isTrue);
    });
  });

  group('уведомления клиента (SCR-44.3)', () {
    test('order_status / payment_status → свой заказ SCR-24; служебные цели — без перехода', () {
      expect(
        NotificationTargets.of(notification('order_status', orderId: 'o-1'), customer: true),
        const NotificationLink('/orders/o-1', NotificationNavigation.go),
      );
      expect(
        NotificationTargets.of(notification('payment_status', orderId: 'o-1'), customer: true)?.location,
        '/orders/o-1',
      );
      for (final String kind in <String>['sync_error', 'credit_blocked', 'return_status']) {
        expect(
          NotificationTargets.of(
            notification(kind, orderId: 'o-1', p: const <String, Object?>{'returnId': 'r1', 'customerId': 'x'}),
            customer: true,
          ),
          isNull,
          reason: kind,
        );
      }
      expect(
        NotificationTargets.of(
          notification('system', p: const <String, Object?>{'target': 'cart_parked'}),
          customer: true,
        ),
        isNull,
      );
    });

    test('привязка: без customerId → профиль (не SCR-45), с customerId → своя карточка', () {
      final AppNotification noId = notification('system', target: NotificationTarget.customerLink);
      expect(NotificationTargets.of(noId)?.location, '/admin/users', reason: 'сотрудник — SCR-45');
      expect(NotificationTargets.of(noId, customer: true)?.location, '/profile');
      expect(
        NotificationTargets.of(
          notification(
            'system',
            target: NotificationTarget.customerLink,
            p: const <String, Object?>{'customerId': 'c-own'},
          ),
          customer: true,
        )?.location,
        '/customers/c-own',
      );
    });
  });
}

/// Сессия клиента без платформенных зависимостей.
final class CustomerTestSession extends SessionController {
  @override
  SessionState build() => SessionState.initial;
}
