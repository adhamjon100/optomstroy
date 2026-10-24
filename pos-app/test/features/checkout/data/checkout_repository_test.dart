// RM-F-006/RM-F-007/RM-F-013 (ядро §22.3, §22.6; DATA-263): `POST /orders` — с ключом из `checkout_draft`
// (`ensureOrderKey` один раз на попытку), `202` + `STALE_DATA` → заказ `submitting`, повтор того же ключа →
// `Idempotent-Replayed`; после перезапуска заказ ищется `GET /orders?idempotencyKey=`. Черновик без БД — ошибка.
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/cart/data/cart_bindings.dart';
import 'package:optomstroy/features/cart/data/repositories/dio_cart_repository.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/checkout/data/repositories/dio_checkout_repository.dart';
import 'package:optomstroy/features/checkout/data/repositories/drift_checkout_draft_repository.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout_draft.dart';
import 'package:optomstroy/features/orders/data/orders_bindings.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';

import '../../../core/database/test_database.dart';
import '../../../core/network/fake_adapter.dart';

Map<String, Object?> order({String status = 'submitting'}) => <String, Object?>{
  'id': 'ord-1',
  'publicNumber': 'POS-2026-000123',
  'status': status,
  'items': <Object?>[
    <String, Object?>{
      'lineNo': 1,
      'variantId': 'v-1',
      'quantity': <String, Object?>{'value': '2.000', 'unitId': 'u-1'},
    },
  ],
  'total': <String, Object?>{'amount': '5700.00', 'currency': 'KGS'},
  'paymentMethod': 'cash',
  'warnings': <Object?>[
    <String, Object?>{'code': 'STALE_DATA', 'message': '1С недоступна'},
  ],
};

Dio dioWith(FakeAdapter adapter) => Dio(BaseOptions(baseUrl: 'http://pos.test/api/v1'))..httpClientAdapter = adapter;

OrderCreateRequest request() => OrderCreateRequest(
  cartId: 'cart-1',
  cartRowVersion: 3,
  paymentMethod: PaymentMethod.cash,
  delivery: const Delivery.pickup(),
  receiver: const Receiver.customer(),
  items: <OrderCreateItem>[
    OrderCreateItem(
      variantId: 'v-1',
      quantity: LineQuantity(value: Qty.units(2), unitId: 'u-1'),
    ),
  ],
);

