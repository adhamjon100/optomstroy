// Порты экранов оформления SCR-21, SCR-22 (и SCR-26 через customers) — зависимости presentation, которые фича
// checkout не может взять сама (DAG 06 §6.1: роль — из auth, флаги и слоты — из core/config, переходы — go_router).
// Значения по умолчанию работают без переопределений; композиционный корень `app/di/overrides.dart` может подставить
// точные (роль из профиля входа — как `catalogViewerRole`, настройки устройства — drift `settings`). В widget-тестах
// все порты переопределяются (`overrideWithValue`).
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart' show OnlineStatus;
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/session/session_controller.dart'
    show sessionControllerProvider, stepUpCoordinatorProvider;
import 'package:optomstroy/core/session/step_up_coordinator.dart' as session show StepUpChallenge;
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:uuid/uuid.dart';

/// Роль текущего пользователя для SCR-21/SCR-22 (видимость сумм долга, эскалация, режим клиента). По умолчанию:
/// `customer` по виду пользователя сессии, иначе `null` (сотрудник без уточнения — показываются только данные,
/// которые разрешил сервер). Корень может подставить роль из профиля входа (`catalogViewerRole`). Права проверяет
/// сервер (D-15).
final checkoutViewerRoleProvider = Provider<RoleCode?>((ref) {
  final UserKind? kind = ref.watch(sessionControllerProvider.select((s) => s.userKind));
  return kind == UserKind.customer ? RoleCode.customer : null;
});

/// Имя пользователя сессии (ФИО, ПДн — только память) для пометки «Разрешено: {name}» (UI-21-028, AC-UI-21-013;
/// FQ-CHK-06, FIX-FE-08). Подставляет корень (профиль сессии фичи auth); `null` — пометка не выводится.
final checkoutViewerNameProvider = Provider<String?>((ref) => null);

/// Сессия заблокирована (idle-блокировка SCR-08, `UNLOCK_REQUIRED`): SCR-22 приостанавливает long-polling оплаты и
/// возобновляет его после разблокировки (02 AC-UI-22-011). В тестах — `overrideWith`.
final checkoutSessionLockedProvider = Provider<bool>(
  (ref) => ref.watch(sessionControllerProvider.select((s) => s.isLocked)),
);

/// Есть ли сеть (`POST /orders`, поиск клиентов, проверка дублей — только онлайн, D-32).
final checkoutOnlineProvider = Provider<bool>((ref) {
  final OnlineStatus? s = ref.watch(onlineStatusProvider).value;
  return s != OnlineStatus.offline;
});

/// Режим QR (`features.qrProvider`, `features.qrWebhook`; ядро v1.9 §24.4).
@immutable
final class CheckoutQrMode {
  /// Создаёт режим.
  const CheckoutQrMode({this.provider = QrProviderMode.none, this.autoConfirm = false});

  /// `QR_PROVIDER`.
  final QrProviderMode provider;

  /// Оплата подтверждается автоматически (1С при `onec`, вебхук банка при `bakai` — R2).
  final bool autoConfirm;
}

/// Режим QR из публичных настроек.
final checkoutQrModeProvider = Provider<CheckoutQrMode>((ref) {
  final PublicFeatureFlags f = ref.watch(publicFeatureFlagsProvider);
  return CheckoutQrMode(
    provider: f.qrProvider,
    autoConfirm: f.qrProvider == QrProviderMode.onec || (f.qrProvider == QrProviderMode.bakai && f.qrWebhook),
  );
});

/// Интервал доставки (`deliverySlots` из `GET /settings/public`, `HH:MM`).
@immutable
final class CheckoutSlot {
  /// Создаёт интервал.
  const CheckoutSlot(this.from, this.to);

  /// Начало `HH:MM`.
  final String from;

  /// Конец `HH:MM`.
  final String to;

  @override
  bool operator ==(Object other) => other is CheckoutSlot && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);
}

/// Интервалы доставки (02 UI-21-011; ядро §19.2).
final checkoutDeliverySlotsProvider = Provider<List<CheckoutSlot>>((ref) {
  final List<CheckoutSlot> slots = <CheckoutSlot>[
    for (final DeliverySlot s
        in ref.watch(publicSettingsProvider.select((PublicSettingsSnapshot s) => s.settings.deliverySlots)) ??
            const <DeliverySlot>[])
      CheckoutSlot(s.from, s.to),
  ];
  return slots;
});

/// Получить step-up токен для операции (`credit.sale.approve`, `payment.qr.confirm_manual`); `null` — отмена.
typedef CheckoutStepUp = Future<String?> Function(String operation);

