// Golden экранов режима клиента-покупателя (RM-G-014; D-18 — compact / medium / expanded; палитра B, reduce-motion):
// SCR-24 своего заказа с платежом на проверке магазина, SCR-34 «Мой долг» при подтверждённой привязке и до неё,
// SCR-41 профиль клиента (блок «Клиент 1С»), SCR-42 настройки клиента (без «Сканера» и «Принтера»). Синтетические
// данные, деньги — целые тыйыны, «сейчас» зафиксировано. Эталоны: `goldens/ci/` (любая ОС) и `goldens/windows/`.
//
// Обновить эталоны: flutter test test/features/customer_mode/golden --update-goldens
import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/customers/presentation/customers_ports.dart';
import 'package:optomstroy/features/customers/presentation/screens/customer_receivables_screen.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';
import 'package:optomstroy/features/orders/presentation/screens/order_details_screen.dart';
import 'package:optomstroy/features/profile/presentation/screens/profile_screen.dart';
import 'package:optomstroy/features/profile/profile_providers.dart';
import 'package:optomstroy/features/settings/domain/entities/settings_entities.dart';
import 'package:optomstroy/features/settings/presentation/screens/settings_screen.dart';

import '../../../support/f_fakes.dart';
import '../../orders/support/orders_harness.dart' as oh;
import '../../settings/support/settings_fakes.dart' as st;
import '../support/customer_mode_harness.dart';
import '../support/customer_profile_fakes.dart';

/// SCR-24: своя заявка, частичная оплата получена, QR-платёж на проверке магазина.
Widget _order(Size size) => oh.OrdersHarness(
  role: RoleCode.customer,
  userId: 'cust-user',
  orders: FakeOrdersRepository()
    ..onGet = (String id, bool refresh) async => Success<OrderDetails>(
      oh.details(
        oh.order(
          status: OrderStatus.awaitingPayment,
          method: PaymentMethod.qrBakai,
          paidTyiyn: 800000,
          payments: <Payment>[
            oh.payment(tyiyn: 800000),
            const Payment(
              id: 'pay-r',
              orderId: 'o1',
              method: PaymentMethod.qrBakai,
              status: PaymentStatus.manualConfirm,
              amount: Money(800750),
              reviewReason: ReviewReason.latePayment,
            ),
          ],
        ),
        <OrderAction>{OrderAction.cancel, OrderAction.printInvoice},
      ),
    ),
).app(const OrderDetailsScreen(orderId: 'o1'), size: size);

Widget _debt(Size size, CustomerSelfLink? link) =>
    CustomerModeHarness(link: link).app(const CustomerReceivablesScreen(customerId: kOwnId), size: size);

/// Сеть есть (без платформенного connectivity_plus).
final class _Net implements NetworkSignalSource {
  const _Net();

  @override
  Future<bool> hasNetwork() async => true;

  @override
  Stream<bool> get changes => const Stream<bool>.empty();
}

/// Сессия без платформенных зависимостей.
final class _Session extends SessionController {
  @override
  SessionState build() => SessionState.initial;
}

Widget _app(Widget home, List<Override> overrides, Size size) => ProviderScope(
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

Widget _profile(Size size) => _app(const ProfileScreen(), <Override>[
  profileRepositoryProvider.overrideWithValue(FakeCustomerProfileRepository(customerMe(link: confirmedLink))),
  clockProvider.overrideWithValue(FixedClock(DateTime.utc(2026, 10, 22, 9))),
  onlineStatusProvider.overrideWith((Ref ref) => Stream<OnlineStatus>.value(OnlineStatus.online)),
  sessionControllerProvider.overrideWith(_Session.new),
], size);

Widget _settings(Size size) => _app(
  const SettingsScreen(),
  st.settingsOverrides(
    sessions: st.FakeSessionsRepository(<DeviceSession>[
      st.session('cur', current: true, name: 'Pixel 7', platform: DevicePlatform.android),
    ]),
    protection: st.FakeProtectionRepository(st.customerProtection),
    viewer: const SettingsViewer(kind: UserKind.customer),
    extra: <Override>[connectivityWatcherProvider.overrideWithValue(ConnectivityWatcher(const _Net()))],
  ),
  size,
);

Future<void> _prepare(WidgetTester tester) async {
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  setUpAll(() => EditableText.debugDeterministicCursor = true);
  tearDownAll(() => EditableText.debugDeterministicCursor = false);

  final Map<String, Widget Function(Size)> scenes = <String, Widget Function(Size)>{
    'scr24_order_review': _order,
    'scr34_debt_confirmed': (Size s) => _debt(s, kConfirmed),
    'scr34_debt_proposed': (Size s) => _debt(s, const CustomerSelfLink(status: CustomerLinkStatus.proposed)),
    'scr41_profile': _profile,
    'scr42_settings': _settings,
  };

  for (final MapEntry<String, Widget Function(Size)> scene in scenes.entries) {
    for (final MapEntry<String, Size> w in kWindows.entries) {
      unawaited(
        goldenTest(
          '${scene.key} · ${w.key}',
          fileName: 'customer_${scene.key}_${w.key}',
          constraints: BoxConstraints.tight(w.value),
          pumpBeforeTest: _prepare,
          builder: () => SizedBox(width: w.value.width, height: w.value.height, child: scene.value(w.value)),
        ),
      );
    }
  }
}
