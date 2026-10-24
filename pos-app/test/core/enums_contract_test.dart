// AC-RM-C-004 п. 1 / AC-RM-B-009: core/enums.dart (сгенерирован scripts/gen_enums.py)
// совпадает с contracts/enums.json — каждый перечень, значения и их порядок,
// HTTP-статусы кодов ошибок, реестры dbEnumValues/checkListValues, хеш источника.
// Регенерация: python -I -X utf8 scripts/gen_enums.py --out <tmp> → <tmp>/enums.dart
// копируется в pos-app/lib/core/enums.dart (pos-app/lib/core/README.md).
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';

/// Имя перечня в enums.json → значения сгенерированного Dart-enum.
final Map<String, Iterable<String>> dartEnums = {
  'user_kind': UserKind.values.map((e) => e.value),
  'user_status': UserStatus.values.map((e) => e.value),
  'role_code': RoleCode.values.map((e) => e.value),
  'customer_link_status': CustomerLinkStatus.values.map((e) => e.value),
  'cart_status': CartStatus.values.map((e) => e.value),
  'order_status': OrderStatus.values.map((e) => e.value),
  'delivery_method': DeliveryMethod.values.map((e) => e.value),
  'receiver_kind': ReceiverKind.values.map((e) => e.value),
  'payment_method': PaymentMethod.values.map((e) => e.value),
  'payment_status': PaymentStatus.values.map((e) => e.value),
  'return_request_status': ReturnRequestStatus.values.map((e) => e.value),
  'transaction_kind': TransactionKind.values.map((e) => e.value),
  'sync_entity': SyncEntity.values.map((e) => e.value),
  'sync_mode': SyncMode.values.map((e) => e.value),
  'sync_run_status': SyncRunStatus.values.map((e) => e.value),
  'outbox_status': OutboxStatus.values.map((e) => e.value),
  'notification_kind': NotificationKind.values.map((e) => e.value),
  'invitation_status': InvitationStatus.values.map((e) => e.value),
  'device_platform': DevicePlatform.values.map((e) => e.value),
  'session_kind': SessionKind.values.map((e) => e.value),
  'step_up_method': StepUpMethod.values.map((e) => e.value),
  'otp_purpose': OtpPurpose.values.map((e) => e.value),
  'otp_status': OtpStatus.values.map((e) => e.value),
  'consent_kind': ConsentKind.values.map((e) => e.value),
  'attribute_value_type': AttributeValueType.values.map((e) => e.value),
  'barcode_type': BarcodeType.values.map((e) => e.value),
  'image_status': ImageStatus.values.map((e) => e.value),
  'customer_source': CustomerSource.values.map((e) => e.value),
  'customer_type': CustomerType.values.map((e) => e.value),
  'customer_onec_status': CustomerOnecStatus.values.map((e) => e.value),
  'contact_kind': ContactKind.values.map((e) => e.value),
  'link_match_method': LinkMatchMethod.values.map((e) => e.value),
  'discount_source': DiscountSource.values.map((e) => e.value),
  'discount_kind': DiscountKind.values.map((e) => e.value),
  'status_change_source': StatusChangeSource.values.map((e) => e.value),
  'transaction_source': TransactionSource.values.map((e) => e.value),
  'return_reason': ReturnReason.values.map((e) => e.value),
  'sync_trigger': SyncTrigger.values.map((e) => e.value),
  'outbox_aggregate': OutboxAggregate.values.map((e) => e.value),
  'idempotency_status': IdempotencyStatus.values.map((e) => e.value),
  'audit_level': AuditLevel.values.map((e) => e.value),
  'print_document_kind': PrintDocumentKind.values.map((e) => e.value),
  'print_job_status': PrintJobStatus.values.map((e) => e.value),
  'sms_status': SmsStatus.values.map((e) => e.value),
  'onec_sync_state': OnecSyncState.values.map((e) => e.value),
  'locale': Locale.values.map((e) => e.value),
  'invitation_role': InvitationRole.values.map((e) => e.value),
  'session_revoke_reason': SessionRevokeReason.values.map((e) => e.value),
  'token_kind': TokenKind.values.map((e) => e.value),
  'token_deny_reason': TokenDenyReason.values.map((e) => e.value),
  'rate_limit_scope': RateLimitScope.values.map((e) => e.value),
  'integration_token_scope': IntegrationTokenScope.values.map((e) => e.value),
  'integration_token_source': IntegrationTokenSource.values.map((e) => e.value),
  'integration_token_revoke_reason': IntegrationTokenRevokeReason.values.map((e) => e.value),
  'receivable_document_kind': ReceivableDocumentKind.values.map((e) => e.value),
  'receivable_document_status': ReceivableDocumentStatus.values.map((e) => e.value),
  'review_reason': ReviewReason.values.map((e) => e.value),
  'cancel_reason_code': CancelReasonCode.values.map((e) => e.value),
  'refund_intent': RefundIntent.values.map((e) => e.value),
  'order_created_via': OrderCreatedVia.values.map((e) => e.value),
  'qr_provider_mode': QrProviderMode.values.map((e) => e.value),
  'return_onec_result': ReturnOnecResult.values.map((e) => e.value),
  'return_approval_reason': ReturnApprovalReason.values.map((e) => e.value),
  'notification_severity': NotificationSeverity.values.map((e) => e.value),
  'sync_error_code': SyncErrorCode.values.map((e) => e.value),
  'sync_error_severity': SyncErrorSeverity.values.map((e) => e.value),
  'outbox_operation': OutboxOperation.values.map((e) => e.value),
  'audit_result': AuditResult.values.map((e) => e.value),
  'audit_severity': AuditSeverity.values.map((e) => e.value),
  'setting_value_type': SettingValueType.values.map((e) => e.value),
  'customer_stock_display': CustomerStockDisplay.values.map((e) => e.value),
  'print_paper': PrintPaper.values.map((e) => e.value),
  'sms_template_key': SmsTemplateKey.values.map((e) => e.value),
  'sms_provider': SmsProvider.values.map((e) => e.value),
  'credit_reason': CreditReason.values.map((e) => e.value),
  'warning_code': WarningCode.values.map((e) => e.value),
  'problem_resource': ProblemResource.values.map((e) => e.value),
  'problem_code': ProblemCode.values.map((e) => e.value),
};

