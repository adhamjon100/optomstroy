// Неизвестный результат `POST /orders` (F-flutter-ui-1, F-flutter-ui-3, F-flutter-data-2; 02 UI-20-020, SCR-20.11,
// SCR-20.11.1, AC-UI-20-019, AC-UI-20-028, AC-UI-21-024; 10 CART-022 (а), ORD-028; ядро §22.6; RM-F-013 п. 4):
// - перезапуск (новый контейнер над той же drift-БД): `checkout_draft.submitted_at` → поиск `GET /orders?idempotencyKey=`
//   → найден → SCR-22 без второго POST; не найден → SCR-21 с тем же ключом (Cart.id сменился — ключ черновика
//   `cart_draft.local_id`);
// - график фоновых повторов 2/4/8/16 с, затем 30 с, «Повторить сейчас» после 2 неудач, «дольше обычного» после 30 с,
//   итог через 10 мин; появление сети — немедленный повтор; окончательный отказ снимает блокировку; ключ > 24 ч.
// Синтетические данные.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/sync/cart_sync.dart';
import 'package:optomstroy/features/checkout/checkout_providers.dart';
import 'package:optomstroy/features/checkout/data/repositories/drift_checkout_draft_repository.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout_draft.dart';
import 'package:optomstroy/features/checkout/presentation/controllers/checkout_controller.dart';
import 'package:optomstroy/features/checkout/presentation/controllers/order_submission_recovery.dart';
import 'package:optomstroy/features/checkout/presentation/providers/checkout_ports.dart';
import 'package:optomstroy/features/checkout/presentation/widgets/order_submission_overlay.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';

import '../../../core/database/test_database.dart';
import '../../../support/f_fakes.dart';
import '../../cart/support/cart_test_support.dart';
import '../checkout_test_support.dart';

OrderSummary summary(String id) => OrderSummary(
  id: id,
  publicNumber: 'POS-2026-000129',
  status: OrderStatus.submitting,
  total: Money.som(100),
  paymentMethod: PaymentMethod.cash,
);

const OrderCreateRequest request = OrderCreateRequest(
  cartId: 'cart-1',
  cartRowVersion: 7,
  paymentMethod: PaymentMethod.cash,
  delivery: Delivery.pickup(),
  receiver: Receiver.customer(),
  items: <OrderCreateItem>[],
);

/// Сеть для теста (переключаемая).
final class _Online extends Notifier<bool> {
  @override
  bool build() => true;

  void set(bool v) => state = v;
}

final _onlineProvider = NotifierProvider<_Online, bool>(_Online.new);

