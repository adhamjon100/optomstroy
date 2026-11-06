// Обвязка тестов оформления заявки с планшета SCR-52 / SCR-53 (13 TAB-2-04): фейки портов `KioskRepository`,
// `KioskCheckoutCart`, `CheckoutRepository` (предпросмотр), часы и мгновенное ожидание со сдвигом часов, предсказуемые
// ключи идемпотентности. Данные тестовые: UUID-заглушки, номера — шаблон `+996 555 000 xxx`, имён людей нет.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/checkout/checkout_providers.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout.dart';
import 'package:optomstroy/features/checkout/domain/repositories/checkout_repository.dart';
import 'package:optomstroy/features/kiosk/domain/kiosk_checkout.dart';
import 'package:optomstroy/features/kiosk/kiosk_providers.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_checkout_controller.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';

/// Корзина планшета и коды — тестовые UUID.
const String kCartId = '0192f3a1-6c3e-7a1b-9f00-000000000201';
const String kChallengeA = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f55';
const String kChallengeB = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f66';
const String kPublicNumber = 'POS-2026-000123';

/// Номера покупателей (цифры после «+996»; тестовый шаблон `555 000 xxx`).
const String kPhoneA = '555000101';
const String kPhoneB = '555000102';

/// Код из SMS теста.
const String kCode = '246810';

/// «Сейчас» тестов (UTC).
final DateTime kNow = DateTime.utc(2026, 11, 4, 9);

/// Предпросмотр корзины планшета: 3 строки, 16 007,50 сом.
CheckoutPreview kioskPreviewFixture({
  int rowVersion = 18,
  String? token = 'pv-1',
  bool ok = true,
  List<CartConflict> conflicts = const <CartConflict>[],
}) => CheckoutPreview(
  cartId: kCartId,
  cartRowVersion: rowVersion,
  ok: ok,
  conflicts: conflicts,
  items: <OrderLine>[
    for (int i = 1; i <= 3; i++)
      OrderLine(
        lineNo: i,
        variantId: 'v-$i',
        quantity: LineQuantity(value: Qty.units(1), unitId: 'pcs'),
      ),
  ],
  subtotal: const Money(1600750),
  total: const Money(1600750),
  totalToPay: const Money(1600750),
  paymentMethod: PaymentMethod.cash,
  previewToken: token,
);

/// Ответ `202 POST /kiosk/order-otp`.
Result<KioskOtpChallenge> otpSent(String challengeId, {int resendAfterSec = 60}) => Success<KioskOtpChallenge>(
  KioskOtpChallenge(
    challengeId: challengeId,
    resendAfter: Duration(seconds: resendAfterSec),
  ),
);

/// Ответ `201 POST /kiosk/orders`.
Result<KioskOrderAccepted> orderAccepted([String number = kPublicNumber]) =>
    Success<KioskOrderAccepted>(KioskOrderAccepted(number));

/// Отказ.
Result<T> refused<T>(Failure f) => FailureResult<T>(f);

/// Фейк `KioskRepository`: ответы по очереди, вызовы запоминаются.
final class FakeKioskRepository implements KioskRepository {
  /// Ответы `POST /kiosk/order-otp` по очереди.
  final List<Result<KioskOtpChallenge>> otpAnswers = <Result<KioskOtpChallenge>>[];
  final List<({String phone, String cartId, String noticeVersion})> otpCalls =
      <({String phone, String cartId, String noticeVersion})>[];

  /// Ответы `POST /kiosk/orders` по очереди (функция — чтобы держать ответ [Completer]-ом).
  final List<Future<Result<KioskOrderAccepted>> Function()> orderAnswers =
      <Future<Result<KioskOrderAccepted>> Function()>[];
  final List<({KioskOrderRequest request, String key})> orderCalls = <({KioskOrderRequest request, String key})>[];

  /// Ответы `GET /kiosk/orders?idempotencyKey=` по очереди.
  final List<Result<KioskOrderAccepted?>> findAnswers = <Result<KioskOrderAccepted?>>[];
  final List<String> findCalls = <String>[];

  void answerOrder(Result<KioskOrderAccepted> r) => orderAnswers.add(() async => r);

  @override
  Future<Result<KioskOtpChallenge>> requestOrderOtp({
    required String phoneE164,
    required String cartId,
    required String noticeVersion,
  }) async {
    otpCalls.add((phone: phoneE164, cartId: cartId, noticeVersion: noticeVersion));
    if (otpAnswers.isEmpty) throw StateError('нет ответа order-otp');
    return otpAnswers.removeAt(0);
  }

