// ADR-085: общие кодеки этапа F (core/network/models/pos_common_dtos.dart) == contracts/openapi/pos-api.v1.yaml 1.1.0
// (`Page`, `Warning`, `UserRef`, `AuditMeta`, `Quantity`, `Receiver`, `Delivery`, `PrintOptions`); чтение JSON
// (core/network/dto_json.dart): деньги → тыйыны, количества → milli-units, ошибки формата — DtoFormatException.
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/network/dto_json.dart';
import 'package:optomstroy/core/network/models/pos_common_dtos.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';

import '../../../support/openapi_schemas.dart';

void main() {
  final OpenApiSchemas? api = OpenApiSchemas.load(const <String>[
    'Page',
    'Warning',
    'UserRef',
    'AuditMeta',
    'Quantity',
    'Receiver',
    'Delivery',
    'PrintOptions',
  ]);
  final String? skip = api == null ? 'нет python с PyYAML — сверка DTO невозможна' : null;

  void matches(String name, Set<String> keys, Set<String> required, {Set<String> ignored = const <String>{}}) {
    expect(<String>{...keys, ...ignored}, api!.props(name), reason: '$name: ключи ≠ properties');
    expect(required, api.required(name), reason: '$name: required ≠ схемы');
  }

  test('ключи и обязательные поля == схемы OpenAPI', () {
    matches('Page', PageDto.jsonKeys, PageDto.requiredKeys);
    matches('Warning', WarningDto.jsonKeys, WarningDto.requiredKeys);
    matches('UserRef', UserRefDto.jsonKeys, UserRefDto.requiredKeys);
    matches('AuditMeta', AuditMetaDto.jsonKeys, AuditMetaDto.requiredKeys, ignored: AuditMetaDto.ignoredKeys);
    matches('Quantity', QuantityDto.jsonKeys, QuantityDto.requiredKeys);
    matches('Receiver', ReceiverDto.jsonKeys, ReceiverDto.requiredKeys);
    matches('Delivery', DeliveryDto.jsonKeys, DeliveryDto.requiredKeys);
    matches('PrintOptions', PrintOptionsDto.jsonKeys, PrintOptionsDto.requiredKeys);
  }, skip: skip);

  test('примеры разбираются; тело Quantity — без baseValue (readOnly)', () {
    final LineQuantity q = QuantityDto.fromJson(jsonCopy(api!.example('Quantity')));
    expect((q.value, q.baseValue), (const Qty(124000), const Qty(124000)));
    expect(QuantityDto.toJson(q).containsKey('baseValue'), isFalse);
    final Delivery d = DeliveryDto.fromJson(jsonCopy(api.example('Delivery')));
    expect((d.method, d.timeFrom, d.recipientPhoneE164), (DeliveryMethod.pickup, '14:00', '+996700000001'));
    final Receiver r = ReceiverDto.fromJson(jsonCopy(api.example('Receiver')));
    expect(r.kind, ReceiverKind.customer);
    expect(WarningDto.fromJson(jsonCopy(api.example('Warning'))).code, WarningCode.staleData);
  }, skip: skip);

  test('dto_json: деньги, проценты, количества со знаком, ошибки формата', () {
    final JsonMap j = <String, dynamic>{
      'm': <String, dynamic>{'amount': '16007.50', 'currency': 'KGS'},
      'bad': <String, dynamic>{'amount': '1.005', 'currency': 'KGS'},
      'p': '5.00',
      'q': '2.500',
      'neg': '-3.250',
      'cash': '-0.50',
    };
    expect(jMoney(j, 'm'), const Money(1600750));
    expect(jMoneyAmount(j, 'cash'), const Money(-50));
    expect(jPercent(j, 'p'), const Percent(500));
    expect(jQty(j, 'q'), const Qty(2500));
    expect(jSignedQty(j, 'neg'), const Qty(-3250));
    expect(jLenientQty(<String, dynamic>{'x': 'n/a'}, 'x'), isNull);
    expect(() => jMoney(j, 'bad'), throwsA(isA<DtoFormatException>()));
    expect(() => jReqMoney(j, 'none'), throwsA(isA<DtoFormatException>()));
    expect(
      () => jReqEnum(<String, dynamic>{'s': 'unknown'}, 's', OrderStatus.tryParse),
      throwsA(isA<DtoFormatException>()),
    );
    expect(moneyJson(const Money(-84250)), <String, dynamic>{'amount': '-842.50', 'currency': 'KGS'});
  });
}
