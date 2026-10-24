// Этап G (основа), ADR-085: общие DTO `Transaction`, `TransactionRelated`, `AuditRow` (core/network/models) ==
// contracts/openapi/pos-api.v1.yaml 1.2.0; синтетические примеры схем разбираются; период журналов ≤ 366 дней.
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/models/audit_record.dart';
import 'package:optomstroy/core/models/journal_period.dart';
import 'package:optomstroy/core/models/transaction.dart';
import 'package:optomstroy/core/network/models/transaction_dtos.dart';
import 'package:optomstroy/core/utils/money.dart';

import '../../../support/openapi_schemas.dart';

void main() {
  final OpenApiSchemas? api = OpenApiSchemas.load(const <String>['Transaction', 'TransactionRelated', 'AuditRow']);
  final String? skip = api == null ? 'нет python с PyYAML — сверка DTO невозможна' : null;

  void matches(String name, Set<String> keys, Set<String> required) {
    expect(keys, api!.props(name), reason: '$name: ключи DTO ≠ properties');
    expect(required, api.required(name), reason: '$name: required DTO ≠ required схемы');
  }

  test('ключи и обязательные поля == схемы OpenAPI 1.2.0', () {
    matches('Transaction', TransactionDto.jsonKeys, TransactionDto.requiredKeys);
    matches('TransactionRelated', TransactionRelatedDto.jsonKeys, TransactionRelatedDto.requiredKeys);
    matches('AuditRow', AuditRowDto.jsonKeys, AuditRowDto.requiredKeys);
  }, skip: skip);

  test('примеры схем разбираются: деньги — тыйыны, перечисления — enums.dart', () {
    final Transaction t = TransactionDto.fromJson(jsonCopy(api!.example('Transaction')));
    expect(t.amount, isA<Money>());
    expect(t.kind, isNotNull);
    expect(t.related, isNotEmpty);
    expect(t.related.first.type, isNotNull);
    final AuditRecord a = AuditRowDto.fromJson(jsonCopy(api.example('AuditRow')));
    expect(a.result, AuditResult.ok);
    expect(a.chainOk, isTrue);
  }, skip: skip);

  test('знак суммы и неизвестные значения перечислений (совместимость вперёд)', () {
    final Transaction t = TransactionDto.fromJson(<String, dynamic>{
      'id': 't1',
      'kind': 'future_kind',
      'number': 'T-1',
      'occurredAt': '2026-10-24T09:00:00Z',
      'amount': <String, dynamic>{'amount': '150.50', 'currency': 'KGS'},
      'sign': '-',
      'status': 'voided',
      'statusGroup': 'voided',
      'related': <Object?>[
        <String, dynamic>{'type': 'unknown_doc'},
      ],
    });
    expect(t.kind, isNull);
    expect(t.signedAmount, const Money(-15050));
    expect(t.statusGroup, TransactionStatusGroup.voided);
    expect(t.related.single.type, isNull);
  });

  test('JournalPeriod: не длиннее 366 дней и не наоборот (RM-G-011 п. 5)', () {
    final DateTime from = DateTime.utc(2026);
    expect(JournalPeriod.tryCreate(from, from.add(const Duration(days: 366))), isNotNull);
    expect(JournalPeriod.tryCreate(from, from.add(const Duration(days: 367))), isNull);
    expect(JournalPeriod.tryCreate(from, from.subtract(const Duration(seconds: 1))), isNull);
  });
}
