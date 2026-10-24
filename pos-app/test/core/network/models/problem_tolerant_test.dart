// FQ-FND-03 (F_spec_sync §3; 08 §2.11, §4.11.2): терпимый разбор массивов объектов расширения problem+json.
// Один элемент `candidates[]` / `conflicts[]`, не являющийся объектом, не должен делать всю ошибку неразбираемой
// (иначе клиент показывает `INTERNAL` вместо кода сервера). Данные синтетические.
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/network/models/problem.dart';

Map<String, dynamic> _problem(Map<String, dynamic> extra) => <String, dynamic>{
  'type': 'https://errors.optomstroy.kg/customer-duplicate-suspected',
  'title': 'Похожий клиент уже есть',
  'status': 409,
  'code': 'CUSTOMER_DUPLICATE_SUSPECTED',
  'requestId': 'req-1',
  ...extra,
};

void main() {
  test('candidates[]: элементы не-объекты пропускаются, код ошибки сохраняется', () {
    final Problem? p = Problem.tryParse(
      _problem(<String, dynamic>{
        'candidates': <Object?>[
          <String, dynamic>{'id': 'c-1', 'name': 'ОсОО «Синтетика»'},
          'c-2',
          null,
          42,
          <String, dynamic>{'id': 'c-3'},
        ],
      }),
    );
    expect(p, isNotNull, reason: 'один неверный элемент не ломает разбор всего problem+json');
    expect(p!.code, 'CUSTOMER_DUPLICATE_SUSPECTED');
    expect(p.candidates, <Map<String, dynamic>>[
      <String, dynamic>{'id': 'c-1', 'name': 'ОсОО «Синтетика»'},
      <String, dynamic>{'id': 'c-3'},
    ]);
  });

  test('conflicts[]: так же терпимо; не массив — null; отсутствует — null', () {
    final Problem? p = Problem.tryParse(
      _problem(<String, dynamic>{
        'conflicts': <Object?>[
          'bad',
          <String, dynamic>{'variantId': 'v-1', 'kind': 'price_changed'},
        ],
        'candidates': 'not-a-list',
      }),
    );
    expect(p, isNotNull);
    expect(p!.conflicts, <Map<String, dynamic>>[
      <String, dynamic>{'variantId': 'v-1', 'kind': 'price_changed'},
    ]);
    expect(p.candidates, isNull);
    expect(Problem.tryParse(_problem(const <String, dynamic>{}))!.candidates, isNull);
  });
}
