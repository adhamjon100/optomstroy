// ADR-085: ручные freezed-DTO сверяются с contracts/openapi/pos-api.v1.yaml —
// набор JSON-ключей DTO == properties схемы, required-поля обязательны в DTO.
// YAML читается через Python (PyYAML — инструмент scripts/*.py этапа B), так как
// пакета yaml среди прямых зависимостей pubspec нет.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/network/models/api_page.dart';
import 'package:optomstroy/core/network/models/auth_token_pair.dart';
import 'package:optomstroy/core/network/models/me.dart';
import 'package:optomstroy/core/network/models/money_dto.dart';
import 'package:optomstroy/core/network/models/problem.dart';
import 'package:optomstroy/core/network/models/public_settings.dart';
import 'package:optomstroy/core/utils/money.dart';

const _script = r'''
import json, sys, yaml
spec = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
json.dump(spec["components"]["schemas"], sys.stdout, ensure_ascii=False, default=str)
''';

Map<String, Object?>? loadSchemas() {
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
  final schemas = loadSchemas();
  final skip = schemas == null ? 'нет python с PyYAML — сверка DTO невозможна' : null;

  Map<String, Object?> schema(String name, [List<String> path = const []]) {
    var node = schemas![name]! as Map<String, Object?>;
    for (final p in path) {
      node = (node['properties']! as Map<String, Object?>)[p]! as Map<String, Object?>;
    }
    return node;
  }

  void matches(
    String name,
    Map<String, Object?> json, {
    List<String> path = const [],
    Set<String> required = const {},
  }) {
    final s = schema(name, path);
    final props = (s['properties']! as Map<String, Object?>).keys.toSet();
    final where = [name, ...path].join('.');
    expect(json.keys.toSet(), props, reason: '$where: ключи DTO ≠ properties схемы');
    expect(
      ((s['required'] as List<Object?>?) ?? const []).cast<String>().toSet(),
      required,
      reason: '$where: required',
    );
  }

  test('Problem, ProblemFieldError, Problem.stepUp, Problem.onec, Warning, Money', () {
    const p = Problem(type: 't', title: 't', status: 400, code: 'VALIDATION_FAILED', requestId: 'r');
    matches('Problem', p.toJson(), required: {'type', 'title', 'status', 'code', 'requestId'});
    matches(
      'ProblemFieldError',
      const ProblemFieldError(field: 'f', message: 'm', rule: 'r').toJson(),
      required: {'field', 'message', 'rule'},
    );
    matches('Problem', const ProblemStepUp().toJson(), path: ['stepUp']);
    matches('Problem', const ProblemOnec().toJson(), path: ['onec']);
    matches(
      'Warning',
      const ApiWarning(code: 'STALE_DATA', message: 'm').toJson(),
      required: {'code', 'message'},
    );
    matches('Money', const MoneyDto(amount: '1.00').toJson(), required: {'amount', 'currency'});
  }, skip: skip);

  test('Page, AuthTokenPair', () {
    final page = const ApiPage<int>(items: [1], nextCursor: null, hasMore: false).toJson((i) => i);
    matches('Page', page, required: {'items', 'nextCursor', 'hasMore'});
    final pair = AuthTokenPair(
      accessToken: 'a',
      accessExpiresIn: 900,
      refreshToken: 'r',
      refreshExpiresAt: DateTime.utc(2026),
      sid: 's',
    );
    matches(
      'AuthTokenPair',
      pair.toJson(),
      required: {'accessToken', 'accessExpiresIn', 'refreshToken', 'refreshExpiresAt', 'sid'},
    );
  }, skip: skip);

  test('Me и вложенные схемы', () {
    const me = Me(id: 'u', kind: 'staff', status: 'active', roles: [], permissions: [], permissionsVersion: 1);
    matches('Me', me.toJson(), required: {'id', 'kind', 'status', 'roles', 'permissions', 'permissionsVersion'});
    matches('Profile', const MeProfile().toJson());
    matches('MeCustomerLink', const MeCustomerLink(status: 'none').toJson(), required: {'status'});
    matches('Settings', const UserSettings().toJson());
    matches('Settings', const ScannerSettings().toJson(), path: ['scanner']);
    matches('Settings', const PrinterSettings().toJson(), path: ['printer']);
    matches(
      'Consent',
      const Consent(kind: 'sms', version: 'v', granted: true).toJson(),
      required: {'kind', 'version', 'granted'},
    );
    matches('Me', const MeSecurity().toJson(), path: ['security']);
    matches('Me', const MeSession().toJson(), path: ['session']);
    matches('Me', const MeAppVersion().toJson(), path: ['appVersion']);
  }, skip: skip);

  test('PublicSettings и вложенные схемы', () {
    matches('PublicSettings', const PublicSettings().toJson());
    matches(
      'DeliverySlot',
      const DeliverySlot(from: '10:00', to: '14:00').toJson(),
      required: {'from', 'to'},
    );
    matches(
      'SupportContact',
      const SupportContact(kind: 'phone', value: 'v').toJson(),
      required: {'kind', 'value'},
    );
    matches('PublicSettings', const PublicFeatures().toJson(), path: ['features']);
  }, skip: skip);

  group('разбор ответов', () {
    test('Problem.tryParse / codeOf / неизвестные поля и enum-значения', () {
      final p = Problem.tryParse({
        'type': 't',
        'title': 'Цены изменились',
        'status': 422,
        'code': 'PRICE_CHANGED',
        'requestId': 'r',
        'futureField': 1,
        'limitRemaining': {'amount': '15500.00', 'currency': 'KGS'},
        'asOf': '2026-10-21T09:15:30.123Z',
        'errors': [
          {'field': 'f', 'message': 'm', 'rule': 'r'},
        ],
      })!;
      expect(p.problemCode, ProblemCode.priceChanged);
      expect(p.limitRemaining!.value, Money.fromString('15500.00'));
      expect(p.asOf, DateTime.utc(2026, 10, 21, 9, 15, 30, 123));
      expect(Problem.tryParse({'code': 'X'}), isNull, reason: 'нет обязательных полей');
      expect(Problem.tryParse('text'), isNull);
      expect(Problem.codeOf({'code': 'A'}), 'A');
      expect(Problem.codeOf(null), isNull);
      expect(const Problem(type: 't', title: 't', status: 500, code: 'NEW_CODE', requestId: 'r').problemCode, isNull);
    });

    test('Me: роли, права, toString без ПДн', () {
      final me = Me.fromJson({
        'id': 'u1',
        'kind': 'staff',
        'status': 'active',
        'roles': ['cashier', 'future_role'],
        'permissions': ['catalog.read'],
        'permissionsVersion': 3,
        'profile': {'fullName': 'Тестов Тест', 'phone': '+996555123456'},
        'customerLink': {'status': 'proposed', 'displayNameMasked': 'ОсОО «Стр***»'},
        'appVersion': {'min': '1.0.0', 'recommended': null},
      });
      expect(me.userKind, UserKind.staff);
      expect(me.userStatus, UserStatus.active);
      expect(me.roleCodes, [RoleCode.cashier]);
      expect(me.can('catalog.read'), isTrue);
      expect(me.can('users.manage'), isFalse);
      expect(me.toString(), isNot(contains('555123456')));
      expect(me.profile.toString(), 'MeProfile(***)');
      expect(me.customerLink.toString(), 'MeCustomerLink(proposed)');
    });

    test('AuthTokenPair.toString без токенов; ApiWarning; MoneyDto.of; ApiPage.fromJson', () {
      final pair = AuthTokenPair.fromJson({
        'accessToken': 'secret-a', // check-secrets: allow — фиктивный токен
        'accessExpiresIn': 900,
        'refreshToken': 'secret-r', // check-secrets: allow — фиктивный токен
        'refreshExpiresAt': '2026-10-28T00:00:00Z',
        'sid': 's',
      });
      expect(pair.toString(), 'AuthTokenPair(***)');
      expect(ApiWarning.fromJson({'code': 'STALE_DATA', 'message': 'm'}).warningCode, WarningCode.staleData);
      expect(MoneyDto.of(const Money(84250)).toJson(), {'amount': '842.50', 'currency': 'KGS'});
      final page = ApiPage<String>.fromJson({
        'items': ['a'],
        'nextCursor': 'c',
        'hasMore': true,
      }, (j) => j! as String);
      expect(page.items, ['a']);
      expect((page.nextCursor, page.hasMore), ('c', true));
      expect(ApiPage.maxLimit, 200);
      expect(
        PublicSettings.fromJson({
          'features': {'qrProvider': 'onec'},
        }).features!.qrProvider,
        'onec',
      );
    });
  });
}