/// Step-up через координатор core/session (StepUpDialog SCR-90; кэш токенов — память процесса).
final checkoutStepUpProvider = Provider<CheckoutStepUp>((ref) {
  final coordinator = ref.watch(stepUpCoordinatorProvider);
  return (String operation) => coordinator.obtain(session.StepUpChallenge(operation: operation));
});

/// Новый `Idempotency-Key` (UUID v4) — ключи платежей и создания клиента (только память, ядро §22.6).
final checkoutKeyFactoryProvider = Provider<String Function()>((ref) => const Uuid().v4);

/// Переходы экранов оформления (go_router — строковые пути 02 §4.1; фича не импортирует app/router, AP-01).
abstract interface class CheckoutNavigator {
  /// SCR-21 → SCR-22 (вернуться в SCR-21 нельзя).
  void orderCreated(BuildContext context, {required String orderId, String? paymentId});

  /// SCR-21 → SCR-20 («Изменить», «Отмена», конфликты корзины).
  void backToCart(BuildContext context, {String? cartId});

  /// SCR-21 → SCR-26; результат — ID созданного или выбранного клиента.
  Future<String?> newCustomer(BuildContext context);

  /// → SCR-24.
  void order(BuildContext context, String orderId);

  /// «Новый заказ» → главный экран роли.
  void home(BuildContext context);

  /// → SCR-38 «Принять оплату» / «Другой способ оплаты».
  void acceptPayment(BuildContext context, String orderId, {PaymentMethod? method});

  /// → SCR-23 (после «Отложить заказ» из диалога долга).
  void parked(BuildContext context);
}

/// Переходы через go_router.
final class GoRouterCheckoutNavigator implements CheckoutNavigator {
  /// Создаёт навигатор.
  const GoRouterCheckoutNavigator(this.role);

  /// Роль (главный экран: `cashier` — SCR-30, `customer` — SCR-50, прочие — SCR-10).
  final RoleCode? role;

  /// Главный экран роли.
  static String homeFor(RoleCode? role) => switch (role) {
    RoleCode.cashier => '/cashier',
    RoleCode.customer => '/home',
    _ => '/catalog',
  };

  @override
  void orderCreated(BuildContext context, {required String orderId, String? paymentId}) {
    final String q = paymentId == null ? '' : '?paymentId=${Uri.encodeQueryComponent(paymentId)}';
    GoRouter.of(context).go('/orders/${Uri.encodeComponent(orderId)}/created$q');
  }

  @override
  void backToCart(BuildContext context, {String? cartId}) {
    final GoRouter router = GoRouter.of(context);
    if (router.canPop()) {
      router.pop();
    } else {
      router.go(cartId == null ? '/cart' : '/cart?cartId=${Uri.encodeQueryComponent(cartId)}');
    }
  }

  @override
  Future<String?> newCustomer(BuildContext context) =>
      GoRouter.of(context).push<String>('/customers/new?returnTo=checkout');

  @override
  void order(BuildContext context, String orderId) =>
      GoRouter.of(context).go('/orders/${Uri.encodeComponent(orderId)}');

  @override
  void home(BuildContext context) => GoRouter.of(context).go(homeFor(role));

  @override
  void acceptPayment(BuildContext context, String orderId, {PaymentMethod? method}) {
    final String m = method == null ? '' : '&method=${method.value}';
    unawaited(GoRouter.of(context).push<void>('/payments/new?orderId=${Uri.encodeQueryComponent(orderId)}$m'));
  }

  @override
  void parked(BuildContext context) => GoRouter.of(context).go('/cart/parked');
}

/// Навигатор оформления.
final checkoutNavigatorProvider = Provider<CheckoutNavigator>(
  (ref) => GoRouterCheckoutNavigator(ref.watch(checkoutViewerRoleProvider)),
);

/// Предпочтения устройства для SCR-21 (02 SCR-21.9: `settings` scope `device` — `checkout.last_delivery_method`,
/// `checkout.last_payment_method`, `checkout.print_options`).
@immutable
final class CheckoutPrefs {
  /// Создаёт предпочтения.
  const CheckoutPrefs({
    this.deliveryMethod,
    this.paymentMethod,
    this.printInvoice = true,
    this.printWaybill = false,
    this.printReceipt = false,
  });

  /// Последний способ получения.
  final DeliveryMethod? deliveryMethod;

  /// Последний способ оплаты (кроме `credit` — никогда не предвыбирается).
  final PaymentMethod? paymentMethod;

  /// «Счёт на оплату».
  final bool printInvoice;

  /// «Накладная (предварительная)».
  final bool printWaybill;