Future<void> _drain() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  configureSqliteForTests();

  group('перезапуск над той же drift-БД (RM-F-013 п. 4, AC-UI-21-024)', () {
    late AppDatabase db;
    late DriftCheckoutDraftRepository drafts;
    late FFakes fakes;
    final FixedClock clock = FixedClock(testNow);

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      drafts = DriftCheckoutDraftRepository(database: () => db, clock: clock, newKey: () => 'order-key-1');
      fakes = FFakes();
      // Сеанс 1: ключ сохранён до отправки, POST /orders ушёл (ответ потерян), приложение закрыто.
      await drafts.save(CheckoutDraft(localCartId: 'local-1', step: CheckoutStep.review, updatedAt: testNow));
      await drafts.ensureOrderKey('local-1');
      await drafts.markSubmitted('local-1');
    });
    tearDown(() => db.close());

    ProviderContainer restart({List<Override> extra = const <Override>[]}) {
      final ProviderContainer c = ProviderContainer(
        overrides: <Override>[
          ...extra,
          appDatabaseProvider.overrideWithValue(db),
          checkoutDraftRepositoryProvider.overrideWithValue(drafts),
          checkoutRepositoryProvider.overrideWithValue(fakes.checkout),
          cartRepositoryProvider.overrideWithValue(fakes.cart),
          checkoutOnlineProvider.overrideWithValue(true),
          clockProvider.overrideWithValue(clock),
          orderSubmissionJitterProvider.overrideWithValue((int ms) => ms),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('заказ создан до перезапуска → найден по idempotencyKey, SCR-22, второго POST нет, черновик удалён', () async {
      fakes.checkout.onFindSubmittedOrder = (String key) async => Success<OrderSummary?>(summary('order-9'));
      final ProviderContainer c = restart();
      expect(c.read(orderSubmissionRecoveryProvider).locked, isFalse);
      await _drain();
      expect(fakes.checkout.calls.single.method, 'findSubmittedOrder');
      expect(fakes.checkout.calls.single.args.single, 'order-key-1');
      final OrderSubmissionState s = c.read(orderSubmissionRecoveryProvider);
      expect(s.created?.orderId, 'order-9');
      expect(s.locked, isFalse);
      expect((await drafts.load('local-1')).valueOrNull, isNull);
    });

    test('заказа нет → SCR-21 с сохранёнными шагами; Cart.id сменился, POST /orders — с тем же ключом', () async {
      fakes.checkout.onFindSubmittedOrder = (String key) async => const Success<OrderSummary?>(null);
      fakes.cart.onFetch = () async => Success<Cart>(mockupCart(id: 'cart-2'));
      fakes.checkout.onPreview = (CheckoutPreviewRequest r) async =>
          Success<CheckoutPreview>(mockupPreview(method: r.paymentMethod));
      final List<String> keys = <String>[];
      fakes.checkout.onCreateOrder = (OrderCreateRequest r, String key, String? s) async {
        keys.add(key);
        return Success<OrderCreateResult>(OrderCreateResult(order: createdOrder(), accepted: false));
      };
      final FakeCartSync sync = FakeCartSync(fakes.cart)
        ..snapshot = const CartLocalSnapshot(localCartId: 'local-1', lines: <CartLocalLine>[], dirty: false);
      final ProviderContainer c = restart(
        extra: <Override>[
          cartSyncProvider.overrideWithValue(sync),
          checkoutViewerRoleProvider.overrideWithValue(RoleCode.cashier),
          checkoutPrefsStoreProvider.overrideWithValue(
            InMemoryCheckoutPrefsStore(
              const CheckoutPrefs(paymentMethod: PaymentMethod.cash, deliveryMethod: DeliveryMethod.pickup),
            ),
          ),
        ],
      );
      c.read(orderSubmissionRecoveryProvider);
      await _drain();
      expect(c.read(orderSubmissionRecoveryProvider).reopenCheckout, isTrue);
      expect(c.read(orderSubmissionRecoveryProvider).locked, isFalse);
      expect((await drafts.load('local-1')).valueOrNull?.orderIdempotencyKey, 'order-key-1');

      final CheckoutController ctl = c.read(checkoutControllerProvider('cart-2').notifier);
      expect(await ctl.open(), isNull);
      expect(c.read(checkoutControllerProvider('cart-2')).draftKey, 'local-1');
      expect(await ctl.submit(), isA<CheckoutCreated>());
      expect(keys, <String>['order-key-1'], reason: 'тот же Idempotency-Key после перезапуска (AC-UI-21-024)');
    });

    test('ключ старше 24 ч → «Разблокировать корзину» очищает submitted_at и ключ', () async {
      // Перезапуск «через 25 ч».
      final ProviderContainer later = ProviderContainer(
        overrides: <Override>[
          appDatabaseProvider.overrideWithValue(db),
          checkoutDraftRepositoryProvider.overrideWithValue(drafts),
          checkoutRepositoryProvider.overrideWithValue(fakes.checkout),
          checkoutOnlineProvider.overrideWithValue(true),
          clockProvider.overrideWithValue(FixedClock(testNow.add(const Duration(hours: 25)))),
        ],
      );
      addTearDown(later.dispose);
      later.read(orderSubmissionRecoveryProvider);
      await _drain();
      expect(later.read(orderSubmissionRecoveryProvider).phase, OrderSubmissionPhase.expired);
      expect(fakes.checkout.calls, isEmpty, reason: 'ключ истёк — повторов и поиска нет');
      await later.read(orderSubmissionRecoveryProvider.notifier).unlockExpired();
      expect(later.read(orderSubmissionRecoveryProvider).locked, isFalse);
      expect((await drafts.load('local-1')).valueOrNull, isNull);
    });
  });

  group('график фоновых повторов (02 SCR-20.11.1, AC-UI-20-028)', () {
    late FFakes fakes;
    late List<Override> overrides;

    setUp(() {
      fakes = FFakes();
      overrides = <Override>[
        ...fakes.overrides,
        checkoutOnlineProvider.overrideWith((Ref ref) => ref.watch(_onlineProvider)),
        clockProvider.overrideWithValue(FixedClock(testNow)),
        orderSubmissionJitterProvider.overrideWithValue((int ms) => ms),
      ];
    });

    Future<ProviderContainer> start(WidgetTester tester) async {
      await tester.pumpWidget(ProviderScope(overrides: overrides, child: const SizedBox()));
      final ProviderContainer c = ProviderScope.containerOf(tester.element(find.byType(SizedBox)));
      // Как хост оболочки: у провайдера есть слушатель (иначе Riverpod 3 приостанавливает его подписки).
      c.listen<OrderSubmissionState>(orderSubmissionRecoveryProvider, (_, _) {});
      c
          .read(orderSubmissionRecoveryProvider.notifier)
          .takeOver(
            PendingOrderSubmission(
              draftKey: 'local-1',
              idempotencyKey: 'order-key-1',
              submittedAt: testNow,
              request: request,
            ),
          );
      return c;
    }

    int creates() => fakes.checkout.calls.where((c) => c.method == 'createOrder').length;

    testWidgets('2/4/8/16 с, затем раз в 30 с; «Повторить сейчас» после 2 неудач; «дольше обычного» после 30 с; '
        'через 10 мин — итоговое состояние без автоповторов', (WidgetTester tester) async {
      final List<OrderCreateRequest> bodies = <OrderCreateRequest>[];
      fakes.checkout.onCreateOrder = (OrderCreateRequest r, String key, String? s) async {
        bodies.add(r);
        return const FailureResult<OrderCreateResult>(NetworkFailure(NetworkFailureKind.timeout));
      };
      final ProviderContainer c = await start(tester);
      OrderSubmissionState s() => c.read(orderSubmissionRecoveryProvider);
      expect((s().locked, s().canRetryNow), (true, false));
      await tester.pump(const Duration(milliseconds: 1999));
      expect(creates(), 0);
      await tester.pump(const Duration(milliseconds: 1));
      expect(creates(), 1);
      await tester.pump(const Duration(seconds: 4));
      expect(creates(), 2);
      expect(s().canRetryNow, isTrue, reason: 'после 2-го неудачного повтора');
      await tester.pump(const Duration(seconds: 8));
      expect(creates(), 3);
      expect(s().long, isFalse, reason: 'ожидание 14 с');
      await tester.pump(const Duration(seconds: 16));
      expect(creates(), 4);
      expect(s().long, isTrue, reason: 'ожидание 2 + 4 + 8 + 16 = 30 с');
      await tester.pump(const Duration(seconds: 29));
      expect(creates(), 4);
      await tester.pump(const Duration(seconds: 1));
      expect(creates(), 5, reason: 'этап 2 — раз в 30 с');
      expect(bodies.every((OrderCreateRequest b) => identical(b, request)), isTrue, reason: 'тело из памяти');
      // До 10 мин ожидания — раз в 30 с.
      await tester.pump(const Duration(minutes: 10));
      expect(s().phase, OrderSubmissionPhase.checkList);
      final int stopped = creates();
      await tester.pump(const Duration(minutes: 5));
      expect(creates(), stopped, reason: 'автоповторы прекращены');
      expect(s().locked, isTrue, reason: 'корзина по-прежнему заблокирована');
      // «Повторить сейчас» — повтор и этап 1 заново.
      await c.read(orderSubmissionRecoveryProvider.notifier).retryNow();
      expect(creates(), stopped + 1);
      expect(s().phase, OrderSubmissionPhase.checking);
      // Неудача «Повторить сейчас» — первая в новом этапе 1: следующий автоповтор через 4 с.
      await tester.pump(const Duration(seconds: 4));
      expect(creates(), stopped + 2);
      c.dispose();
    });

    testWidgets('появление сети — немедленный повтор; ответ 201 → заказ для SCR-22, черновик удалён', (
      WidgetTester tester,
    ) async {
      int n = 0;
      fakes.checkout.onCreateOrder = (OrderCreateRequest r, String key, String? s) async => ++n == 1
          ? const FailureResult<OrderCreateResult>(NetworkFailure(NetworkFailureKind.offline))
          : Success<OrderCreateResult>(OrderCreateResult(order: createdOrder(), accepted: true));
      final ProviderContainer c = await start(tester);
      await tester.pump(const Duration(seconds: 2));
      expect(creates(), 1);
      c.read(_onlineProvider.notifier).set(false);
      await tester.pump();
      c.read(_onlineProvider.notifier).set(true);
      await tester.pump();
      expect(creates(), 2, reason: 'без ожидания 4 с');
      expect(c.read(orderSubmissionRecoveryProvider).created?.orderId, 'order-1');
      expect(c.read(orderSubmissionRecoveryProvider).locked, isFalse);
      expect(c.read(createdOrderHandoffProvider)['order-1']?.accepted, isTrue);
      c.dispose();
    });

    testWidgets('окончательный отказ (422 PRICE_CHANGED) — блокировка снята, заказ не создан, ключ очищен', (
      WidgetTester tester,
    ) async {
      fakes.checkoutDraft.drafts['local-1'] = CheckoutDraft(
        localCartId: 'local-1',
        step: CheckoutStep.review,
        updatedAt: testNow,
        orderIdempotencyKey: 'order-key-1',
        submittedAt: testNow,
      );
      fakes.checkout.onCreateOrder = (OrderCreateRequest r, String key, String? s) async =>
          const FailureResult<OrderCreateResult>(ConflictFailure(ConflictKind.priceChanged));
      final ProviderContainer c = await start(tester);
      await tester.pump(const Duration(seconds: 2));
      final OrderSubmissionState s = c.read(orderSubmissionRecoveryProvider);
      expect(s.locked, isFalse);
      expect(s.rejected, isA<ConflictFailure>());
      expect(fakes.checkoutDraft.drafts, isEmpty);
      c.dispose();
    });

    testWidgets('оверлей UI-20-020 и хост: «Проверяем результат…», «Повторить сейчас»; найденный заказ → SCR-22', (
      WidgetTester tester,
    ) async {
      final CheckoutHarness h = CheckoutHarness();
      int n = 0;
      h.fakes.checkout.onCreateOrder = (OrderCreateRequest r, String key, String? s) async => ++n < 3
          ? const FailureResult<OrderCreateResult>(NetworkFailure(NetworkFailureKind.timeout))
          : Success<OrderCreateResult>(OrderCreateResult(order: createdOrder(), accepted: false));
      await h.pump(
        tester,
        const OrderSubmissionHost(child: Scaffold(body: OrderSubmissionOverlay())),
        size: const Size(400, 600),
      );
      final ProviderContainer c = ProviderScope.containerOf(tester.element(find.byType(OrderSubmissionOverlay)));
      c
          .read(orderSubmissionRecoveryProvider.notifier)
          .takeOver(
            PendingOrderSubmission(
              draftKey: 'cart-1',
              idempotencyKey: 'order-key-1',
              submittedAt: testNow,
              request: request,
            ),
          );
      await tester.pump();
      expect(find.text('Проверяем результат создания заказа…'), findsOneWidget);
      expect(find.byKey(OrderSubmissionKeys.retry), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(find.byKey(OrderSubmissionKeys.retry), findsOneWidget);
      await tester.tap(find.byKey(OrderSubmissionKeys.retry));
      await tester.pump();
      await tester.pump();
      expect(h.nav.calls, contains('orderCreated:order-1:-'));
    });
  });
}
