// Обвязка тестов режима клиента-покупателя (RM-G-014; 10 CUST-021…CUST-025; 02 SCR-24, SCR-25, SCR-32…SCR-35,
// SCR-41, SCR-42 в режиме клиента): фейки фичи customers (справочник, долги) из обвязки этапа G, роль `customer`
// и своя привязка через порт `customerSelfLinkProvider` — зритель `customersViewerProvider` НЕ подменяется, а
// выводится так же, как в приложении. Синтетические данные (не реальная интеграция), деньги — целые тыйыны.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/session_controller.dart' show stepUpCoordinatorProvider;
import 'package:optomstroy/core/session/step_up_coordinator.dart';
import 'package:optomstroy/core/session/step_up_token_cache.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart' show catalogViewerRoleProvider;
import 'package:optomstroy/features/customers/customers_providers.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/repositories/customer_directory_repository.dart';
import 'package:optomstroy/features/customers/domain/repositories/receivables_repository.dart';
import 'package:optomstroy/features/customers/presentation/customers_ports.dart';
import 'package:optomstroy/features/customers/presentation/new/new_customer_controller.dart';

import '../../customers/support/customers_harness.dart' as cu;

/// Окна golden (D-18).
const Map<String, Size> kWindows = <String, Size>{
  'compact': Size(390, 844),
  'medium': Size(820, 1000),
  'expanded': Size(1366, 900),
};

/// Своя карточка 1С клиента-покупателя.
const String kOwnId = 'c-own';

/// Чужая карточка.
const String kForeignId = 'c-foreign';

/// Подтверждённая привязка.
const CustomerSelfLink kConfirmed = CustomerSelfLink(status: CustomerLinkStatus.confirmed, customerId: kOwnId);

/// Обвязка экранов клиентов в режиме `customer`.
final class CustomerModeHarness {
  CustomerModeHarness({this.link = kConfirmed, this.linkCompleter, this.online = true, this.selfService = true})
    : clock = FixedClock(cu.kNow) {
    stepUp = StepUpCoordinator(StepUpTokenCache(clock: clock, skew: Duration.zero));
    receivables = cu.FakeReceivables(memory);
    directory.onCard = (String id, Set<CustomerInclude> include) async =>
        Success<Customer>(cu.cashierCustomer(id: id, name: 'ОсОО «Азамат Строй»'));
  }

  /// Своя привязка (`GET /me`), если [linkCompleter] не задан.
  final CustomerSelfLink? link;

  /// Незавершённая загрузка привязки (состояние «загрузка»).
  final Completer<CustomerSelfLink?>? linkCompleter;

  final bool online;

  /// `features.customerSelfService` (`CUSTOMER_SELF_SERVICE`).
  final bool selfService;
  final FixedClock clock;
  late final StepUpCoordinator stepUp;
  final InMemoryCustomerFinanceMemory memory = InMemoryCustomerFinanceMemory();
  final cu.FakeDirectory directory = cu.FakeDirectory();
  late final cu.FakeReceivables receivables;
  int linkLoads = 0;

  List<Override> get overrides => <Override>[
    connectivityWatcherProvider.overrideWithValue(ConnectivityWatcher(_Net(online))),
    clockProvider.overrideWithValue(clock),
    stepUpCoordinatorProvider.overrideWithValue(stepUp),
    newCustomerViewerRoleProvider.overrideWithValue(RoleCode.customer),
    customersSelfServiceProvider.overrideWithValue(selfService),
    catalogViewerRoleProvider.overrideWithValue(RoleCode.customer),
    customerSelfLinkProvider.overrideWith((Ref ref) {
      linkLoads++;
      return linkCompleter?.future ?? Future<CustomerSelfLink?>.value(link);
    }),
    // Корень подключил служебные действия (как в приложении) — скрыть их должен режим клиента, а не пустой порт.
    customerToCartActionProvider.overrideWithValue((BuildContext context, String customerId) async {}),
    customerDebtPaymentsEnabledProvider.overrideWith((Ref ref) => true),
    customerOrdersTabBuilderProvider.overrideWithValue(
      (BuildContext context, String customerId) => const SizedBox(key: ValueKey<String>('orders-tab-body')),
    ),
    customersOnlineProvider.overrideWith((Ref ref) => online),
    newCustomerOnlineProvider.overrideWith((Ref ref) => online),
    customerFinanceMemoryProvider.overrideWithValue(memory),
    customerDirectoryRepositoryProvider.overrideWithValue(directory),
    receivablesRepositoryProvider.overrideWithValue(receivables),
    onlineStatusProvider.overrideWith(
      (Ref ref) => Stream<OnlineStatus>.value(online ? OnlineStatus.online : OnlineStatus.offline),
    ),
  ];

  /// Приложение с экраном [home] в окне [size].
  Widget app(Widget home, {Size size = const Size(390, 844)}) => ProviderScope(
    key: ObjectKey(this),
    overrides: overrides,
    child: MaterialApp(
      theme: AppTheme.light(),
      locale: const Locale('ru'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      debugShowCheckedModeBanner: false,
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true, size: size, padding: EdgeInsets.zero),
        child: child!,
      ),
      home: home,
    ),
  );

  /// Показать [home] и дождаться загрузки.
  Future<void> pump(WidgetTester tester, Widget home, {Size size = const Size(390, 844)}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(home, size: size));
    await cu.settle(tester);
  }
}

final class _Net implements NetworkSignalSource {
  const _Net(this.online);

  final bool online;

  @override
  Future<bool> hasNetwork() async => online;

  @override
  Stream<bool> get changes => const Stream<bool>.empty();
}