Map<String, Object?> loadContract() =>
    jsonDecode(File('../contracts/enums.json').readAsStringSync()) as Map<String, Object?>;

List<Map<String, Object?>> group(Map<String, Object?> json, String key) =>
    (json[key]! as List<Object?>).cast<Map<String, Object?>>();

List<String> values(Map<String, Object?> e) => (e['values']! as List<Object?>).cast<String>();

/// Канонический JSON как в gen_enums.py: json.dumps(sort_keys=True, ensure_ascii=False, separators=(',', ':')).
String canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${canonical(value[k])}').join(',')}}';
  }
  if (value is List) return '[${value.map(canonical).join(',')}]';
  return jsonEncode(value);
}

void main() {
  final contract = loadContract();

  test('версия контракта и sha256 источника совпадают с заголовком enums.dart', () {
    expect(enumsContractVersion, contract['version']);
    final digest = sha256.convert(utf8.encode(canonical(contract))).toString();
    final header = File('lib/core/enums.dart').readAsLinesSync()[1];
    expect(header, contains('sha256 $digest'), reason: 'enums.dart устарел — перегенерируйте gen_enums.py');
  });

  test('каждый перечень enums.json есть в Dart с теми же значениями и порядком', () {
    final names = <String>{};
    for (final key in ['dbEnums', 'checkLists', 'apiEnums']) {
      for (final e in group(contract, key)) {
        final name = e['name']! as String;
        names.add(name);
        expect(dartEnums.containsKey(name), isTrue, reason: 'нет Dart-enum для $name');
        expect(dartEnums[name]!.toList(), values(e), reason: name);
      }
    }
    names.add('problem_code');
    expect(dartEnums.keys.toSet(), names, reason: 'лишние/недостающие перечни');
  });

  test('ProblemCode: коды и HTTP-статусы 08 §2.4', () {
    final codes = group(contract, 'problemCodes');
    expect(ProblemCode.values.map((e) => e.value).toList(), [for (final c in codes) c['code']]);
    for (final c in codes) {
      final code = ProblemCode.tryParse(c['code']! as String)!;
      expect(code.httpStatuses, (c['http']! as List<Object?>).cast<int>(), reason: code.value);
    }
  });

  test('реестры dbEnumValues и checkListValues', () {
    expect(dbEnumValues, {for (final e in group(contract, 'dbEnums')) e['name']: values(e)});
    final checks = <String, List<String>>{
      for (final e in group(contract, 'checkLists'))
        for (final column in (e['columns']! as List<Object?>).cast<String>()) column: values(e),
    };
    expect(checkListValues, checks);
  });

  test('tryParse: известное значение и неизвестное (совместимость вперёд)', () {
    expect(PaymentStatus.tryParse('qr_shown'), PaymentStatus.qrShown);
    expect(PaymentStatus.tryParse('future_status'), isNull);
    expect(ProblemCode.tryParse(null), isNull);
  });
}
