// ADR-085, RM-F-006: ручные DTO оформления == contracts/openapi/pos-api.v1.yaml 1.1.0 (`CheckoutPreview`,
// `CartCheckoutPreviewRequest`, `OrdersCreateRequest`): ключи, required, разбор примера, тела без цен и итогов
// (D-23; `clientTotalSnapshot` удалён — ORD-020), `geo` в `delivery` не передаётся (Q-178).
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/cart/data/cart_bindings.dart';
import 'package:optomstroy/features/checkout/data/dto/checkout_dtos.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout.dart';
import 'package:optomstroy/features/orders/data/orders_bindings.dart';

import '../../../support/openapi_schemas.dart';

const List<String> _schemas = <String>[
  'CheckoutPreview',
  'CartCheckoutPreviewRequest',
  'OrdersCreateRequest',
  'OrdersCreateItem',
  'CartOverride',
];

void main() {
  final OpenApiSchemas? api = OpenApiSchemas.load(_schemas);
  final String? skip = api == null ? 'нет python с PyYAML — сверка DTO невозможна' : null;

  void matches(String name, Set<String> keys, Set<String> required) {
    expect(keys, api!.props(name), reason: '$name: ключи DTO ≠ properties');
    expect(required, api.required(name), reason: '$name: required DTO ≠ required схемы');
  }

  test('ключи и обязательные поля == схемы OpenAPI', () {
    matches('CheckoutPreview', CheckoutPreviewDto.jsonKeys, CheckoutPreviewDto.requiredKeys);
    matches('CartCheckoutPreviewRequest', CheckoutRequestDto.previewKeys, CheckoutRequestDto.previewRequired);
    matches('OrdersCreateRequest', CheckoutRequestDto.createKeys, CheckoutRequestDto.createRequired);
    matches('OrdersCreateItem', CheckoutRequestDto.createItemKeys, CheckoutRequestDto.createItemKeys);
    matches('CartOverride', CheckoutRequestDto.overrideKeys, CheckoutRequestDto.overrideKeys);
    final Map<String, dynamic> example = api!.example('CheckoutPreview');
    expect((example['paymentChecks'] as Map<String, dynamic>).keys.toSet(), CheckoutPreviewDto.paymentChecksKeys);
    expect((example['permissions'] as Map<String, dynamic>).keys.toSet(), CheckoutPreviewDto.permissionsKeys);
    expect((example['onecCheck'] as Map<String, dynamic>).keys.toSet(), CheckoutPreviewDto.onecCheckKeys);
    expect(api.props('OrdersCreateRequest'), isNot(contains('clientTotalSnapshot')));
  }, skip: skip);

  test('пример CheckoutPreview разбирается: итоги, конфликты, строки, права, проверка 1С', () {
    final CheckoutPreview p = CheckoutPreviewDto.fromJson(
      jsonCopy(api!.example('CheckoutPreview')),
      cart: const CartDtoDecoder(),
      order: const OrderDtoDecoder(),
    );
    expect(p.ok, isTrue);
    expect(p.total, const Money(1600750));
    expect(p.totalToPay, const Money(1600750));
    expect(p.cashRounding, const Money(1600750));
    expect(p.conflicts.single.variantId, isNotEmpty);
    expect(p.items.single.lineTotal, const Money(1600750));
    expect(p.paymentChecks!.creditReason, CreditReason.forbiddenRole);
    expect(p.permissions!.allowedPaymentMethods, <PaymentMethod>[PaymentMethod.cash]);
    expect(p.permissions!.discountLimitPercent, const Percent(500));
    expect(p.onecCheck!.result, OnecCheckResult.ok);
    expect(p.previewToken, isNotEmpty);
  }, skip: skip);

  test('тело POST /orders: позиции и количества, без цен/итогов; receiver.kind=customer без ПДн', () {
    final Map<String, dynamic> body = CheckoutRequestDto.create(
      OrderCreateRequest(
        cartId: 'cart-1',
        cartRowVersion: 9,
        previewToken: 'tok',
        customerId: 'cust-1',
        paymentMethod: PaymentMethod.qrBakai,
        delivery: Delivery(
          method: DeliveryMethod.delivery,
          address: 'Бишкек, ул. Токтогула, 1',
          recipientPhoneE164: '+996700123456',
          desiredDate: DateTime.utc(2026, 10, 23),
          timeFrom: '10:00',
          timeTo: '14:00',
        ),
        receiver: const Receiver.customer(),
        items: <OrderCreateItem>[
          OrderCreateItem(
            variantId: 'v-1',
            quantity: LineQuantity(value: Qty.units(2), unitId: 'u-1'),
          ),
        ],
        printOptions: const PrintOptions(invoice: true),
      ),
    );
    expect(body.keys.toSet().difference(CheckoutRequestDto.createKeys), isEmpty);
    expect(body['receiver'], <String, dynamic>{'kind': 'customer'});
    expect(body['delivery'], <String, dynamic>{
      'method': 'delivery',
      'address': 'Бишкек, ул. Токтогула, 1',
      'recipientPhone': '+996700123456',
      'desiredDate': '2026-10-23',
      'timeFrom': '10:00',
      'timeTo': '14:00',
    });
    expect(body['items'], <Map<String, dynamic>>[
      <String, dynamic>{
        'variantId': 'v-1',
        'quantity': <String, dynamic>{'value': '2.000', 'unitId': 'u-1', 'packagingId': null},
      },
    ]);
    for (final String forbidden in <String>[
      'price',
      'unitPrice',
      'total',
      'subtotal',
      'amount',
      'clientTotalSnapshot',
    ]) {
      expect(body.containsKey(forbidden), isFalse, reason: forbidden);
    }
    final Map<String, dynamic> preview = CheckoutRequestDto.preview(
      const CheckoutPreviewRequest(
        cartId: 'cart-1',
        cartRowVersion: 9,
        paymentMethod: PaymentMethod.credit,
        delivery: Delivery.pickup(),
        receiver: Receiver.customer(),
        creditOverrideReason: 'постоянный клиент',
      ),
    );
    expect(preview.keys.toSet().difference(CheckoutRequestDto.previewKeys), isEmpty);
    expect(preview['creditOverride'], <String, dynamic>{'reason': 'постоянный клиент'});
    expect(preview['delivery'], <String, dynamic>{'method': 'pickup'});
  });
}
