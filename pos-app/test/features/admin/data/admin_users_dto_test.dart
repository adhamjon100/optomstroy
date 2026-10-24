// ADR-085: ручной разбор DTO фичи admin сверяется с contracts/openapi/pos-api.v1.yaml —
// поля, которые читает/пишет клиент, существуют в схеме; обязательные поля схемы читаются;
// тела запросов не содержат лишних ключей (additionalProperties: false) и содержат required.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/features/admin/data/users/admin_users_dto.dart';
import 'package:optomstroy/features/admin/domain/users/emergency_login_code.dart';
import 'package:optomstroy/features/admin/domain/users/invitation.dart';

const _script = r'''
import json, sys, yaml
spec = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
json.dump(spec["components"]["schemas"], sys.stdout, ensure_ascii=False, default=str)
''';

Map<String, Object?>? _loadSchemas() {
  for (final python in ['python', 'python3', 'py']) {
    try {
      final r = Process.runSync(python, [
        '-I',
        '-X',
        'utf8',
        '-c',
        _script,
        '../contracts/openapi/pos-api.v1.yaml',
      ], stdoutEncoding: utf8);
      if (r.exitCode == 0) return jsonDecode(r.stdout as String) as Map<String, Object?>;
    } on ProcessException {
      continue;
    }
  }
  return null;
}

void main() {
  final schemas = _loadSchemas();
  final skip = schemas == null ? 'нет python с PyYAML — сверка DTO невозможна' : null;

  /// properties и required схемы (с разворотом allOf).
  (Set<String>, Set<String>) shape(String name) {
    final props = <String>{};
    final req = <String>{};
    void walk(Map<String, Object?> node) {
      final ref = node[r'$ref'];
      if (ref is String) walk(schemas![ref.split('/').last]! as Map<String, Object?>);
      for (final part in (node['allOf'] as List<Object?>?) ?? const []) {
        walk(part! as Map<String, Object?>);
      }
      props.addAll(((node['properties'] as Map<String, Object?>?) ?? const {}).keys);
      req.addAll(((node['required'] as List<Object?>?) ?? const []).cast<String>());
    }

    walk(schemas![name]! as Map<String, Object?>);
    return (props, req);
  }

  void readsWithin(String schema, Set<String> read) {
    final (props, required) = shape(schema);
    expect(props.containsAll(read), isTrue, reason: '$schema: лишние поля ${read.difference(props)}');
    expect(read.containsAll(required), isTrue, reason: '$schema: не читаются required ${required.difference(read)}');
  }

  void bodyWithin(String schema, Set<String> body) {
    final (props, required) = shape(schema);
    expect(props.containsAll(body), isTrue, reason: '$schema: ключи вне схемы ${body.difference(props)}');
    expect(body.containsAll(required), isTrue, reason: '$schema: нет required ${required.difference(body)}');
  }

  test('ответы: читаемые поля есть в схемах', () {
    readsWithin('AdminUser', {
      'id',
      'kind',
      'status',
      'phoneMasked',
      'fullName',
      'roles',
      'permissionsVersion',
      'lastLoginAt',
      'devicesCount',
      'createdAt',
      'invitation',
      'rowVersion',
    });
    readsWithin('Invitation', {
      'id',
      'phoneMasked',
      'roles',
      'status',
      'createdBy',
      'createdAt',
      'expiresAt',
      'acceptedAt',
      'appliedToUserId',
    });
    readsWithin('AdminEmergencyLoginCode', {'code', 'expiresAt', 'phoneMasked'});
    readsWithin('CustomerLink', {'id', 'customerId', 'status', 'userId', 'matchedBy', 'createdAt'});
    readsWithin('CustomersLinkUser', {'id', 'displayName', 'phoneMasked'});
    readsWithin('CustomerPhone', {'value', 'verified'});
    readsWithin('AuthStepUpToken', {'stepUpToken', 'expiresAt', 'method', 'scope'});
    readsWithin('AuthOtpChallengeIssued', {'challengeId', 'resendAfterSec', 'otpTtlSec'});
    readsWithin('Page', {'items', 'nextCursor', 'hasMore', 'totalEstimate'});
    final (customer, _) = shape('CustomersListItem');
    expect(customer.containsAll({'id', 'name', 'displayName', 'inn', 'phones', 'onecCode', 'links'}), isTrue);
  }, skip: skip);

  test('тела запросов: ключи по схемам, required присутствуют', () {
    bodyWithin(
      'AdminInvitationsCreateRequest',
      AdminUsersDto.invitationRequest(
        InvitationDraft(
          phoneE164: '+996700000007',
          role: RoleCode.seller,
          fullName: 'Асан',
          expiresAt: DateTime(2026, 11, 21),
        ),
      ).keys.toSet(),
    );
    bodyWithin(
      'AdminInvitationsCreateRequest',
      AdminUsersDto.invitationRequest(
        const InvitationDraft(phoneE164: '+996700000007', role: RoleCode.seller),
      ).keys.toSet(),
    );
    // Тела, которые формирует DioAdminUsersRepository (точные значения — dio_admin_users_repository_test.dart).
    bodyWithin('AdminUsersRolesSetRequest', {'roles', 'reason', 'rowVersion'});
    bodyWithin('AdminUsersBlockRequest', {'blocked', 'reason'});
    bodyWithin('AdminUsersPinResetRequest', {'reason'});
    bodyWithin('AdminUsersEmergencyLoginCodeRequest', {'reason', 'comment'});
    bodyWithin('AdminUsersEmergencyLoginCodeRequest', {'reason'});
    bodyWithin('AdminUsersCreateRequest', {'phone', 'fullName', 'roles'});
    bodyWithin('CustomersLinkConfirmRequest', {'comment'});
    bodyWithin('CustomersLinkRejectRequest', {'comment'});
    bodyWithin('AuthStepUpRequest', {'method', 'pin', 'operation'});
    bodyWithin('AuthStepUpRequest', {'method', 'operation', 'challengeId', 'code'});
  }, skip: skip);

  test('enum-значения клиента совпадают с контрактом', () {
    final reasons =
        ((schemas!['AdminUsersEmergencyLoginCodeRequest']! as Map<String, Object?>)['properties']!
                as Map<String, Object?>)['reason']!
            as Map<String, Object?>;
    expect((reasons['enum']! as List<Object?>).toSet(), {for (final r in EmergencyCodeReason.values) r.value});
    final ops = ((schemas['StepUpOperation']! as Map<String, Object?>)['enum']! as List<Object?>).toSet();
    expect(
      ops.containsAll({
        'users.roles.assign',
        'users.manage',
        'users.pin.reset',
        'users.emergency_code.issue',
        'session.revoke.any',
        'invitations.manage',
        'customer.link.resolve',
      }),
      isTrue,
    );
  }, skip: skip);
}