void main() {
  configureSqliteForTests();

  test('202 → accepted, заказ submitting с STALE_DATA; ключ уходит в Idempotency-Key; replay распознаётся', () async {
    var calls = 0;
    final FakeAdapter adapter = FakeAdapter((RequestOptions o) async {
      calls++;
      return json(
        202,
        order(),
        headers: calls > 1 ? <String, String>{ApiHeaders.idempotentReplayed: 'true'} : const <String, String>{},
      );
    });
    final DioCheckoutRepository repo = DioCheckoutRepository(
      dioWith(adapter),
      cart: const CartDtoDecoder(),
      order: const OrderDtoDecoder(),
    );
    final OrderCreateResult first = (await repo.createOrder(request(), idempotencyKey: 'k-1')).valueOrNull!;
    expect((first.accepted, first.replayed, first.order.status), (true, false, OrderStatus.submitting));
    expect(first.order.warnings.single.code, WarningCode.staleData);
    final OrderCreateResult again = (await repo.createOrder(request(), idempotencyKey: 'k-1')).valueOrNull!;
    expect(again.replayed, isTrue);
    expect(adapter.requests.map((r) => r.headers[ApiHeaders.idempotencyKey]), <Object?>['k-1', 'k-1']);
  });

  test('409 possible_duplicate (OpenAPI 1.2.0): номер похожего заказа и «N минут назад» из possibleDuplicateCreatedAt '
      '(UI-21-029); без даты или с будущей датой — без минут', () async {
    Map<String, Object?> problem(Object? createdAt) => <String, Object?>{
      'type': 'about:blank',
      'title': 'Похожий заказ',
      'status': 409,
      'code': 'ORDER_STATE_INVALID',
      'requestId': 'r-1',
      'reason': 'possible_duplicate',
      'possibleDuplicateOrderId': 'ord-0',
      'possibleDuplicatePublicNumber': 'POS-2026-000122',
      'possibleDuplicateCreatedAt': ?createdAt,
    };
    Object? createdAt = '2026-10-22T08:53:30Z';
    final FakeAdapter adapter = FakeAdapter((RequestOptions o) async => json(409, problem(createdAt)));
    final DioCheckoutRepository repo = DioCheckoutRepository(
      dioWith(adapter),
      cart: const CartDtoDecoder(),
      order: const OrderDtoDecoder(),
      clock: FixedClock(DateTime.utc(2026, 10, 22, 9)),
    );
    Future<ConflictFailure> fail() async =>
        (await repo.createOrder(request(), idempotencyKey: 'k-1')).failureOrNull! as ConflictFailure;
    final ConflictFailure f = await fail();
    expect(f.reason, 'possible_duplicate');
    expect(f.details['possibleDuplicatePublicNumber'], 'POS-2026-000122');
    expect(f.details[DioCheckoutRepository.possibleDuplicateMinutesAgoKey], 6);
    createdAt = null;
    expect((await fail()).details.containsKey(DioCheckoutRepository.possibleDuplicateMinutesAgoKey), isFalse);
    createdAt = '2026-10-22T09:30:00Z';
    expect((await fail()).details.containsKey(DioCheckoutRepository.possibleDuplicateMinutesAgoKey), isFalse);
    createdAt = 'не дата';
    expect((await fail()).details.containsKey(DioCheckoutRepository.possibleDuplicateMinutesAgoKey), isFalse);
  });

  test('после перезапуска: GET /orders?idempotencyKey= находит заказ или null', () async {
    var found = true;
    final FakeAdapter adapter = FakeAdapter(
      (RequestOptions o) async => json(200, <String, Object?>{
        'items': found ? <Object?>[(order()..remove('items'))..['itemsCount'] = 1] : <Object?>[],
        'nextCursor': null,
        'hasMore': false,
      }),
    );
    final DioCheckoutRepository repo = DioCheckoutRepository(
      dioWith(adapter),
      cart: const CartDtoDecoder(),
      order: const OrderDtoDecoder(),
    );
    final OrderSummary? summary = (await repo.findSubmittedOrder('k-1')).valueOrNull;
    expect(summary!.publicNumber, 'POS-2026-000123');
    found = false;
    expect((await repo.findSubmittedOrder('k-1')).valueOrNull, isNull);
    expect(adapter.requests.first.path, '/orders');
  });

  group('черновик оформления', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('ensureOrderKey один раз; выбор и отправка сохраняются; без БД — UnknownFailure', () async {
      var n = 0;
      final DriftCheckoutDraftRepository repo = DriftCheckoutDraftRepository(
        database: () => db,
        clock: FixedClock(DateTime.utc(2026, 10, 22, 9)),
        newKey: () => 'key-${++n}',
      );
      expect((await repo.ensureOrderKey('cart-1')).valueOrNull, 'key-1');
      expect((await repo.ensureOrderKey('cart-1')).valueOrNull, 'key-1');
      final CheckoutDraft saved = (await repo.save(
        CheckoutDraft(
          localCartId: 'cart-1',
          step: CheckoutStep.payment,
          updatedAt: DateTime.utc(2026),
          paymentMethod: PaymentMethod.qrBakai,
          deliveryMethod: DeliveryMethod.delivery,
          receiverKind: ReceiverKind.otherPerson,
        ),
      )).valueOrNull!;
      expect(
        (saved.step, saved.paymentMethod, saved.orderIdempotencyKey),
        (CheckoutStep.payment, PaymentMethod.qrBakai, 'key-1'),
      );
      await repo.markSubmitted('cart-1');
      expect((await repo.pendingSubmissions()).valueOrNull!.single.orderIdempotencyKey, 'key-1');
      await repo.clear('cart-1');
      expect((await repo.load('cart-1')).valueOrNull, isNull);
      final DriftCheckoutDraftRepository closed = DriftCheckoutDraftRepository(
        database: () => null,
        clock: const SystemClock(),
      );
      expect((await closed.ensureOrderKey('cart-1')).failureOrNull, isA<UnknownFailure>());
    });
  });

  test('корзина: 409 VERSION_CONFLICT → current (диалог «Применить мои / Оставить серверную»)', () async {
    final FakeAdapter adapter = FakeAdapter(
      (RequestOptions o) async => json(
        409,
        problem(
          'VERSION_CONFLICT',
          409,
          extra: <String, Object?>{
            'current': <String, Object?>{'id': 'cart-1', 'status': 'active', 'items': <Object?>[], 'rowVersion': 8},
          },
        ),
      ),
    );
    final DioCartRepository repo = DioCartRepository(dioWith(adapter));
    final Result<Cart> r = await repo.clear(rowVersion: 7);
    final Failure f = r.failureOrNull!;
    expect(f, isA<ConflictFailure>());
    expect(repo.conflictCurrent(f)!.rowVersion, 8);
    expect(adapter.requests.single.path, '/cart');
  });
}