  @override
  Future<Result<KioskOrderAccepted>> submitOrder(KioskOrderRequest request, {required String idempotencyKey}) {
    orderCalls.add((request: request, key: idempotencyKey));
    if (orderAnswers.isEmpty) throw StateError('нет ответа orders');
    return orderAnswers.removeAt(0)();
  }

  @override
  Future<Result<KioskOrderAccepted?>> findOrder(String idempotencyKey) async {
    findCalls.add(idempotencyKey);
    if (findAnswers.isEmpty) throw StateError('нет ответа find');
    return findAnswers.removeAt(0);
  }

  /// `POST /kiosk/reset {cartId}` (сброс FLOW-045, 13 TAB-2-05): ответ — [onReset]; без него — новая пустая корзина.
  final List<String> resetCalls = <String>[];
  Future<Result<Cart>> Function(String cartId)? onReset;

  @override
  Future<Result<Cart>> reset(String cartId) {
    resetCalls.add(cartId);
    final Future<Result<Cart>> Function(String cartId)? answer = onReset;
    if (answer != null) return answer(cartId);
    return Future<Result<Cart>>.value(
      Success<Cart>(
        Cart(
          id: '0192f3a1-6c3e-7a1b-9f00-${(300 + resetCalls.length).toString().padLeft(12, '0')}',
          status: CartStatus.active,
          items: const <CartLine>[],
          rowVersion: 1,
        ),
      ),
    );
  }
}

/// Фейк предпросмотра (`CheckoutRepository.preview`); прочие операции SCR-21 планшет не вызывает.
final class FakeKioskCheckoutRepository implements CheckoutRepository {
  /// Ответы по очереди; пусто — [fallback].
  final List<Result<CheckoutPreview>> answers = <Result<CheckoutPreview>>[];
  Result<CheckoutPreview> fallback = Success<CheckoutPreview>(kioskPreviewFixture());
  final List<CheckoutPreviewRequest> calls = <CheckoutPreviewRequest>[];

  @override
  Future<Result<CheckoutPreview>> preview(CheckoutPreviewRequest request, {String? idempotencyKey}) async {
    calls.add(request);
    return answers.isEmpty ? fallback : answers.removeAt(0);
  }

  @override
  Future<Result<OrderCreateResult>> createOrder(
    OrderCreateRequest request, {
    required String idempotencyKey,
    String? stepUpToken,
  }) => throw UnimplementedError('POST /orders планшету закрыт');

  @override
  Future<Result<OrderSummary?>> findSubmittedOrder(String idempotencyKey) => throw UnimplementedError();
}

/// Фейк корзины для оформления.
final class FakeKioskCheckoutCart implements KioskCheckoutCart {
  KioskCartRef? cart = const KioskCartRef(cartId: kCartId, rowVersion: 18);
  int refreshes = 0;

  @override
  Future<KioskCartRef?> current() async => cart;

  @override
  Future<void> refresh() async => refreshes++;
}

/// Набор фейков одного теста.
final class KioskCheckoutFakes {
  KioskCheckoutFakes() : clock = FixedClock(kNow);

  final FakeKioskRepository repo = FakeKioskRepository();
  final FakeKioskCheckoutRepository checkout = FakeKioskCheckoutRepository();
  final FakeKioskCheckoutCart cart = FakeKioskCheckoutCart();
  final FixedClock clock;

  /// Ожидания контроллера (мгновенные; часы сдвигаются на их длительность).
  final List<Duration> sleeps = <Duration>[];
  int _keys = 0;

  /// Ключи идемпотентности — UUID v4 вида `…-4000-8000-00000000000N`.
  String nextKey() => '00000000-0000-4000-8000-${(++_keys).toString().padLeft(12, '0')}';

  void advance(Duration d) => clock.set(clock.nowUtc().add(d));

  /// Переопределения портов; [withCart] = `false` — порт корзины задаёт тест сам.
  List<Override> overrides({bool bound = true, bool withCart = true}) => <Override>[
    kioskRepositoryProvider.overrideWithValue(bound ? repo : null),
    if (withCart) kioskCheckoutCartProvider.overrideWithValue(bound ? cart : null),
    checkoutRepositoryProvider.overrideWithValue(checkout),
    clockProvider.overrideWithValue(clock),
    kioskCheckoutSleepProvider.overrideWithValue((Duration d) async {
      sleeps.add(d);
      advance(d);
    }),
    kioskCheckoutKeyFactoryProvider.overrideWithValue(nextKey),
  ];
}
