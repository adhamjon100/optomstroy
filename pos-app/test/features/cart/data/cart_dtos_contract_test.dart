// ADR-085, RM-F-001/RM-F-005: ручные DTO корзины == contracts/openapi/pos-api.v1.yaml 1.2.0 — ключи DTO (∪ игнорируемые)
// == properties схемы, required DTO == required схемы; синтетический пример каждой схемы (значения `example`
// контракта) разбирается в сущность без потерь (деньги — тыйыны, количества — milli-units); тела запросов содержат
// только свойства схемы и все обязательные, без цен и итогов (D-23).
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/cart/data/dto/cart_dtos.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';

import '../../../support/openapi_schemas.dart';

const List<String> _schemas = <String>[
  'Cart',
  'CartItem',
  'CartConflict',
  'CartParkedSummary',
  'CartParkResponse',
  'Image',
  'Packaging',
  'CartPutItemRequest',
  'CartUpdateRequest',
  'CartCustomerSetRequest',
  'CartDiscountRequest',
  'CartParkRequest',
  'CartParkedResumeRequest',
  'CartOverride',
];

void main() {
  final OpenApiSchemas? api = OpenApiSchemas.load(_schemas);
  final String? skip = api == null ? 'нет python с PyYAML — сверка DTO невозможна' : null;

  void matches(String name, Set<String> keys, Set<String> required, {Set<String> ignored = const <String>{}}) {
    expect(keys.intersection(ignored), isEmpty, reason: '$name: ключ одновременно разбирается и игнорируется');
    expect(<String>{...keys, ...ignored}, api!.props(name), reason: '$name: ключи DTO ≠ properties');
    expect(required, api.required(name), reason: '$name: required DTO ≠ required схемы');
  }

  test('ключи и обязательные поля ответов == схемы OpenAPI', () {
    matches('Cart', CartDto.jsonKeys, CartDto.requiredKeys, ignored: CartDto.ignoredKeys);
    matches('CartItem', CartItemDto.jsonKeys, CartItemDto.requiredKeys);
    matches('CartConflict', CartConflictDto.jsonKeys, CartConflictDto.requiredKeys);
    matches(
      'CartParkedSummary',
      CartParkedSummaryDto.jsonKeys,
      CartParkedSummaryDto.requiredKeys,
      ignored: CartParkedSummaryDto.ignoredKeys,
    );
    matches('CartParkResponse', CartParkResponseDto.jsonKeys, CartParkResponseDto.requiredKeys);
    matches('Image', CartImageDto.jsonKeys, CartImageDto.requiredKeys, ignored: CartImageDto.ignoredKeys);
    matches('Packaging', CartPackagingDto.jsonKeys, CartPackagingDto.requiredKeys);
  }, skip: skip);

  test('тела запросов: ключи и обязательные поля == схемы OpenAPI', () {
    matches('CartPutItemRequest', CartRequestDto.putItemKeys, CartRequestDto.putItemRequired);
    matches('CartUpdateRequest', CartRequestDto.updateKeys, CartRequestDto.updateRequired);
    matches('CartCustomerSetRequest', CartRequestDto.customerKeys, CartRequestDto.customerRequired);
    matches('CartDiscountRequest', CartRequestDto.discountKeys, CartRequestDto.discountRequired);
    matches('CartParkRequest', CartRequestDto.parkKeys, CartRequestDto.parkRequired);
    matches('CartParkedResumeRequest', CartRequestDto.resumeKeys, const <String>{});
  }, skip: skip);

  test('пример Cart разбирается: тыйыны, milli-units, строки, конфликты, клиент', () {
    final Cart cart = CartDto.fromJson(jsonCopy(api!.example('Cart')));
    expect(cart.status, CartStatus.active);
    expect(cart.total, const Money(1600750));
    expect(cart.subtotal, const Money(1600750));
    expect(cart.appliedDiscountPercent, const Percent(500));
    expect(cart.unitsCount, const Qty(124000));
    expect(cart.rowVersion, 1);
    final CartLine line = cart.items.single;
    expect(line.quantity.value, const Qty(124000));
    expect(line.quantity.baseValue, const Qty(124000));
    expect(line.unitPrice, const Money(1600750));
    expect(line.available, const Qty(124000));
    expect(line.remainingAvailable, const Qty(124000));
    expect(line.packaging!.factor, const Qty(124000));
    expect(line.image!.sha256, 'a' * 64);
    expect(line.warnings, <CartItemWarning>[CartItemWarning.priceChanged]);
    expect(cart.warnings.single.kind, CartConflictKind.priceChanged);
    expect(cart.warnings.single.oldPrice, const Money(1600750));
    expect(cart.customer!.id, isNotEmpty);
    expect(cart.receiver!.kind, ReceiverKind.customer);
    // OpenAPI 1.2.0: `restoredFromOrder {number, reason}` (08 §3.8 «Уточнения» п. 4).
    expect(cart.restoredFromOrder!.number, 'POS-2026-000123');
    expect(cart.restoredFromOrder!.reason, isNotEmpty);
  }, skip: skip);

  test('Cart.restoredFromOrder: ключи == схема 1.2.0; нет поля, null или объект без number → null (08 §2.11)', () {
    final Map<String, dynamic> example = jsonCopy(api!.example('Cart'));
    final Map<String, dynamic> nested = (example['restoredFromOrder'] as Map<Object?, Object?>).cast<String, dynamic>();
    expect(nested.keys.toSet(), CartRestoredFromOrderDto.jsonKeys, reason: 'Cart.restoredFromOrder: ключи DTO');
    Cart parse(Object? value, {bool omit = false}) {
      final Map<String, dynamic> j = jsonCopy(example);
      if (omit) {
        j.remove('restoredFromOrder');
      } else {
        j['restoredFromOrder'] = value;
      }
      return CartDto.fromJson(j);
    }

    expect(parse(null, omit: true).restoredFromOrder, isNull);
    expect(parse(null).restoredFromOrder, isNull);
    expect(parse(<String, dynamic>{'reason': 'x'}).restoredFromOrder, isNull);
    final CartRestoredFromOrder r = parse(<String, dynamic>{
      'number': 'POS-2026-000001',
      'reason': null,
    }).restoredFromOrder!;
    expect(r.number, 'POS-2026-000001');
    expect(r.reason, isNull);
  }, skip: skip);

  test('пример CartParkResponse, CartParkedSummary разбираются', () {
    final CartParkResult park = CartParkResponseDto.fromJson(jsonCopy(api!.example('CartParkResponse')));
    expect(park.parked.id, isNotEmpty);
    expect(park.active.items, hasLength(1));
    final CartParkedSummary s = CartParkedSummaryDto.fromJson(jsonCopy(api.example('CartParkedSummary')));
    expect(s.total, const Money(1600750));
    expect(s.owner!.displayName, isNotEmpty);
  }, skip: skip);

  test('отрицательный остаток строки (EQ-CAT-12) и неразбираемый available конфликта', () {
    final CartLine line = CartItemDto.fromJson(<String, dynamic>{
      'variantId': 'v-1',
      'quantity': <String, dynamic>{'value': '2.000', 'unitId': 'u-1'},
      'available': '-3.500',
    });
    expect(line.available, const Qty(-3500));
    final CartConflict c = CartConflictDto.fromJson(<String, dynamic>{
      'variantId': 'v-1',
      'kind': 'stock_insufficient',
      'available': 'n/a',
    });
    expect(c.available, isNull);
    expect(c.kind, CartConflictKind.stockInsufficient);
    expect(CartConflictDto.fromJson(<String, dynamic>{'variantId': 'v', 'kind': 'future_kind'}).kind, isNull);
  });

  test('тела запросов: без цен/итогов, mode=set по умолчанию, override — только с причиной', () {
    final Map<String, dynamic> put = CartRequestDto.putItem(
      CartItemPut(
        quantity: LineQuantity(value: Qty.units(6), unitId: 'u-1', packagingId: 'p-6'),
        rowVersion: 3,
        priceSnapshot: const Money(235000),
      ),
    );
    expect(put, <String, dynamic>{
      'quantity': <String, dynamic>{'value': '6.000', 'unitId': 'u-1', 'packagingId': 'p-6'},
      'priceSnapshot': <String, dynamic>{'amount': '2350.00', 'currency': 'KGS'},
      'rowVersion': 3,
      'mode': 'set',
    });
    expect(
      CartRequestDto.discount(
        const CartDiscountInput(percent: Percent(750), rowVersion: 4, overrideReason: 'постоянный'),
      ),
      <String, dynamic>{
        'percent': '7.50',
        'rowVersion': 4,
        'override': <String, dynamic>{'reason': 'постоянный'},
      },
    );
    expect(CartRequestDto.discount(const CartDiscountInput(percent: Percent(500), rowVersion: 4)), <String, dynamic>{
      'percent': '5.00',
      'rowVersion': 4,
    });
    expect(
      CartRequestDto.customer(
        'c-1',
        2,
        const Receiver(kind: ReceiverKind.otherPerson, name: 'Иван', phoneE164: '+996700123456'),
      ),
      <String, dynamic>{
        'customerId': 'c-1',
        'receiver': <String, dynamic>{'kind': 'other_person', 'name': 'Иван', 'phone': '+996700123456'},
        'rowVersion': 2,
      },
    );
    expect(CartRequestDto.park(5, ''), <String, dynamic>{'rowVersion': 5});
  });
}