  /// «Товарный чек».
  final bool printReceipt;

  /// Копия с изменениями.
  CheckoutPrefs copyWith({
    DeliveryMethod? deliveryMethod,
    PaymentMethod? paymentMethod,
    bool? printInvoice,
    bool? printWaybill,
    bool? printReceipt,
  }) => CheckoutPrefs(
    deliveryMethod: deliveryMethod ?? this.deliveryMethod,
    paymentMethod: paymentMethod ?? this.paymentMethod,
    printInvoice: printInvoice ?? this.printInvoice,
    printWaybill: printWaybill ?? this.printWaybill,
    printReceipt: printReceipt ?? this.printReceipt,
  );
}

/// Хранилище предпочтений устройства.
abstract interface class CheckoutPrefsStore {
  /// Прочитать.
  CheckoutPrefs read();

  /// Записать.
  void write(CheckoutPrefs prefs);
}

/// Предпочтения в памяти процесса (по умолчанию; корень может подключить drift `settings`, scope `device`).
final class InMemoryCheckoutPrefsStore implements CheckoutPrefsStore {
  /// Создаёт хранилище.
  InMemoryCheckoutPrefsStore([this._prefs = const CheckoutPrefs()]);

  CheckoutPrefs _prefs;

  @override
  CheckoutPrefs read() => _prefs;

  @override
  void write(CheckoutPrefs prefs) => _prefs = prefs;
}

/// Предпочтения устройства для оформления.
final checkoutPrefsStoreProvider = Provider<CheckoutPrefsStore>((ref) => InMemoryCheckoutPrefsStore());

/// Передача результата `POST /orders` из SCR-21 в SCR-22 без повторного запроса (02 SCR-22.4: «данные — из ответа
/// `POST /orders`»). Только память процесса (заказы на диск не пишутся, 07 §11.2).
final class CreatedOrderHandoff extends Notifier<Map<String, OrderCreatedHandoffEntry>> {
  @override
  Map<String, OrderCreatedHandoffEntry> build() => const <String, OrderCreatedHandoffEntry>{};

  /// Запомнить созданный заказ.
  void put(Order order, {required bool accepted, PrintOptions? printOptions}) =>
      state = <String, OrderCreatedHandoffEntry>{
        order.id: OrderCreatedHandoffEntry(order: order, accepted: accepted, printOptions: printOptions),
      };

  /// Забрать (и забыть) заказ.
  OrderCreatedHandoffEntry? take(String orderId) => state[orderId];
}

/// Созданный заказ для SCR-22.
@immutable
final class OrderCreatedHandoffEntry {
  /// Создаёт запись.
  const OrderCreatedHandoffEntry({required this.order, required this.accepted, this.printOptions});

  /// Заказ из ответа `POST /orders`.
  final Order order;

  /// `202 Accepted` (1С недоступна, `STALE_DATA`).
  final bool accepted;

  /// Выбранные документы печати.
  final PrintOptions? printOptions;
}

/// Последний созданный заказ (SCR-21 → SCR-22).
final createdOrderHandoffProvider = NotifierProvider<CreatedOrderHandoff, Map<String, OrderCreatedHandoffEntry>>(
  CreatedOrderHandoff.new,
);

/// Печать PDF документа заказа (счёт, товарный чек — формирует backend, D-27); `false` — печать не выполнена
/// (отмена диалога, ошибка принтера, принтер не подключён). Ошибка печати не влияет на заказ (PRINT-001).
typedef CheckoutPrinter = Future<bool> Function(OrderDocumentFile file);

/// Печать документов SCR-22. По умолчанию — «принтер не подключён» (строка документа показывает «Не удалось
/// напечатать · Повторить»); корень подключает `printingCheckoutPrinter` (checkout_printing.dart, пакет `printing`):
/// пакет не импортируется экранами, пока набор `image`/`archive` не исправлен (F_spec_questions FQ-CHK-07).
final checkoutPrinterProvider = Provider<CheckoutPrinter>(
  (ref) =>
      (OrderDocumentFile file) async => false,
);

/// Слот баннера уведомления центра на SCR-21 (RM-F-008: `cart_price_changed`, `cart_stock_changed`,
/// `credit_blocked`; 02 SCR-44.3). checkout ↛ notifications (DAG 06 §6.1): виджет подставляет корень; `null` — нет.
typedef CheckoutNotificationBannerBuilder = Widget Function(BuildContext context, String cartId);

/// Баннер уведомлений оформления (по `Cart.id`).
final checkoutNotificationBannerProvider = Provider<CheckoutNotificationBannerBuilder?>((ref) => null);
