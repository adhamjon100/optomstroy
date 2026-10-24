// RR-2: номер «клиента с карточкой 1С» в integration_test (SCR-06, auth_flow_test) совпадает с телефоном фикстуры
// 1С `customers-search.200` — её отдаёт pos-api в ONEC_MODE=fixtures, и из неё же local-stack.mjs берёт
// `AUTH_FIXTURES.customerLinked`. Расхождение (как после замены ПДн в фикстурах) ловится здесь, без живого стека.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/fixture_phones.dart';

File _fixture() {
  const String rel = 'contracts/onec/fixtures/customers-search.200.json';
  for (final String p in <String>['../$rel', rel]) {
    final File f = File(p);
    if (f.existsSync()) return f;
  }
  fail('не найдена фикстура $rel (запуск из pos-app/)');
}

void main() {
  test('kLinkedPhoneDigits = последние 9 цифр body[0].phone фикстуры customers-search.200', () {
    final Map<String, Object?> json = jsonDecode(_fixture().readAsStringSync()) as Map<String, Object?>;
    final List<Object?> body = json['body']! as List<Object?>;
    final String phone = (body.first! as Map<String, Object?>)['phone']! as String;

    expect(phone, matches(RegExp(r'^\+996\d{9}$')));
    expect(kLinkedPhoneDigits, matches(RegExp(r'^\d{9}$')));
    expect(phone.substring(phone.length - 9), kLinkedPhoneDigits);
  });
}
